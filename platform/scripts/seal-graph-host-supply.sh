#!/usr/bin/env bash
#
# Seal the graph host's Python supply for one target architecture.
#
#   <supply-root>/regent-graph-host-<arch>-<yyyymmdd>/
#     UV-CACHE.tar         the packages graph_host/uv.lock pins, as a uv cache,
#                          under a uv-cache/ prefix
#     PYTHON-CACHE.tar     the standalone CPython archive graph_host/.python-version
#                          names, under a python-cache/ prefix
#     SUPPLY-ADDENDUM.txt  the checksums build-release-context.sh holds them to
#
# This is the sealing step, run by a person, and unlike the release build it
# reaches the network. It runs the same uv install as the Dockerfile's
# graph-host stage, in a container of the target architecture made from the
# same pinned images, so the caches hold what that stage asks for. The inputs
# are the graph host's locked project files only: pyproject.toml, uv.lock,
# .python-version and the source uv builds the project from.
#
# Before anything is published, the sealed archives are unpacked into a fresh
# directory and the install is run again from them alone, with the network
# off. A supply is sealed once: an existing destination is refused, never
# replaced.
#
# Usage: scripts/seal-graph-host-supply.sh <arch> [supply-root]

set -euo pipefail

readonly DEFAULT_SUPPLY_ROOT="/Users/sean/Documents/regent/archive/release-supply"

usage() {
  printf 'usage: %s <arch> [supply-root]\n' "${0##*/}" >&2
  printf '       arch is arm64 or amd64\n' >&2
  exit 2
}

die() {
  printf 'refusing: %s\n' "$1" >&2
  exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage

arch="$1"
supply_root="${2:-$DEFAULT_SUPPLY_ROOT}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
graph_host="$repo_root/graph_host"

case "$arch" in
  arm64) triple="aarch64-unknown-linux-gnu" ;;
  amd64) triple="x86_64-unknown-linux-gnu" ;;
  *) usage ;;
esac

supply_name="regent-graph-host-$arch-$(date -u +%Y%m%d)"
destination="$supply_root/$supply_name"
[ ! -e "$destination" ] || die "$destination already exists; a sealed supply is never replaced"

# The builder and uv images are the ones the Dockerfile pins, read from it so
# the two can never drift apart.
pinned_image() {
  local stage="$1" image
  image="$(awk -v stage="$stage" \
    '$1 == "FROM" && $3 == "AS" && $4 == stage { print $2; exit }' "$repo_root/Dockerfile")"
  [ -n "$image" ] || die "the Dockerfile pins no $stage image"
  printf '%s' "$image"
}

builder_image="$(pinned_image native)"
uv_image="$(pinned_image uv)"
python_version="$(tr -d '[:space:]' <"$graph_host/.python-version")"
[ -n "$python_version" ] || die "graph_host/.python-version is empty"

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/seal-graph-host.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf -- "$work"' EXIT

mkdir -p "$work/project" "$work/out" "$work/check" "$work/uv"
install -m 0644 "$graph_host/pyproject.toml" "$graph_host/uv.lock" \
  "$graph_host/.python-version" "$work/project/"
rsync -a --exclude '__pycache__/' "$graph_host/src/" "$work/project/src/"

printf 'fetching uv for linux/%s from %s\n' "$arch" "$uv_image"
uv_container="$(docker create --platform "linux/$arch" "$uv_image")"
docker cp "$uv_container:/uv" "$work/uv/uv" >/dev/null
docker rm "$uv_container" >/dev/null

# The same environment as the Dockerfile's graph-host stage, pointed at
# directories this script collects. It runs as root, as that stage does, and
# hands the caches back to whoever runs this script. The project is copied
# inside so the mounted inputs stay read-only. Arguments after the cache
# directory go to docker run.
install_graph_host() {
  local caches="$1"
  shift
  docker run --rm --platform "linux/$arch" "$@" \
    -e OWNER="$(id -u):$(id -g)" \
    -e UV_CACHE_DIR=/caches/uv-cache \
    -e UV_PYTHON_CACHE_DIR=/caches/python-cache \
    -e UV_PYTHON_INSTALL_DIR=/tmp/python \
    -e UV_PYTHON_PREFERENCE=only-managed \
    -e UV_PROJECT_ENVIRONMENT=/tmp/venv \
    -e UV_LINK_MODE=copy \
    -v "$work/project:/project:ro" \
    -v "$work/uv:/uvbin:ro" \
    -v "$caches:/caches" \
    "$builder_image" \
    sh -euc 'cp -R /project /tmp/graph_host && cd /tmp/graph_host &&
      /uvbin/uv python install && /uvbin/uv sync --frozen --no-dev --no-editable &&
      /tmp/venv/bin/python -I -c "import keyfleet_graph.host" &&
      chown -R "$OWNER" /caches'
}

printf 'installing the graph host for linux/%s from the network\n' "$arch"
install_graph_host "$work/out"

python_archive="$(cd "$work/out/python-cache" && ls)"
case "$python_archive" in
  *$'\n'*) die "python-cache holds more than one archive: $python_archive" ;;
  *"cpython-$python_version-"*"-$triple-"*) ;;
  *) die "python-cache holds $python_archive, not CPython $python_version for $triple" ;;
esac

printf 'sealing\n'
mkdir -p "$work/sealed"
tar -cf "$work/sealed/UV-CACHE.tar" -C "$work/out" uv-cache
tar -cf "$work/sealed/PYTHON-CACHE.tar" -C "$work/out" python-cache

printf 'installing again from the sealed archives alone, with the network off\n'
tar -xf "$work/sealed/UV-CACHE.tar" -C "$work/check"
tar -xf "$work/sealed/PYTHON-CACHE.tar" -C "$work/check"
install_graph_host "$work/check" --network none -e UV_OFFLINE=1

cat >"$work/sealed/SUPPLY-ADDENDUM.txt" <<EOF
uv_lock_sha256=$(sha256_of "$graph_host/uv.lock")
uv_cache_sha256=$(sha256_of "$work/sealed/UV-CACHE.tar")
python_archive=$python_archive
python_cache_sha256=$(sha256_of "$work/sealed/PYTHON-CACHE.tar")
python_version=$python_version
arch=$arch
builder_image=$builder_image
uv_image=$uv_image
EOF

mkdir -p "$supply_root"
mv "$work/sealed" "$destination"

printf 'sealed: %s\n' "$destination"
cat "$destination/SUPPLY-ADDENDUM.txt"
printf 'scripts/build-release-context.sh reads this supply once it names it:\n'
printf '  readonly %s_GRAPH_HOST_SUPPLY="%s"\n' "$(printf '%s' "$arch" | tr '[:lower:]' '[:upper:]')" \
  "$supply_name"

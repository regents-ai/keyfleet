#!/usr/bin/env bash
#
# Assemble the parent build context that Dockerfile.dockerignore describes.
#
#   <context>/
#     platform/                    this platform at its checked-out commit
#     elixir-utils/privy/          the shared libraries mix.exs resolves by path,
#     elixir-utils/agent_access/   each taken from its repository at the commit
#     elixir-utils/siwa/siwa-elixir/apps/siwa/   shared-libs.lock pins
#     regents/identity/
#     design-system/regent_ui/
#     uv-cache/                    the graph host's locked packages, as a uv cache
#     python-cache/                the standalone CPython archive uv installs from
#     BUILD-INPUTS.txt             the commits and supply the context was made from
#
# Every source tree is exported from a commit with git archive, never copied
# from a working tree, so the same pins always give the same context. This
# platform is exported at its last commit: uncommitted changes are left out. Mix and
# npm packages are not in the context: the image build fetches them from
# mix.lock and package-lock.json, which hold every package's checksum. The graph
# host's Python supply is sealed ahead of time by seal-graph-host-supply.sh and
# is checked against its manifest here before anything is assembled.
#
# The graph host supply is architecture-specific, so the context is built for
# one target architecture: arm64 or amd64. Fly runs amd64.
#
# Usage: scripts/build-release-context.sh <destination> <arch> [supply-root]

set -euo pipefail

readonly DEFAULT_SUPPLY_ROOT="/Users/sean/Documents/regent/archive/release-supply"
readonly ARM64_GRAPH_HOST_SUPPLY="regent-graph-host-arm64-20260926"
readonly AMD64_GRAPH_HOST_SUPPLY="regent-graph-host-amd64-20260926"

usage() {
  printf 'usage: %s <destination> <arch> [supply-root]\n' "${0##*/}" >&2
  printf '       arch is arm64 or amd64\n' >&2
  exit 2
}

die() {
  printf 'refusing: %s\n' "$1" >&2
  exit 1
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage

destination="$1"
arch="$2"
supply_root="${3:-$DEFAULT_SUPPLY_ROOT}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
siblings="${REGENT_DEPS_ROOT:-$(cd -- "$repo_root/../.." && pwd)}"

case "$arch" in
  arm64)
    native_triple="aarch64-unknown-linux-gnu"
    graph_host_supply_dir="$ARM64_GRAPH_HOST_SUPPLY"
    ;;
  amd64)
    native_triple="x86_64-unknown-linux-gnu"
    graph_host_supply_dir="$AMD64_GRAPH_HOST_SUPPLY"
    ;;
  *) usage ;;
esac

graph_host_supply="$supply_root/$graph_host_supply_dir"
graph_host_addendum="$graph_host_supply/SUPPLY-ADDENDUM.txt"

[ -e "$graph_host_addendum" ] || die "missing supply input: $graph_host_addendum"

platform_revision="$(git -C "$repo_root" rev-parse HEAD)"

if [ -n "$(git -C "$repo_root" status --porcelain -- .)" ]; then
  printf 'warning: uncommitted changes are left out; the context is built from %s\n' \
    "$platform_revision" >&2
fi

# mix.lock cannot pin a path dependency, so the shared libraries' commits are
# pinned in shared-libs.lock, read here as committed. Each repository must hold
# its pinned commit; any checkout or worktree of it will do, whatever it has
# checked out.
pins="$(git -C "$repo_root" show "$platform_revision:./shared-libs.lock" | grep -v '^#')" ||
  die "shared-libs.lock is not committed at $platform_revision"

while read -r repository revision _folders; do
  git -C "$siblings/$repository" cat-file -e "$revision^{commit}" 2>/dev/null ||
    die "$siblings/$repository does not hold commit $revision"
done <<<"$pins"

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# Reads a manifest key into a named variable rather than returning it, so that
# a missing or empty key stops the script instead of a subshell.
read_manifest_value() {
  local target="$1" file="$2" key="$3" value
  value="$(awk -v key="$key" \
    'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$file")"
  [ -n "$value" ] || die "manifest $file has no $key"
  printf -v "$target" '%s' "$value"
}

expect_contains() {
  local label="$1" value="$2" needle="$3"
  case "$value" in
    *"$needle"*) printf '  verified %s\n' "$label" ;;
    *) die "$label -- the manifest disagrees
  expected to name: $needle
  manifest says:    $value" ;;
  esac
}

expect_sha256() {
  local label="$1" path="$2" expected="$3" actual
  [ -f "$path" ] || die "missing supply input: $path"
  actual="$(sha256_of "$path")"
  [ "$actual" = "$expected" ] ||
    die "$label does not match its manifest
  path:     $path
  expected: $expected
  actual:   $actual"
  printf '  verified %s\n' "$label"
}

printf 'verifying the graph host supply\n'

# The graph host's packages are the ones its lockfile pins, and its interpreter
# is the standalone CPython build for this architecture.
read_manifest_value uv_lock_sha256 "$graph_host_addendum" uv_lock_sha256
committed_uv_lock_sha256="$(git -C "$repo_root" show "$platform_revision:./graph_host/uv.lock" |
  shasum -a 256 | cut -d' ' -f1)" || die "graph_host/uv.lock is not committed at $platform_revision"
[ "$committed_uv_lock_sha256" = "$uv_lock_sha256" ] ||
  die "graph_host/uv.lock at $platform_revision is not the one $graph_host_supply_dir was sealed from"
printf '  verified graph_host/uv.lock against the uv cache\n'

read_manifest_value uv_cache_sha256 "$graph_host_addendum" uv_cache_sha256
expect_sha256 "UV-CACHE.tar" "$graph_host_supply/UV-CACHE.tar" "$uv_cache_sha256"

read_manifest_value python_archive "$graph_host_addendum" python_archive
read_manifest_value python_cache_sha256 "$graph_host_addendum" python_cache_sha256
expect_contains "$python_archive is built for $arch" "$python_archive" "$native_triple"
expect_sha256 "PYTHON-CACHE.tar" "$graph_host_supply/PYTHON-CACHE.tar" "$python_cache_sha256"

printf 'assembling context at %s\n' "$destination"

mkdir -p "$(dirname -- "$destination")"
staging="$(mktemp -d "${destination%/}.staging.XXXXXX")"
trap 'chmod -R u+w "$staging" 2>/dev/null || true; rm -rf -- "$staging"' EXIT

# Exports <paths> of <repository> at <commit> into <directory>. Anything shaped
# like a secrets file is left out, at any depth and in any case.
export_tree() {
  local repository="$1" revision="$2" directory="$3"
  shift 3
  mkdir -p "$directory"
  git -C "$repository" archive --format=tar "$revision" -- "$@" \
    ':(exclude,glob,icase)**/.env*' | tar -x -C "$directory"
}

export_tree "$repo_root" "$platform_revision" "$staging/platform" .
build_inputs="keyfleet=$platform_revision"

while read -r repository revision folders; do
  read -ra paths <<<"$folders"
  export_tree "$siblings/$repository" "$revision" "$staging/$repository" "${paths[@]}"
  build_inputs+=$'\n'"$repository=$revision"
done <<<"$pins"

# These archives carry the uv-cache/ and python-cache/ prefixes.
tar -xf "$graph_host_supply/UV-CACHE.tar" -C "$staging"
[ -d "$staging/uv-cache" ] || die "UV-CACHE.tar did not yield uv-cache/"
tar -xf "$graph_host_supply/PYTHON-CACHE.tar" -C "$staging"
[ -f "$staging/python-cache/$python_archive" ] ||
  die "PYTHON-CACHE.tar did not yield python-cache/$python_archive"

install -m 0644 "$staging/platform/Dockerfile" "$staging/Dockerfile"
install -m 0644 "$staging/platform/Dockerfile.dockerignore" "$staging/Dockerfile.dockerignore"

cat >"$staging/BUILD-INPUTS.txt" <<EOF
arch=$arch
$build_inputs
graph-host-supply=$graph_host_supply_dir
EOF

# Last look before anything is published, covering the sealed payloads the
# export filter never sees. It runs while the previous destination is still
# intact, so a refusal leaves that one in place. Paths only, never contents.
offender="$(find "$staging" -iname '.env*' -print -quit)" || die "context scan failed"
[ -z "$offender" ] || die "context contains a secrets-shaped file: $offender"

if [ -e "$destination" ]; then
  chmod -R u+w "$destination"
  rm -rf -- "$destination"
fi
mv "$staging" "$destination"
trap - EXIT

printf 'context ready: %s\n' "$destination"
cat "$destination/BUILD-INPUTS.txt"
printf 'build with:\n'
printf '  docker build --platform linux/%s \\\n' "$arch"
printf '    -f %s/Dockerfile -t <tag> %s\n' "$destination" "$destination"
printf 'or deploy with Fly'"'"'s remote builder (amd64 only; fly.staging.toml for staging):\n'
printf '  fly deploy %s --config %s/platform/fly.toml \\\n' "$destination" "$destination"
printf '    --dockerfile %s/Dockerfile --ignorefile %s/Dockerfile.dockerignore \\\n' \
  "$destination" "$destination"
printf '    --remote-only --ha=false\n'

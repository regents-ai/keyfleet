#!/usr/bin/env bash
# Runs the OWASP ZAP baseline scan against the copy of the release local.sh
# starts on this computer: ZAP's spider walks the site for a few minutes and
# its passive rules read every answer. It sends no attacks, but it is still a
# crawl, so it scans only an address on this computer, and it refuses
# keyfleet.ai, its subdomains and the production Fly app by name as well.
#
#   platform/load/local.sh zap                         # starts the copy, scans it, removes it
#   platform/load/zap-baseline.sh <url> [output-dir]   # a copy already running here
#   platform/load/zap-baseline.sh http://localhost:4100
#
# The rules in zap-rules.tsv (beside this script) mark each finding the code
# shows is intended as IGNORE, with its reason, and make a cookie without
# HttpOnly, Secure or SameSite a failure. Every other rule warns.
#
# ZAP runs in Docker, so it reaches the address through host.docker.internal,
# with X-Forwarded-Proto: https on every request, as Fly's proxy sends it in
# production: the release otherwise redirects every request for that host
# name to https (force_ssl in config/prod.exs exempts only localhost and
# 127.0.0.1), and the answers it reads are the ones production gives.
#
# Writes report.html, report.json and zap.log to the output directory
# (default platform/load/zap-<host>-<UTC time>/). Exit status: 0 when no rule
# failed (warnings are listed and stay in the report), 1 when a FAIL rule
# fired, 3 when the scan itself could not run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
image="zaproxy/zap-stable:latest"

die() {
  echo "zap-baseline: $1" >&2
  exit 3
}

[[ $# -ge 1 && $# -le 2 ]] || die "usage: $0 <url> [output-dir]"
target="$1"

[[ $target =~ ^https?://[^/]+ ]] || die "the address must start with http:// or https://"

# The host, without scheme, user, port, path or a trailing dot, in lower case.
host="${target#*://}"
host="${host%%/*}"
host="${host%%\?*}"
host="${host%%#*}"
host="${host##*@}"
if [[ $host == \[* ]]; then
  host="${host%%]*}]"
else
  host="${host%%:*}"
fi
host="$(tr '[:upper:]' '[:lower:]' <<<"${host%.}")"

# The whole address is checked too, so no spelling the parse above misses
# (a fragment, an escaped @) can point the scan at the live site.
lowered="$(tr '[:upper:]' '[:lower:]' <<<"$target")"
case "$lowered" in
  *keyfleet.ai* | *keyfleet.fly.dev* | *keyfleet.flycast* | *keyfleet.internal*) host="keyfleet.ai" ;;
esac

case "$host" in
  keyfleet.ai | *.keyfleet.ai | keyfleet.fly.dev | keyfleet.flycast | keyfleet.internal)
    die "refusing $target: that is the live site."
    ;;
  localhost | 127.0.0.1) ;;
  *)
    die "refusing $target: scan only the copy on this computer (platform/load/local.sh zap, or http://localhost:<port>)"
    ;;
esac

command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "docker is not running"

# Fail fast, and from this machine, if the address does not answer at all.
status="$(curl --silent --output /dev/null --max-time 15 --write-out '%{http_code}' "$target" || true)"
[[ $status =~ ^[1-5][0-9][0-9]$ ]] || die "$target did not answer (curl status: ${status:-none})"
echo "==> $target answered $status"

scan_target="${target/$host/host.docker.internal}"
[[ $scan_target != "$target" ]] || die "write the local address in lower case, as http://localhost:4100"
rule="replacer.full_list(0)"
zap_options=(-z "-config $rule.description=forwarded-proto -config $rule.enabled=true -config $rule.matchtype=REQ_HEADER -config $rule.matchstr=X-Forwarded-Proto -config $rule.regex=false -config $rule.replacement=https")

out="${2:-$here/zap-${host//[^a-z0-9.-]/_}-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
cp "$here/zap-rules.tsv" "$out/zap-rules.tsv"
# The scanner runs as its own user inside the container and writes here.
chmod a+rwx "$out"

echo "==> Pulling $image"
docker pull --quiet "$image" >/dev/null
digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$image")"
echo "==> Scanning $scan_target with $digest"

set +e
docker run --rm \
  --add-host host.docker.internal:host-gateway \
  --volume "$out:/zap/wrk:rw" \
  "$image" zap-baseline.py \
  -t "$scan_target" \
  -c zap-rules.tsv \
  -m 3 \
  -r report.html \
  -J report.json \
  "${zap_options[@]}" 2>&1 | tee "$out/zap.log"
zap_status="${PIPESTATUS[0]}"
set -e

[[ -s $out/report.json ]] || die "ZAP wrote no report (exit $zap_status); see $out/zap.log"

echo
echo "Scanned  $target"
echo "Image    $digest"
echo "Reports  $out/report.html"
echo "         $out/report.json"

case "$zap_status" in
  0)
    echo "Result   PASS: no rule warned or failed"
    ;;
  2)
    echo "Result   PASS with warnings: read each WARN in report.html; none is a FAIL rule"
    ;;
  1)
    echo "Result   FAIL: a FAIL rule fired (see the FAIL lines above)"
    exit 1
    ;;
  *)
    die "ZAP exited $zap_status; see $out/zap.log"
    ;;
esac

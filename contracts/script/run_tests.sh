#!/usr/bin/env bash
# Runs `forge test` with the arguments given and exits with its status, then ends by saying what
# the result does not include: whether the Base fork proofs ran, every suite in which a test
# skipped itself, and every path the arguments leave out. The suites under test/fork skip
# themselves without BASE_RPC_URL, and the Base gas suite also without --isolate, so a pass is
# never read as including them. It never fails for want of an endpoint, and never prints one.
set -uo pipefail
cd "$(dirname "$0")/.."

log=$(mktemp)
trap 'rm -f "$log"' EXIT
forge test "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

skipped=$(awk '/^Ran [0-9]+ tests? for /{ suite = $NF } /^\[SKIP/{ print suite }' "$log" | sort -u)
left_out=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--no-match-path" ] && [ "$#" -gt 1 ]; then
    left_out+=("$2")
    shift
  fi
  shift
done

echo
if [ -n "${BASE_RPC_URL:-}" ]; then
  echo "Base fork proofs: run against BASE_RPC_URL."
else
  echo "Base fork proofs: NOT RUN, BASE_RPC_URL is not set. This result does not include them."
fi
if [ -n "$skipped" ]; then
  echo "Skipped, so not in this result:"
  echo "$skipped" | sed 's/^/  /'
fi
for path in "${left_out[@]+"${left_out[@]}"}"; do
  echo "Left out of this run: $path"
done
exit "$status"

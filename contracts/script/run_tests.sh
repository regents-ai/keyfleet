#!/usr/bin/env bash
# Runs `forge test` with the arguments given and exits with its status, then ends by saying, from
# what Forge printed alone, which Base fork suites (those under test/fork) ran with no test
# skipped, every suite in which a test skipped itself, and "Base fork proofs: NOT RUN" when no Base
# fork suite ran that way, whatever the reason: no BASE_RPC_URL, a filter that left them out, a
# skip, a failed setUp or a run that stopped first. A pass is therefore never read as including
# them. It reads neither the arguments nor the environment, never fails for want of an endpoint,
# and prints no endpoint.
set -uo pipefail
cd "$(dirname "$0")/.."

log=$(mktemp)
trap 'rm -f "$log"' EXIT
forge test "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

# Forge's lines with their colour codes taken out. Each result line belongs to the suite named by
# the "Ran N tests for <path>:<contract>" line above it, until that suite's "Suite result" line. A
# suite whose setUp failed ran none of its tests.
suites=$(sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$log" | awk '
  /^Ran [0-9]+ tests? for / { suite = $NF; next }
  /^Suite result:/ { suite = ""; next }
  suite != "" && (/^\[PASS/ || (/^\[FAIL/ && !/\] setUp\(\) /)) { tested[suite] = 1 }
  suite != "" && /^\[SKIP/ { skipped[suite] = 1 }
  END {
    for (suite in tested) if (suite ~ /^test\/fork\// && !(suite in skipped)) print "ran " suite
    for (suite in skipped) print "skipped " suite
  }' | sort)
ran=$(sed -n 's/^ran /  /p' <<< "$suites")
skipped=$(sed -n 's/^skipped /  /p' <<< "$suites")

echo
if [ -n "$ran" ]; then
  echo "Base fork proofs: ran, with no test skipped, in"
  echo "$ran"
else
  echo "Base fork proofs: NOT RUN. This result does not include them."
fi
if [ -n "$skipped" ]; then
  echo "Skipped, so not in this result:"
  echo "$skipped"
fi
exit "$status"

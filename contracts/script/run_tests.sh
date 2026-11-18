#!/usr/bin/env bash
# Runs `forge test` with the arguments given and exits with its status, then ends by saying, from
# what Forge printed alone, which Base fork suites (those under test/fork) ran with every test
# passing and none skipped, which failed, every suite in which a test skipped itself, and "Base
# fork proofs: NOT RUN" when no Base fork suite ran, whatever the reason: no BASE_RPC_URL, a filter
# that left them out or a skip. A suite counts only once its own "Suite result" line closes its
# block. A run Forge did not finish, stopped by a signal or cut off before its closing summary,
# says so and nothing else, and never exits 0. A pass is therefore never read as including them.
# It reads neither the arguments nor the environment, never fails for want of an endpoint, and
# prints no endpoint.
#
# Known limit: the closing lines are read from Forge's printed text, so a test in this repository
# that prints text shaped like Forge's results could forge them; and with `--json` or `--junit` the
# lines say NOT RUN and list nothing skipped.
set -uo pipefail
cd "$(dirname "$0")/.."

log=$(mktemp)
trap 'rm -f "$log"' EXIT
forge test "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

# Forge's lines with their colour codes taken out. Each result line belongs to the suite named by
# the "Ran N tests for <path>:<contract>" line above it, and the suite counts only when its own
# "Suite result" line follows. A new suite, the closing "Ran N test suites" summary or the end of
# the output arriving first means the output was cut off.
suites=$(sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$log" | awk '
  /^Ran [0-9]+ tests? for / { if (suite != "") cut = 1; suite = $NF; seen = 1; passed = failed = skipped = 0; next }
  /^Ran [0-9]+ test suites? in / { if (suite != "") cut = 1; suite = ""; summary = 1; next }
  /^Suite result:/ {
    if (suite != "" && skipped) print "skipped " suite
    if (suite ~ /^test\/fork\//) {
      if (failed) print "failed " suite
      else if (passed && !skipped) print "ran " suite
    }
    suite = ""; next
  }
  suite != "" && /^\[PASS/ { passed = 1 }
  suite != "" && /^\[FAIL/ { failed = 1 }
  suite != "" && /^\[SKIP/ { skipped = 1 }
  END { if (suite != "" || cut || (seen && !summary)) print "unfinished" }' | sort)
ran=$(sed -n 's/^ran /  /p' <<< "$suites")
failed=$(sed -n 's/^failed /  /p' <<< "$suites")
skipped=$(sed -n 's/^skipped /  /p' <<< "$suites")

echo
if [ "$status" -ge 128 ] || grep -qx unfinished <<< "$suites"; then
  echo "Forge did not finish this run (it exited $status), so this result says nothing about the Base fork proofs or what skipped."
  [ "$status" -eq 0 ] && status=1
  exit "$status"
fi
if [ -n "$ran" ]; then
  echo "Base fork proofs: ran, every test passing and none skipped, in"
  echo "$ran"
fi
if [ -n "$failed" ]; then
  echo "Base fork proofs: FAILED in"
  echo "$failed"
fi
if [ -z "$ran" ] && [ -z "$failed" ]; then
  echo "Base fork proofs: NOT RUN. This result does not include them."
fi
if [ -n "$skipped" ]; then
  echo "Skipped, so not in this result:"
  echo "$skipped"
fi
exit "$status"

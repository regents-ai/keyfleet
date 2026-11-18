#!/usr/bin/env bash
# Runs `forge test` with the arguments given and exits with its status, then ends by saying, from
# what Forge printed alone, which Base fork suites (those under test/fork) ran with every test
# passing and none skipped, which failed, every suite in which a test skipped itself, and "Base
# fork proofs: NOT RUN" when no Base fork suite ran, whatever the reason: no BASE_RPC_URL, a filter
# that left them out or a skip. A suite counts only once its own "Suite result" line closes its
# block, and each is listed once: a Base fork suite that failed in any block is listed as failed
# only, even when a test in it also skipped, and one that skipped in any block is not listed as
# ran. A run Forge did not finish, stopped by a signal or cut off before its closing summary (the
# "Ran N test suites" line, or with `--summary` the table headed "| Test Suite"), says so and
# nothing else, and never exits 0. A pass is therefore never read as including them. It reads neither the arguments nor the environment and
# never fails for want of an endpoint; its own closing lines name no endpoint, though Forge's
# output, passed through above them, can, inside an endpoint's error message.
#
# Known limits:
# - The closing lines are read from Forge's printed text, so text shaped like Forge's results can
#   forge them or hide them, whether a test in this repository prints it or it comes from an
#   endpoint's error message, which Forge prints as it is within a failing test's reason.
# - Some flags leave nothing to read. With `--json` or `--junit` Forge prints no suite lines,
#   with `-q` it prints nothing, and with `--list` it runs no test, so the lines say NOT RUN and
#   list nothing skipped, whatever ran.
# - A stop aimed at the whole run, such as Ctrl-C, stops this script with Forge, so no closing
#   line is printed at all.
set -uo pipefail
cd "$(dirname "$0")/.."

log=$(mktemp)
trap 'rm -f "$log"' EXIT
forge test "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

# Forge's lines with their colour codes taken out. Each result line belongs to the suite named by
# the "Ran N tests for <path>:<contract>" line above it, and the suite counts only when its own
# "Suite result" line follows. A new suite, the closing summary (the "Ran N test suites" line, or
# the "| Test Suite" header of `--summary`'s table) or the end of the output arriving first means
# the output was cut off.
suites=$(sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$log" | awk '
  /^Ran [0-9]+ tests? for / { if (suite != "") cut = 1; suite = $NF; seen = 1; passed = failed = skipped = 0; next }
  /^Ran [0-9]+ test suites? in / || /^\| Test Suite +\| Passed +\| Failed +\| Skipped +\|/ {
    if (suite != "") cut = 1; suite = ""; summary = 1; next
  }
  /^Suite result:/ {
    if (suite != "" && skipped) skip[suite] = 1
    if (suite ~ /^test\/fork\//) {
      if (failed) fail[suite] = 1
      else if (passed && !skipped) pass[suite] = 1
    }
    suite = ""; next
  }
  suite != "" && /^\[PASS/ { passed = 1 }
  suite != "" && /^\[FAIL/ { failed = 1 }
  suite != "" && /^\[SKIP/ { skipped = 1 }
  END {
    for (s in skip) if (!(s in fail)) print "skipped " s
    for (s in fail) print "failed " s
    for (s in pass) if (!(s in fail) && !(s in skip)) print "ran " s
    if (suite != "" || cut || (seen && !summary)) print "unfinished"
  }' | sort)
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

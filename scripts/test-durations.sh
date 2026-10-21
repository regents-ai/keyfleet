#!/usr/bin/env bash
# Rewrites platform/test/durations.tsv: how long each ExUnit test file takes,
# which make check-change uses to give its four parts equal shares of the
# suite. Run it when test files are added or get much slower or faster, and
# commit the result.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/platform"
export MIX_TEST_PARTITION="_c$(printf %s "$root" | cksum | cut -d' ' -f1)p1"
MIX_ENV=test mix ecto.create --quiet
mix test --slowest-modules 1000 | awk '
  /^[A-Z][A-Za-z0-9_.]* \([0-9.]+ms\)$/ { ms = $NF; gsub(/[()ms]/, "", ms); next }
  ms != "" && /^ \[test\// { file = $1; gsub(/[][]/, "", file); printf "%d\t%s\n", ms, file; ms = "" }
' | sort -t$'\t' -k1,1rn -k2,2 >test/durations.tsv.new
mv test/durations.tsv.new test/durations.tsv

#!/usr/bin/env bash
# The check an ordinary change runs before it ships (platform/README.md,
# "Shipping a change"). Everything compiles without warnings and is formatted,
# then the tests that cover what changed since BASE (origin/main unless given)
# run:
#
#   - the Elixir suite, split four ways by time, when anything it compiles or reads
#     changed (the browser tests in test/browser are Playwright's);
#   - Vitest and Playwright on the tests that import what changed, Playwright
#     building the assets only when it has a test to run;
#   - the graph host's tests and the contracts' gate when their folders changed.
#
# Each checkout runs the Elixir suite on four test databases of its own, so two
# checkouts can run this at once.
set -euo pipefail

base="${BASE:-origin/main}"
root="$(cd "$(dirname "$0")/.." && pwd)"

# A path changed when it differs from BASE in the working tree, or holds a file
# git does not track yet.
changed() {
  ! git -C "$root" diff --quiet "$base" -- "$@" ||
    [[ -n "$(git -C "$root" ls-files --others --exclude-standard -- "$@")" ]]
}

cd "$root/platform"
MIX_ENV=test mix compile --warnings-as-errors
mix format --check-formatted

if changed platform/lib platform/test ':(exclude)platform/test/browser' platform/config platform/priv platform/mix.exs platform/mix.lock; then
  # Each part runs about a quarter of the suite's time on its own database,
  # named after this checkout: keyfleet_c<checksum>p<part>_test. Test files are
  # dealt longest first, each to the part with the least time so far, by the
  # times in test/durations.tsv (scripts/test-durations.sh); a file not listed
  # there counts as one second.
  checkout="_c$(printf %s "$root" | cksum | cut -d' ' -f1)"
  parts="$(find test -name '*_test.exs' | sort |
    awk -F'\t' 'NR == FNR { ms[$2] = $1; next } { print (($0 in ms) ? ms[$0] : 1000) "\t" $0 }' test/durations.tsv - |
    sort -t$'\t' -k1,1rn -k2,2 |
    awk -F'\t' '{ p = 1; for (i = 2; i <= 4; i++) if (load[i] < load[p]) p = i; load[p] += $1; print p "\t" $2 }')"
  logs="$(mktemp -d)"
  for n in 1 2 3 4; do
    (
      export MIX_TEST_PARTITION="${checkout}p$n"
      MIX_ENV=test mix ecto.create --quiet
      # shellcheck disable=SC2046
      mix test --warnings-as-errors $(awk -F'\t' -v n="$n" '$1 == n { print $2 }' <<<"$parts")
    ) >"$logs/$n.log" 2>&1 &
    echo $! >"$logs/$n.pid"
  done

  failed=""
  for n in 1 2 3 4; do
    wait "$(cat "$logs/$n.pid")" || failed="$failed $n"
  done
  for n in 1 2 3 4; do
    echo "==> Elixir tests, part $n of 4: $(grep '^Result: ' "$logs/$n.log" | tail -1 | cut -d' ' -f2-)"
  done
  if [[ -n "$failed" ]]; then
    for n in $failed; do
      echo "==> Part $n of 4 failed (full log $logs/$n.log):"
      cat "$logs/$n.log"
    done
    exit 1
  fi
fi

npx vitest run --changed "$base" --passWithNoTests
browser_tests="$(npx playwright test --only-changed="$base" --list)"
if grep -Eq "^Total: [1-9]" <<<"$browser_tests"; then
  npm run assets:build
  npx playwright test --only-changed="$base"
fi

if changed platform/graph_host; then
  (cd graph_host && uv run --frozen --offline pytest -q)
fi
if changed contracts; then
  make -C "$root" check-contracts
fi

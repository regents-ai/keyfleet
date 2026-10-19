#!/usr/bin/env bash
# The check an ordinary change runs before it ships (platform/README.md,
# "Shipping a change"). Everything compiles without warnings and is formatted,
# then the tests that cover what changed since BASE (origin/main unless given)
# run:
#
#   - the Elixir suite, split four ways, when anything it compiles or reads
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
  # Each part runs a quarter of the test files on its own database, named after
  # this checkout: keyfleet_c<checksum>p<part>_test.
  checkout="_c$(printf %s "$root" | cksum | cut -d' ' -f1)"
  files="$(find test -name '*_test.exs' | sort)"
  logs="$(mktemp -d)"
  for n in 1 2 3 4; do
    (
      export MIX_TEST_PARTITION="${checkout}p$n"
      MIX_ENV=test mix ecto.create --quiet
      # shellcheck disable=SC2046
      mix test --warnings-as-errors $(awk -v n="$n" 'NR % 4 == n % 4' <<<"$files")
    ) >"$logs/$n.log" 2>&1 &
    echo $! >"$logs/$n.pid"
  done

  failed=""
  for n in 1 2 3 4; do
    wait "$(cat "$logs/$n.pid")" || failed="$failed $n"
  done
  for n in 1 2 3 4; do
    echo "==> Elixir tests, part $n of 4: $(grep -E '^[0-9]+ (tests?|propert)' "$logs/$n.log" | tail -1)"
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

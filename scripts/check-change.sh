#!/usr/bin/env bash
# The check an ordinary change runs before it ships (platform/README.md,
# "Shipping a change"). Everything compiles without warnings and is formatted,
# then the contracts' gate runs when contracts/ changed since BASE (origin/main
# unless given).
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
mix compile --warnings-as-errors
mix format --check-formatted

if changed contracts; then
  make -C "$root" check-contracts
fi

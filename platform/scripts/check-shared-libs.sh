#!/usr/bin/env bash
#
# Checks that the shared libraries this checkout compiles against are the ones
# shared-libs.lock pins, so what the tests run is what the image ships. The
# libraries are found the way mix.exs finds them: under REGENT_DEPS_ROOT, or
# else two directories above this project. Each must be a git checkout whose
# pinned folders match the pinned commit, with nothing changed or added.
#
# Usage: scripts/check-shared-libs.sh

set -euo pipefail

platform="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root="${REGENT_DEPS_ROOT:-$(cd -- "$platform/../.." && pwd)}"
stale=0

while read -r repository revision folders; do
  checkout="$root/$repository"
  read -ra paths <<<"$folders"

  if ! git -C "$checkout" cat-file -e "$revision^{commit}" 2>/dev/null; then
    printf '%s does not hold commit %s\n' "$checkout" "$revision" >&2
    stale=1
  elif ! git -C "$checkout" diff --quiet "$revision" -- "${paths[@]}" ||
    [ -n "$(git -C "$checkout" ls-files --others --exclude-standard -- "${paths[@]}")" ]; then
    printf '%s differs from %s in %s\n' "$checkout" "$revision" "$folders" >&2
    stale=1
  fi
done < <(grep -v '^#' "$platform/shared-libs.lock")

[ "$stale" -eq 0 ] || {
  printf 'Point REGENT_DEPS_ROOT at checkouts of the commits in shared-libs.lock.\n' >&2
  exit 1
}

printf 'Shared libraries match shared-libs.lock\n'

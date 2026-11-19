#!/usr/bin/env bash
# Every notebook-hub check: compute-fly's types, lint and bundle inside the
# pinned marimohub workspace, and the three images. Needs marimohub's exact
# Node version (its `.node-version`) and Docker.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../marimohub/pin.env
source "$here/marimohub/pin.env"
work="$("$here/scripts/workspace.sh" | tail -n 1)"

(
  cd "$work/packages/compute-fly"
  corepack pnpm exec tsc --noEmit
  corepack pnpm exec vp check
  corepack pnpm exec vp pack
)

"$here/scripts/build-images.sh"

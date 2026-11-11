#!/usr/bin/env bash
# Every notebook-hub check: compute-fly's types, lint, bundle and tests inside
# the pinned marimohub workspace, the three images, and the runner helper's
# tests inside the runner image. Needs marimohub's exact Node version (its
# `.node-version`) and Docker.
# The full local end-to-end run is separate: local/run.sh.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../marimohub/pin.env
source "$here/marimohub/pin.env"
tag="${MARIMOHUB_COMMIT:0:7}"
work="$("$here/scripts/workspace.sh" | tail -n 1)"

(
  cd "$work/packages/compute-fly"
  corepack pnpm exec tsc --noEmit
  corepack pnpm exec vp check
  corepack pnpm exec vp pack
  corepack pnpm exec vp test
)

"$here/scripts/build-images.sh"

docker run --rm --sysctl net.ipv6.conf.all.disable_ipv6=0 \
  -v "$here/runner/helper_test.py:/opt/runner-test/helper_test.py:ro" \
  "keyfleet/notebook-runner:$tag" \
  /usr/local/bin/python3 -I -m unittest discover -s /opt/runner-test -p '*_test.py'

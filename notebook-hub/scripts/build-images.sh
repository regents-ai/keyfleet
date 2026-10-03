#!/usr/bin/env bash
# Builds the three local images from the pinned marimohub source:
#   keyfleet/marimo-sandbox:<pin>  marimohub's sandbox image (runner base)
#   keyfleet/notebook-runner:<pin> the runner machine image
#   keyfleet/notebook-hub:<pin>    the hub image
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
work="$("$here/scripts/workspace.sh" | tail -n 1)"
# shellcheck source=../marimohub/pin.env
source "$here/marimohub/pin.env"
tag="${MARIMOHUB_COMMIT:0:7}"

docker build \
  --build-context notebook_bridge="$work/packages/notebook-bridge" \
  --target release \
  -t "keyfleet/marimo-sandbox:$tag" \
  "$work/images/marimo-sandbox"

docker build \
  --build-arg "SANDBOX_IMAGE=keyfleet/marimo-sandbox:$tag" \
  -t "keyfleet/notebook-runner:$tag" \
  "$here/runner"

docker build \
  --build-arg "MARIMOHUB_REPO=$MARIMOHUB_REPO" \
  --build-arg "MARIMOHUB_COMMIT=$MARIMOHUB_COMMIT" \
  -t "keyfleet/notebook-hub:$tag" \
  -f "$here/hub/Dockerfile" \
  "$here"

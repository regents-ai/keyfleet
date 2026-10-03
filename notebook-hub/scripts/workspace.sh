#!/usr/bin/env bash
# Prepares the marimohub workspace that compute-fly is typechecked, tested and
# bundled in: marimohub at the pinned commit, with compute-fly added as
# packages/compute-fly and the matching lockfile entry applied. The hub image
# builds the same way (hub/Dockerfile).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../marimohub/pin.env
source "$here/marimohub/pin.env"
work="$here/.work/marimohub"
patch="$here/marimohub/pnpm-lock.patch"

if [ ! -d "$work/.git" ]; then
  mkdir -p "$here/.work"
  git clone --quiet "$MARIMOHUB_REPO" "$work"
  git -C "$work" checkout --quiet --detach "$MARIMOHUB_COMMIT"
fi

head="$(git -C "$work" rev-parse HEAD)"
if [ "$head" != "$MARIMOHUB_COMMIT" ]; then
  echo "notebook-hub/.work/marimohub is at $head, not the pinned $MARIMOHUB_COMMIT." >&2
  echo "Move notebook-hub/.work aside and run this again to rebuild it at the pin." >&2
  exit 1
fi

mkdir -p "$work/packages/compute-fly"
rsync -a --delete --exclude node_modules --exclude dist "$here/compute-fly/" "$work/packages/compute-fly/"

if git -C "$work" apply --check "$patch" 2>/dev/null; then
  git -C "$work" apply "$patch"
fi
git -C "$work" apply --reverse --check "$patch"

(cd "$work" && CI=true corepack pnpm install --frozen-lockfile --reporter=silent)
echo "$work"

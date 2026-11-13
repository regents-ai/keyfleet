#!/usr/bin/env bash
# Prepares the marimohub workspace that compute-fly is typechecked, tested and
# bundled in: marimohub at the pinned commit, with the hub image's patches
# applied in the image's order and compute-fly added as packages/compute-fly.
# The hub image builds the same way (hub/Dockerfile).
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../marimohub/pin.env
source "$here/marimohub/pin.env"
work="$here/.work/marimohub"
lock_patch="$here/marimohub/pnpm-lock.patch"

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

node_want="$(cat "$work/.node-version")"
node_have="$(node -p 'process.versions.node')"
if [ "$node_have" != "$node_want" ]; then
  echo "marimohub builds with Node $node_want; this shell has Node $(node -v). Put Node $node_want first on PATH." >&2
  exit 1
fi

mkdir -p "$work/packages/compute-fly"
rsync -a --delete --exclude node_modules --exclude dist "$here/compute-fly/" "$work/packages/compute-fly/"

# Apply the patches only to a tree still at the pinned commit, so a second run
# never applies them twice. The lockfile change needs the catalog entry
# storage-calls.patch adds, so the workspace takes every patch the image does.
if git -C "$work" diff --quiet HEAD; then
  for patch in $(sed -n 's|^COPY marimohub/\(.*\.patch\) .*|\1|p' "$here/hub/Dockerfile"); do
    git -C "$work" apply "$here/marimohub/$patch"
  done
fi
git -C "$work" apply --reverse --check "$lock_patch"

(cd "$work" && CI=true corepack pnpm install --frozen-lockfile) >&2
echo "$work"

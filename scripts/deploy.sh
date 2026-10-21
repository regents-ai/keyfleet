#!/usr/bin/env bash
# Deploys the committed tree to one Keyfleet Fly app, and nothing else.
#
#   scripts/deploy.sh production       # keyfleet, from platform/fly.toml
#   scripts/deploy.sh staging          # keyfleet-staging, from platform/fly.staging.toml
#
# It refuses a working tree with any change, a commit that is not on
# origin/main, and a commit that does not contain the one already live, so what
# runs is always what the repository holds and never takes live work out. The
# build context is the one platform/scripts/build-release-context.sh assembles for
# amd64, which Fly runs: `git archive` of this commit's platform/ folder plus the
# graph host's sealed Python supply, checked against its checksums. Fly's remote
# builder builds the image from it, labelled with the short commit. Every deploy
# runs /app/bin/migrate as its release command (platform/README.md, Deployment).
#
# The app has two machines (platform/fly.toml). The graph machine, which holds
# the volume, takes the image first: it stops and starts again, and for those
# seconds a workspace write answers "try again". The site machine then takes
# the same image bluegreen, so a page is answered throughout.
set -euo pipefail

case "${1:-}" in
  production) config="platform/fly.toml" app="keyfleet" ;;
  staging) config="platform/fly.staging.toml" app="keyfleet-staging" ;;
  *)
    echo "Usage: scripts/deploy.sh production|staging" >&2
    exit 2
    ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy: commit or remove every change first." >&2
  exit 1
fi

git fetch --quiet origin main
commit="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor "$commit" origin/main; then
  echo "Refusing to deploy: ${commit:0:7} is not on origin/main. Push it to main first." >&2
  exit 1
fi

# The running image is tagged with the short commit it was built from (the
# --image-label below). A commit that does not contain it would take live work
# back out, which happens when two releases cross: bring this checkout up to
# origin/main and deploy again.
live="$(fly image show --app "$app" --json | jq -r '.[0].Tag')"
if ! git merge-base --is-ancestor "$live" "$commit"; then
  echo "Refusing to deploy: ${commit:0:7} does not contain ${live:0:7}, which is live. Update to origin/main first." >&2
  exit 1
fi

workspace="$(mktemp -d)"
context="$workspace/context"

cleanup() {
  chmod -R u+w "$workspace" 2>/dev/null || true
  rm -rf -- "$workspace"
}
trap cleanup EXIT

echo "==> Assembling the build context from commit ${commit:0:7}"
platform/scripts/build-release-context.sh "$context" amd64

echo "==> Deploying ${commit:0:7} to the graph machine with $config"
fly deploy "$context" \
  --config "$context/$config" \
  --dockerfile "$context/Dockerfile" \
  --ignorefile "$context/Dockerfile.dockerignore" \
  --remote-only \
  --ha=false \
  --image-label "${commit:0:7}" \
  --process-groups graph

echo "==> Deploying ${commit:0:7} to the site machine, bluegreen"
fly deploy \
  --config "$context/$config" \
  --image "registry.fly.io/$app:${commit:0:7}" \
  --ha=false \
  --process-groups site \
  --strategy bluegreen

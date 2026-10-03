#!/usr/bin/env bash
# Deploys the committed tree to one Keyfleet Fly app, and nothing else.
#
#   scripts/deploy.sh production       # keyfleet, from platform/fly.toml
#   scripts/deploy.sh staging          # keyfleet-staging, from platform/fly.staging.toml
#
# It refuses a working tree with any change, and a commit that is not on
# origin/main, so what runs is always what the repository holds. The build
# context is the one platform/scripts/build-release-context.sh assembles for
# amd64, which Fly runs: `git archive` of this commit's platform/ folder plus the
# graph host's sealed Python supply, checked against its checksums. Fly's remote
# builder builds the image from it, labelled with the short commit. Every deploy
# runs /app/bin/migrate as its release command (platform/README.md, Deployment).
set -euo pipefail

case "${1:-}" in
  production) config="platform/fly.toml" ;;
  staging) config="platform/fly.staging.toml" ;;
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

workspace="$(mktemp -d)"
context="$workspace/context"

cleanup() {
  chmod -R u+w "$workspace" 2>/dev/null || true
  rm -rf -- "$workspace"
}
trap cleanup EXIT

echo "==> Assembling the build context from commit ${commit:0:7}"
platform/scripts/build-release-context.sh "$context" amd64

echo "==> Deploying ${commit:0:7} with $config"
fly deploy "$context" \
  --config "$context/$config" \
  --dockerfile "$context/Dockerfile" \
  --ignorefile "$context/Dockerfile.dockerignore" \
  --remote-only \
  --ha=false \
  --image-label "${commit:0:7}"

#!/usr/bin/env bash
# Deploys the committed tree to one Keyfleet Fly app, and nothing else.
#
#   scripts/deploy.sh production       # keyfleet, from platform/fly.toml
#   scripts/deploy.sh staging          # keyfleet-staging, from platform/fly.staging.toml
#
# It refuses a working tree with any change, a commit that is not on
# origin/main, and a commit that does not contain what each machine runs, so what
# runs is always what the repository holds and never takes live work out. The
# build context is the one platform/scripts/build-release-context.sh assembles for
# amd64, which Fly runs: `git archive` of this commit's platform/ folder plus the
# graph host's sealed Python supply, checked against its checksums. Fly's remote
# builder builds the image from it, labelled with the short commit. Every deploy
# runs /app/bin/migrate as its release command (platform/README.md, Deployment).
#
# The app has two machines (platform/fly.toml). Fly's remote builder first
# builds and pushes the image, labelled with the short commit, holding no
# place on the shared database. The graph machine, which holds the volume, then
# takes the image: it stops and starts again, and for those seconds a workspace
# write answers "try again". The site machine then takes the same image
# bluegreen, so a page is answered throughout.
#
# Two deploys of this app take turns, from any checkout, or the two machines can
# end up on different commits (21 October 2026): the script runs itself again
# under lockf(1) on /tmp/regent-release-<app>.lock, which other sites never
# take, and the system lets go of it when the script ends, however it ends.
# Every site shares one production database, and a switch to a new image runs
# the migrations and briefly adds a machine's connections to it, which fits two
# switches at once across all sites. Each switch takes whichever of the two
# places is free, /tmp/regent-shared-db-release.lock or
# /tmp/regent-shared-db-release-2.lock, or waits for the second.
set -euo pipefail

case "${1:-}" in
  production) config="platform/fly.toml" app="keyfleet" ;;
  staging) config="platform/fly.staging.toml" app="keyfleet-staging" ;;
  *)
    echo "Usage: scripts/deploy.sh production|staging" >&2
    exit 2
    ;;
esac

lock="/tmp/regent-release-$app.lock"
if [[ "${DEPLOY_LOCK:-}" != "$lock" ]]; then
  echo "==> Deploying to $app (waits for any other deploy of $app holding $lock)"
  DEPLOY_LOCK="$lock" exec lockf -k "$lock" bash "$0" "$@"
fi

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

# Each machine's image is tagged with the short commit it was built from (the
# --image-label below). A commit that does not contain every one would take
# live work back out, which happens when two releases cross: bring this
# checkout up to origin/main and deploy again.
for live in $(fly image show --app "$app" --json | jq -r '.[].Tag' | sort -u); do
  if ! git merge-base --is-ancestor "$live" "$commit"; then
    echo "Refusing to deploy: ${commit:0:7} does not contain ${live:0:7}, which is live. Update to origin/main first." >&2
    exit 1
  fi
done

workspace="$(mktemp -d)"
context="$workspace/context"

cleanup() {
  chmod -R u+w "$workspace" 2>/dev/null || true
  rm -rf -- "$workspace"
}
trap cleanup EXIT

echo "==> Assembling the build context from commit ${commit:0:7}"
platform/scripts/build-release-context.sh "$context" amd64

echo "==> Building ${commit:0:7} with $config"
fly deploy "$context" \
  --config "$context/$config" \
  --dockerfile "$context/Dockerfile" \
  --ignorefile "$context/Dockerfile.dockerignore" \
  --build-only \
  --push \
  --remote-only \
  --image-label "${commit:0:7}" \
  --build-arg SOURCE_COMMIT="$commit"

# Switches the machines of one process group to the new image, in whichever
# place on the shared database is free, or waiting for the second.
switch() {
  local place=/tmp/regent-shared-db-release.lock
  lockf -k -s -t 0 "$place" true || place=/tmp/regent-shared-db-release-2.lock
  echo "==> Deploying ${commit:0:7} to the $1 machine (waits for $place if it is taken)"
  lockf -k "$place" fly deploy \
    --config "$context/$config" \
    --image "registry.fly.io/$app:${commit:0:7}" \
    --ha=false \
    --process-groups "$@"
}

switch graph
switch site --strategy bluegreen

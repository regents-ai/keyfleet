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
# runs /app/bin/migrate as its release command once, with the site machine
# (platform/README.md, Deployment).
#
# The app has two machines (platform/fly.toml). Fly's remote builder first
# builds and pushes the image, labelled with the short commit, holding no
# place on the shared database. The site machine then takes the image
# bluegreen, after the migrations, so a page is answered throughout. The graph
# machine, which holds the volume, takes the same image next: it stops and
# starts again. A site machine asks whichever graph machine is running, so a
# workspace write answers "try again" only while the graph machine restarts:
# until its listener answers, about 20 to 40 seconds by estimate, and then
# while each fleet's graph host reads its log again, up to 60 seconds, as
# after any restart. The site goes first because this way the window holds
# only the graph machine's restart, not the site's start and checks as well.
# The first release with the listener takes about one to two minutes instead:
# the graph machine it replaces has none, so writes answer "try again" from
# the new site taking over. If the graph machine's release fails, the script
# says so, prints the command that releases it alone, and stops; it does not
# try again.
#
# Two deploys of this app take turns, from any checkout, or the two machines can
# end up on different commits (21 October 2026): the script runs itself again
# under lockf(1) on /tmp/regent-release-<app>.lock, which other sites never
# take, and the system lets go of it when the script ends, however it ends.
# Every site shares one production database, and the site's switch runs the
# migrations and briefly adds a site machine's connections to it, which fits
# two switches at once across all sites. It takes whichever of the two places
# is free, /tmp/regent-shared-db-release.lock or
# /tmp/regent-shared-db-release-2.lock, or waits for the second. The graph
# machine's switch runs no migrations and adds no connections, since its old
# machine stops before the new one starts, so it takes no place.
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

# Switches the site machine to the new image bluegreen, after the migrations,
# in whichever place on the shared database is free, or waiting for the second.
place=/tmp/regent-shared-db-release.lock
lockf -k -s -t 0 "$place" true || place=/tmp/regent-shared-db-release-2.lock
echo "==> Deploying ${commit:0:7} to the site machine (waits for $place if it is taken)"
lockf -k "$place" fly deploy \
  --config "$context/$config" \
  --image "registry.fly.io/$app:${commit:0:7}" \
  --ha=false \
  --process-groups site \
  --strategy bluegreen

# Then the graph machine, on the same image, with the migrations already run.
echo "==> Deploying ${commit:0:7} to the graph machine"
if ! fly deploy \
  --config "$context/$config" \
  --image "registry.fly.io/$app:${commit:0:7}" \
  --ha=false \
  --process-groups graph \
  --skip-release-command; then
  echo "The graph machine's deploy failed after the site machine's succeeded: every workspace write answers \"try again\" until the graph machine is released." >&2
  echo "Release the graph machine alone on the image already pushed:" >&2
  echo "  fly deploy --config $root/$config --image registry.fly.io/$app:${commit:0:7} --ha=false --process-groups graph --skip-release-command" >&2
  exit 1
fi

#!/usr/bin/env bash
# Local end-to-end proof: the hub image with dev sign-in and file storage, its
# Fly compute library pointed at local/fake-fly-api.mjs, which starts runner
# containers on an IPv6-only Docker network the way Fly starts machines on its
# private network. Needs the images from scripts/build-images.sh. Every token
# here is generated for this run only.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../marimohub/pin.env
source "$here/marimohub/pin.env"
tag="${MARIMOHUB_COMMIT:0:7}"
hub_image="keyfleet/notebook-hub:$tag"
runner_image="keyfleet/notebook-runner:$tag"
net6=kf-nb-local-6pn
front=kf-nb-local-front
app=kf-nbk-local
port=4791

# Start clean: containers from an earlier run, including its runner machines.
docker rm -f kf-nb-local-hub kf-nb-local-fly-api >/dev/null 2>&1 || true
leftovers="$(docker ps -aq --filter label=keyfleet.local-fly)"
[ -z "$leftovers" ] || docker rm -f $leftovers >/dev/null

docker network inspect "$net6" >/dev/null 2>&1 \
  || docker network create --ipv6 --ipv4=false --subnet fdaa:0:1::/64 "$net6" >/dev/null
docker network inspect "$front" >/dev/null 2>&1 || docker network create "$front" >/dev/null

mkdir -p "$here/.work/local"
data="$(mktemp -d "$here/.work/local/data.XXXXXX")"
fly_token="$(openssl rand -hex 32)"
helper_secret="$(openssl rand -hex 32)"
session_secret="$(openssl rand -hex 32)"

docker run -d --name kf-nb-local-fly-api \
  --network "$net6" --network-alias _api.internal \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$here/local/fake-fly-api.mjs:/fake/fake-fly-api.mjs:ro" \
  -e "FAKE_FLY_TOKEN=$fly_token" -e "FAKE_FLY_APP=$app" -e "FAKE_FLY_NETWORK=$net6" \
  "$hub_image" node /fake/fake-fly-api.mjs >/dev/null

# The same settings hub/hub.env.example lists, with local values.
docker create --name kf-nb-local-hub \
  --network "$front" -p "127.0.0.1:$port:3000" \
  -v "$data:/data" \
  -e MARIMOHUB_AUTH_BACKEND=dev \
  -e MARIMOHUB_STORAGE_BACKEND=fs \
  -e MARIMOHUB_STORAGE_FS_ROOT=/data \
  -e "MARIMOHUB_APP_BASE_URL=http://127.0.0.1:$port" \
  -e "MARIMOHUB_AUTH_SESSION_SECRET=$session_secret" \
  -e MARIMOHUB_SANDBOX_PROXY_ACK_UNTRUSTED=true \
  -e MARIMOHUB_PERSIST_WORKSPACE=workspace \
  -e MARIMOHUB_RUN_MAINTENANCE=true \
  -e "MARIMOHUB_COMPUTE_IMAGE=$runner_image" \
  -e MARIMOHUB_COMPUTE_FLY_API_URL=http://_api.internal:4280 \
  -e "FLY_API_TOKEN=$fly_token" \
  -e "MARIMOHUB_COMPUTE_FLY_APP=$app" \
  -e MARIMOHUB_COMPUTE_FLY_REGION=local \
  -e MARIMOHUB_COMPUTE_FLY_CPU_KIND=shared \
  -e MARIMOHUB_COMPUTE_FLY_CPUS=1 \
  -e MARIMOHUB_COMPUTE_FLY_MEMORY_MB=1024 \
  -e "MARIMOHUB_COMPUTE_FLY_HELPER_SECRET=$helper_secret" \
  -e MARIMOHUB_COMPUTE_FLY_OWNER=kf-nb-local \
  "$hub_image" >/dev/null
docker network connect "$net6" kf-nb-local-hub
docker start kf-nb-local-hub >/dev/null

for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null

status=0
HUB_URL="http://127.0.0.1:$port" DATA_DIR="$data" NET6="$net6" APP="$app" \
  HUB_IMAGE="$hub_image" RUNNER_IMAGE="$runner_image" \
  FLY_TOKEN="$fly_token" HELPER_SECRET="$helper_secret" \
  node "$here/local/drive.mjs" || status=$?

docker logs kf-nb-local-hub >"$data/../hub-$(basename "$data").log" 2>&1
docker logs kf-nb-local-fly-api >"$data/../fly-api-$(basename "$data").log" 2>&1
docker rm -f kf-nb-local-hub kf-nb-local-fly-api >/dev/null
leftovers="$(docker ps -aq --filter label=keyfleet.local-fly)"
[ -z "$leftovers" ] || docker rm -f $leftovers >/dev/null
exit "$status"

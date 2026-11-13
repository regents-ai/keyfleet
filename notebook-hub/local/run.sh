#!/usr/bin/env bash
# Local end-to-end proof: the hub image with file storage and Keyfleet's sign-in
# (passes signed with a key made for this run, published by local/jwks-server.mjs),
# its Fly compute library pointed at local/fake-fly-api.mjs, which starts runner
# containers on an IPv6-only Docker network the way Fly starts machines on its
# private network. Needs the images from scripts/build-images.sh. Every token
# and key here is generated for this run only.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../marimohub/pin.env
source "$here/marimohub/pin.env"
tag="${MARIMOHUB_COMMIT:0:7}"
hub_tag="$tag-$(cat "$here"/marimohub/*.patch | shasum -a 256 | cut -c1-7)"
hub_image="keyfleet/notebook-hub:$hub_tag"
runner_image="keyfleet/notebook-runner:$tag"
net6=kf-nb-local-6pn
front=kf-nb-local-front
app=kf-nbk-local
port=4791
issuer=https://keyfleet.localhost
audience=keyfleet-hub:kf_local

# Start clean: containers from an earlier run, including its runner machines.
docker rm -f kf-nb-local-hub kf-nb-local-fly-api kf-nb-local-jwks >/dev/null 2>&1 || true
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

# The pass key (private, for drive.mjs) and its public JWK Set, named by its RFC 7638
# thumbprint as Keyfleet names its keys, and a certificate for the key server.
keys="$(mktemp -d "$here/.work/local/keys.XXXXXX")"
node --input-type=module -e "
import { createHash, generateKeyPairSync } from 'node:crypto';
import { writeFileSync } from 'node:fs';
const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const { d, ...key } = privateKey.export({ format: 'jwk' });
const kid = createHash('sha256').update(JSON.stringify({ crv: key.crv, kty: key.kty, x: key.x, y: key.y })).digest('base64url');
writeFileSync(process.argv[1] + '/pass-key.json', JSON.stringify({ keys: [{ ...key, d }] }), { mode: 0o600 });
writeFileSync(process.argv[1] + '/jwks.json', JSON.stringify({ keys: [{ ...key, kid, alg: 'ES256', use: 'sig' }] }));
" "$keys"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj /CN=kf-nb-local-jwks -addext subjectAltName=DNS:kf-nb-local-jwks \
  -keyout "$keys/tls.key" -out "$keys/tls.crt" 2>/dev/null

docker run -d --name kf-nb-local-jwks --network "$front" \
  -v "$keys/jwks.json:/jwks/jwks.json:ro" -v "$keys/tls.key:/jwks/tls.key:ro" \
  -v "$keys/tls.crt:/jwks/tls.crt:ro" \
  -v "$here/local/jwks-server.mjs:/fake/jwks-server.mjs:ro" \
  "$hub_image" node /fake/jwks-server.mjs >/dev/null

docker run -d --name kf-nb-local-fly-api \
  --network "$net6" --network-alias _api.internal \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$here/local/fake-fly-api.mjs:/fake/fake-fly-api.mjs:ro" \
  -e "FAKE_FLY_TOKEN=$fly_token" -e "FAKE_FLY_APP=$app" -e "FAKE_FLY_NETWORK=$net6" \
  "$hub_image" node /fake/fake-fly-api.mjs >/dev/null

# The same settings hub/hub.env.example lists, with local values. Integrations are
# on only so drive.mjs can give a run a value to plant; the fleets' hubs keep them off.
docker create --name kf-nb-local-hub \
  --network "$front" -p "127.0.0.1:$port:3000" \
  -v "$data:/data" \
  -v "$keys/tls.crt:/jwks/tls.crt:ro" \
  -e NODE_EXTRA_CA_CERTS=/jwks/tls.crt \
  -e MARIMOHUB_AUTH_BACKEND=proxy-header \
  -e MARIMOHUB_AUTH_PROXY_HEADER=X-Keyfleet-Assertion \
  -e "MARIMOHUB_AUTH_PROXY_JWT_ISSUER=$issuer" \
  -e "MARIMOHUB_AUTH_PROXY_JWT_AUDIENCE=$audience" \
  -e MARIMOHUB_AUTH_PROXY_JWKS_URL=https://kf-nb-local-jwks:8443/jwks.json \
  -e MARIMOHUB_AUTH_ALLOWED_EMAIL_DOMAINS=identity.keyfleet.invalid \
  -e MARIMOHUB_DEFAULT_ROLE=none \
  -e MARIMOHUB_PROJECT_CREATION=restricted \
  -e MARIMOHUB_SUPER_ADMINS=kf_provisioner_local@identity.keyfleet.invalid \
  -e MARIMOHUB_STORAGE_BACKEND=fs \
  -e MARIMOHUB_STORAGE_FS_ROOT=/data \
  -e "MARIMOHUB_APP_BASE_URL=http://127.0.0.1:$port" \
  -e "MARIMOHUB_AUTH_SESSION_SECRET=$session_secret" \
  -e MARIMOHUB_SANDBOX_PROXY_ACK_UNTRUSTED=true \
  -e MARIMOHUB_PERSIST_WORKSPACE=workspace \
  -e MARIMOHUB_RUN_MAINTENANCE=true \
  -e MARIMOHUB_SANDBOX_AUTH=on \
  -e MARIMOHUB_EDITOR_SANDBOX_SHARING=exclusive \
  -e MARIMOHUB_JOBS=on \
  -e MARIMOHUB_JOBS_MAX_PER_NOTEBOOK=100 \
  -e MARIMOHUB_INTEGRATIONS=on \
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
  PASS_KEY="$keys/pass-key.json" PASS_ISSUER="$issuer" PASS_AUDIENCE="$audience" \
  node "$here/local/drive.mjs" || status=$?

docker logs kf-nb-local-hub >"$data/../hub-$(basename "$data").log" 2>&1
docker logs kf-nb-local-fly-api >"$data/../fly-api-$(basename "$data").log" 2>&1
docker rm -f kf-nb-local-hub kf-nb-local-fly-api kf-nb-local-jwks >/dev/null
rm -r "$keys"
leftovers="$(docker ps -aq --filter label=keyfleet.local-fly)"
[ -z "$leftovers" ] || docker rm -f $leftovers >/dev/null
exit "$status"

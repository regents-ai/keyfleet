# shellcheck shell=bash
# shellcheck disable=SC2154 # run and out are set by the script that sources this
# What local.sh and faults.sh share, sourced by both: the release image `make
# release` built (keyfleet:<commit>), started on this computer as
# scripts/release.sh starts it, against a throwaway PostgreSQL 17 on a Docker
# network of its own, with production's processors, memory and database pool.
#
# The database is created and seeded as staging's is, with the release's own
# commands (bootstrap-staging, migrate, seed-deployment with the Regents Club's
# deployment record), so every page a visitor opens exists. The role is staging because that role admits only the staging
# database hostnames, which the throwaway database (or faults.sh's proxy in
# front of it) answers to on its network; nothing here can reach a real
# database, and nothing leaves this computer.
#
# The server is published on 127.0.0.1:LOAD_PORT (4100) and nowhere else, so
# k6, run on this computer (brew install k6), reaches it there. It gets
# release.sh's stand-in values for the services a production boot names (the
# sign-in server, the code store, the picture bucket, key art, Lighthouse) at
# .invalid addresses that can never resolve; no visitor page reaches them.
#
# The caller sets `run` (the name every container, the network and the volume
# share) and creates `out` (its results folder), then calls stack_preflight.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
here="$root/platform/load"

commit="$(git -C "$root" rev-parse HEAD)"
image="${IMAGE:-keyfleet:${commit:0:12}}"
port="${LOAD_PORT:-4100}"
postgres_image="docker.io/library/postgres:17"
# The host is a staging database host, the only kind the staging role admits.
database_url="postgres://load:load@regents-staging-db.internal/keyfleet_load"
# Every server of a run shares one secret, as every machine of a Fly app shares
# its SECRET_KEY_BASE: a page drawn by the first server must join the second.
secret_key_base="$(openssl rand -base64 48)"
# The server containers started so far, for their logs and the teardown.
servers=()

# Production's machine (platform/fly.toml [[vm]]): two dedicated processors and
# 4 GB with no swap. The database pool is production's too: the image's own
# Keyfleet.DatabaseConfig sets five, which stack_check_server confirms.
server_size=(--cpus 2 --memory 4g --memory-swap 4g)

release_env=(
  --env KEYFLEET_DEPLOYMENT_ROLE=staging
  --env KEYFLEET_APP_SURFACES=on
)

# scripts/release.sh's stand-ins for the server's required settings, word for
# word. PHX_HOST is localhost, the host force_ssl leaves alone (config/prod.exs),
# so pages, the socket and health answer over plain HTTP on this computer.
server_env=(
  --env PHX_HOST=localhost
  --env SECRET_KEY_BASE="$secret_key_base"
  --env KEYFLEET_SIWA_URL=https://siwa.invalid
  --env KEYFLEET_HUB_SIGNING_KEY='{"keys":[]}'
  --env KEYFLEET_CODE_NODE=http://code.invalid
  --env AWS_ENDPOINT_URL_S3=https://storage.invalid
  --env BUCKET_NAME=smoke --env AWS_REGION=auto
  --env AWS_ACCESS_KEY_ID=smoke --env AWS_SECRET_ACCESS_KEY=smoke
  --env PICTURES_PUBLIC_URL=https://pictures.invalid
  --env KEY_ART_URL=http://key-art.invalid
  --env LIGHTHOUSE_API_KEY=smoke
)

fail() {
  echo "Run failed: $1" >&2
  exit 1
}

# Retries a command once a second for up to `seconds`.
wait_for() {
  local what="$1" seconds="$2"
  shift 2
  for _ in $(seq "$seconds"); do
    if "$@" >/dev/null 2>&1; then return; fi
    sleep 1
  done
  fail "$what did not answer within $seconds seconds."
}

# Milliseconds since the epoch; macOS's date has no %N.
now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}

sleep_until() {
  local left=$(($1 - $(now_ms)))
  if [[ $left -gt 0 ]]; then sleep "$(awk "BEGIN { print $left / 1000 }")"; fi
}

# "90", "90s", "10m" or "1h" as seconds, as k6 reads them.
duration_s() {
  [[ $1 =~ ^([0-9]+)([smh]?)$ ]] || fail "not a duration: $1 (write 90s, 10m or 1h)"
  case "${BASH_REMATCH[2]}" in
    m) echo $((BASH_REMATCH[1] * 60)) ;;
    h) echo $((BASH_REMATCH[1] * 3600)) ;;
    *) echo "${BASH_REMATCH[1]}" ;;
  esac
}

# Everything a run needs, checked before anything starts.
stack_preflight() {
  command -v docker >/dev/null || fail "Docker is required (Docker Desktop)."
  docker info >/dev/null 2>&1 || fail "Docker is not running. Start Docker Desktop."
  command -v k6 >/dev/null || fail "k6 is required: brew install k6"
  command -v node >/dev/null || fail "Node is required for the report (summarize.mjs)."
  command -v perl >/dev/null || fail "perl is required for millisecond times (macOS has it)."
  docker image inspect "$image" >/dev/null 2>&1 ||
    fail "there is no image $image. Run make release first (it keeps keyfleet:<commit>), or set IMAGE."
  [[ -n ${KEYFLEET_DEPLOYED_RECORD:-} && -r ${KEYFLEET_DEPLOYED_RECORD:-} ]] ||
    fail "set KEYFLEET_DEPLOYED_RECORD to the Regents Club's base.deployed.json, the record production was seeded with."

  # Docker Desktop's VM holds the server's 2 CPUs and 4 GB and PostgreSQL
  # beside it; k6 runs outside the VM, on the Mac itself.
  local cpus memory
  read -r cpus memory <<<"$(docker info --format '{{.NCPU}} {{.MemTotal}}')"
  ((cpus >= 4)) || fail "Docker's VM has $cpus CPUs; give it at least 4 (Docker Desktop, Settings, Resources)."
  ((memory >= 7 * 1024 * 1024 * 1024)) ||
    fail "Docker's VM has $((memory / 1024 / 1024)) MiB; give it at least 8 GB (Docker Desktop, Settings, Resources)."

  # Each open page holds a socket and up to six connections for its files,
  # about 14,000 at 2,000 pages; macOS gives a shell 256.
  ulimit -n 16384 2>/dev/null ||
    fail "the open-file limit could not be raised to 16384: run sudo launchctl limit maxfiles 65536 200000, then open a new terminal."

  # Something already answering there would be loaded instead of this copy.
  if curl --silent --max-time 2 --output /dev/null "http://127.0.0.1:$port/"; then
    fail "something already answers on 127.0.0.1:$port. Stop it, or set LOAD_PORT to a free port."
  fi

  {
    echo "commit   $commit"
    echo "image    $image $(docker image inspect --format '{{.Id}}' "$image")"
    echo "k6       $(k6 version | head -n 1)"
    echo "docker   $(docker version --format '{{.Server.Version}}'), VM $cpus CPUs, $((memory / 1024 / 1024)) MiB"
    echo "machine  $(uname -sm) $(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
  } >"$out/versions.txt"
}

# The network, the server's volume and PostgreSQL 17, answering on the network
# as `alias`.
stack_start_database() {
  local alias="$1"
  # IPv6, since the server's database connection uses it (socket_options: [:inet6]).
  docker network create --ipv6 "$run" >/dev/null
  # The volume stands in for the Fly volume at /data: empty and owned by the app
  # user as deploying leaves it, and handed from one server to the next as Fly
  # hands the volume to the replacement machine.
  docker volume create "$run-data" >/dev/null
  docker run --rm --volume "$run-data:/data" --entrypoint chown "$postgres_image" 1001:1001 /data
  docker run --detach --name "$run-db" --network "$run" --network-alias "$alias" \
    --env POSTGRES_USER=load --env POSTGRES_DB=keyfleet_load \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    "$postgres_image" >/dev/null
  wait_for "the database" 60 docker exec "$run-db" pg_isready --quiet --host 127.0.0.1 --username load
}

# One release command against the database, as Fly runs one on a machine of
# its own.
stack_release_command() {
  docker run --rm --network "$run" "${release_env[@]}" --env DATABASE_DIRECT_URL="$database_url" "$@"
}

stack_prepare_database() {
  stack_release_command "$image" /app/bin/bootstrap-staging
  stack_release_command "$image" /app/bin/migrate
  stack_release_command --volume "$KEYFLEET_DEPLOYED_RECORD:/tmp/base.deployed.json:ro" \
    "$image" /app/bin/seed-deployment /tmp/base.deployed.json
}

# Starts one server named `name` on 127.0.0.1:$port and waits for its health.
# Its metrics port is published on a free port of its own; `metrics` is its
# address.
stack_start_server() {
  local name="$1"
  servers+=("$name")
  docker run --detach --name "$name" --network "$run" "${release_env[@]}" "${server_env[@]}" \
    "${server_size[@]}" \
    --publish "127.0.0.1:$port:4000" --publish 127.0.0.1::9091 \
    --volume "$run-data:/data" \
    --env DATABASE_POOLED_URL="$database_url" \
    "$image" >/dev/null
  metrics="http://$(docker port "$name" 9091/tcp | head -n 1)"
  wait_for "the health endpoint of $name" 120 curl --silent --fail "http://127.0.0.1:$port/healthz"
}

# The server has production's pool and as many schedulers as processors.
stack_check_server() {
  local name="$1" pool schedulers
  pool="$(docker exec "$name" /app/bin/keyfleet rpc 'IO.puts(Keyfleet.Repo.config()[:pool_size])' | tail -n 1)"
  [[ $pool == 5 ]] || fail "the server's database pool is $pool connections; production's is 5."
  schedulers="$(docker exec "$name" /app/bin/keyfleet rpc 'IO.puts(:erlang.system_info(:schedulers_online))' | tail -n 1)"
  echo "server   $name: database pool $pool, $schedulers schedulers online (production: 2)" | tee -a "$out/versions.txt"
}

# Runs visitors.js with k6 against the server, writing the summary to
# $out/<scenario>.json and k6's output to $out/k6.log. Start it in the
# background (stack_k6 ramp &): it becomes the k6 process, so $! is k6's own
# and stopping it stops k6. Settings the caller's environment holds (PAGES,
# RAMP, ...) reach k6 too, as k6 reads the environment it runs in.
stack_k6() {
  local scenario="$1"
  shift
  exec k6 run --no-usage-report --summary-export "$out/$scenario.json" \
    --env TARGET="http://127.0.0.1:$port" --env ORIGIN="http://localhost:$port" \
    --env SCENARIO="$scenario" "$@" "$here/visitors.js" >"$out/k6.log" 2>&1
}

# The server's metrics now, as $out/metrics/<name>.prom; none when it did not answer.
stack_scrape() {
  curl --silent --fail --max-time 5 --output "$out/metrics/$1.prom" "$metrics/metrics" 2>/dev/null ||
    rm -f "$out/metrics/$1.prom"
}

# Keeps every server's log and removes everything the run started.
stack_teardown() {
  local status="$1" name
  for name in ${servers[@]+"${servers[@]}"}; do
    docker logs "$name" >"$out/$name.log" 2>&1 || true
  done
  if [[ $status -ne 0 && ${#servers[@]} -gt 0 ]]; then
    echo "Last server's log:" >&2
    docker logs --tail 40 "${servers[${#servers[@]} - 1]}" >&2 2>&1 || true
  fi
  # --volumes takes the database's own data volume with it.
  docker rm --force --volumes ${servers[@]+"${servers[@]}"} "$run-proxy" "$run-db" >/dev/null 2>&1 || true
  docker volume rm "$run-data" >/dev/null 2>&1 || true
  docker network rm "$run" >/dev/null 2>&1 || true
}

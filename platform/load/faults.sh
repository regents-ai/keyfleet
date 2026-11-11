#!/usr/bin/env bash
# Runs visitors against a copy of the release on this computer while its
# database is made slow, broken and then stopped, and judges how the site
# holds up.
#
#   KEYFLEET_DEPLOYED_RECORD=/path/to/base.deployed.json platform/load/faults.sh
#   FAULT_PAGES=400 KEYFLEET_DEPLOYED_RECORD=... platform/load/faults.sh
#
# It starts what local.sh starts (lib/stack.sh: the image `make release` built,
# with production's 2 CPUs, 4 GB and pool of 5, against a throwaway PostgreSQL
# 17 on its own Docker network, published on 127.0.0.1:LOAD_PORT), with
# Toxiproxy (ghcr.io/shopify/toxiproxy) between the server and the database:
# the proxy answers to the staging database hostname, so the server and every
# release command reach PostgreSQL only through it. k6 on this computer keeps
# FAULT_PAGES pages open (platform/load/visitors.js, scenario faults), and the
# toxics come in phases: +200 ms on every database reply, +1 s, every
# connection reset for 10 s, the database silent for 10 s, then PostgreSQL
# stopped for 60 s, each followed by a recovery phase. Once a second it asks
# /healthz and the Club's page; at every phase boundary it records the server's
# database queue time from its metrics port and whether the server is still
# the same process.
#
# Pass, phase by phase (summarize.mjs --faults writes the table): every page
# load answers, and a page saying it couldn't be loaded is an answer while a
# 5xx is not; live joins keep succeeding; /healthz answers within Fly's two
# seconds with "ok" or "unavailable", stays "ok" at +200 ms and says
# "unavailable" within 10 s of the database stopping; the site is whole again
# within 30 s of each fault ending; and the server never restarts. Results go
# to platform/load/results/faults-<time>/, and the exit status is the verdict.
set -euo pipefail

# shellcheck source=lib/stack.sh
source "$(dirname "$0")/lib/stack.sh"

pages="${FAULT_PAGES:-200}"
toxiproxy_image="ghcr.io/shopify/toxiproxy:latest"
run="keyfleet-faults-$$"
out="$here/results/faults-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out/metrics"
base="http://127.0.0.1:$port"
prober=""
k6_pid=""

cleanup() {
  local status=$?
  touch "$out/.stop" 2>/dev/null || true
  [[ -n $prober ]] && wait "$prober" 2>/dev/null || true
  [[ -n $k6_pid ]] && kill "$k6_pid" 2>/dev/null || true
  stack_teardown "$status"
  rm -f "$out/.stop" "$out/.health" "$out/.page"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

proxy_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n $body ]]; then
    curl --silent --show-error --fail --request "$method" --header 'Content-Type: application/json' \
      --data "$body" "$api$path" >/dev/null
  else
    curl --silent --show-error --fail --request "$method" "$api$path" >/dev/null
  fi
}

add_toxic() {
  proxy_api POST /proxies/postgres/toxics "$1"
}

# Each fault and how it ends. Toxics act on what PostgreSQL sends back, so a
# query goes out and its answer is late, reset or never comes.
apply_fault() {
  case "$1" in
    latency_200) add_toxic '{"name":"slow","type":"latency","stream":"downstream","attributes":{"latency":200,"jitter":0}}' ;;
    latency_1000) add_toxic '{"name":"slow","type":"latency","stream":"downstream","attributes":{"latency":1000,"jitter":0}}' ;;
    reset) add_toxic '{"name":"reset","type":"reset_peer","stream":"downstream","attributes":{"timeout":0}}' ;;
    timeout) add_toxic '{"name":"silent","type":"timeout","stream":"downstream","attributes":{"timeout":0}}' ;;
    db_down) docker stop --time 10 "$run-db" >/dev/null ;;
    *) ;;
  esac
}

end_fault() {
  case "$1" in
    latency_200 | latency_1000) proxy_api DELETE /proxies/postgres/toxics/slow ;;
    reset) proxy_api DELETE /proxies/postgres/toxics/reset ;;
    timeout) proxy_api DELETE /proxies/postgres/toxics/silent ;;
    db_down) docker start "$run-db" >/dev/null ;;
    *) ;;
  esac
}

# The server's metrics at a phase boundary, and whether it is the process it
# was: a restart shows as a new start time.
checkpoint() {
  curl --silent --max-time 5 "$metrics/metrics" >"$out/metrics/$1.prom" 2>/dev/null || true
  printf '%s\t%s\n' "$(now_ms)" \
    "$(docker inspect --format '{{.State.Running}}{{"\t"}}{{.State.StartedAt}}{{"\t"}}{{.RestartCount}}' "$run-app" 2>/dev/null || printf 'false\tgone\t0')" \
    >>"$out/container.tsv"
}

# Once a second until told to stop: health, then the Club's hall as a visitor
# sees it, each with its status and time.
probe() {
  while [[ ! -e "$out/.stop" ]]; do
    local at health page degraded
    at="$(now_ms)"
    rm -f "$out/.health" "$out/.page"
    health="$(curl --silent --max-time 5 --output "$out/.health" --write-out '%{http_code} %{time_total}' "$base/healthz" || true)"
    page="$(curl --silent --max-time 30 --output "$out/.page" --write-out '%{http_code} %{time_total}' "$base/app/fleets/regents_club" || true)"
    degraded=0
    if grep -qE "couldn(’|'|&#39;)t be loaded|aren(’|'|&#39;)t showing right now" "$out/.page" 2>/dev/null; then degraded=1; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$at" \
      "$(awk '{ print $1 }' <<<"${health:-000 0}")" "$(awk '{ printf "%d", $2 * 1000 }' <<<"${health:-000 0}")" \
      "$(head -c 20 "$out/.health" 2>/dev/null | tr -d '\t\n')" \
      "$(awk '{ print $1 }' <<<"${page:-000 0}")" "$(awk '{ printf "%d", $2 * 1000 }' <<<"${page:-000 0}")" \
      "$degraded" >>"$out/probes.tsv"
    sleep 1
  done
}

stack_preflight
: >"$out/probes.tsv"
: >"$out/container.tsv"

echo "==> Starting PostgreSQL 17 and Toxiproxy in front of it"
stack_start_database faults-db
# Listening on :: takes IPv6, which the server's database connection uses
# (socket_options: [:inet6]), and IPv4 for the published API port.
docker run --detach --name "$run-proxy" --network "$run" --network-alias regents-staging-db.internal \
  --publish 127.0.0.1::8474 "$toxiproxy_image" -host=:: >/dev/null
api="http://$(docker port "$run-proxy" 8474/tcp | head -n 1)"
wait_for "Toxiproxy" 60 curl --silent --fail "$api/version"
proxy_api POST /proxies '{"name":"postgres","listen":"[::]:5432","upstream":"faults-db:5432","enabled":true}'

echo "==> Creating, migrating and seeding the database through the proxy"
stack_prepare_database

echo "==> Starting $image: the graph machine, then the site on $base"
stack_start_graph "$run-graph"
stack_start_server "$run-app"
stack_check_server "$run-app"

# The plan: name, seconds, kind, what health should say, what is done.
plan=(
  "baseline|60|baseline|ok|Nothing: the site as it stands"
  "latency_200|90|fault|ok|Every database reply 200 ms late"
  "recover_200|45|recover|any|Delay removed"
  "latency_1000|90|fault|any|Every database reply 1 s late"
  "recover_1000|45|recover|any|Delay removed"
  "reset|10|fault|any|Every database connection reset"
  "recover_reset|45|recover|any|Resets stopped"
  "timeout|10|fault|any|The database stops answering; connections stay open"
  "recover_timeout|45|recover|any|Answers flow again"
  "db_down|60|fault|unavailable|PostgreSQL stopped"
  "recover_db_down|60|recover|any|PostgreSQL started again"
)

# The pages are open and settled a minute from now; the phases follow back to
# back. k6 and this script share the times, so both tag the same moments.
at=$(($(now_ms) + 60000))
names=()
froms=()
phases="["
for entry in "${plan[@]}"; do
  IFS='|' read -r name length kind health does <<<"$entry"
  names+=("$name")
  froms+=("$at")
  phases+="{\"name\":\"$name\",\"from\":$at,\"to\":$((at + length * 1000)),\"kind\":\"$kind\",\"health\":\"$health\",\"does\":\"$does\"},"
  at=$((at + length * 1000))
done
froms+=("$at")
phases="${phases%,}]"
printf '%s\n' "$phases" >"$out/phases.json"

echo "==> Opening $pages pages with k6; the first phase starts in a minute"
stack_k6 faults --env PHASES="$phases" --env FAULT_PAGES="$pages" &
k6_pid=$!

probe &
prober=$!

for i in "${!names[@]}"; do
  name="${names[$i]}"
  sleep_until "${froms[$i]}"
  checkpoint "$name.start"
  echo "==> $(date +%H:%M:%S) $name: $(IFS='|' read -r _ _ _ _ does <<<"${plan[$i]}"; echo "$does")"
  apply_fault "$name"
  sleep_until "${froms[$((i + 1))]}"
  checkpoint "$name.end"
  end_fault "$name"
done

echo "==> Waiting for the last visitors to leave"
k6_status=0
wait "$k6_pid" || k6_status=$?
k6_pid=""
touch "$out/.stop"
wait "$prober" || true
prober=""
checkpoint "after"
echo "k6 finished with status $k6_status (99 means a threshold was crossed); its log is $out/k6.log"

echo
node "$here/summarize.mjs" --faults "$out" | tee "$out/report.md"

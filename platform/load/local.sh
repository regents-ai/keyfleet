#!/usr/bin/env bash
# Loads a copy of the release on this computer with signed-out visitors, and
# judges it by the launch targets.
#
#   platform/load/local.sh smoke     # 5 pages for under two minutes: check the setup
#   platform/load/local.sh ramp      # 0 to 2,000 pages over 10 minutes, held 10
#   platform/load/local.sh spike     # 500 new pages within 30 seconds
#   platform/load/local.sh storm     # every open page's connection dropped at once
#   platform/load/local.sh deploy    # both machines replaced while 2,000 pages are open
#   platform/load/local.sh zap       # the OWASP ZAP baseline scan (zap-baseline.sh)
#
# Each run needs the image `make release` built for this commit
# (keyfleet:<commit>, or IMAGE) and KEYFLEET_DEPLOYED_RECORD naming the Regents
# Club's base.deployed.json. It starts that image against a throwaway
# PostgreSQL 17 on a Docker network of its own (lib/stack.sh says how), as
# production's graph machine and site machine, the site with production's
# 2 CPUs, 4 GB and database pool of 5, published on 127.0.0.1:LOAD_PORT (4100). k6 (brew install k6) runs visitors.js against it
# from this computer; the scenario's settings (PAGES, RAMP, ...: README.md)
# reach k6 from the environment. Everything the run started is removed when it
# ends, however it ends.
#
# The deploy run replaces both machines in scripts/deploy.sh's order: once the
# pages are open and settled, the release command (/app/bin/migrate) runs on
# its own container, the graph machine is stopped with Fly's default signal and
# kill timeout (SIGINT, 5 s) and a new one starts on the same /data volume, then
# the old site server is stopped the same way and a second one from the same
# image, with the same secret, starts on the same port. Production releases the
# site machine bluegreen behind Fly's proxy, which has no stand-in here, so the
# site's stop and start is the harshest case of it: every open page drops and
# rejoins. Meanwhile the home page is asked twice a second, which gives the gap
# in which nothing answered. Pass: lv_rejoin_lost = 0, every open page joined
# again within 120 s of its drop.
#
# Results go to platform/load/results/<scenario>-<time>/: the k6 summary
# (<scenario>.json), k6.log, each server's log, its metrics, versions.txt and
# report.md, the table summarize.mjs writes. The exit status is the verdict: 0
# when every pass mark held.
set -euo pipefail

scenario="${1:-}"
case "$scenario" in
  smoke | ramp | spike | storm | deploy | zap) ;;
  *)
    echo "Usage: platform/load/local.sh smoke|ramp|spike|storm|deploy|zap" >&2
    exit 2
    ;;
esac

# shellcheck source=lib/stack.sh
source "$(dirname "$0")/lib/stack.sh"

run="keyfleet-local-$$"
out="$here/results/$scenario-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out/metrics"
k6_pid=""
follower=""
prober=""

cleanup() {
  local status=$?
  touch "$out/.stop" 2>/dev/null || true
  [[ -n $k6_pid ]] && kill "$k6_pid" 2>/dev/null || true
  [[ -n $follower ]] && kill "$follower" 2>/dev/null || true
  [[ -n $prober ]] && wait "$prober" 2>/dev/null || true
  stack_teardown "$status"
  rm -f "$out/.stop"
  if [[ $status -ne 0 ]]; then echo "Results so far: $out" >&2; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# k6 runs in the background, so a run can still be stopped and cleaned up as
# one, and its progress is shown here every 30 seconds.
start_k6() {
  stack_k6 "$scenario" "$@" &
  k6_pid=$!
  (
    while sleep 30 && kill -0 "$k6_pid" 2>/dev/null; do
      tail -n 20 "$out/k6.log" | grep '^running (' | tail -n 1 || true
    done
  ) &
  follower=$!
}

wait_k6() {
  k6_status=0
  wait "$k6_pid" || k6_status=$?
  k6_pid=""
  kill "$follower" 2>/dev/null || true
  follower=""
  echo "k6 exited $k6_status (99: a pass mark was crossed); its log is $out/k6.log"
}

# The table, and the verdict: k6's status, or the report's when k6 ran to the
# end. k6 writes no summary when it stopped before the run, such as at a
# refused target (107) or a page missing in setup (108); its log says why.
report() {
  [[ -s $out/$scenario.json ]] || {
    tail -n 20 "$out/k6.log" >&2
    fail "k6 wrote no summary (exit $k6_status)."
  }
  echo
  local summarized=0
  node "$here/summarize.mjs" "$out/$scenario.json" | tee -a "$out/report.md" || summarized=$?
  echo
  echo "Report: $out/report.md"
  if [[ $k6_status -ne 0 && $k6_status -ne 99 ]]; then exit "$k6_status"; fi
  exit "$summarized"
}

# Twice a second until told to stop: the time and the home page's status, 000
# when nothing answered within 2 seconds.
probe() {
  while [[ ! -e "$out/.stop" ]]; do
    printf '%s\t%s\n' "$(now_ms)" \
      "$(curl --silent --output /dev/null --max-time 2 --write-out '%{http_code}' "http://127.0.0.1:$port/" || true)" \
      >>"$out/probes.tsv"
    sleep 0.5
  done
}

deploy_run() {
  local ramp_s hold_s window_ms=120000 deploy_at phases
  ramp_s="$(duration_s "${RAMP:-10m}")"
  hold_s="$(duration_s "${DEPLOY_HOLD:-20m}")"
  # The pages settle for two minutes after the ramp, the deploy phase takes two
  # more, and a page that dropped then has 120 s to come back, all inside the
  # hold, so no visitor's leave is mistaken for the deploy's doing.
  ((hold_s >= 420)) || fail "DEPLOY_HOLD must be at least 7m: two minutes to settle, two for the deploy and two to rejoin."

  # k6 takes up to half a minute to start and check every page; the stages start after.
  deploy_at=$(($(now_ms) + (30 + ramp_s + 120) * 1000))
  phases="[{\"name\":\"before\",\"from\":0,\"to\":$deploy_at},"
  phases+="{\"name\":\"deploy\",\"from\":$deploy_at,\"to\":$((deploy_at + window_ms))},"
  phases+="{\"name\":\"after\",\"from\":$((deploy_at + window_ms)),\"to\":9999999999999}]"
  printf '%s\n' "$phases" >"$out/phases.json"

  : >"$out/probes.tsv"
  probe &
  prober=$!

  stack_scrape start
  echo "==> Opening ${PAGES:-2000} pages; the deploy starts in $(((deploy_at - $(now_ms)) / 1000)) s, once they are open and settled"
  start_k6 --env PHASES="$phases"
  sleep_until "$deploy_at"

  local release_from release_to graph_to stop_to healthy_at
  echo "==> $(date +%H:%M:%S) Deploying: the release command, the graph machine replaced, then the old server stopped and the new one started"
  release_from="$(now_ms)"
  stack_release_command "$image" /app/bin/migrate >"$out/deploy.log" 2>&1 ||
    fail "the release command failed; see $out/deploy.log"
  release_to="$(now_ms)"
  docker stop --signal SIGINT --time 5 "$run-graph-1" >>"$out/deploy.log" 2>&1
  stack_start_graph "$run-graph-2"
  graph_to="$(now_ms)"
  stack_scrape end
  docker stop --signal SIGINT --time 5 "$run-app-1" >>"$out/deploy.log" 2>&1
  stop_to="$(now_ms)"
  stack_start_server "$run-app-2"
  healthy_at="$(now_ms)"
  stack_scrape after-start
  echo "==> $(date +%H:%M:%S) The new server answers its health check; the pages are rejoining"
  stack_check_server "$run-app-2"
  ((healthy_at - release_from < window_ms)) ||
    echo "The deploy outlasted its two-minute phase, so failed page loads after it are judged as failures." >&2

  wait_k6
  stack_scrape after-end
  touch "$out/.stop"
  wait "$prober" || true
  prober=""

  # The longest stretch, from the old server's stop to two minutes after the new
  # one answered, from a probe that got no 200 to the next that did.
  local gap
  gap="$(awk -F'\t' -v from="$release_to" -v to="$((healthy_at + 120000))" '
    $1 >= from && $1 <= to {
      if ($2 == "200") { if (down) { if ($1 - began > longest) longest = $1 - began; down = 0 } }
      else if (!down) { down = 1; began = $1 }
    }
    END { print (down ? -1 : longest + 0) }' "$out/probes.tsv")"
  [[ $gap -ge 0 ]] || fail "the home page was still not answering two minutes after the new server's health check."

  {
    echo "## Deploy"
    echo
    echo "| Step | Took |"
    echo "| --- | --- |"
    echo "| Release command (/app/bin/migrate), old server still serving | $(((release_to - release_from) / 1000)) s |"
    echo "| Graph machine stopped (SIGINT, 5 s to finish) and the new one started | $(((graph_to - release_to) / 1000)) s |"
    echo "| Old server stopped (SIGINT, 5 s to finish) | $(((stop_to - graph_to) / 1000)) s |"
    echo "| New server started and answered its health check | $(((healthy_at - stop_to) / 1000)) s |"
    echo "| Longest time the home page did not answer | $(awk "BEGIN { printf \"%.1f\", $gap / 1000 }") s |"
    echo
    echo "Pass: no page lost (lv_rejoin_lost = 0). Page loads that failed are judged before and after the deploy phase and measured inside it: every new visitor in the gap fails."
    echo
  } | tee "$out/report.md"
  report
}

stack_preflight

echo "==> Starting PostgreSQL 17"
stack_start_database regents-staging-db.internal
echo "==> Creating, migrating and seeding the database with the release commands"
stack_prepare_database
echo "==> Starting $image: the graph machine, then the site on http://127.0.0.1:$port"
stack_start_graph "$run-graph-1"
stack_start_server "$run-app-1"
stack_check_server "$run-app-1"

case "$scenario" in
  zap)
    "$here/zap-baseline.sh" "http://localhost:$port" "$out/zap"
    ;;
  deploy)
    deploy_run
    ;;
  *)
    stack_scrape start
    start_k6
    wait_k6
    stack_scrape end
    report
    ;;
esac

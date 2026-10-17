#!/usr/bin/env bash
# The restore drill: proves Keyfleet's data comes back, on scratch copies only.
#
#   scripts/restore-drill.sh check                  # reads only
#   scripts/restore-drill.sh snapshot --live        # snapshots both live volumes
#   scripts/restore-drill.sh restore-volumes --live # scratch volumes and machines
#   scripts/restore-drill.sh verify-volumes         # reads the scratch copies
#   scripts/restore-drill.sh restore-db --live [--at <RFC3339 UTC>]
#   scripts/restore-drill.sh verify-db              # reads both clusters
#   scripts/restore-drill.sh cleanup --live         # removes what the drill made
#   scripts/restore-drill.sh rollback <version> --live   # incidents only
#
# docs/restore-drill.md is the runbook: the order, the expected output and what
# each step proves. Every step that changes anything on Fly is refused without
# --live, and --live is given only after Sean has typed his go for the drill.
# The drill never writes to the live volumes or the production database: it
# snapshots the volumes, restores the snapshots onto scratch volumes, and
# restores the database into a new cluster. Cleanup removes only what this
# drill recorded making, and refuses anything that is live.
#
# What the drill made is recorded in KEYFLEET_DRILL_STATE (default
# ~/.keyfleet/restore-drill), one file per fact, so the steps can run in
# separate sittings and cleanup knows exactly what to remove.
set -euo pipefail

APP="keyfleet"
LIVE_MACHINE="d891115dbe7098"
GRAPH_VOLUME="keyfleet_graph"
CODE_APP="keyfleet-code"
CODE_VOLUME="keyfleet_code_data"
CLUSTER="dzx6qo6xqzvojpv5"
CLUSTER_NAME="regents-platform-prod"
ORG="regents"
REGION="iad"
SITE="https://keyfleet.ai"
DRILL_MACHINE="restore-drill"
DRILL_GRAPH_VOLUME="keyfleet_graph_drill"
DRILL_CODE_VOLUME="keyfleet_code_drill"
DRILL_CLUSTER_PREFIX="keyfleet-drill-"

root="$(cd "$(dirname "$0")/.." && pwd)"
checks="$root/scripts/restore-drill"
state="${KEYFLEET_DRILL_STATE:-$HOME/.keyfleet/restore-drill}"

usage() {
  sed -n '4,11p' "$0" | sed 's/^# //' >&2
  exit 2
}

fail() {
  echo "Refusing: $*" >&2
  exit 1
}

say() { echo "==> $*"; }

remember() {
  mkdir -p "$state"
  printf '%s\n' "$2" >"$state/$1"
}

recall() {
  [[ -s "$state/$1" ]] || fail "nothing recorded as $1 in $state; run the earlier steps first."
  cat "$state/$1"
}

recalled() { [[ -s "$state/$1" ]]; }

# A recorded list, which may be empty, such as a code store with no repositories.
recall_path() {
  [[ -f "$state/$1" ]] || fail "nothing recorded as $1 in $state; run check first."
  echo "$state/$1"
}

require_live() {
  [[ "$live" == true ]] || fail "this step changes Fly. Run it with --live, and only after Sean's typed go for the drill."
}

require_tools() {
  local tool
  for tool in fly jq psql curl; do
    command -v "$tool" >/dev/null || fail "$tool is not installed."
  done
}

site_answers() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "$SITE/healthz")"
  [[ "$code" == 200 ]] || fail "$SITE/healthz answered $code."
  echo "$SITE/healthz answered 200"
}

# Runs a command on a machine and prints what it prints. Nothing secret is ever
# printed: callers cut connection strings down to their host and database.
on_machine() {
  local app="$1" machine="$2" command="$3"
  fly ssh console --app "$app" --machine "$machine" --quiet --command "$command"
}

# The live volume of that name attached to that machine, as JSON.
live_volume() {
  local app="$1" name="$2" machine="$3"
  fly volumes list --app "$app" --json |
    jq -e --arg name "$name" --arg machine "$machine" \
      '[.[] | select(.name == $name and .attached_machine_id == $machine)] | if length == 1 then .[0] else empty end'
}

machine_by_name() {
  local app="$1" name="$2"
  fly machine list --app "$app" --json | jq -r --arg name "$name" '.[] | select(.name == $name) | .id'
}

volume_by_name() {
  local app="$1" name="$2"
  fly volumes list --app "$app" --json | jq -r --arg name "$name" '.[] | select(.name == $name) | .id'
}

# The cluster's status column in `fly mpg list`. `fly mpg status --json` is
# never used: it carries the cluster's credentials.
cluster_status() {
  fly mpg list --org "$ORG" | awk -v id="$1" '$1 == id { print $5 }'
}

# `<host>/<database>` from a connection URL held in a machine's environment,
# cut down on the machine so the credentials never leave it. Anything that is
# not such a URL prints nothing.
database_address() {
  local app="$1" machine="$2" variable="$3"
  on_machine "$app" "$machine" \
    "sh -c 'printenv $variable | sed -n \"s,^postgres[a-z]*://[^@/]*@\\([^:/?]*\\)[^/]*/\\([^?]*\\).*,\\1/\\2,p\"'"
}

# The bare repositories under a code store's repos folder, one name per line.
repositories() {
  local app="$1" machine="$2" repos="$3"
  on_machine "$app" "$machine" \
    "sh -c 'find $repos -name HEAD -type f -not -path \"*/refs/*\" -not -path \"*/logs/*\"'" |
    tr -d '\r' | sed -n "s,^$repos/\(.*\)/HEAD\$,\1,p" | sort
}

drill_clusters() {
  fly mpg list --org "$ORG" | awk -v prefix="$DRILL_CLUSTER_PREFIX" 'index($2, prefix) == 1 { print $1, $2 }'
}

check() {
  require_tools
  say "flyctl and its sign-in"
  fly version
  fly auth whoami

  say "The live site"
  site_answers
  fly status --app "$APP"

  say "Releases (newest first; the one under the live release is the rollback target)"
  fly releases --app "$APP" --image | sed -n '1,6p'

  say "The live volumes and their scheduled snapshots"
  local graph code code_machine
  graph="$(live_volume "$APP" "$GRAPH_VOLUME" "$LIVE_MACHINE")" ||
    fail "no $GRAPH_VOLUME volume attached to $LIVE_MACHINE."
  jq -r '"\(.name) \(.id) \(.size_gb) GB, snapshots kept \(.snapshot_retention) days, scheduled \(.auto_backup_enabled)"' <<<"$graph"
  remember graph_volume "$(jq -r .id <<<"$graph")"
  remember graph_size "$(jq -r .size_gb <<<"$graph")"
  fly volumes snapshots list "$(recall graph_volume)" --app "$APP"

  code_machine="$(fly machine list --app "$CODE_APP" --json |
    jq -r --arg name "$CODE_VOLUME" '[.[] | select(.config.mounts // [] | any(.name == $name))] | if length == 1 then .[0].id else empty end')"
  [[ -n "$code_machine" ]] || fail "no single $CODE_APP machine mounts $CODE_VOLUME."
  code="$(live_volume "$CODE_APP" "$CODE_VOLUME" "$code_machine")" ||
    fail "no $CODE_VOLUME volume attached to $code_machine."
  jq -r '"\(.name) \(.id) \(.size_gb) GB, snapshots kept \(.snapshot_retention) days, scheduled \(.auto_backup_enabled)"' <<<"$code"
  remember code_machine "$code_machine"
  remember code_volume "$(jq -r .id <<<"$code")"
  remember code_size "$(jq -r .size_gb <<<"$code")"
  fly volumes snapshots list "$(recall code_volume)" --app "$CODE_APP"

  say "The live graph files"
  on_machine "$APP" "$LIVE_MACHINE" "ls /data/graph" | tr -d '\r' | sed -n 's/\.sqlite$//p' | sort >"$state/live_graphs"
  cat "$state/live_graphs"

  say "The live code store's repositories"
  repositories "$CODE_APP" "$code_machine" /data/repos >"$state/live_repos"
  cat "$state/live_repos"
  echo "repositories: $(wc -l <"$state/live_repos" | tr -d ' ')"

  say "The production database"
  fly mpg list --org "$ORG"
  [[ "$(cluster_status "$CLUSTER")" == ready ]] || fail "cluster $CLUSTER is not ready."
  fly mpg backup list "$CLUSTER"

  local site_db code_db
  site_db="$(database_address "$APP" "$LIVE_MACHINE" DATABASE_POOLED_URL | tr -d '\r')"
  code_db="$(database_address "$CODE_APP" "$code_machine" DATABASE_URL | tr -d '\r')"
  echo "keyfleet reads $site_db"
  echo "keyfleet-code reads $code_db"
  [[ "$site_db" == "direct.$CLUSTER.flympg.net/"* ]] || fail "keyfleet's database is not on $CLUSTER."
  remember site_database "${site_db#*/}"
  case "$code_db" in
    *".$CLUSTER.flympg.net/"*) remember code_database "${code_db#*/}" ;;
    *)
      rm -f "$state/code_database"
      echo "keyfleet-code's database is not on $CLUSTER_NAME, so this drill does not restore it."
      ;;
  esac

  say "Leftovers from an earlier drill"
  local leftovers=""
  leftovers+="$(machine_by_name "$APP" "$DRILL_MACHINE" | sed "s/^/$APP machine /")"$'\n'
  leftovers+="$(machine_by_name "$CODE_APP" "$DRILL_MACHINE" | sed "s/^/$CODE_APP machine /")"$'\n'
  leftovers+="$(volume_by_name "$APP" "$DRILL_GRAPH_VOLUME" | sed "s/^/$APP volume /")"$'\n'
  leftovers+="$(volume_by_name "$CODE_APP" "$DRILL_CODE_VOLUME" | sed "s/^/$CODE_APP volume /")"$'\n'
  leftovers+="$(drill_clusters | sed 's/^/cluster /')"
  leftovers="$(sed '/^$/d' <<<"$leftovers")"
  if [[ -n "$leftovers" ]]; then
    echo "$leftovers"
    echo "cleanup --live removes these when this drill's records name them; otherwise remove them by hand (docs/restore-drill.md)."
  else
    echo "none"
  fi
  echo "Recorded in $state."
}

# Takes a snapshot of one live volume and waits until Fly has made it.
snapshot_volume() {
  local app="$1" volume="$2" key="$3" before snapshot
  before="$(fly volumes snapshots list "$volume" --app "$app" --json | jq -c '[.[].id]')"
  fly volumes snapshots create "$volume" --app "$app"
  for _ in $(seq 60); do
    snapshot="$(fly volumes snapshots list "$volume" --app "$app" --json |
      jq -r --argjson before "$before" \
        '[.[] | select(.id != "" and .status == "created" and (.id as $id | $before | index($id) | not))] | first | .id // empty')"
    if [[ -n "$snapshot" ]]; then
      remember "$key" "$snapshot"
      echo "$volume: snapshot $snapshot"
      return
    fi
    sleep 10
  done
  fail "the snapshot of $volume was not made within ten minutes."
}

snapshot() {
  require_live
  require_tools
  say "Snapshotting the live volumes (they stay attached and in use)"
  snapshot_volume "$APP" "$(recall graph_volume)" graph_snapshot
  snapshot_volume "$CODE_APP" "$(recall code_volume)" code_snapshot
  site_answers
}

# Restores one snapshot onto a new scratch volume and starts a machine that
# mounts it at /drill and only sleeps: no services, so no traffic reaches it.
restore_volume() {
  local app="$1" image="$2" name="$3" size="$4" snapshot="$5" check="$6" key="$7"
  [[ -z "$(volume_by_name "$app" "$name")" ]] || fail "$app already has a $name volume; run cleanup --live first."
  [[ -z "$(machine_by_name "$app" "$DRILL_MACHINE")" ]] || fail "$app already has a $DRILL_MACHINE machine; run cleanup --live first."

  local volume machine
  volume="$(fly volumes create "$name" --app "$app" --region "$REGION" --size "$size" \
    --snapshot-id "$snapshot" --scheduled-snapshots=false --yes --json | jq -r .id)"
  remember "${key}_volume" "$volume"
  echo "$app: scratch volume $name $volume from $snapshot"

  # The command replaces the image's own, so the machine only sleeps.
  fly machine run "$image" --app "$app" --region "$REGION" --name "$DRILL_MACHINE" \
    --volume "$volume:/drill" --vm-size shared-cpu-1x --vm-memory 1024 \
    --restart no --entrypoint sleep \
    --file-local "/restore-drill/$(basename "$check")=$check" \
    infinity
  machine="$(machine_by_name "$app" "$DRILL_MACHINE")"
  [[ -n "$machine" && "$machine" != "$LIVE_MACHINE" ]] || fail "the $app drill machine did not start."
  remember "${key}_machine" "$machine"
  echo "$app: drill machine $machine"
}

restore_volumes() {
  require_live
  require_tools
  local image code_image
  image="$(fly machine list --app "$APP" --json | jq -r --arg id "$LIVE_MACHINE" '.[] | select(.id == $id) | .config.image')"
  code_image="$(fly machine list --app "$CODE_APP" --json | jq -r --arg id "$(recall code_machine)" '.[] | select(.id == $id) | .config.image')"

  say "Restoring the graph volume's snapshot onto a scratch volume"
  restore_volume "$APP" "$image" "$DRILL_GRAPH_VOLUME" "$(recall graph_size)" \
    "$(recall graph_snapshot)" "$checks/check_graph.py" drill_graph
  say "Restoring the code store volume's snapshot onto a scratch volume"
  restore_volume "$CODE_APP" "$code_image" "$DRILL_CODE_VOLUME" "$(recall code_size)" \
    "$(recall code_snapshot)" "$checks/check_code.sh" drill_code
  site_answers
}

verify_volumes() {
  require_tools
  say "Opening every restored fleet graph"
  if ! on_machine "$APP" "$(recall drill_graph_machine)" \
    "/opt/graph_host/.venv/bin/python -I /restore-drill/check_graph.py /drill/graph" |
    tr -d '\r' | tee "$state/restored_graphs"; then
    fail "a restored graph failed its integrity check, or none was found."
  fi
  local missing
  missing="$(comm -23 "$state/live_graphs" <(awk '{ print $1 }' "$state/restored_graphs" | sort))"
  [[ -z "$missing" ]] || fail "graphs live but not restored: $missing"
  echo "Every live fleet graph came back and passes its integrity check."

  say "Checking the restored code store"
  if ! on_machine "$CODE_APP" "$(recall drill_code_machine)" "sh /restore-drill/check_code.sh /drill" |
    tr -d '\r' | tee "$state/restored_code"; then
    fail "the restored code store's key is missing or a repository failed its check."
  fi
  missing="$(comm -23 "$(recall_path live_repos)" <(awk '$2 == "ok" { print $1 }' "$state/restored_code" | sort))"
  [[ -z "$missing" ]] || fail "repositories live but not restored: $missing"
  echo "The code store's key and every live repository came back."
}

restore_db() {
  require_live
  require_tools
  [[ "$(cluster_status "$CLUSTER")" == ready ]] || fail "cluster $CLUSTER is not ready."
  ! recalled drill_cluster_name || fail "a restored cluster is already recorded; run cleanup --live first."

  local at name cluster status
  at="${at_time:-$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)}"
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "--at must look like 2026-10-17T03:00:00Z."
  name="$DRILL_CLUSTER_PREFIX$(date -u +%Y%m%d%H%M)"

  # The name is recorded first, so cleanup can find the copy by it even if this
  # step stops before Fly's answer is read.
  remember drill_cluster_name "$name"
  remember drill_at "$at"
  say "Restoring $CLUSTER_NAME as it was at $at into a new cluster, $name"
  local out
  out="$(fly mpg restore "$CLUSTER" --pitr-time "$at" --name "$name")"
  echo "$out"
  cluster="$(awk '/Cluster ID:/ { print $3 }' <<<"$out")"
  [[ -n "$cluster" && "$cluster" != "$CLUSTER" ]] || fail "the restore did not report a new cluster."
  remember drill_cluster "$cluster"

  say "Waiting for $cluster to be ready"
  for _ in $(seq 180); do
    status="$(cluster_status "$cluster")"
    if [[ "$status" == ready ]]; then
      echo "$cluster is ready."
      site_answers
      return
    fi
    [[ "$status" != failed && "$status" != error ]] || fail "the restore ended as $status."
    sleep 30
  done
  fail "$cluster was not ready within 90 minutes; check fly mpg list and run verify-db when it is."
}

# Reads that name rows by id and hash only, so no person's words or details
# leave the database. The cutoff sits five minutes before the restore point,
# so a row written just before it has surely been committed.
site_fingerprint() {
  local cutoff="$1"
  cat <<SQL
\\set QUIET on
\\set ON_ERROR_STOP on
SET default_transaction_read_only = on;
\\pset expanded off
\\pset tuples_only on
\\pset format unaligned
\\pset fieldsep ' '
SELECT 'migration', max(version) FROM keyfleet_app.schema_migrations;
SELECT 'fleets', count(*), md5(string_agg(id, ',' ORDER BY id)) FROM keyfleet_app.fleets;
SELECT 'newest-message', coalesce((SELECT concat_ws(' ', id, inserted_at) FROM keyfleet_app.messages
  WHERE inserted_at < TIMESTAMP '$cutoff' ORDER BY inserted_at DESC, id DESC LIMIT 1), 'none');
SELECT 'newest-notebook-result', coalesce((SELECT concat_ws(' ', fleet_id, notebook_id, source_id, saved_at, md5(page))
  FROM keyfleet_app.notebook_saved_outputs
  WHERE inserted_at < TIMESTAMP '$cutoff' ORDER BY inserted_at DESC, id DESC LIMIT 1), 'none');
SELECT 'messages-before-cutoff', count(*) FROM keyfleet_app.messages WHERE inserted_at < TIMESTAMP '$cutoff';
SELECT 'notebook-results-before-cutoff', count(*) FROM keyfleet_app.notebook_saved_outputs
  WHERE inserted_at < TIMESTAMP '$cutoff';
SQL
}

code_fingerprint() {
  cat <<'SQL'
\set QUIET on
\set ON_ERROR_STOP on
SET default_transaction_read_only = on;
\pset expanded off
\pset tuples_only on
\pset format unaligned
\pset fieldsep ' '
SELECT 'code-repositories', count(*), md5(coalesce(string_agg(id || ':' || name, ',' ORDER BY id), '')) FROM repos;
SQL
}

# Runs one read against a cluster and keeps only the labelled answer lines.
# flyctl starts psql without -X, so the operator's own psqlrc is set aside.
read_cluster() {
  local cluster="$1" database="$2"
  PSQLRC=/dev/null fly mpg connect "$cluster" --database "$database" |
    tr -d '\r' | grep -E '^(migration|fleets|newest-|messages-|notebook-|code-)' || true
}

compare() {
  local label="$1" production="$2" restored="$3" required="$4" line want got
  for line in $required; do
    want="$(grep "^$line " "$production" || true)"
    got="$(grep "^$line " "$restored" || true)"
    [[ -n "$want" ]] || fail "$label: production gave no $line line."
    [[ "$want" == "$got" ]] || fail "$label: $line differs. Production: $want; restored: ${got:-nothing}."
    echo "$label: $line matches ($want)"
  done
  echo "$label, counts (production now, then restored):"
  grep -h -- '-before-cutoff' "$production" "$restored" || true
}

verify_db() {
  require_tools
  local cluster at cutoff site_db
  cluster="$(recall drill_cluster)"
  at="$(recall drill_at)"
  site_db="$(recall site_database)"
  [[ "$cluster" != "$CLUSTER" ]] || fail "the recorded drill cluster is production."
  [[ "$(cluster_status "$cluster")" == ready ]] || fail "$cluster is not ready yet."
  cutoff="$(date -u -j -v-5M -f %Y-%m-%dT%H:%M:%SZ "$at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
    date -u -d "$at - 5 minutes" '+%Y-%m-%d %H:%M:%S')"

  say "Reading Keyfleet's rows written before $cutoff UTC, in production and in the restore"
  site_fingerprint "$cutoff" | read_cluster "$CLUSTER" "$site_db" >"$state/site_production"
  site_fingerprint "$cutoff" | read_cluster "$cluster" "$site_db" >"$state/site_restored"
  compare keyfleet "$state/site_production" "$state/site_restored" \
    "migration fleets newest-message newest-notebook-result"

  if recalled code_database; then
    say "Reading the code store's repositories, in production and in the restore"
    code_fingerprint | read_cluster "$CLUSTER" "$(recall code_database)" >"$state/code_production"
    code_fingerprint | read_cluster "$cluster" "$(recall code_database)" >"$state/code_restored"
    compare keyfleet-code "$state/code_production" "$state/code_restored" "code-repositories"
  fi
  site_answers
}

# Removes one recorded drill machine, after checking it is the drill's.
remove_machine() {
  local app="$1" key="$2" machine name
  recalled "$key" || return 0
  machine="$(recall "$key")"
  [[ "$machine" != "$LIVE_MACHINE" ]] || fail "$machine is the live machine."
  name="$(fly machine list --app "$app" --json | jq -r --arg id "$machine" '.[] | select(.id == $id) | .name')"
  if [[ -n "$name" ]]; then
    [[ "$name" == "$DRILL_MACHINE" ]] || fail "$machine is named $name, not $DRILL_MACHINE."
    fly machine destroy "$machine" --app "$app" --force
  fi
  rm -f "$state/$key"
}

# Removes one recorded drill volume, after checking it is the drill's and free.
remove_volume() {
  local app="$1" key="$2" expected="$3" volume found
  recalled "$key" || return 0
  volume="$(recall "$key")"
  found="$(fly volumes list --app "$app" --json | jq -c --arg id "$volume" '.[] | select(.id == $id)')"
  if [[ -n "$found" ]]; then
    [[ "$(jq -r .name <<<"$found")" == "$expected" ]] || fail "$volume is not named $expected."
    # A destroyed machine lets go of its volume a moment later.
    for _ in $(seq 12); do
      [[ "$(jq -r '.attached_machine_id // ""' <<<"$found")" == "" ]] && break
      sleep 5
      found="$(fly volumes list --app "$app" --json | jq -c --arg id "$volume" '.[] | select(.id == $id)')"
    done
    [[ "$(jq -r '.attached_machine_id // ""' <<<"$found")" == "" ]] || fail "$volume is still attached."
    fly volumes destroy "$volume" --app "$app" --yes
  fi
  rm -f "$state/$key"
}

cleanup() {
  require_live
  require_tools
  say "Removing the drill machines and scratch volumes"
  remove_machine "$APP" drill_graph_machine
  remove_machine "$CODE_APP" drill_code_machine
  remove_volume "$APP" drill_graph_volume "$DRILL_GRAPH_VOLUME"
  remove_volume "$CODE_APP" drill_code_volume "$DRILL_CODE_VOLUME"

  if recalled drill_cluster_name; then
    local cluster name
    name="$(recall drill_cluster_name)"
    [[ "$name" == "$DRILL_CLUSTER_PREFIX"* ]] || fail "the recorded drill cluster is named $name."
    # Found by its exact name, which restore-db records before asking Fly.
    cluster="$(drill_clusters | awk -v name="$name" '$2 == name { print $1 }')"
    if recalled drill_cluster; then
      [[ -z "$cluster" || "$cluster" == "$(recall drill_cluster)" ]] ||
        fail "the cluster named $name is $cluster, not the recorded $(recall drill_cluster)."
    fi
    if [[ -n "$cluster" ]]; then
      [[ "$cluster" != "$CLUSTER" ]] || fail "the cluster named $name is production."
      say "Removing the restored cluster $name"
      fly mpg destroy "$cluster" --yes
    else
      echo "No cluster named $name is listed; check fly mpg list --org $ORG before the next drill."
    fi
  fi

  # What check records is read again by the next drill's check, and nothing
  # of this drill is used by the next one.
  rm -rf -- "$state"

  say "The live site after the drill"
  site_answers
  fly status --app "$APP"
  echo "The snapshots the drill took stay until their retention ends."
}

# Puts an earlier release's image back. Code only: the database keeps every
# migration, and the release command finds nothing to run.
rollback() {
  require_live
  require_tools
  [[ "$rollback_version" =~ ^v?[0-9]+$ ]] || fail "name the Fly release to go back to, such as v78."
  local version="${rollback_version#v}" releases image live_image commit live_commit migrations answer
  releases="$(fly releases --app "$APP" --json)"
  image="$(jq -r --argjson v "$version" '.[] | select(.Version == $v and .Status == "complete") | .ImageRef' <<<"$releases")"
  live_image="$(jq -r '[.[] | select(.Status == "complete")] | first | .ImageRef' <<<"$releases")"
  [[ -n "$image" ]] || fail "no completed release v$version."
  [[ "$image" != "$live_image" ]] || fail "v$version is already live."

  # Each image is labelled with its short commit (scripts/deploy.sh).
  git -C "$root" fetch --quiet origin main
  commit="$(sed -E 's/@sha256:.*//; s/.*://' <<<"$image")"
  live_commit="$(sed -E 's/@sha256:.*//; s/.*://' <<<"$live_image")"
  git -C "$root" cat-file -e "$commit^{commit}" 2>/dev/null || fail "v$version's image label $commit is not a commit here."
  git -C "$root" cat-file -e "$live_commit^{commit}" 2>/dev/null || fail "the live image label $live_commit is not a commit here."
  migrations="$(git -C "$root" diff --name-only "$commit" "$live_commit" -- platform/priv/repo/migrations)"
  if [[ -n "$migrations" ]]; then
    echo "The live release has migrations v$version does not carry; they stay applied:"
    echo "$migrations"
    echo "Read each before going on: v$version's code must work with their tables."
    read -r -p "Go back to v$version anyway? Type yes: " answer
    [[ "$answer" == yes ]] || fail "not rolled back."
  fi

  # The image goes back with the fly.toml it was released with.
  local config
  config="$(mktemp -d)/fly.toml"
  git -C "$root" show "$commit:platform/fly.toml" >"$config"
  say "Deploying v$version's image $image with its own fly.toml"
  fly deploy --app "$APP" --config "$config" --image "$image" --ha=false
  site_answers
}

[[ $# -ge 1 ]] || usage
step="$1"
shift
live=false
at_time=""
rollback_version=""
if [[ "$step" == rollback ]]; then
  [[ $# -ge 1 ]] || usage
  rollback_version="$1"
  shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) live=true ;;
    --at)
      [[ $# -ge 2 ]] || usage
      at_time="$2"
      shift
      ;;
    *) usage ;;
  esac
  shift
done

cd "$root"
case "$step" in
  check) check ;;
  snapshot) snapshot ;;
  restore-volumes) restore_volumes ;;
  verify-volumes) verify_volumes ;;
  restore-db) restore_db ;;
  verify-db) verify_db ;;
  cleanup) cleanup ;;
  rollback) rollback ;;
  *) usage ;;
esac

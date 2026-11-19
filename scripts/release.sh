#!/usr/bin/env bash
# Builds the committed tree into the release image and proves the image runs.
# Run it through `make release`, which runs every gate on that same tree first.
#
# The build context is the one platform/scripts/build-release-context.sh
# assembles: `git archive` of HEAD's platform/ folder plus the graph host's
# sealed Python supply, checked against its checksums. Nothing else uncommitted,
# ignored or outside this repository enters the image. The build reuses no
# cached layers, and the Dockerfile fetches every other dependency at the
# version the lockfiles pin; the shared libraries' repositories are public, so
# the build takes no credentials. The image is built for this machine's Docker
# architecture, since it runs here.
#
# The smoke check starts the image against a throwaway PostgreSQL, at the
# version platform/.tool-versions names, on its own Docker network and removes
# them afterwards. It runs the staging release commands against it, seeds the
# few rows one workspace write needs (a deployed fleet whose key ownership was
# just read, one Key and its owner's account, an account that holds no Key, and
# an active project), then starts production's two machines (platform/fly.toml),
# which share no cluster: the graph machine with an empty graph volume, answering
# to its process group's private name, and the site machine with none. It
# checks the health endpoint, the home page, a built stylesheet, the graph
# host's Python, the running site's database connection and a graph writer
# answering on the graph machine. Then, through the site's own code, it proves
# that the graph machine's private listener refuses a request with no pass and
# with a pass for another audience, route or fleet or one that has expired,
# takes one real write as the Key's
# owner, has its read tables at or past that write, sends the site the head
# notice for it, answers the same command again as a replay, refuses the write
# of an account that holds no Key with nothing written, checks a write without
# making it, and keeps its port mapper closed to the site machine. Last come two
# timed drills: the graph machine frozen after a write was sent (the site
# answers that the outcome is unknown, and the same command sent again is made
# once), and the graph machine stopped (the site answers "try again" at once,
# and logs the write and the await it could not send, once each).
# It runs as staging because that role admits only the staging database
# hostnames, which the throwaway database answers to on its network. The server
# gets no chain node or Privy app, so it reads no chain and offers no sign-in.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

commit="$(git rev-parse HEAD)"
image="keyfleet:${commit:0:12}"
run="keyfleet-smoke-$$"
database_url="postgres://smoke:smoke@regents-staging-db.internal/keyfleet_smoke"
# The throwaway database is the PostgreSQL version platform/.tool-versions names.
postgres="$(awk '$1 == "postgres" { print $2 }' platform/.tool-versions)"
[[ -n $postgres ]] || { echo "platform/.tool-versions names no postgres version." >&2; exit 1; }
# The network's own private IPv6 range, one per run, as Fly's private network
# is IPv6: the graph process group's private name has only an IPv6 record.
subnet="fd4b:6b66:$(printf '%x' $(($$ % 65536)))"
graph_name="graph.process.keyfleet.internal"
# The fleet the seeded write goes to, its Key's owner and an account with no Key.
fleet="fleet_tech_classic"
holder_wallet="0x1111111111111111111111111111111111111111"
stranger_wallet="0x2222222222222222222222222222222222222222"
workspace="$(mktemp -d)"
context="$workspace/context"

cleanup() {
  status=$?
  if [[ $status -ne 0 ]]; then
    for machine in graph app; do
      if docker container inspect "$run-$machine" >/dev/null 2>&1; then
        echo "The $machine machine's log:" >&2
        docker logs --tail 40 "$run-$machine" >&2
      fi
    done
  fi
  docker unpause "$run-graph" >/dev/null 2>&1 || true
  # --volumes takes the database's data volume with it, so no run leaves one behind.
  docker rm --force --volumes "$run-app" "$run-graph" "$run-db" >/dev/null 2>&1 || true
  docker network rm "$run" >/dev/null 2>&1 || true
  chmod -R u+w "$workspace" 2>/dev/null || true
  rm -rf -- "$workspace"
}
trap cleanup EXIT

# Retries a command once a second for up to a minute.
wait_for() {
  local what="$1"
  shift
  for _ in $(seq 60); do
    if "$@" >/dev/null 2>&1; then return; fi
    sleep 1
  done
  echo "Smoke check failed: $what did not answer within a minute." >&2
  exit 1
}

fail() {
  echo "Smoke check failed: $1" >&2
  exit 1
}

# Runs Elixir on the site machine, as an operator on that machine would.
on_site() {
  docker exec "$run-app" /app/bin/keyfleet rpc "$1" 2>&1
}

case "$(docker info --format '{{.Architecture}}')" in
  aarch64 | arm64) arch=arm64 ;;
  x86_64 | amd64) arch=amd64 ;;
  *) fail "Docker runs on an architecture with no sealed graph host supply" ;;
esac

echo "==> Assembling the build context from commit $commit for $arch"
platform/scripts/build-release-context.sh "$context" "$arch"
graph_host_supply="$(sed -n 's/^graph-host-supply=//p' "$context/BUILD-INPUTS.txt")"

echo "==> Building $image from commit $commit"
docker build --no-cache --platform "linux/$arch" \
  --build-arg SOURCE_COMMIT="$commit" \
  --label "org.opencontainers.image.revision=$commit" --tag "$image" \
  --file "$context/Dockerfile" "$context"
digest="$(docker image inspect --format '{{.Id}}' "$image")"

echo "==> Starting a throwaway database"
docker network create --ipv6 --subnet "$subnet::/64" "$run" >/dev/null
docker run --detach --name "$run-db" --network "$run" \
  --network-alias regents-staging-db.internal \
  --env POSTGRES_USER=smoke --env POSTGRES_DB=keyfleet_smoke \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  "docker.io/library/postgres:$postgres" >/dev/null
wait_for "the database" docker exec "$run-db" pg_isready --quiet --host 127.0.0.1 --username smoke
server_version="$(docker exec "$run-db" psql --username smoke --dbname keyfleet_smoke --tuples-only --no-align --command 'SHOW server_version')"
# The answer is the version, then the build's own note, such as "17.12 (Debian 17.12-1.pgdg13+1)".
[[ ${server_version%% *} == "$postgres" ]] || fail "the throwaway database is PostgreSQL $server_version, not $postgres"

release_env=(
  --network "$run"
  --env KEYFLEET_DEPLOYMENT_ROLE=staging
  --env KEYFLEET_APP_SURFACES=on
)

# A release command runs on a one-off machine of its own, as Fly runs it.
command_env=("${release_env[@]}" --env DATABASE_DIRECT_URL="$database_url")

echo "==> Creating and migrating the database with the release commands"
docker run --rm "${command_env[@]}" "$image" /app/bin/bootstrap-staging
docker run --rm "${command_env[@]}" "$image" /app/bin/migrate
pending="$(docker run --rm "${command_env[@]}" "$image" /app/bin/pending-migrations | tail -n 1)"
[[ $pending == none ]] || fail "the database and the release disagree: $pending"

# The minimum one write needs, written straight into the throwaway database:
# the fleet's deployment on a chain this site has no node for, with its own
# founding deck from the image (a deployed fleet's pages draw its Keys' cards
# from it), its key ownership read through a recent block (fresh for the next
# hour), Key 1 owned by the holder's wallet, the holder's and the stranger's
# accounts, and an active project.
deck_file="$(grep -l '"fleet": "CLASSIC #1"' "$context"/platform/priv/decks/0x*.json)"
deck_hash="$(basename "$deck_file" .json)"
table_hash="$(sed -n 's/^ *"table": "\(0x[0-9a-f]\{64\}\)",$/\1/p' "$deck_file")"
deck_size="$(grep -c '^ *"0x[0-9a-f]\{64\}",\{0,1\}$' "$deck_file")"
[[ -n $table_hash && $deck_size -gt 0 ]] || fail "Classic's founding deck could not be read"
echo "==> Seeding one Key, its owner, an account with no Key and a project"
docker exec --interactive "$run-db" psql --username smoke --dbname keyfleet_smoke \
  --quiet --set ON_ERROR_STOP=1 <<SQL
BEGIN;
UPDATE keyfleet_app.fleets SET
  chain_id = 31337, chain_fleet_id = 1, deployed_block = 1, deck_size = $deck_size,
  keys_address = '0x00000000000000000000000000000000000000a1',
  manager_address = '0x00000000000000000000000000000000000000a2',
  rewards_address = '0x00000000000000000000000000000000000000a3',
  votes_address = '0x00000000000000000000000000000000000000a4',
  treasury_address = '0x00000000000000000000000000000000000000a5',
  shards_address = '0x00000000000000000000000000000000000000a6',
  usdc_address = '0x00000000000000000000000000000000000000a7',
  regent_address = '0x00000000000000000000000000000000000000a8',
  regent_staking_address = '0x00000000000000000000000000000000000000a9',
  autolaunch_factory_address = '0x00000000000000000000000000000000000000aa',
  club_claims_address = '0x00000000000000000000000000000000000000ab',
  trait_table_hash = '$table_hash',
  deck_hash = '$deck_hash'
WHERE id = '$fleet';
INSERT INTO keyfleet_app.chain_cursors
  (fleet_id, next_block, head_block, head_block_hash, observed_at, ownership_seq)
VALUES ('$fleet', 100, 100, '0x$(printf 'd%.0s' {1..64})',
  (now() AT TIME ZONE 'utc') + interval '1 hour', 1);
INSERT INTO keyfleet_app.key_attachments
  (fleet_id, token_id, ownership_epoch, owner_wallet, block_number, block_hash,
   transaction_hash, log_index, record_seq)
VALUES ('$fleet', 1, 1, '$holder_wallet', 50, '0x$(printf 'e%.0s' {1..64})',
  '0x$(printf 'f%.0s' {1..64})', 0, 1);
INSERT INTO regent_names.platform_human_users
  (id, privy_user_id, wallet_address, wallet_addresses, created_at, updated_at)
VALUES
  (1001, 'did:privy:smoke-holder', '$holder_wallet', ARRAY['$holder_wallet'], now(), now()),
  (1002, 'did:privy:smoke-stranger', '$stranger_wallet', ARRAY['$stranger_wallet'], now(), now());
INSERT INTO keyfleet_app.projects (fleet_id, name, title, state, repository)
VALUES ('$fleet', 'smoke', 'Smoke', 'active', 'fleet-tech-classic-smoke');
COMMIT;
SQL

# Both machines sign and check passes with this key set, made for this run alone.
signing_keys="$(docker run --rm "${command_env[@]}" --env KEYFLEET_RELEASE_COMMAND=migrate \
  "$image" /app/bin/keyfleet eval '
    {:ok, _started} = Application.ensure_all_started(:jose)
    {_fields, key} = JOSE.JWK.to_map(JOSE.JWK.generate_key({:ec, "P-256"}))
    IO.puts(Jason.encode!(%{keys: [key]}))' | tail -n 1)"

# The addresses and keys of the sign-in server, the code store, the picture
# bucket, key art and Lighthouse are required but never used here; .invalid
# names can never resolve.
machine_env=(
  "${release_env[@]}"
  --env DATABASE_POOLED_URL="$database_url"
  --env PHX_HOST=localhost
  --env SECRET_KEY_BASE="$(openssl rand -base64 48)"
  --env KEYFLEET_SIWA_URL=https://siwa.invalid
  --env KEYFLEET_HUB_SIGNING_KEY="$signing_keys"
  --env KEYFLEET_CODE_NODE=http://code.invalid
  --env KEYFLEET_GRAPH_URL="http://$graph_name:4400"
  --env AWS_ENDPOINT_URL_S3=https://storage.invalid
  --env BUCKET_NAME=smoke --env AWS_REGION=auto
  --env AWS_ACCESS_KEY_ID=smoke --env AWS_SECRET_ACCESS_KEY=smoke
  --env PICTURES_PUBLIC_URL=https://pictures.invalid
  --env KEY_ART_URL=http://key-art.invalid
  --env LIGHTHOUSE_API_KEY=smoke
  # The presence timer's wallet key is required and never used here: with no
  # chain node nothing is sent. A fresh random key that holds nothing.
  --env KEYFLEET_PRESENCE_TIMER_KEY="0x$(openssl rand -hex 32)"
  # Fly names the image each machine runs; here it is the one just built.
  --env FLY_IMAGE_REF="$image"
)

# /data stands in for the Fly volume, empty and owned by the app user as
# deploying leaves it.
echo "==> Starting the graph machine"
docker run --detach --name "$run-graph" "${machine_env[@]}" \
  --network-alias "$graph_name" \
  --tmpfs /data:uid=1001,gid=1001 \
  "$image" /app/bin/graph >/dev/null

echo "==> Starting the site machine"
docker run --detach --name "$run-app" "${machine_env[@]}" \
  --publish 127.0.0.1::4000 \
  "$image" >/dev/null
base="http://$(docker port "$run-app" 4000/tcp | head -n 1)"
wait_for "the health endpoint" curl --silent --fail "$base/healthz"

health="$(curl --silent --fail "$base/healthz")"
[[ $health == ok ]] || fail "the health endpoint answered \"$health\""

home="$(curl --silent --fail "$base/")"
stylesheet="$(grep -oE '/assets/[^"]+-[0-9a-f]{32}\.css' <<<"$home" | head -n 1)" ||
  fail "the home page links no fingerprinted stylesheet"
stylesheet_answer="$(curl --silent --fail --output /dev/null --write-out '%{http_code} %{content_type} %{size_download} bytes' "$base$stylesheet")"
[[ $stylesheet_answer == "200 text/css"* ]] || fail "$stylesheet answered $stylesheet_answer"

graph_host="$(docker exec "$run-graph" /opt/graph_host/.venv/bin/python -I -c \
  'import platform, keyfleet_graph.host; print("Python", platform.python_version())')" ||
  fail "the graph host's Python could not load the graph host"

connected_database="$(on_site \
  '[[name]] = Keyfleet.Repo.query!("SELECT current_database()").rows; IO.puts(name)')"
[[ $connected_database == keyfleet_smoke ]] || fail "the server's database answered \"$connected_database\""

# The fleet's graph writer answers on the graph machine once its graph host has
# read the fleet's (empty) log, asked by an operator on that machine.
graph_writer() {
  docker exec "$run-graph" /app/bin/keyfleet rpc \
    "{:ok, _hello} = Keyfleet.Graph.Writer.request(\"$fleet\", \"hello\", %{})"
}
wait_for "a graph writer on the graph machine" graph_writer

# Elixir shared by the proofs below, run on the site machine.
prelude="
  fleet = \"$fleet\"
  url = Application.fetch_env!(:keyfleet, :graph)[:url]
  ask = fn path, opts ->
    Req.request!([method: :post, url: url <> path, body: \"{}\", retry: false,
      connect_options: [transport_opts: [inet6: true]]] ++ opts).status
  end
  person = fn id ->
    {:ok, [account]} = Keyfleet.Accounts.accounts_by_ids([id], actor: %Keyfleet.Actors.System{})
    Keyfleet.Actors.Human.for_account(account)
  end
  body = %{project: \"smoke\", type: \"note\",
    data: %{\"title\" => \"Smoke\", \"body\" => \"Written by the release smoke check.\"}}
  write = fn command_id ->
    authority = Keyfleet.Graph.Authority.workspace_command(person.(1001), 1, command_id)
    {micros, reply} = :timer.tc(fn -> Keyfleet.Graph.Client.command(fleet, \"create\", body, authority) end)
    {reply, div(micros, 1000)}
  end
"

echo "==> Proving the site reaches the graph machine the new way"
proofs="$(on_site "$prelude"'
  # The listener answers its health check, and refuses a request with no
  # pass, a pass for the code store, for another route or another fleet, and
  # one that has expired.
  200 = Req.get!(url <> "/healthz", retry: false, connect_options: [transport_opts: [inet6: true]]).status
  401 = ask.("/fleets/#{fleet}/write", [])
  401 = ask.("/fleets/#{fleet}/write", auth: {:bearer, Keyfleet.Code.Pass.read("smoke")})
  401 = ask.("/fleets/#{fleet}/write", auth: {:bearer, Keyfleet.Graph.Pass.mint(fleet, "check")})
  401 = ask.("/fleets/#{fleet}/write", auth: {:bearer, Keyfleet.Graph.Pass.mint("regents_club", "write")})
  expired = Keyfleet.Notebooks.Pass.sign(
    %{"aud" => "keyfleet-graph", "sub" => "keyfleet", "fleet" => fleet, "scope" => "write"}, -1)
  401 = ask.("/fleets/#{fleet}/write", auth: {:bearer, expired})
  IO.puts("refusals: no pass 401, code-store pass 401, another route 401, another fleet 401, expired 401")

  # One real write, through the workspace action members and agents use.
  Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keyfleet.Graph.head_topic(fleet))
  holder = person.(1001)
  args = Map.merge(body, %{as_key: 1, command_id: "smoke-write"})
  {:ok, first} = Keyfleet.Graph.create_object(fleet, args, actor: holder)
  seq = first.head_seq
  false = first.replayed
  true = first.watermark >= seq
  IO.puts("write: accepted at #{seq}, read tables at #{first.watermark}")

  head =
    receive do
      {:graph_head, ^fleet, _run_id, watermark} when watermark >= seq -> watermark
    after
      10_000 -> raise "no head notice reached the site"
    end

  IO.puts("notice: the site heard the head reach #{head}")

  {:ok, again} = Keyfleet.Graph.create_object(fleet, args, actor: holder)
  true = again.replayed and again.head_seq == seq
  IO.puts("replay: the same command answered as a replay at #{again.head_seq}")

  # An account that holds no Key: the site refuses it, and so does the graph
  # machine itself, reading the account from the database.
  stranger = person.(1002)
  refused = Map.put(args, :command_id, "smoke-refused")
  {:error, %Ash.Error.Forbidden{}} = Keyfleet.Graph.create_object(fleet, refused, actor: stranger)
  stranger_rule = Keyfleet.Graph.Authority.workspace_command(stranger, 1, "smoke-refused")
  {:error, %Keyfleet.Graph.Errors.NotKeyHolderError{}} =
    Keyfleet.Graph.Client.command(fleet, "create", body, stranger_rule)

  # A check of a new write, which writes nothing.
  check_rule = Keyfleet.Graph.Authority.workspace_command(holder, 1, "smoke-check")
  {:ok, _taken} = Keyfleet.Graph.Client.check(fleet, "create", body, check_rule)

  {:ok, after_both} = Keyfleet.Graph.create_object(fleet, args, actor: holder)
  true = after_both.head_seq == seq
  IO.puts("refused: not_key_holder from the graph machine; check: taken; nothing written (head still #{after_both.head_seq})")

  # No other machine reaches the port mapper of the graph machine.
  {:ok, graph} = :inet.getaddr(String.to_charlist(URI.parse(url).host), :inet6)
  {:error, :econnrefused} = :gen_tcp.connect(graph, 4369, [:inet6], 2_000)
  IO.puts("port mapper: refused from the site machine")
')" || fail "a proof of the graph listener failed: $proofs"
echo "$proofs"

# The site waits for the writer's longest answer and a second more
# (Keyfleet.Graph.Client), so a frozen graph machine is answered in about 13 s.
echo "==> Drill: the graph machine frozen after a write was sent"
docker pause "$run-graph" >/dev/null
frozen="$(on_site "$prelude"'
  {{:error, :indeterminate}, ms} = write.("smoke-frozen")
  true = ms < 15_000
  IO.puts("frozen: indeterminate after #{ms} ms")
')" || fail "the frozen write was not answered as indeterminate in time: $frozen"
echo "$frozen"
docker unpause "$run-graph" >/dev/null
resent="$(on_site "$prelude"'
  {{:ok, first}, _ms} = write.("smoke-frozen")
  {{:ok, %{"replayed" => true} = second}, _ms} = write.("smoke-frozen")
  true = second["head_seq"] == first["head_seq"]
  IO.puts("resent: ok (replayed: #{first["replayed"]}), then a replay at #{second["head_seq"]}: made once")
')" || fail "the frozen write, sent again, was not made exactly once: $resent"
echo "$resent"

echo "==> Drill: the graph machine stopped"
docker stop "$run-graph" >/dev/null
stopped="$(on_site "$prelude"'
  # Each call runs as a page or agent request does, with the output of the
  # site machine itself, so what it logs goes to the log of the site machine
  # and not back to this rpc.
  as_request = fn fun ->
    Task.await(Task.async(fn ->
      Process.group_leader(self(), Process.whereis(:user))
      fun.()
    end))
  end
  {{:error, :unavailable}, ms} = as_request.(fn -> write.("smoke-stopped") end)
  true = ms < 2_000
  {micros, 0} =
    as_request.(fn -> :timer.tc(fn -> Keyfleet.Graph.Client.await(fleet, "any", 1) end) end)
  IO.puts("stopped: unavailable after #{ms} ms; await 0 after #{div(micros, 1000)} ms")
')" || fail "the site did not answer \"try again\" at once with the graph machine stopped: $stopped"
echo "$stopped"

# The site machine logs each request it could not send, once.
logged_once() {
  local site_log
  site_log="$(docker logs "$run-app" 2>&1)"
  [[ $(grep -cF "graph write for $fleet not sent: " <<<"$site_log") == 1 &&
    $(grep -cF "graph await for $fleet not sent: " <<<"$site_log") == 1 ]]
}
wait_for "one log line each for the unsent write and await" logged_once
unsent="$(docker logs "$run-app" 2>&1 | grep -F "graph write for $fleet not sent: " |
  sed -E 's/.*not sent: ([^"]*)".*/\1/')"
echo "logged: the unsent write and await once each ($unsent)"

echo
echo "Release built and smoke-checked"
echo "  app commit      $commit"
git show "$commit:platform/mix.lock" | grep -oE '\{:git, "[^"]+", "[0-9a-f]{40}"' | sort -u |
  sed -E 's/\{:git, "([^"]+)", "([0-9a-f]+)"/  shared library  \1 \2/'
echo "  graph supply    $graph_host_supply"
echo "  image           $image"
echo "  image digest    $digest"
echo "  migrations      bootstrap-staging and migrate succeeded; pending-migrations: $pending"
echo "  health          $base/healthz answered $health"
echo "  static asset    $stylesheet answered $stylesheet_answer"
echo "  graph host      $graph_host loaded the graph host"
echo "  database        the running server queried $connected_database on PostgreSQL $server_version"
echo "  graph service   the site reached the graph machine at http://$graph_name:4400 with no cluster"
echo "  frozen graph    ${frozen#frozen: }; ${resent#resent: }"
echo "  stopped graph   ${stopped#stopped: }; logged once each ($unsent)"

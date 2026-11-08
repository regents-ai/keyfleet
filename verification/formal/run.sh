#!/bin/sh
# Keyfleet's formal checks. Every model's holding rules must hold, every
# finding rule must break, and every broken variant must break the rule it
# names. Then the agent property tests run on the real sign-in code, and once
# on each broken copy of it, which must fail.
#
#   verification/formal/run.sh                           models and agent properties
#   verification/formal/run.sh code-store <pre-receive>  the code store's push rule
#
# <pre-receive> is infra/keyfleet/hooks/pre-receive in a checkout of
# regents-ai/keyfleet-code's keyfleet branch. TLC and Java are pinned below;
# Elixir and Erlang come from platform/.tool-versions; mise installs them.
# Nothing here reads a database or any network beyond installing tools and
# StreamData.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
platform=$(cd "$here/../../platform" && pwd)

tlc_tool='http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar]@1.7.4'
tlc_sha256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
java_tool='java@temurin-25.0.5+8.0.LTS'
elixir_tool="elixir@$(awk '$1 == "elixir" { print $2 }' "$platform/.tool-versions")"
erlang_tool="erlang@$(awk '$1 == "erlang" { print $2 }' "$platform/.tool-versions")"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
runs=0
failures=0

pass() { echo "ok    $*"; }
fail() {
  echo "FAIL  $*"
  failures=$((failures + 1))
}

new_run() {
  runs=$((runs + 1))
  run=$work/run-$runs
  mkdir "$run"
}

elixir_run() {
  mise exec "$elixir_tool" "$erlang_tool" -- elixir "$@" </dev/null
}

# --- the code store's push rule ---------------------------------------------

if [ "${1:-}" = code-store ]; then
  hook=${2:?usage: run.sh code-store <pre-receive>}
  hook=$(cd "$(dirname "$hook")" && pwd)/$(basename "$hook")
  mise install --quiet "$elixir_tool" "$erlang_tool"

  if elixir_run "$here/properties/code_store_properties.exs" "$hook" >"$work/hook.out" 2>&1; then
    pass "code store: a push is taken exactly when it only adds"
  else
    fail "code store: the push rule (output below)"
    tail -40 "$work/hook.out"
  fi

  while IFS='|' read -r name from to; do
    new_run
    FROM=$from TO=$to perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$hook" >"$run/pre-receive"
    chmod +x "$run/pre-receive"
    if cmp -s "$hook" "$run/pre-receive"; then
      fail "code store, $name: the change no longer applies to the hook"
    elif elixir_run "$here/properties/code_store_properties.exs" "$run/pre-receive" >"$run/out" 2>&1; then
      fail "code store, $name: the property test missed the broken hook"
    elif grep -q "Failed with generated values" "$run/out"; then
      pass "code store, $name: caught"
    else
      fail "code store, $name: the run stopped before the property failed (output below)"
      tail -40 "$run/out"
    fi
  done <<'MUTATIONS'
allows_deletes|*) echo "$ref: branches and tags can't be deleted here."; refused=1; continue ;;|*) continue ;;
allows_force_push|if ! git merge-base --is-ancestor "$old" "$new"; then|if false; then
allows_tag_moves|refs/tags/*)|refs/tags/never/*)
MUTATIONS

  [ "$failures" -eq 0 ] && echo "All code store checks ran as expected." && exit 0
  echo "$failures code store check(s) did not."
  exit 1
fi

# --- the models ---------------------------------------------------------------

mise install --quiet "$tlc_tool" "$java_tool" "$elixir_tool" "$erlang_tool"
tlc_jar=$(mise where "$tlc_tool")/tla2tools.jar
java=$(mise where "$java_tool")/bin/java
echo "$tlc_sha256  $tlc_jar" | shasum -a 256 -c - >/dev/null

# tlc <folder> <module>: checks $run/<module>.cfg; sets status.
tlc() {
  cp "$here/$1/$2.tla" "$run/"
  status=0
  (cd "$run" && "$java" -XX:+UseParallelGC -Xmx1g -cp "$tlc_jar" tlc2.TLC \
    -workers 2 -metadir meta -config "$2.cfg" "$2.tla" >tlc.out 2>&1 </dev/null) || status=$?
}

while read -r folder module cfg; do
  new_run
  cp "$here/$folder/$cfg" "$run/$module.cfg"
  tlc "$folder" "$module"
  if [ "$status" -eq 0 ]; then
    pass "$folder/$cfg: every rule holds"
  else
    fail "$folder/$cfg: TLC exit $status (output below)"
    tail -40 "$run/tlc.out"
  fi
done <<'HOLDING'
pairing PairingLife PairingLife.cfg
pairing PairingLife PairingLife-lock.cfg
shard ShardLife ShardLife.cfg
guards ActionGuards ActionGuards.cfg
HOLDING

# Each line: the base config, the check removed ("none" for a finding), and
# the one rule that must break.
while read -r folder module cfg broken kind rule; do
  new_run
  {
    grep -vE '^(INVARIANT|PROPERTY) ' "$here/$folder/$cfg" | sed "s/Broken = \"none\"/Broken = \"$broken\"/"
    echo "$kind $rule"
  } >"$run/$module.cfg"
  if ! grep -q "Broken = \"$broken\"" "$run/$module.cfg"; then
    fail "$folder/$cfg has no Broken constant"
    continue
  fi
  tlc "$folder" "$module"
  what=$([ "$broken" = none ] && echo "finding" || echo "without $broken")
  if [ "$status" -ge 12 ] && [ "$status" -le 13 ] && grep -qE "(Invariant|property) $rule is violated" "$run/tlc.out"; then
    pass "$folder, $what: $rule breaks"
  else
    fail "$folder, $what: $rule should break, TLC exit $status (output below)"
    tail -40 "$run/tlc.out"
  fi
done <<'BREAKING'
pairing PairingLife PairingLife.cfg none INVARIANT NoWriteAfterUnpair
shard ShardLife ShardLife.cfg none INVARIANT NothingAfterRecordedEnd
shard ShardLife ShardLife.cfg none INVARIANT NothingAfterChainEnd
guards ActionGuards ActionGuards.cfg none INVARIANT AgentVotingOffStopsPollVotes
guards ActionGuards ActionGuards.cfg none INVARIANT RestrictedAddsNothingToWorkspace
guards ActionGuards ActionGuards.cfg none INVARIANT BlockedOnlyWhenChainSaysNo
guards ActionGuards ActionGuards.cfg none INVARIANT OnlyOwnProjectsDeleted
guards ActionGuards ActionGuards.cfg none INVARIANT MessagesFollowWorkspaceRule
pairing PairingLife PairingLife-lock.cfg smart_on_ethereum INVARIANT SmartWalletOnlyOnBase
pairing PairingLife PairingLife-lock.cfg pair_over_row PROPERTY OnePairingAtATime
pairing PairingLife PairingLife-lock.cfg code_reused INVARIANT CodeSingleUse
pairing PairingLife PairingLife-lock.cfg no_sign_in_check INVARIANT NoWriteWithoutPairing
pairing PairingLife PairingLife-lock.cfg no_pairing_check INVARIANT NoWriteWithoutPairing
pairing PairingLife PairingLife-lock.cfg no_recheck INVARIANT NoWriteAfterUnpair
pairing PairingLife PairingLife-lock.cfg no_mcp_recheck INVARIANT NoFormerPersonDataInAnswer
shard ShardLife ShardLife.cfg shard_any_key INVARIANT ShardOnlyForItsKey
shard ShardLife ShardLife.cfg no_expiry_check INVARIANT NothingAfterExpiry
shard ShardLife ShardLife.cfg no_epoch_check INVARIANT NothingAfterRecordedMove
shard ShardLife ShardLife.cfg no_fresh_check INVARIANT EndsWithinFreshWindow
shard ShardLife ShardLife.cfg paired_with_shard INVARIANT PairedOnlyWithoutShard
guards ActionGuards ActionGuards.cfg smart_on_ethereum INVARIANT SmartWalletOnlyOnBase
guards ActionGuards ActionGuards.cfg no_sign_in_check INVARIANT NoWriteWithoutPairing
guards ActionGuards ActionGuards.cfg no_pairing_check INVARIANT NoWriteWithoutPairing
guards ActionGuards ActionGuards.cfg shard_any_key INVARIANT ShardOnlyForItsKey
guards ActionGuards ActionGuards.cfg no_fresh_check INVARIANT NothingWhileReaderBehind
guards ActionGuards ActionGuards.cfg no_restriction_check INVARIANT RestrictedReadOnlyInNotebooks
guards ActionGuards ActionGuards.cfg no_owner_check INVARIANT NobodyChangesAnotherKeysItem
guards ActionGuards ActionGuards.cfg fork_needs_owner INVARIANT AnyoneMayFork
guards ActionGuards ActionGuards.cfg anyone_ends_polls INVARIANT PollEndOnlyByStarter
guards ActionGuards ActionGuards.cfg hook_allows_rewrites INVARIANT CodeStoreOnlyAdds
guards ActionGuards ActionGuards.cfg steps_ignore_head INVARIANT WalletStepsOnlyForHolder
guards ActionGuards ActionGuards.cfg contract_ignores_voting INVARIANT AgentVotingOffStopsBallots
BREAKING

# --- the agent sign-in code -----------------------------------------------------

agent=lib/keyfleet/actors/agent.ex

if elixir_run "$here/properties/agent_properties.exs" "$platform" >"$work/agent.out" 2>&1; then
  pass "agent sign-in: every property holds on $agent"
else
  fail "agent sign-in: a property fails on $agent (output below)"
  tail -40 "$work/agent.out"
fi

while IFS='|' read -r name from to; do
  new_run
  mkdir -p "$run/$(dirname "$agent")"
  FROM=$from TO=$to perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$platform/$agent" >"$run/$agent"
  if cmp -s "$platform/$agent" "$run/$agent"; then
    fail "agent sign-in, $name: the change no longer applies to $agent"
  elif elixir_run "$here/properties/agent_properties.exs" "$run" >"$run/out" 2>&1; then
    fail "agent sign-in, $name: the property tests missed it"
  elif grep -q "Failed with generated values" "$run/out"; then
    pass "agent sign-in, $name: caught"
  else
    fail "agent sign-in, $name: the run stopped before a property failed (output below)"
    tail -40 "$run/out"
  fi
done <<'MUTATIONS'
smart_on_ethereum|and chain_id == 8453)),|and chain_id in [1, 8453])),
refresh_ignores_person|privy_user_id: ^owner} = current} <-|privy_user_id: _} = current} <-
valid_ignores_episode|{:ok, %{id: ^id, privy_user_id: ^owner}} -> true|{:ok, %{id: _, privy_user_id: ^owner}} -> true
unpaired_reads_pairing|def refresh(_), do: {:error, :not_paired}|def refresh(actor), do: Keyfleet.Agents.with_pairing(actor)
MUTATIONS

[ "$failures" -eq 0 ] && echo "All checks ran as expected." && exit 0
echo "$failures check(s) did not."
exit 1

---
name: keyfleet-formal-verification
description: Check a Keyfleet change against the formal models of what a paired agent and a shard holder may do (pairing, the Key a person puts an agent on, shard life, each action's checks, wallet steps, the code store's push rule). Use before shipping any change to agent sign-in or pairing, KeyActor, Keys.identity, held_keys or agent_keys, agents on Keys, shards, chain freshness, edits restrictions, polls, pins, direct messages, projects, the notebook or code gateways, wallet steps, or the code store's pre-receive hook.
---

# Keyfleet formal verification

Three TLA+ models and two property-test files in `verification/formal/` check
the promises Keyfleet makes about agents. Each model's header names the code
behind every step. Each rule is one plain sentence in the model's Rules
section.

| Folder | What it checks |
|---|---|
| `pairing/` | One agent wallet pairs, unpairs and re-pairs while it sends one write, and its person puts it on a Key: who gets in, whether a write can be saved after the unpair, and whose agent stands on a Key. |
| `shard/` | One shard is given, ends, runs out or loses its Key to a transfer, and the Key the agent's person put it on changes hands, while Keyfleet reads the chain behind it: when its rights stop. |
| `guards/` | One request of each kind passes sign-in, pairing, standing, freshness, the edits restriction and the action's own rule; wallet steps are read at the latest block and judged by the contract. |
| `properties/agent_properties.exs` | The real `Keyfleet.Actors.Agent` on random agents: a smart wallet counts only on Base; refresh and valid? admit only the same pairing and person. |
| `properties/code_store_properties.exs` | The real pre-receive hook of the code store on random pushes: a push is taken exactly when it only adds. |

## Run

```sh
verification/formal/run.sh
```

About a minute. It checks that every holding rule holds, that every open
finding still breaks, that every model breaks when one of its checks is
removed, and that the agent property tests pass on
`platform/lib/keyfleet/actors/agent.ex` and fail on four broken copies of it.
The last line says whether every check ran as expected.

The code store's rule lives in regents-ai/keyfleet-code, keyfleet branch.
From a checkout of it:

```sh
verification/formal/run.sh code-store <keyfleet-code checkout>/infra/keyfleet/hooks/pre-receive
```

About a minute. It runs the push property on the hook and on three broken
copies (deletes, force pushes, moved tags allowed).

Tools: run.sh pins TLC 1.7.4 and Java 25 and installs them with mise; Elixir
and Erlang come from `platform/.tool-versions`. The first run fetches
StreamData.

## Read a result

- **A holding rule breaks.** Read the trace with `/statechart`: give it the
  model and the config that failed. It shows the shortest path to the break
  in plain words. Replay each step against the code named in the model's
  header. If a step cannot happen in the code, the model is wrong: fix the
  model and say what was wrong. If every step can happen, it is a bug: report
  it with the path in the code's words. Do not weaken the rule, and put any
  product fix in a change of its own.
- **An open finding no longer breaks.** The code was fixed. Confirm in the
  code, then move the rule from run.sh's finding list into the holding
  config, add a broken variant that removes the new check, and update the
  findings table below.
- **A broken variant is not caught.** The rule no longer guards that check.
  Usually the rule was restated in terms of the check itself; state it from
  the facts instead (the models keep each check's result separate from the
  facts the rules read).
- **"the change no longer applies".** `agent.ex` or the hook changed under a
  mutation in run.sh. Rewrite that mutation so it again removes the same
  check from the new code.

## Change the models

When a change alters a covered file on purpose, update the model from the
code before you rerun, and keep one step in the code as one step in the
model. Change a rule only when the promise itself changed, and cite the
evidence (doc comment, test, commit message). Then redraw the model's chart:
run `/statechart` on the model with its `-chart.cfg` and `.view.mjs` in the
same folder, replace `chart.mmd` and `chart-report.md` (the command's
`report.md`), and render `chart.svg` from `chart.mmd` as the skill's
`references/render.md` says, with its colours in a `<style>` at the start.

## Coverage record

Synced with Keyfleet `9de7fc8cd` (elixir-utils `d89c69df697f81d2a56a43124eada843d1682303`,
keyfleet-code `c815666e`, not rechecked). To see what changed since:

```sh
git diff 9de7fc8cd..HEAD -- <the paths below>
```

Move the sync commit forward only after you confirm that the models describe
the code at the new commit.

**Actions covered.** `platform/priv/tool_manifest.json` lists 133 tools: 8
public, 2 sign-in, 16 that need only the pairing, 97 that need the pairing
and standing in a fleet (the Key tools and the wallet steps for the agent's
own wallet) and 10 page tools for a person's own wallet. Which Keys an agent
acts as is one rule, `Keyfleet.Keys.agent_keys/3`: its own Keys alone; else
the Key its person put it on and every Key it holds an active shard of; else
its person's Keys. `guards/` models each kind by the checks it passes:
workspace edit and fork, code push and project delete (KeyActor), pin,
notebook change, poll vote and poll end (membership), direct and room
messages (held_keys), ballot and issue shard (wallet steps). Putting an agent
on a Key is the person's alone and has no agent route; `pairing/` and
`shard/` model it.

**pairing/** — rules NoWriteWithoutPairing, SmartWalletOnlyOnBase,
CodeSingleUse, NoFormerPersonDataInAnswer, OnePairingAtATime,
OnKeyOnlyForItsPerson; NoWriteAfterUnpair holds with the lock
(`PairingLife-lock.cfg`, every database write) and breaks without it
(`PairingLife.cfg`, a workspace graph write: open finding F1).
- `platform/lib/keyfleet_web/plugs/signed_agent.ex` (`admit/2`)
- `platform/lib/keyfleet_web/plugs/mcp_agent.ex` (`recheck/2`)
- `platform/lib/keyfleet/actors/agent.ex` (`authenticated?/1`, `refresh/1`, `valid?/1`)
- `platform/lib/keyfleet/agents.ex` (`with_pairing/1`), `platform/lib/keyfleet/keys.ex` (`identity/2`, `assigned_keys/3`, `agents_on_keys/2`)
- `platform/lib/keyfleet/keys/agent_key.ex`, `platform/lib/keyfleet/keys/changes/put_agent.ex`
- elixir-utils `ash_components/agents/lib/regent_agents/`: the pairing code, the paired agent's `Pair` action, `authority.ex` (`lock/4`, `lock_current/3`), `require_pairing.ex`
- Writes with `RegentAgents.RequirePairing` (lock): `platform/lib/keyfleet/agents/agent_profile.ex`, `agents/check_in.ex`, `agents/checkpoint.ex`, `dms/block.ex`, `dms/conversation.ex`, `dms/message.ex`, `graph/pin.ex`, `keys/posting_key.ex`, `polls/poll.ex`, `polls/vote.ex`, `proposals/words.ex`, `rooms/message.ex`, `rooms/mute.ex`, `rooms/room.ex`, `rooms/wall_removal.ex`
- Writes with `KeyActor.held_command/5` or `hold_pairing/1` (lock): `platform/lib/keyfleet/projects/hold.ex`, `projects/publish.ex`, `notebooks.ex` (notebook locks)
- Writes without it: `platform/lib/keyfleet/graph/writer.ex` (workspace graph writes, `KeyActor.command/5`)

**shard/** — rules ShardOnlyForItsKey, NothingAfterExpiry,
NothingAfterRecordedMove, PlacementEndsWithRecordedMove,
EndsWithinFreshWindow, PairedOnlyWithoutShardOrPlace; NothingAfterRecordedEnd
breaks (open finding F1, the shard side); NothingAfterChainEnd breaks by
design (the reading's lag, at most 420 seconds and 3,000 blocks).
- `platform/lib/keyfleet/graph/checks/key_actor.ex` (`command/5`, `held_command/5`, `authority/4`)
- `platform/lib/keyfleet/keys.ex` (`agent_keys/3`, `placed_on?/3`, `active_shard/4`), `platform/lib/keyfleet/keys/shard_event.ex` (`:active?`)
- `platform/lib/keyfleet/chain/cursor.ex` (`fresh?`, `@fresh_seconds`, `@fresh_blocks`), `chain/scanner.ex`, `chain/read_fleet.ex`
- `contracts/src/KeyfleetShards.sol` (issue, end, ownership epoch)

**guards/** — rules NoWriteWithoutPairing, SmartWalletOnlyOnBase,
ShardOnlyForItsKey, PersonKeysOnlyAsLastResort, AgentVotingOffStopsBallots,
AgentVotingOffStopsPollVotes, NobodyChangesAnotherKeysItem, AnyoneMayFork,
RestrictedReadOnlyInNotebooks, RestrictedAddsNothingToWorkspace,
CodeStoreOnlyAdds, PollEndOnlyByStarter, NothingWhileReaderBehind,
WalletStepsOnlyForHolder, MessagesFollowWorkspaceRule; the open finding
rules are in the table below.
- `platform/lib/keyfleet/graph/checks/key_actor.ex` (`command/5`), `platform/lib/keyfleet/keys.ex` (`identity/2`, `held_keys/2`, `agent_keys/3`), `platform/lib/keyfleet/access/check.ex`
- `platform/lib/keyfleet/graph/pin.ex`, `platform/lib/keyfleet/graph/validations/unrestricted.ex`, `platform/graph_host/src/keyfleet_graph/host.py` (item owner)
- `platform/lib/keyfleet/polls/checks/standing.ex`, `platform/lib/keyfleet/polls/validations/agent_voting.ex`, `platform/lib/keyfleet/polls/vote.ex`, `platform/lib/keyfleet/dms/checks/key_holder.ex`
- `platform/lib/keyfleet_web/plugs/notebook_gateway.ex`, `platform/lib/keyfleet_web/plugs/code_gateway.ex`, `platform/lib/keyfleet/projects/hold.ex`
- `platform/lib/keyfleet/wallet_steps/build.ex`, `reads.ex`, `vote_steps.ex`, `key_steps.ex`; `platform/lib/keyfleet_web/wallet/wallet_panel.ex`; `platform/lib/keyfleet_web/controllers/agent_chain_controller.ex`
- `contracts/src/KeyfleetVotes.sol` (`_requireGovernor`), `contracts/src/KeyfleetShards.sol` (`mayGovern`)

**properties/** — `agent_properties.exs` covers `platform/lib/keyfleet/actors/agent.ex`;
`code_store_properties.exs` covers keyfleet-code `infra/keyfleet/hooks/pre-receive`
(set as git's hooks path in that repo's Dockerfile).

## Findings at the sync commit

Open findings break on purpose: run.sh expects them to. Each is reported, not
fixed here; a fix changes who may act and waits for Sean's go.

| Id | Rule | State | What breaks |
|---|---|---|---|
| F1 | pairing NoWriteAfterUnpair (`PairingLife.cfg`) | Open for workspace graph writes | A workspace graph write is checked, then sent to the graph host with no transaction held across the call (f67913e6), so an unpair that commits in between does not stop it. Every database write holds the pairing lock (0001d1f7). |
| F1 | shard NothingAfterRecordedEnd | Open | Database writes read a shard's standing again inside their transaction, and graph writes check it once, but nothing locks the recorded shard or Key, so the reader can record the shard's end between that read and the save. |
| F2 | guards OnlyOwnProjectsDeleted | Open | A Key can take over another Key's archived project and delete it, its notebooks and repository included (the 26 Oct design). |
| F3 | guards AgentVotingOffStopsPollVotes | Fixed in 0001d1f7 | A poll vote cast through a shard is refused while the Key's agent voting is off (`agent_voting_off`). |
| F4 | guards BlockedOnlyWhenChainSaysNo | Open | A wallet step offers only the Keys in Keyfleet's record, so a Key bought or a shard received within the reading's lag shows "No Keys to use" and the press is withheld. |
| F5 | guards RestrictedAddsNothingToWorkspace | Fixed in 0001d1f7 | A Key whose edits are restricted no longer pins or unpins (`edits_restricted`). |
| F6 | guards MessagesFollowWorkspaceRule | Fixed in 0001d1f7 | Messages and the workspace ask one rule, `Keys.agent_keys/3`, so an agent that owns a Key never messages as a Key it holds a shard of. |

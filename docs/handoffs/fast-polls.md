# Fast polls — handoff

**Objective.** Let a fleet's agents decide one outside move together in seconds
(the brief in `repos/keyfleet/HANDOFF.md`, Arena as the first example), in two
modes: `poll` (every seated Key votes, most votes wins) and `delegate` (one agent
decides, the others' votes are suggestions).

**Branch and worktree.** `kf/fast-polls` from `d20aa54`, at
`/Users/sean/Documents/regent/worktrees/keyfleet-fast-polls`. Local only: not
pushed, not deployed.

## Founder answers this is built on (7 Oct 2026)

1. Each agent votes itself. Keyfleet pushes the decision at once and holds a short
   window; each owner picks their own model. Keyfleet makes no model calls.
2. Jev now: the guide gives a Jev recipe on the owner's own OpenRouter key.
3. Simple rules: one vote per Key; any agent in the fleet opens a session and is
   its delegate; most votes wins, a tie goes to higher total confidence, then the
   move listed first; no minimum turnout; votes hidden until close; in delegate
   mode only the delegate decides.
4. Engine plus practice feed, built locally. No Arena connector, entrant, push or
   release without a separate go.

## What was built

- `Keyfleet.Polls` domain (`platform/lib/keyfleet/polls.ex`, `lib/keyfleet/polls/`):
  sessions, seats, rounds, votes and an append-only log written in the same
  transaction as each change under the session's advisory lock. The log is
  announced on `poll:<session_id>` after commit.
- A round closes at its deadline (Oban `Keyfleet.Polls.Deadline`, queue `polls`)
  or as soon as every counted vote is in. A closed round is frozen by a database
  trigger. One vote per Key is a unique identity: the same vote again answers 200,
  a different one 409 `vote_conflict`.
- Eight signed agent routes under `/api/v1/agent/fleets/:fleet_id/polls`
  (`AgentPollController`): list, open, join, leave, end, wait, open round, vote.
  `wait` answers at once when the log has new lines, otherwise holds up to
  `:agent_wait_ms` (25 s) and answers within milliseconds of the next line.
- Body checks and caps in `SignedAgent` (round body 24 KiB, observation 8 KiB of
  JSON, 1–600 s deadline, 5–1440 min session, confidence 0–1).
- Plain-words refusals in `KeyfleetWeb.Refusal`; contract 1.1.0 with every poll
  path; guide section "Fast polls" with the Jev recipe in `priv/public/docs.md`.
- Telemetry `keyfleet.polls.round_open.seconds` (outcome, early).
- Migration `20261008032425_fast_polls.exs` and resource snapshots.

## Checks run

- Every poll route's documented answers driven end to end in
  `signed_agent_contract_test.exs`; contract, guide-route, metrics and boundary
  tests succeed.
- Throwaway scenario runs (deleted afterwards): delegate mode, both tie rules,
  deadline close and its repeat, two agents of one Key voting together, a wait
  answering 16 ms after a round opened, a shard ending mid-round.
- `mix compile --warnings-as-errors`, `mix credo`, `mix ash.codegen --check` clean.
- Test database: `MIX_TEST_PARTITION=_fastpolls` (keyfleet_fastpolls_test).
- Full suite: 906 tests. The release test's table list gained the five poll
  tables. Workspace tests need `graph_host/.venv` (`uv sync --frozen` in
  `platform/graph_host`); worktrees lack it, and without it 62 of them fail.

## Remaining

- Push and release need Sean's go.
- Arena connector and entrant: not started; needs a separate go.
- No human page for polls; agents only.
- Jev confidence is assumed to be 0–1; check against a real Jev answer before
  relying on it (a paid call needs Sean's go).

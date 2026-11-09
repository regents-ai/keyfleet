# Polls — handoff

**Objective.** Each fleet has a polls page that anyone can read and only the
fleet's Key holders can write to. A poll is one question with its choices. Any
fleet Key holder votes once while it is open, and the choice with the most votes
is the result. Polls bind no one to anything. People use the page; agents use
the browser tools or the signed agent routes (the CLI).

**Branch and worktree.** `kf/polls-page` from `40573be`, at
`/Users/sean/Documents/regent/worktrees/keyfleet-polls-page`. Local only: not
pushed, not deployed.

## Founder answers this is built on (8 Oct 2026)

- "A poll lasts from 1 minute to 1 hour, chosen by the creator, and can have
  only 1 question."
- One poll per Key per 24 hours, counted from when that Key last started one
  and shared by a person and their paired agents.
- Any fleet Key holder votes while the poll is open; nobody joins or leaves.
- Only one-question polls; the earlier sessions, rounds, seats, delegate mode,
  log and `wait` are removed (hard cutover).
- No "leader decides": polls are non-binding and decided by most votes. A tie
  is shown as a tie.
- Notes the starter adds, and each Key's vote and reason, are visible to the
  fleet's Key holders only. The public sees each choice's count once a poll
  closes.
- Active polls first (newest first), then past polls.
- Arena: no connection yet.

## What was built

- `Keyfleet.Polls` domain (`platform/lib/keyfleet/polls.ex`): the `Poll` and
  `Vote` resources. A Key's start is serialised by an advisory lock on fleet
  and Key, so the 24-hour limit holds under concurrent starts. A vote reads the
  poll under a shared lock and ending reads it for update, so a vote racing an
  end is either counted or turned away. One vote per Key is a unique identity:
  the same vote again answers 200, a different one 409 `vote_conflict`. A
  database trigger keeps votes from changing.
- A poll closes at `closes_at` or when its starter ends it. Closing is a time,
  not a job: nothing runs in the background.
- Totals are hidden while a poll is open; only the number of votes shows.
- Starting and ending are announced on `polls:<fleet_id>` and each vote on
  `poll:<poll_id>`, so open pages read again.
- Pages: `/app/fleets/:fleet_id/polls` (Start form for a Key holder, Active,
  Past) and `/app/fleets/:fleet_id/polls/:poll_id` (countdown, vote form,
  results, End button for the starter, notes and each Key's vote for Key
  holders). The page moves from Choices to Results on its own when time runs
  out. Area module `KeyfleetWeb.PollsLive` inside `ShellLive`; styles in
  `platform/assets/css/pages/polls.css`.
- Five browser tools in `platform/priv/tool_manifest.json`: polls_list,
  polls_start, polls_show, polls_vote and polls_end. Each calls the signed agent
  route of the same name below. A refusal at the daily limit carries
  `retry_after`.
- Five signed agent routes under `/api/v1/agent/fleets/:fleet_id/polls`
  (`AgentToolController`, answered by `AgentTools.Polls.Answer`): list,
  `start`, `:poll_id`, `:poll_id/vote`, `:poll_id/end`. The limit answers 429
  `poll_limit_reached` with `Retry-After`.
  Body caps in `SignedAgent` (start 40448 bytes, vote 8048 bytes).
- Contract 2.0.0 (`platform/contracts/api-contract.openapiv3.yaml`), public
  spec `info.version` 6.0.0, guide section "Polls" with a "Deciding with a
  model" Jev recipe, and a breaking-changes entry in `platform/priv/public/docs.md`.
- Five CLI commands described for regents-cli in `cli/commands.json` and
  `cli/COMMANDS.md`: `polls list|start|show|vote|end`.
- Migrations: `20261008223900_drop_fast_poll_sessions.exs` removes the
  earlier session tables, then `20261008224645_one_question_polls.exs` creates
  `polls` and `poll_votes`.

## Checks run

- `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `mix ash.codegen --check`,
  `mix keyfleet.sync_api_contract --check`, `mix assets.build`, `make check-cli`.
- Three behaviour tests in `platform/test/keyfleet/polls_test.exs`: who reads
  notes and votes, the 24-hour limit with its retry time, and the 1–60 minute
  range. Every poll route's documented answers are driven in
  `signed_agent_contract_test.exs`.
- Browser on :4101 against the lab database (`KEYFLEET_LAB=http://127.0.0.1:41999`,
  database `keyfleet_lab_41999_dev`), with three sample polls inserted by SQL:
  the list order, a tie, the countdown, an open poll turning into Results on its
  own, and a closed poll showing the public its totals but no notes or votes.
  Phone width has no sideways scroll.
- Not walked in the browser: starting and voting while signed in. The lab chain
  node was not running, so no account held a Key there.
- Test database: `MIX_TEST_PARTITION=_pollspage`.

## Remaining

- Push and release need Sean's go through the Keyfleet chief.
- The earlier fast-poll tables are live on v30 behind a closed site; the drop
  migration removes them at release, which needs Sean's go. Before release, a
  read-only count of `poll_sessions`, `poll_seats`, `poll_rounds`, `poll_votes`
  and `poll_events` in production should be 0, or Sean accepts losing what is
  in them (Sentinel, 8 Oct). None is on the protected-table list.
- Sentinel CLEAR on f1da0e8 (23:05Z). Its Low note about two clocks does not
  apply: Ash replaces `now()` in the `Vote.in_poll` filter with the app's
  `DateTime.utc_now()` before the query is sent (`AshSql.Expr.as_of_or_now/1`),
  the same clock `Polls.open?/2` uses.
- The breaking-changes date in the guide should be set to the release date.
- The regents-cli lane builds the five `polls` commands.
- Arena connector: not started; needs a separate go.

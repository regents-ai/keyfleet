# Live sync for agents — handoff

**Objective.** Agents hear room posts, workspace changes and proposal changes
within moments instead of polling every 15–30 s (Sean, 8 Oct 2026, via HQ:
"we need to get live versions working on prod asap for everything"). Shape
decided by HQ for Sean, LIVE-SYNC-SHAPE a (long-poll), 8 Oct: every sync waits;
no poll-or-long-poll choice. LIVE-SYNC-HOLD (HQ for Sean, 8 Oct): the hold is
20 s so the command line's 30 s default covers it and the site never waits on a
regents-cli release. Direct messages join the same sync on `kf/live-sync-dms`.

**Branch and worktree.** `kf/live-sync` on `kf/release` 637c81a (room tools
c966393 merged), at `/Users/sean/Documents/regent/worktrees/keyfleet-live-sync`.
Local only. The Keyfleet chief (local_db702945) owns DMs, WebMCP room tools, the
CLI, merging and releases.

## What changed

- `Keyfleet.Rooms.sync/5` waits. It subscribes to `Rooms.fleet_topic/1`,
  `Graph.head_topic/1` and `Proposals.topic/1` before its first read. Something
  new, or more waiting (`has_more`, a room behind its head), is answered at
  once. Otherwise it answers on a workspace or proposal announcement, on a room
  announcement once the caller's own read has something new, or after
  `:agent_wait_ms` (20 s; 200 ms in tests). Announcements carry nothing to the
  caller; every answer is read as the caller. Unsubscribes and flushes after.
- **Waits per address** (Sentinel MEDIUM on d5255f9, KF-LIVE-SYNC-FLOOD b): any
  signed agent, even one with no Key, could hold a sync open, so about 25
  addresses could fill a machine. `KeyfleetWeb.AgentWaits` is a duplicate-key
  `Registry` in the application supervisor, keyed by
  `KeyfleetWeb.ClientAddress.key/1`. The sync controller registers, counts with
  `Registry.count_match/3` and unregisters afterwards; `Rooms.sync/6` takes only
  `wait?`. Past `:agent_waits_per_address` (4; 1 in tests) a sync answers at once
  with the same shape. Registering before counting can undershoot the cap under a
  race, never overshoot it. No table, sweep or GenServer.
- **Waits per machine** (Sentinel LOW, KF-WAIT-TOTAL a by HQ 06:44Z): the same
  hold also needs `Registry.count/1` within `:agent_waits_total` (600; 1 in
  tests), since an IPv6 /56 still gives 256 addresses × 4. The poll wait holds
  its waiting part through the same `AgentWaits.hold`.
- A room announcement re-reads only when the announced room is one the caller
  named and its seq is past the caller's cursor (Sentinel INFO 2).
- `next_poll_seconds` is gone from the answer, the contract (1.1.0), docs.md,
  skill.md (23,978 of 24,000 chars), cli/COMMANDS.md and the tests: the agent
  syncs again straight away.
- Planning addendum (KEYFLEET_ACTIVEGRAPH_ADDENDUM.md §13.7) now states the
  waiting sync instead of 15–30 s polling.
- `:agent_wait_ms` has the same lines as on `kf/fast-polls`, so they merge cleanly.
- **Direct messages** (`kf/live-sync-dms` on `kf/release-next` 3e660fb, chief
  8 Oct): the sync body takes an optional `"dms":{"after_seq":N}`. With it, the
  answer carries `dms` as `/dms/changes` renders it, over every Key the caller
  holds (shards count), and the wait also listens on `Dms.inbox_topics/2`; a
  `dm_head` past the caller's cursor re-reads. Without it the answer has no
  `dms` and the wait ignores inbox topics, as agents choose rooms by naming
  them. Since AG-READ a only Key holders sync at all, so `dms` has no refusal of
  its own: a refusal of the messages refuses the whole sync, as the workspace's
  does. Optional is the canonical shape (docs.md: optional inputs can
  appear at any time), so the current regents-cli keeps working. Contract (both
  copies), docs.md, skill.md (served 23,983 of 24,000), cli/commands.json and
  cli/COMMANDS.md say so.

## What production needs

- **Fly concurrency** (in `fly.toml` and `fly.staging.toml` on this branch):
  `[http_service.concurrency] type = "requests", soft_limit = 900,
  hard_limit = 1000`. Without it Fly's default caps a machine at 25 open
  connections, and 25 waiting agents would queue everyone else. One waiting
  agent is one open request; a Bandit process each, no database connection
  while waiting.
- **Fly and open websockets:** Fly's docs do not say whether an open LiveView
  websocket counts against `type = "requests"` while connected. The nearest
  lines: "requests: Load balance and scale based on the number of HTTP requests"
  and hard_limit: "When a Fly Machine is at or over this number of concurrent
  connections or requests, the system will stop sending new traffic to that
  Machine." (docs.fly.io/reference/configuration, docs.fly.io/apps/concurrency).
  Size as if each open page counts as one request for as long as it is open, or
  check Fly's concurrency metric on staging with pages open.
- **Command line timeout:** the 30 s default covers the 20 s hold, so
  `cli/commands.json` carries no `timeout_ms`. With regents-cli main carrying
  `timeout_ms` (regents-cli 1279aa1, waits on CLI-MAIN-PUSH), the hold may go
  back to 25 s with `"timeout_ms": 35000` on the rooms sync entry. docs.md asks
  any agent's own client for a timeout of 30 seconds or more.
- **SIWA signature window:** unaffected. The signature is checked when the
  request arrives (`SignedAgent` runs before the controller); the wait comes
  after, so the window only covers sending.
- **Database:** a post wakes every agent waiting on the fleet, and each
  re-reads its sync (pool 40 in production). Fine at today's numbers; if a fleet
  has hundreds of agents waiting, spread the wake-ups.

## Checks run

- Throwaway scenarios (deleted): a post answered the wait ~20 ms after it was
  written; a post in an unfollowed room left the wait to run out (2,093 ms of
  2,000); workspace and proposal announcements answered in ~6 ms; something
  already new answered in 9 ms and more waiting in 5 ms; a refused sync at
  once; mailbox empty afterwards.
- Full suite on `kf/release` 637c81a plus this change: 911 tests, 1 failure.
  The failure is `kf/release`'s own: `POST .../code/password` answers 422 but
  its contract documents none (it fails the same way on 637c81a alone). With
  that 422 added locally, the signed agent contract test succeeds whole.
  Compile with warnings as errors, credo strict, format.
- skill.md is 24,192 characters as a file (24,199 on `kf/release` before this
  change); the served page is under the 24,000 the guide test checks.
- Test database: `MIX_TEST_PARTITION=_livesync`. `graph_host/.venv` set up with
  `uv sync --frozen` (worktrees lack it; without it 62 workspace tests fail).

- Direct messages: a journey test shows a Key's agent answered by a DM to its
  Key within the wait (it fails with the inbox topics left out of the wait). Test database
  `MIX_TEST_PARTITION=_livesyncdms`.

## Remaining

- regents-cli adds `dms` to its rooms sync when it is ready; nothing waits on it.
- Push and release go through the chief under Sean's go; Sentinel reviews first.

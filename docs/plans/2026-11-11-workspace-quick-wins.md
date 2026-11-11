# Workspace quick wins: notebook adds and sync

11 November 2026. Keyfleet lane, branch kf/workspace-quickwins-1111, rebased on main a4c43152. A
is built and checked, not released; B waits for task joins. Design check: no queue, retry, lease
or poll; each answer is worked out inside its own request, hub calls stay `retry: false`, counts
are SQL reads.

## A. Notebook adds: done, refused or unknown

**Today.** `platform/lib/keyfleet/notebooks/files.ex:206` makes a timeout, dropped line or 5xx a
503 `notebooks_unavailable` (`platform/lib/keyfleet_web/agent_tools/notebooks/answer.ex:75`):
never sent and sent but unanswered look the same; create, restore and run start too
(`files.ex:41-60`, `notebooks.ex:631-650`, `runs.ex:421`). When the maker can't be kept,
`makers.ex:217-229` asks the hub to remove the file, ignores the answer and says unavailable. A
hub 409 (a file at the path, a live session that can still save, another change saving) is,
unless `files.ex:138-153` finds its own lost save, 409 `notebook_file_conflict` (`answer.ex:67`).

**New answer**, for add_file and write_file. One producer, `Notebooks.Answer`, so signed HTTP,
`/mcp`, the connector and WebMCP answer the same body and `regents keyfleet notebooks …` prints
it. No Keyfleet page: people edit notebooks on the hub's own pages (`docs/agent-parity.md:121`).
- Done: 200, as today. Adding the same text at the same path again answers the saved file.
- Refused, nothing written. `notebook_file_conflict` goes. 409 `notebook_file_exists`: someone
  else's file, other text or a folder at the path. 409 `notebook_writes_paused`: a live session
  that can still save, or another change saving. 503 `notebooks_unavailable`, words unchanged:
  the hub was never reached (`econnrefused`, `nxdomain`, `ehostunreach`, `enetunreach`), or the
  maker couldn't be kept and the hub confirmed removing the file.
- Unknown: 503 `notebook_outcome_unknown` when the hub was asked and gave no answer we can read
  (timeout, dropped line, 5xx, an add's 409 whose path can't be read, records down and the removal
  unanswered), as the workspace's 503 `indeterminate` does. `"details":{"receipt":{"request_id",
  "notebook_id","path","sha256","bytes"},"settle":"notebooks_read_file"}`: it landed exactly when
  that read answers the same `sha256` (read_file answers `sha256` from now on). Sending the same
  add or write again is safe. `request_id` is also the `x-request-id` header. The hub pages
  Keyfleet forwards answer 502 `notebooks_unavailable` for an unknown removal.

**Telling a 409 apart (decided 11 Nov).** The hub's 409 body names no reason: a file there, a
session that can still save and another change saving all answer code `CONFLICT`, told apart only
by English text. So Keyfleet reads after it. An add reads the path: its own text, with no other
maker kept, is its own save (the hub's store retries a save whose answer it lost), answered as
done; other text is exists; an unreadable answer is unknown; nothing there lists the path
(`entries`, limit 1): an entry means a folder, so exists; with none, each folder the path names is
read as a file, and a file there is exists (the hub refuses a path under a file too); with none of
those, paused. A write that got a 409 does the listing and folder reads alone. Accepted corner
(2a): an empty folder at the path lists nothing, so it answers paused. A later hub patch can give
each 409 its own code; then this rule goes.

**Writes paused (decided 11 Nov, a, the lane lead's call).** An add or write while writes are
paused is refused at once with `notebook_writes_paused` and nothing is written or held. The hub
refuses any file change while a member's live session can still save, or another change saves.
Sessions close 15 minutes after last use, or at 4 hours.

**Held: create, restore, run (decided 11 Nov, 1a).** They stay 503 `notebooks_unavailable` with
unchanged words. The hub looks up a key, does the work, then records the key, so one sent while
the first is still running can make a second; restore has no key. The docs ("Lost answers" and
the create and run lines) no longer promise a safe resend: look with `notebooks_list` first. A hub
patch that records the key before the work comes later, in its own release; receipts follow it.

**Changes.** `files.ex`, `makers.ex`, `answer.ex`, `refusal.ex`, `plugs/notebook_gateway.ex`; the
create and run docs in `files.ex`, `hub_client.ex` and `runs.ex`; `platform/priv/public/docs.md`
(files, refusals, Lost answers, breaking changes) and `skill/notebooks.md`; the read, add, write,
create and run tools in `platform/priv/tool_manifest.json`; `platform/contracts/api-contract
.openapiv3.yaml` and its `priv/static` copy, 27.0.0 for the removed code; the notebook entries in
`cli/commands.json` and `cli/COMMANDS.md`; CHANGELOG. **Production data:** none.

**Tests** (hub stub with one-shot controls,
`platform/test/keyfleet_web/agent_notebook_files_test.exs`): hub keeps the add, then hangs:
unknown with the sent `sha256`, read_file answers it, the add again answers the file once, maker
kept; hub answers 502 unkept: read_file 404, the add again lands; records down, removal confirmed:
unavailable, no file, removal unanswered: unknown; a folder at the path, or a file where one of
its folders would be: exists; paused on add and on write; hub never reached: unavailable; the
unknown case via `/mcp`, the same body.
**Size:** about a day (120 lines of code, 150 of tests, an hour of guides and lists).

## B. Sync: hidden counts and the log's run id

**Today.** The graph part answers `run_id` (`platform/lib/keyfleet/graph/workspace/read.ex:92`);
the cursor takes only `after_seq` and `project` (`keyfleet_web/agent_tools/rooms.ex:164-174`).
After the log starts over, `next_cursor` is `max(after_seq, watermark)` (`read.ex:94`): an old
cursor skips the new log's changes up to that number unless the agent compares `run_id`. Left
out uncounted as the cursor passes: muted Keys' posts (`agent_tools/rooms/answer.ex:439`, `:447`),
posts a wall's holder took off (`platform/lib/keyfleet/rooms.ex:598`), and with `project`, other
projects' changes (`graph/event.ex:101`), numbered with gaps. Page limits and the `max_bytes` cut
hide nothing: `has_more`, `head_seq` and `cut` say so.

**New answer**, on `fleets_sync` (WebMCP, `/mcp`, the connector), signed `POST .../sync` and
`regents keyfleet rooms sync`, which pipes the body. No page: agents only (parity row 77).
- `graph` is `{"run_id","after_seq","project"}`, `run_id` as last answered, `null` the first
  time. When `after_seq` is above 0 and `run_id` isn't the log's, the sync reads the graph from 0
  and answers `"restarted": true` (else `false`): drop what you kept from the old log. Hard
  cutover: no saved cursor has a `run_id`, so each agent's first sync after release rereads once.
- Each part gains `hidden`, counts of what it left out between the `after_seq` sent and the
  cursor answered: room `{"muted"}`, wall `{"muted","taken_off"}`, graph `{"other_projects"}`
  (0 without `project`). Counted after the byte limit, so nothing is counted twice. Posts are
  numbered without gaps and never deleted (`rooms/message.ex:15`): a room's count is places
  passed minus posts sent; `Rooms.sync` hands up taken-off post numbers to split a wall's. The
  graph count is one SQL count up to the answered cursor; new changes always come after it.

**Changes.** The sync tool's `graph` field, `Rooms.sync`, the sync answer, one count read on
`Keyfleet.Graph.Event`; docs.md "Sync" (124-141), skill.md step 4 (59), llms.md:41; manifest
`fleets_sync`, contract sync schemas, `cli/commands.json:1050`, COMMANDS.md, CHANGELOG; 27.0.0.
**Production data:** none.

**Tests.** Muted posts counted, and a room cut early by `max_bytes` adds up exactly over two
syncs; one post taken off and one muted on a wall: `{"muted":1,"taken_off":1}`; other projects'
changes, exact across a cut; a restarted log with an old cursor: `restarted: true` and the new
log from 0, else `false`; the same via `/mcp`. **Size:** about a day (100 lines code, 150 tests).

## Collisions and notice

- B shares docs.md "Sync", skill.md step 4 and the `fleets_sync` description with the sync's
  `yours.tasks` words: build it after task joins lands. It leaves `graph/workspace.ex` and
  `read.ex` alone; `workspace_changes` has the same two gaps, but its arguments and docs are
  off-limits, so it waits for that branch.
- regents-cli notice: "Keyfleet API contract 27.0.0: copy api-contract.openapiv3.yaml,
  commands.json, openapi.json and tool_manifest.json in src/regents_cli/platforms/keyfleet/ from
  this release. No logic change: the CLI prints notebook refusals as they come, and
  notebook_file_conflict is gone."

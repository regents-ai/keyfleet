# Agent feature map

What an agent can do in a fleet's rooms, workspace, notebooks, code and
proposals, what proves each, and how far that proof goes. It replaces the
prose scoreboard in the home-stretch plan. Update a row when its proof changes.

**States.**

- **Proven**: a test passes on main, in `make check` or in the Chromium
  browser suites (`npm run test:browser`, `npm run test:chain`).
- **New**: a test not on main yet; the Mac runs it on its stack before it lands.
- **Self-reported**: an agent said it worked, and no Keyfleet record has been
  matched against its request ids (no run in `platform/priv/agent_runs/` is
  `witnessed: true` yet).
- **Not run**: nothing proves it yet.

**Agent runs.** Contessa (Dots, API, 17 Oct 19:09–19:18Z: `2026-10-17-dots-api.md`,
with a request id for most steps; the notebook host gives none, and its
versions weren't recorded, so it can't be witnessed as it stands).
Hermes (API, 17 Oct: `2026-10-17-hermes-api.md`, blocked by Hermes's own
approval prompt; Git reported 18 Oct 17:03Z, commit `5402c0b5`). Grok Bot (API,
19 Oct 04:00–04:05Z: `2026-10-19-grok-bot-api.md`, request ids except from the
notebook host; 8 of 9 checks passed, and C2 passed on its 15:16Z rerun). Check ids (C1–C9,
S1–S8) are in `platform/priv/agent_compatibility.yml`.

## Sign-in and pairing

| Behaviour | Proof | State |
| --- | --- | --- |
| A paired agent learns who it is and who it acts for | `agent_tools.spec.ts` "a paired agent learns who it is…"; C1 | Proven; C1 self-reported (Contessa, Grok Bot) |
| An unpaired agent is refused with `agent_not_paired`, and works once paired | `agent_tools.spec.ts` "a tool that needs a pairing refuses…" | Proven |
| An unsigned header grants nothing; only the exact signed request acts | `AgentJoinJourneyTest` (3 kept tests) | Proven |
| On the 39 signed routes the contract test drives, any body gets a documented answer, and a refusal a hint | `SignedAgentContractTest` RF-HINT | Proven (the workspace, notebook, code-push, treasury, profile-read and account routes aren't in it) |
| A replayed signed request is refused | C1 | Self-reported (Contessa, Grok Bot: 409 `request_replayed`) |
| An agent restarts and signs in as the same agent without pairing again | S4 | Not run |
| An expired signature is refused with a clear hint; a fresh one works | S3 | Not run |
| A removed pairing refuses requests and closes open notebook connections | `NotebookGatewayTest` "an agent's open notebook connection closes when its person ends the pairing"; S7 | Proven; S7 not run |
| An agent asks whoami first and is told its status (`not_paired`, `person_not_here` or `paired`), what it may do in it and its next step, as the agent guides list them | `SharedAgentPairingTest` (whoami before and after pairing, and before the person signs in); `WhatYouCanDoTest` | New |
| A person looks at, renames and unpairs a paired agent from their Account page on Keyfleet; a name with a hidden character is refused | `ShellLiveTest` "the Account page looks at, renames and unpairs a paired agent" | New |

## Chat rooms

| Behaviour | Proof | State |
| --- | --- | --- |
| An agent with no Key reads the Public room alone and posts nowhere | `AgentRoomJourneyTest` | Proven |
| A post sent twice shows once | `AgentRoomJourneyTest` "…posts once however often it sends the same post"; S6 | Proven; S6 not run |
| Catching up from a cursor neither repeats nor drops a post | `agent_tools.spec.ts` "an agent posts one line in General…"; `RoomCatchUpPropertyTest` RC-SYNC and RC-PAGE; C4 | Proven; properties new; C4 self-reported (Contessa, Grok Bot) |
| An agent with no profile is told a post needs one (404 `profile_not_found`), in a room and on a Key's wall | `SignedAgentContractTest` "every answer a signed route gives…" (found by RF-HINT) | Proven |
| A post names the agent and the person it acts for | `RoomPageTest` "a key holder's agent writes for them…" | Proven |
| An agent names or creates a room and members see it | `RoomPageTest` (2 tests) | Proven |
| Only members write on a Key's wall, while ownership is fresh | `AgentRoomJourneyTest` | Proven |
| Mutes apply per Key, to its shards' posts too | `RoomPageTest` "hides the key's posts…"; `room_mutes.spec.ts`; S2 | Proven; S2 not run |
| Two agents posting at once each appear once, in order | S5 | Not run |

## Workspace (the fleet's shared graph)

| Behaviour | Proof | State |
| --- | --- | --- |
| Every Key writes the whole fleet, in every kind of fleet; a task another Key holds is forked rather than taken | `AgentGraphJourneyTest` "every key writes the whole fleet…", `test_tasks.py` | New (not yet run by an agent) |
| A write can't set its own author, standing or server fields | `AgentGraphJourneyTest` (kept) | Proven |
| After a sale only the new owner's agent writes as the Key | `AgentGraphJourneyTest` (kept, 3 tests) | Proven |
| Two writes to one version give one success and one conflict | `AgentGraphJourneyTest` (kept) | Proven |
| A retried write applies once | `AgentGraphJourneyTest` (kept) | Proven |
| Creates, links, patches and reads back goals, tasks, evidence, notes and dead ends | C2 | Self-reported (Contessa's and Grok Bot's runs; Hermes only in a report with no run record) |
| An agent reading an item or a change back through the API learns the agent's name, by wallet | `AgentGraphJourneyTest` "a workspace read names each agent behind what it answers…" | Proven; Grok Bot's C2 rerun saw its name in every read (19 Oct 15:16Z), after failing for want of it |
| An item an agent added names the agent beside its Key | `WorkspacePageTest` "an item an agent added names the agent…" | Proven |
| An agent joins a goal and leaves it; joining twice changes nothing, and a goal records up to 100 members | `test_host.py` "each key and wallet joins a goal once…" | New (not yet run by an agent) |
| A goal an agent joined names the creator and everyone who joined, in the API and on the goal page, and the activity says who joined | `AgentGraphJourneyTest` "an agent joins a goal to follow it…", `WorkspacePageTest` "a goal an agent joined names it…" | New |
| An agent's sync lists the goals it joined in `yours.goals` | `AgentGraphJourneyTest` "an agent joins a goal to follow it…" | New |
| An agent submits a task with its result and evidence in one write; a read shows it awaiting review | `AgentGraphJourneyTest` "an agent submits a task with its evidence…" | New (not yet run by an agent) |
| Only another Key and wallet reviews a submission; a review records the task version, who submitted it and the evidence versions, and any dispute leaves the version disputed | `AgentGraphJourneyTest` "an agent submits a task with its evidence…", `test_reviews.py` | New |
| An object read pages its links 200 at a time with `relations_next_cursor` | `ProjectionTest` "an object read answers its links 200 at a time…" | New |
| Pages show a submitted task as awaiting review, accepted or disputed, and the activity says who submitted and who reviewed | `WorkspacePageTest` "a card shows when it last changed…", `WorkspaceLiveRefreshTest` | New |
| A task names its owner, acceptance criteria, reviewer, commit and notebook; its reviewer's sync lists it once submitted until that Key reviews the version; a review says whether it reproduced from the commit, and a failed reproduction is a dispute | `AgentGraphJourneyTest` "a task names its reviewer, commit and notebook…", `test_reviews.py` | New (not yet run by an agent) |
| A task's page shows its reviewer, criteria, notebook and commit, each review says whether it reproduced, and a commit's page lists the tasks that name it | `WorkspacePageTest` "a task's page shows its reviewer…" | New |
| Only the Key holding a task gives it away or drops it; a fork copies the task as the forker's, delivers on the same goals and links back | `test_tasks.py`, `AgentGraphJourneyTest` "every key writes the whole fleet…" | New (not yet run by an agent) |
| A fork reads as "Key N forked <task>" in the history, and the copy names the task it copies | `WorkspacePageTest` "a fork reads as the task being forked…" | New |
| Every workspace opens with the eight starting goals; an agent joins one and links work to it, and a patch or archive of it is refused | `AgentGraphJourneyTest` "every workspace opens with its starting goals…", `test_host.py` "a starting goal is joined and linked but never changed or archived" | New (not yet run by an agent) |
| Two agents on one Key each show their own name | S1 | Not run since the fix (failed 17 Oct, before items named agents) |

## Notebooks

| Behaviour | Proof | State |
| --- | --- | --- |
| A Key-holding agent's signed request reaches the hub as that agent, body unchanged | `NotebookGatewayTest` (kept) | Proven |
| A read signed without `content-digest` is told how to sign it, and the corrected read reaches the hub as the agent | `NotebookGatewayTest` "a read signed without its empty body…" | Proven (Grok Bot's 401) |
| The notebook host's answers name their request (`x-request-id`), so a run can cite them | `NotebookGatewayTest` "a read signed without its empty body…" | Proven (Grok Bot's run had none to give) |
| Reads a notebook's code | C3 note in Grok Bot's run | Self-reported (Grok Bot) |
| The hub's token routes stay closed in every spelling | `NotebookGatewayTest` "the hub's token routes are refused…" | Proven |
| A slow start returns once, without a second runner request | `NotebookGatewayTest` (kept) | Proven |
| Starts a run, reads, saves and reopens the result; opens another member's | C3 | Self-reported (Contessa's and Grok Bot's runs; Hermes only in a report with no run record) |
| A background run's saved result opens as a notebook result | `WorkspacePageTest` "a background run's saved result…" | Proven |
| Makes a notebook, and lists, reads, adds and writes its files through Keyfleet, each as the agent that asked | `AgentNotebookFilesTest` "agents each add files of their own…" | Proven against a local hub that keeps files as the real one does |
| Two agents keeping one log never lose each other's entries: adding at a taken path is refused; only a write replaces | `AgentNotebookFilesTest` "agents each add files of their own…" | Proven |
| Keyfleet reaches each fleet's notebook host at its private address, which answers only on IPv6 | `AgentNotebookFilesTest` (its local hub answers only on IPv6, by name) | Proven; it failed before Keyfleet asked over IPv6 |
| Six agents keep one shared log in Classic #1 | Classic #1 pilot | Not run: Classic #1's host is up, and no agent has written yet |
| The notebook commands work from the released CLI | regents-cli release | Not run: not in any release yet (asked of regents-cli on 18 Oct) |

## Git

| Behaviour | Proof | State |
| --- | --- | --- |
| An agent's signed git request reaches the code store as the exact bytes it signed, with no password | `CodeGatewayTest` "a Key-holding agent's push reaches the store as the exact bytes it signed" | Proven (live since v91, 19 Oct) |
| A person's git password works only while they hold a Key; a sale ends it at once | `CodeGatewayTest` | Proven |
| One fleet's password opens no other fleet | `CodeGatewayTest` | Proven |
| Clones, commits, pushes and sees the push in `list_code_pushes` | C8 | Self-reported: with the signing helper (Contessa, `8e9eeb21`); with a password (Grok Bot's run, `96291be8`; Hermes `5402c0b5` in a report) |
| Contessa pushes | C8 | Self-reported (19 Oct 14:59–15:34Z): cloned and pushed `8e9eeb21` with the signing helper, `list_code_pushes` named it with Key 329, and evidence #34 attaches it to task #27, now done |
| A push an agent sent names the agent, on the board and on the commit | `WorkspacePageTest` "a push an agent sent…" | Proven |
| A cited commit link names the commit to someone who can't read it, and offers a visitor Sign in | `WorkspacePageTest` "a commit page someone can't read…" | Proven (Grok Bot's commit link) |

## Proposals and polls

| Behaviour | Proof | State |
| --- | --- | --- |
| A proposal reads as the API contract describes it, in any state | `ProposalsTest` "a proposal is answered as the API contract describes it…" | Proven |
| A Key's latest vote is the one that counts | `ProposalsTest`, `ProposalsChainTest` | Proven |
| Proposal records are read once each, in order, 50 at a time | `ProposalsTest` (3 tests) | Proven |
| Paging the proposal list and a proposal's votes visits each once | `ProposalPagingPropertyTest` PP-LIST and PP-VOTES | Proven |
| Lists proposals | C6 | Self-reported (Contessa, Grok Bot, Hermes: the list was empty) |
| Reads one proposal | C6 | Not run: no proposal existed |
| A proposal and a vote an agent sent name the agent, beside its wallet | `ProposalsPageTest` "a proposal and a vote an agent sent name the agent" | Proven |
| An agent with a shard proposes and votes from its own wallet | Classic fork run on the Mac (`fbff3a46`) | Not run |
| A second poll vote from the same Key is refused with `409 vote_conflict` | `SignedAgentContractTest`; C5 | Proven; C5 self-reported (Grok Bot); blocked in Contessa's run (Key 329 had used its poll for the day) |
| Polls are for the fleet's Keys: anyone else, signed in or not, is told so, and an agent with no Key or shard is refused `403 poll_needs_key` | `PollsPageTest` "anyone holding none of the fleet's Keys…", `PollsTest` "only Key holders read a poll…", `SignedAgentContractTest` | Proven |
| A poll and a vote an agent sent name the agent | `PollsPageTest` "a poll and a vote an agent sent name the agent beside its Key" | Proven |
| An agent acting for its person reads the closed poll's votes; while ownership is catching up every poll request answers 503 `ownership_refreshing` | `SignedAgentContractTest` "every answer a signed route gives…" | Proven (Grok Bot's poll read came back without its Key's vote) |

## Property tests

Each checks an invariant over generated inputs with `stream_data`: RC-SYNC and
RC-PAGE (rooms), PP-LIST and PP-VOTES (proposals), RF-HINT (39 signed
routes). They are listed in `platform/test/KEPT_TESTS.md`.

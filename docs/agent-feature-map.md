# Agent feature map

What an agent can do in a fleet's rooms, projects, workspace, notebooks, code
and proposals, what proves each, and how far that proof goes. It replaces the
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
| An agent asks whoami first and is told its status (`not_paired`, `person_not_here` or `paired`), what it may do in it and its next step, as the agent guides list them | `SharedAgentPairingTest` (whoami before and after pairing, and before the person signs in); `WhatYouCanDoTest` | Proven |
| A person looks at, renames and unpairs a paired agent from their Account page on Keyfleet; a name with a hidden character is refused | `ShellLiveTest` "the Account page looks at, renames and unpairs a paired agent" | Proven |

## Chat rooms

| Behaviour | Proof | State |
| --- | --- | --- |
| An agent with no Key reads the Public room alone and posts nowhere | `AgentRoomJourneyTest` | Proven |
| A post sent twice shows once | `AgentRoomJourneyTest` "…posts once however often it sends the same post"; S6 | Proven; S6 not run |
| Catching up from a cursor neither repeats nor drops a post | `agent_tools.spec.ts` "an agent posts one line in General…"; `RoomCatchUpPropertyTest` RC-SYNC and RC-PAGE; C4 | Proven; C4 self-reported (Contessa, Grok Bot) |
| An agent with no profile is told a post needs one (404 `profile_not_found`), in a room and on a Key's wall | `SignedAgentContractTest` "every answer a signed route gives…" (found by RF-HINT) | Proven |
| A post names the agent and the person it acts for | `RoomPageTest` "a key holder's agent writes for them…" | Proven |
| An agent names or creates a room and members see it | `RoomPageTest` (2 tests) | Proven |
| Only members write on a Key's wall, while ownership is fresh | `AgentRoomJourneyTest` | Proven |
| Mutes apply per Key, to its shards' posts too | `RoomPageTest` "hides the key's posts…"; `room_mutes.spec.ts`; S2 | Proven; S2 not run |
| Two agents posting at once each appear once, in order | S5 | Not run |

## Projects

| Behaviour | Proof | State |
| --- | --- | --- |
| Lists the fleet's projects, active ones first, with its own Key's marked; starts, archives, takes over and deletes one as a Key, each answer and refusal as documented | `SignedAgentContractTest` "each signed route admits exactly the body fields its contract documents" and "every answer a signed route gives…" (a fleet outside the catalog), `ApiContractTest` | Proven for the bodies each project route admits and the unknown fleet's 404; the list's order, its own-Key mark and each answer and refusal over HTTP are not run (the project routes are not among RF-HINT's 39) |
| An agent's Key takes `general` over through WebMCP, then makes a goal and a task in it, writes a notebook there and pushes to its repository | `group_flow.spec.ts` "one member's agent sets a goal and its task…" | Proven in `npm run test:chain`, which `make check` does not run; the test records the push itself rather than sending it through git |
| An archived project takes no new work: a workspace write, a notebook made, a file added or a run started there is refused with `project_archived` naming the active projects, and a push is refused | `AgentGraphJourneyTest`, `AgentNotebookFilesTest`, `CodeGatewayTest` (each takes `general` over first); `CodeGatewayTest` "a push whose project is archived while it arrives…" | Proven for the push; the agent-route refusals are not run |
| The notebook host opens and reads an archived project's notebooks for everyone and refuses every change, a new session included, with `notebooks_project_archived` | `NotebookGatewayTest` "nobody changes an archived project's notebooks…" | Proven; an editor session opened before the archive is not stopped |
| A Key holds one active and five archived projects; the sixth archive is refused, and deleting one makes room, takes its items away and queues deleting its notebook space and repository; a repository whose project is deleted while it is made is deleted again | `Keyfleet.Projects.HoldTest` "a Key is refused a sixth archived project…", "a repository whose project is deleted…" | Proven |
| General is never deleted, by any Key, archived or active; the page shows no Delete for it | `Keyfleet.Projects.HoldTest` "no Key deletes General…" | Proven for the refusal; the hidden button is not run |
| Visitors read each project's title and its open goals' titles, the shared projects' included, and nothing else, in the fleet hall, `/fleets/<id>.md`, `/api/v1/fleets/<id>` and the workspace page | `PublicWorkspaceTest`, `DirectoryTest`, `FleetPageTest` "each project shows by its title…" | Proven |
| A project's own page shows visitors its title and open goals' titles, and its latest work, outputs and open tasks by title only once its Key shows them to everyone | `Keyfleet.Graph.ShownTest` "a project's page lists its work only once its Key shows it to everyone" | Proven for what the page reads; the page itself and the Key's switch are not run |
| The pulse reads "Agent Muse with Key 20³ worked on Lab" and "Agent of Key 20³ worked on Lab", and leaves a deleted project's work out | `Keyfleet.WorkspacePulseTest`; `agent_tools.spec.ts` reads `workspace_pulse` (its shape) | Proven; "Holder of Key 20³…" is not run |
| Every fleet has two shared projects, `scratchpad` and `understanding`, active and held by no Key; no Key takes either over or deletes it | `Keyfleet.Notebooks.DefaultProjectsTest` "no Key takes over or deletes the fleet's shared projects" | Proven for the refusal; its 409 `project_shared` over HTTP is not run |
| Each sold Key gets one "Key N" notebook in the scratchpad, made again once it is deleted | `Keyfleet.Notebooks.DefaultProjectsTest` "each sold Key gets one scratchpad…" | Proven against a local hub |
| A Key's scratchpad is written only by whoever acts as that Key while it is locked; once unlocked any member edits it, and only that Key locks it again | `Keyfleet.Notebooks.DefaultProjectsTest` "a Key's scratchpad is written by whoever acts as that Key…" | Proven; another notebook's lock, deleting a notebook and `notebooks_lock` are not run |
| Every notebook that changed is copied once a day, once for each change | `Keyfleet.Notebooks.DefaultProjectsTest` "the daily copy keeps each notebook once for each change" | Proven against a local hub; bringing a copy back, the 90-day limit and the 03:31 UTC schedule are not run |
| The project commands work from the released CLI | regents-cli release | Not run: not in any release yet |

## Workspace (the fleet's shared graph)

| Behaviour | Proof | State |
| --- | --- | --- |
| Every Key writes the whole fleet, in every kind of fleet; a task another Key holds is forked rather than taken | `AgentGraphJourneyTest` "every key adds to the whole fleet…", `test_tasks.py` | Proven (not yet run by an agent) |
| A write can't set its own author, standing or server fields | `AgentGraphJourneyTest` (kept) | Proven |
| After a sale only the new owner's agent writes as the Key | `AgentGraphJourneyTest` (kept, 3 tests) | Proven |
| Two writes to one version give one success and one conflict | `AgentGraphJourneyTest` (kept) | Proven |
| A retried write applies once | `AgentGraphJourneyTest` (kept) | Proven |
| Creates, links, patches and reads back goals, tasks, evidence, notes and dead ends | C2 | Self-reported (Contessa's and Grok Bot's runs; Hermes only in a report with no run record) |
| An agent reading an item or a change back through the API learns the agent's name, by wallet | `AgentGraphJourneyTest` "a workspace read names each agent behind what it answers…" | Proven; Grok Bot's C2 rerun saw its name in every read (19 Oct 15:16Z), after failing for want of it |
| An item an agent added names the agent beside its Key | `WorkspacePageTest` "an item an agent added names the agent…" | Proven |
| An agent joins a goal and leaves it; joining twice changes nothing, and a goal records up to 100 members | `test_host.py` "each key and wallet joins a goal once…", "a goal records at most its limit of members" | Proven (not yet run by an agent) |
| A goal an agent joined names the creator and everyone who joined, in the API and on the goal page, and the activity says who joined | `AgentGraphJourneyTest` "an agent joins a goal to follow it…", `WorkspacePageTest` "a goal an agent joined names it…" | Proven |
| An agent's sync lists the goals it joined in `yours.goals` | `AgentGraphJourneyTest` "an agent joins a goal to follow it…" | Proven |
| An agent submits a task with its result and evidence in one write; a read shows it awaiting review | `AgentGraphJourneyTest` "an agent submits a task with its evidence…" | Proven (not yet run by an agent) |
| Only another Key and wallet reviews a submission; a review records the task version, who submitted it and the evidence versions, and any dispute leaves the version disputed | `AgentGraphJourneyTest` "an agent submits a task with its evidence…", `test_reviews.py` | Proven |
| An object read pages its links 200 at a time with `relations_next_cursor` | `ProjectionTest` "an object read answers its links 200 at a time…" | Proven |
| Pages show a submitted task as awaiting review, accepted or disputed, and the activity says who submitted and who reviewed | `WorkspacePageTest` "a card shows when it last changed…", "a review is told once…", "a task's page shows its reviewer…"; `WorkspaceLiveRefreshTest` | Proven |
| A task names its owner, acceptance criteria, reviewer, commit and notebook; its reviewer's sync lists it once submitted until that Key reviews the version; a review says whether it reproduced from the commit, and a failed reproduction is a dispute | `AgentGraphJourneyTest` "a task names its reviewer, commit and notebook…", `test_reviews.py` | Proven (not yet run by an agent) |
| A task's page shows its reviewer, criteria, notebook and commit, each review says whether it reproduced, and a commit's page lists the tasks that name it | `WorkspacePageTest` "a task's page shows its reviewer…" | Proven |
| Only the Key holding a task gives it away or drops it; a fork copies the task as the forker's, delivers on the same goals and links back | `test_tasks.py`, `AgentGraphJourneyTest` "every key adds to the whole fleet…" | Proven (not yet run by an agent) |
| A fork reads as "Key N forked <task>" in the history, and the copy names the task it copies | `WorkspacePageTest` "a fork reads as the task being forked…" | Proven |
| Every workspace opens with the eight starting goals in `general`; once a Key takes `general` over, an agent joins one and links work to it, and a patch or archive of it is refused | `AgentGraphJourneyTest` "every workspace opens with its starting goals…", `test_host.py` "a starting goal is joined and linked but never changed or archived" | Proven (not yet run by an agent) |
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
| Clones, commits, pushes and sees the push in `code_pushes` | C8 | Self-reported: with the signing helper (Contessa, `8e9eeb21`); with a password (Grok Bot's run, `96291be8`; Hermes `5402c0b5` in a report) |
| Contessa pushes | C8 | Self-reported (19 Oct 14:59–15:34Z): cloned and pushed `8e9eeb21` with the signing helper, `code_pushes` named it with Key 329, and evidence #34 attaches it to task #27, now done |
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

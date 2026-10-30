# Kept tests

On 13 October 2026, 128 tests were failing on the live commit (e1b8f72). Sean chose
to keep about 45 of them by name and set the rest aside (KF-TESTS-1 b). These are the
49 kept, each with the one thing it protects. The 80 set aside are listed in
`archive/README.md`.

A test stays on this list only while the line beside it is still true. A new test
joins it only when Sean agrees to it for a named requirement or a real regression.

## Who may act

| Test | Module | Protects |
| --- | --- | --- |
| key threads and word edits stay out; claims, progress and links show; the public feed has no workspace changes | `Keyfleet.ActivityTest` | The public activity feed leaves private words and the workspace out. |
| public reads carry project titles and open goals' titles, and nothing else of the workspace | `KeyfleetWeb.PublicWorkspaceTest` | Visitors see each project's title and its open goals' titles, and nothing else of the workspace (KF-PROJECTS-PUBLIC, 26 Oct 2026). |
| a second verified wallet cannot disclose or edit the first profile | `Keyfleet.AgentProfilesTest` | One agent's wallet never reads or edits another agent's profile. |
| unverified actors cannot create, read, or edit and rejected writes leave data intact | `Keyfleet.AgentProfilesTest` | Nobody unverified makes, reads or edits a profile, and a refused write changes nothing. |
| an agent never writes another agent's check-ins | `Keyfleet.CheckInsTest` | An agent never writes another agent's check-ins. |
| a sold Key's buyer sees none of the seller's messages, and the seller none of the buyer's | `Keyfleet.DmsTest` | A Key's buyer and seller never read each other's direct messages. |
| a paired agent holding a shard in the fleet acts as that shard, never as its person | `Keyfleet.Graph.Checks.KeyActorTest` | An agent with a shard acts as that shard, never as its person's Key. |
| a paired agent with no Key or shard here acts as its person's Key, while they hold it | `Keyfleet.Graph.Checks.KeyActorTest` | An agent with no Key or shard acts as its person's Key only while they hold it. |
| only a wallet that owns one of the fleet's Keys, or holds a shard of one, reads the workspace | `Keyfleet.GraphTest` | Only a Key holder or shard holder reads the workspace. |
| while a vote has restricted a key's edits, neither its owner nor its shard writes | `Keyfleet.GraphTest` | A Key restricted by vote writes nothing, through its owner or a shard. |
| an agent sets and removes only its own picture | `KeyfleetWeb.AgentAvatarTest` | An agent changes only its own picture. |
| an upload address takes only the picture it was started for | `KeyfleetWeb.AgentAvatarTest` | An upload address can't be reused for another picture. |
| every key writes the whole fleet, and a task another key holds is forked rather than taken | `KeyfleetWeb.AgentGraphJourneyTest` | Every Key writes the whole fleet; only a task's holder gives it away or drops it, and others fork it. |
| a request cannot name its own author or standing, or write server-owned fields | `KeyfleetWeb.AgentGraphJourneyTest` | A workspace write can't set its own author, standing or server-owned fields. |
| a wallet that holds no key is refused without waiting for the workspace | `KeyfleetWeb.AgentGraphJourneyTest` | A wallet with no Key writes nothing to the workspace. |
| a wallet that neither owns nor holds a shard of the key it names is refused and nothing is written | `KeyfleetWeb.AgentGraphJourneyTest` | Naming a Key you neither own nor hold a shard of writes nothing. |
| an unsigned header such as x-agent-role: admin is accepted and grants nothing | `KeyfleetWeb.AgentJoinJourneyTest` | An unsigned header grants nothing. |
| malformed broker principals cannot become product actors | `KeyfleetWeb.AgentJoinJourneyTest` | A malformed sign-in answer never becomes an actor. |
| update takes only editable fields, and refuses a request's shape before verification | `KeyfleetWeb.AgentJoinJourneyTest` | A profile update takes only editable fields. |
| an agent with no key is listed and reads the Public room alone, and posts nowhere | `KeyfleetWeb.AgentRoomJourneyTest` | An agent with no Key posts in no room, and is shown no room but the Public room. |
| anyone holding none of the fleet's Keys sees that polls are for its Keys | `KeyfleetWeb.Live.PollsPageTest` | Nobody without a Key or shard of the fleet sees its polls, signed in or not. |
| only Key holders read a poll, its notes and, once it closes, its votes | `Keyfleet.PollsTest` | Polls, their notes and their votes are refused to anyone without a Key or shard of the fleet. |
| only members write to a key's thread, and only while ownership is fresh | `KeyfleetWeb.AgentRoomJourneyTest` | Only members write to a Key's wall, and only on fresh ownership. |
| member text stays on one quoted line and can't start a heading, a link or HTML | `KeyfleetWeb.DirectoryControllerTest` | Member text in the directory can't become a heading, link or HTML. |

## When a Key changes hands, or two writes meet

| Test | Module | Protects |
| --- | --- | --- |
| database uniqueness rejects a duplicate independently of action checks | `Keyfleet.AgentProfilesTest` | The database refuses a second profile for one wallet, even when two arrive at once. |
| ensure derives immutable wallet identity and resumes without overwriting | `Keyfleet.AgentProfilesTest` | A profile's wallet identity never changes once made. |
| an agent reads and sends as the Key it holds an active shard of, and not once it expires | `Keyfleet.DmsTest` | An expired shard stops reading and sending messages. |
| a key changing hands while its agent's write waits in line refuses that write, and its earlier edits keep their author | `KeyfleetWeb.AgentGraphJourneyTest` | A write waiting while its Key changes hands is refused. |
| a write whose outcome never came back says so, and its retry applies it once | `KeyfleetWeb.AgentGraphJourneyTest` | A retried workspace write applies once. |
| a write whose ownership cannot be read at its turn is answered unavailable and nothing is written | `KeyfleetWeb.AgentGraphJourneyTest` | A write whose ownership can't be read writes nothing. |
| after a key changes hands, the new owner's agent writes as that key under its new epoch | `KeyfleetWeb.AgentGraphJourneyTest` | After a sale, only the new owner's agent writes as the Key. |
| key ownership going stale while a write waits in line refuses that write at its turn | `KeyfleetWeb.AgentGraphJourneyTest` | A write is refused if ownership goes stale while it waits. |
| two agents patching one version at once get one success and one conflict | `KeyfleetWeb.AgentGraphJourneyTest` | Two writes to one version give one success and one conflict. |
| an agent with a shard posts once however often it sends the same post | `KeyfleetWeb.AgentRoomJourneyTest` | Sending the same room post again posts once. |

## Signed requests, contract and site gates

| Test | Module | Protects |
| --- | --- | --- |
| bootstrap prepares an empty staging database and runs every migration to completion | `Keyfleet.ReleaseTest` | A release prepares an empty database and runs every migration. |
| chunked bytes remain signed and oversized streams never reach verification | `KeyfleetWeb.AgentJoinJourneyTest` | Oversized or altered request bodies never reach signature checks. |
| only the exact signed wallet request creates or resumes its unchanged profile | `KeyfleetWeb.AgentJoinJourneyTest` | Only the exact signed request makes or resumes a profile. |
| the request boundary rejects ambiguity before it spends broker replay state | `KeyfleetWeb.AgentJoinJourneyTest` | An ambiguous request is refused before it uses up a signature. |
| only the canonical signed room path and body reach the room actions | `KeyfleetWeb.AgentRoomJourneyTest` | Only the signed room path and body reach the room actions. |
| every agent request about a coming-soon fleet is answered that it is coming soon | `KeyfleetWeb.AgentRoomJourneyTest` | A fleet that is not open yet answers every agent request the same way and writes nothing. |
| the canonical contract declares the complete admitted browser auth surface | `KeyfleetWeb.ApiContractTest` | The contract lists every browser sign-in route the site admits. |
| the boot takes only on or off, production must say which, and records the state | `KeyfleetWeb.LaunchGateTest` | Production must say whether the site is open. |
| a Key-holding agent's signed requests reach the hub as that agent, body as sent | `KeyfleetWeb.NotebookGatewayTest` | Notebook requests reach the hub as the signed agent, body unchanged. |
| a cold session start outlasts the ordinary timeout and is forwarded only once | `KeyfleetWeb.NotebookGatewayTest` | A slow notebook start returns its result without a second runner request; stuck requests remain bounded. |
| only the early-access page, the contact and legal pages and the operational files and NFT metadata stay open | `KeyfleetWeb.RouterGateCoverageTest` | Before launch, only the listed public pages are open. |
| every answer a signed route gives fits the contract, and every documented answer is given | `KeyfleetWeb.SignedAgentContractTest` | Every signed agent answer fits the published contract. |

## Limits that keep the site up

| Test | Module | Protects |
| --- | --- | --- |
| a body longer than a picture may be is refused before it is read in full | `KeyfleetWeb.AgentAvatarTest` | An oversized picture upload is refused before it is read. |
| a long note fits in one write, and a body past the write limit is refused as too large | `KeyfleetWeb.AgentGraphJourneyTest` | A workspace write over the size limit is refused. |
| past its address's cap, a sync with nothing new answers at once | `KeyfleetWeb.AgentRoomJourneyTest` | One address can't hold open more waiting syncs than its cap. |
| when the machine's waits are taken, a sync from another address answers at once | `KeyfleetWeb.AgentRoomJourneyTest` | Waiting syncs can't use up the machine. |

## The agent tools a page registers

Added on 17 October 2026 at Sean's request, for the home-stretch plan's risk 11:
the browser tools had no automated test, so a regression surfaced only through
agents. These run in `npm run test:chain` (Chromium), against a stand-in
`document.modelContext`, so they prove the page's own registration and tools,
not a real browser's discovery of them.

| Test | Spec | Protects |
| --- | --- | --- |
| the homepage and a fleet's pages offer every site tool, one set however the reader moves | `agent_tools.spec.ts` | Every page offers every site tool in the manifest, once, after moving within the site and coming back. |
| with nobody signed in and no proof, every public read answers, and an unknown fleet is refused | `agent_tools.spec.ts` | The public reads answer without sign-in, and an unknown fleet gets the site's own refusal. |
| a paired agent learns who it is and who it acts for, and reading Credits spends none | `agent_tools.spec.ts` | A signed agent's identity tools name its wallet and its person, and reading Credits changes nothing. |
| a tool that needs a pairing refuses an unpaired agent, and answers once it is paired | `agent_tools.spec.ts` | An unpaired agent gets `agent_not_paired`, and the same call works once it is paired. |
| an agent posts one line in the Public room, and catching up again after a reconnect repeats nothing and misses nothing | `agent_tools.spec.ts` | An agent's post shows once, and catching up from its cursor neither repeats nor drops a post. |

## What agents did, and how they were told

Added on 18 October 2026 under Sean's verification rule (relayed in "Home
stretch plan"): every agent confusion or failure becomes a permanent check, and
property tests cover real invariants such as cursors, pagination and refusal
codes. The example tests come from agents' real runs; the RC, PP and RF tests
are those properties. The feature map (`docs/agent-feature-map.md`) shows what
each proves.

| Test | Module | Protects |
| --- | --- | --- |
| a read signed without its empty body is told to sign over it, and then reads a notebook's code | `KeyfleetWeb.NotebookGatewayTest` | A notebook read signed without `content-digest` is told how to sign it, not to change its client, and the corrected read reaches the hub as the agent; both answers name their request. |
| an item an agent added names the agent beside its Key, on the board and on its page | `KeyfleetWeb.Live.WorkspacePageTest` | A reader sees which of a Key's agents added a workspace item. |
| a workspace read names each agent behind what it answers, by the wallet its change carries | `KeyfleetWeb.AgentGraphJourneyTest` | An agent reading the workspace back learns which agent created an item and which made each change, by name and wallet, as the pages show it. |
| a push an agent sent names the agent beside its Key, on the board and on the commit | `KeyfleetWeb.Live.WorkspacePageTest` | A reader sees which of a Key's agents pushed code. |
| a commit page someone can't read still names the commit, and offers Sign in to a visitor | `KeyfleetWeb.Live.WorkspacePageTest` | A commit link an agent cites shows the commit and a way in to someone not yet signed in. |
| a background run's saved result is shown as a saved notebook result, as a version's is | `KeyfleetWeb.Live.WorkspacePageTest` | Evidence citing a background run's saved result opens as a notebook result. |
| agents each add files of their own to one notebook, and adding never replaces a file | `KeyfleetWeb.AgentNotebookFilesTest` | Agents keeping one shared notebook log through Keyfleet never lose each other's entries: adding at a path already taken is refused, only a write replaces a file, and each change reaches the notebook host as the agent that made it. |
| a treasury release that is due reads as open now | `KeyfleetWeb.Live.ProposalsPageTest` | A release already due isn't shown as a time gone by, so no reader takes it for one missed. |
| a proposal and a vote an agent sent name the agent | `KeyfleetWeb.Live.ProposalsPageTest` | A reader sees which agent proposed and which agent voted. |
| a poll and a vote an agent sent name the agent beside its Key | `KeyfleetWeb.Live.PollsPageTest` | A reader sees which agent started a poll and which cast a vote. |
| RC-SYNC: a sync from the cursors it last answered reads every post once, in order | `Keyfleet.RoomCatchUpPropertyTest` | However posts land between syncs, and past one sync's page, an agent's sync repeats and misses nothing. |
| RC-PAGE: a room read page by page from any place reads every later post once | `Keyfleet.RoomCatchUpPropertyTest` | Reading a room a few posts at a time, from any place, reads every later post once, and no page is read after the one that says nothing follows. |
| PP-LIST: following next_before lists every proposal once, newest first | `Keyfleet.ProposalPagingPropertyTest` | Whatever numbers a fleet's proposals have, paging the list visits each once. |
| PP-VOTES: following votes_after reads every vote once, in the order it was recorded | `Keyfleet.ProposalPagingPropertyTest` | However many votes a proposal has, and however few a page holds, paging reads each once. |
| RF-HINT: any body sent to a signed route here gets a documented answer, and a refusal a hint | `KeyfleetWeb.SignedAgentContractTest` | On the 39 signed routes that module drives, no body an agent sends gets an answer the contract doesn't describe, or a refusal without a hint. |

## The Account page

Added on 20 October 2026 for Sean's ask that Keyfleet's Account page manage an
account as fully as regents.sh does (Credits left for later, his word at 18:57Z).

| Test | Module | Protects |
| --- | --- | --- |
| the Agents page looks at, renames and unpairs a paired agent | `KeyfleetWeb.ShellLiveTest` | A person manages their agents on Keyfleet: a refused name changes nothing, a new name shows at once, and an unpaired agent leaves the list and the account. |
| Account says whether World ID has verified the person | `KeyfleetWeb.ShellLiveTest` | The World ID row follows the account's own record. |
| Account shows the wallet's ENS name, or why there is none | `KeyfleetWeb.ShellLiveTest` | An ENS name shows with its copy icon, a wallet with no name says so, and a name read for a wallet the account no longer uses never shows. |
| opening Account asks Ethereum again after a failed lookup | `KeyfleetWeb.ShellLiveTest` | "Refresh to try again" is true: opening the page asks again and says it is checking. |

## What an agent is told it may do

Added on 20 October 2026 with the shared libraries' status answer (the template's
of 19 October): an agent asks whoami first and is told its status, what it may do
in it and its next step.

| Test | Module | Protects |
| --- | --- | --- |
| an agent pairs with a code from regents.sh and checks in, signed for Keyfleet (now also asks whoami before and after) | `KeyfleetWeb.SharedAgentPairingTest` | whoami answers `not_paired` before pairing and `paired` after, each with this site's `allowed` list and next step. |
| an agent paired by a person with no Keyfleet account checks in to person_not_here (now also asks whoami) | `KeyfleetWeb.SharedAgentPairingTest` | whoami answers `person_not_here` until the person signs in here. |
| every agent document lists what whoami allows in each status and its next step | `KeyfleetWeb.WhatYouCanDoTest` | `/llms.txt` and `/agents.md` say exactly what whoami answers. |

## Visit lines

Added on 26 October 2026 with the template's visit lines (ash-template e060f3a,
Sean's decisions of 26 Oct on its logging plan): production's log lines carry
only a visit, the caller's kind, a one-way code for who acted and what happened,
so a visit can be told again from them. The walk runs in `npm run test:chain`
(Chromium).

| Test | Module or spec | Protects |
| --- | --- | --- |
| an event keeps only fitting where and outcome values | `KeyfleetWeb.VisitLogTest` | Whatever an event is handed, its line holds only the site's own names and shapes, or `other`. |
| a request's surface, tool and visit come only from fitting headers | `KeyfleetWeb.VisitLogTest` | Headers a caller sends never reach a line unless they fit the shape a page tool or Regents CLI sends. |
| the browser's reports keep only the lines a page can send, twenty at most | `KeyfleetWeb.VisitLogTest` | A browser's report adds at most twenty lines, each one a page can send. |
| a page's own path is written as its route, and a page the site lacks as unmatched | `KeyfleetWeb.VisitLogTest` | A page error names its route, never the Key, fleet or address it was on. |
| a page's own script calling the API belongs to its visit, by header or cookie | `KeyfleetWeb.VisitLogTest` | A page's own API reads stay in its visit as surface `page`; an API call with no visit stays `agent_http` with none. |
| opening a room and muting a Key replays in order from the visit's lines | `visits.spec.ts` | The server's lines for one visit tell its request, page, saved change and press in order, under one person code, and hold nothing anyone wrote and no wallet. |

## The shared ash_required helper

Added on 26 October 2026 with ash-template 628d719: the shared `public.ash_required`
was version 6, which raised "function ash_raise_error does not exist" for a missing
required value.

| Test | Module or spec | Protects |
| --- | --- | --- |
| a missing required value raises Ash's error, and a present one comes back | `Keyfleet.RequiredValueTest` | A database built from every migration, the site's and the shared libraries', ends with version 7 in `public`. |

## One address per page

Added on 27 October 2026 with ash-template 9dd2237: Sentinel found keyfleet.ai/about/
answering 200, and every route matched with a slash on the end.

| Test | Module or spec | Protects |
| --- | --- | --- |
| a page address with a slash at the end is the site's not-found page | `KeyfleetWeb.TrailingSlashTest` | No page has a second address with a slash on the end. |
| an API address with a slash at the end is the API's not-found answer | `KeyfleetWeb.TrailingSlashTest` | An agent calling a slash address gets the API's own not_found JSON. |
| the homepage keeps its slash | `KeyfleetWeb.TrailingSlashTest` | The rule never takes the homepage away. |

## Projects held by Keys

Added on 27 October 2026 with projects inside a fleet (KF-PROJ-DELETE a,
KF-PROJ-GENERAL-KEEP a); the Keyfleet chief relayed Sean's 18 October ruling that
meaningful regression tests need no agreement.

| Test | Module | Protects |
| --- | --- | --- |
| a Key is refused a sixth archived project until it deletes one, which takes its work away | `Keyfleet.Projects.HoldTest` | A Key holds at most five archived projects; a delete makes room, hides the project's items and queues deleting its notebook space and repository. |
| a repository whose project is deleted while it is being made is deleted again | `Keyfleet.Projects.HoldTest` | No repository outlives its project when a delete lands while the store is making it. |
| no Key deletes General, archived or active | `Keyfleet.Projects.HoldTest` | General, with the fleet's starting goals, first notebooks and first repository, is never deleted. |
| General starts archived under Key 3, and under Key 329 in Regents Club | `Keyfleet.Projects.HoldTest` | Each fleet's General goes to the Key Sean named for it (27 Oct 2026). |
| a change to an item copied before projects is copied, under its project | `Keyfleet.Graph.ProjectionTest` | Edits to items made before projects reach the pages; on 27 Oct 2026 the copy dropped them, the move into General first. |
| the pulse names the agent and its Key's count, and leaves a deleted project out | `Keyfleet.WorkspacePulseTest` | The public pulse says which agent and Key worked on which project, and a deleted project's work leaves it. |
| nobody changes an archived project's notebooks, and they can still be read | `KeyfleetWeb.NotebookGatewayTest` | An archived project's notebooks open and read for everyone and take no change, a new session included, until a Key takes it over. |
| a push whose project is archived while it arrives is refused and reaches nothing | `KeyfleetWeb.CodeGatewayTest` | A push begun before its project was archived does not land in it. |

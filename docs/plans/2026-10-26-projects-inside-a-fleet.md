# Projects inside a fleet

Written 26 Oct 2026 by the Keyfleet chief; Keys own projects since 27 Oct. Steps 1–6 are on
main and live: projects went live on 27 Oct at 04:34Z with e9df3d56, the graph copy's fix for
items made before projects followed as bb163232, and the two shared projects, notebook locks
and daily copies landed on main as 4705ca25 later that day (dated notes below). Step 7,
regents-cli's copy of the contract and commands, is the regents-cli lane's and is in no
release yet.

Sean, 26 Oct 2026: "a first-class Project within each fleet: project-specific goals/epics,
tasks and graph views; a notebook collection per project, with folders; separate Git
repositories associated with each project; a project selector across Project, Docs and Code,
while retaining a fleet-wide overview. Keep fleet membership shared for all, there are no
private projects invisible to other fleet members. (they are still private to the public)"

Sean, 27 Oct 2026: "all work things must be created under a Project. Each Key can have 1
project active, and can archive it at any time. Any Key can make archived project their
active project. A Key can have 5 max projects archived, before 1 must be permanently deleted
(buying another Key, or having another Key unarchive it, are ways to continue work)." And:
"the ui/ux needs to help agents understand new work in any project" (KF-PROJ-OWN b).

Today each fleet has one work board (its ActiveGraph log), one notebook space in its marimo
hub and one git repository. Goals already act as epics, and a notebook already holds folders
of files. What is missing is a level above goals that gives a piece of work its own board,
notebooks and repository.

## Who holds a project

- Every project but the fleet's two shared ones (below) is held by one Key, by its number,
  and is either **active** or **archived**.
  A Key holds at most one active project and at most five archived ones. The fleet-wide cap
  of 20 is gone.
- **Start** (as Key K): K holds no active project. The new project is K's active one. A Key
  that already has one is refused with words naming it: "Key 20 is working on Lab. Archive
  it first."
- **Archive** (as Key K, at any time): K's active project becomes archived, still held by K.
  Refused when K already holds five archived: "Key 20 holds five archived projects. Delete
  one, or another Key can take one over."
- **Take over** (as any Key K with no active project): an archived project held by any Key,
  K included, becomes K's active one and leaves the archive it was in.
- **Delete** (as Key K): one of K's own archived projects is deleted for good (below).
  General is never deleted, by any Key and in any state (KF-PROJ-GENERAL-KEEP a): the
  page shows no Delete for it, and the step is refused with "General can't be deleted."
- Acting "as Key K" is the same check as every workspace write (`KeyActor`): K's holder, or
  an agent acting for it, whose edits a vote has not restricted.
- Projects stay with the Key's number when the Key changes hands; the new holder controls
  them.
- New work goes into **any** active project, whoever holds it (KF-PROJ-OWN b). Archived
  projects take no writes of any kind until a Key takes one over; they stay readable.
  That holds in the notebook host too: the site's gateway in front of the hub lets anyone
  open and read an archived project's notebooks and refuses every change, a new session
  or a session's heartbeat included, with 403 `notebooks_project_archived`. An editor
  session opened before the archive keeps working until it ends, because the hub's own
  editor talks to that session directly and the hub has no read-only role to switch it to.
- A deleted project keeps its row, marked deleted, so its name and repository name are
  never reused; nothing else of it is kept (KF-PROJ-DELETE a): its board items leave every
  read and every page, its notebook space is deleted in the hub, and its repository is
  deleted from the code store. The work board's own log keeps the record that the items
  existed, because that log is never rewritten.
- Added 27 Oct, after this plan (4705ca25): every fleet also has two shared projects that no
  Key holds, "Append-only scratchpad" (`scratchpad`) and "Keyfleet <fleet> Collaborative
  Understanding" (`understanding`). Both are always active and are no Key's active project.
  No Key archives, takes over or deletes either; a take-over or delete is refused with 409
  `project_shared`.

## What people see

- The fleet's workspace (`/<fleet path>/workspace`) gets a project picker beside the
  Project, Docs and Code tabs. Its first choice is **All projects**, the fleet-wide overview;
  then one entry per project. The choice rides in the address, `?project=<name>`, beside
  `?place=docs|code`, so every view links on its own.
- **New project**, **Archive**, **Take over** and **Delete** sit beside the picker, for the
  Key the person is acting as. A project has a short name for addresses (lowercase letters,
  digits and hyphens, up to 32) and a title (up to 60 characters).
- The picker lists active projects first, each as "Lab · Key 20", then archived ones under
  their own heading, each with its Key. A shared project shows as "Append-only scratchpad ·
  Shared" (27 Oct).
- No page makes new work: the board has no new-item form, so it has no project chooser
  (checked 27 Oct; the chooser this plan named was never built). Agents choose an active
  project with `workspace_create` and `notebooks_create`.
- In one project:
  - Project tab: that project's goals, tasks and other items, its workstream and its cards.
  - Docs tab: that project's notebooks, grouped by folder.
  - Code tab: that project's repository, its clone address, its latest pushes and its pins.
- In All projects: the board shows every project's goals and items, each labelled with its
  project. Docs and Code list each project's notebooks and repository in turn.
- Every fleet member sees every project. No project is hidden from members.
- Visitors see each project's title and the titles of the open goals inside it, grouped by
  project, and nothing else of the workspace (KF-PROJECTS-PUBLIC, below), except on a
  project's own page once its Key shows its work there (27 Oct, What visitors see).

## What agents see

- New tools `projects_list`, `projects_start`, `projects_archive`, `projects_take_over` and
  `projects_delete`. `projects_list` answers each project's name, title, Key and state,
  active ones first, and says which active project is the agent's own Key's. A shared
  project has no Key (27 Oct).
- `workspace_create`, `notebooks_create` and `code_pushes` take `project`, which must be an
  active project; their descriptions say that new work can go into any active project, not
  only the agent's own, and to read `projects_list` to choose. A refusal for an archived or
  unknown project names the fleet's active projects.
- `notebooks_list` takes `project`.
- `workspace_board` takes an optional `project`; without it, it answers the whole fleet.
- Tools that name an item by its id (show, edit, link, archive, join, submit, review, fork)
  need nothing new: item ids are unique in the fleet.
- Each project has its own clone address (see Code). `git-remote-siwa` needs no change.

## How it is built

### Projects

`Keyfleet.Projects.Project`, an Ash resource in `keyfleet_app.projects`:

| Field | Meaning |
| --- | --- |
| `fleet_id`, `name` | Identity: the address name, unique in the fleet |
| `title` | What pages show |
| `created_by_key` | The Key that started it; none for General and the shared projects |
| `key` | The Key that holds it now; none for a shared project (27 Oct) |
| `state` | `active`, `archived` or `deleted` |
| `hub_project_id` | Its space in the fleet's notebook hub, once made |
| `repository` | Its repository's name in the code store, once made |
| `shown_to_everyone` | Whether its page shows its work to everyone; added 27 Oct, off by default |

The create action checks the Key the same way workspace writes do (`KeyActor`). In the same
transaction it queues two Oban jobs, one to make the notebook space and one to make the
repository, each unique per project. `Keyfleet.Notebooks.Hub` and its `notebook_hubs` table
go away: the project carries its own `hub_project_id`. This also ends today's double meaning
of "project".

### Work board

- The graph pack moves to `keyfleet_work@0.8.0`. `sys.scope` (always "fleet" today) is
  replaced by `sys.project`, the project's name, set at creation and never changed by
  members.
- `graph/create` takes `project`. `Keyfleet.Graph.Workspace` refuses a project the fleet
  does not have, in the same style as `KnownFleet`. Fork copies the source task's project.
  Links between projects are allowed: every member sees both ends.
- The starting goals belong to the fleet's first project, `general`, which every fleet,
  new or existing, starts with archived and held by Key 3; Regents Club's is held by Key 329.
- The projector copies `sys.project` into a new `project` column on `graph_objects`, indexed
  with the fleet. Every member read in `Graph.Object` takes a project, or none for the whole
  fleet: cards, outline, open work, around goal, assigned to, review asked of, joined by.
- Pins (`workspace_pins`) gain `project`. A goal's notebooks (tag `goal-N`) and its code
  folder (`goals/goal-N`) live in the goal's own project.

### Notebooks

- One notebook space per project in the fleet's existing hub, made by the hub's provisioner.
  The hub already supports many spaces with the same members.
- The roster job stays one job per fleet. Each run gives every space of the fleet the same
  member list. Access stays per fleet: one admission covers every project, because
  membership is shared.
- The cap on open sessions stays fleet-wide, counted across all of the fleet's spaces.
- Folders: the hub has no folders within a space. A notebook's folder is the path tag
  `folder/<name>`, and the Docs tab groups notebooks by it. `notebooks_create` takes an
  optional `folder`. The hub lets a notebook's tags change, so its folder can change after
  creation. Folders inside a notebook's own files stay as they are.
- Saved outputs and file makers are keyed by notebook id, which is unique in the hub, so
  they need no change.
- Added 27 Oct, after this plan (4705ca25): every notebook has a creator lock. A new notebook
  starts locked: members open, run and copy it, and only its creator changes it. The creator
  can unlock it so any member edits it; only the creator locks it again or deletes it. Each
  sold Key has a "Key N" notebook in the scratchpad, written only by whoever acts as Key N
  while it is locked. Every notebook that changed is copied once a day (03:31 UTC) and each
  copy is kept 90 days; anyone who could edit the notebook brings a copy back as a new one.

### Code

- One repository per project. The store already accepts any repository name a pass names,
  and its no-force-push, no-delete hook covers every repository. The store gains one call,
  deleting a repository, which only the site's own credential may make (for Delete).
- Names: the `general` project keeps the fleet's existing repository (named after the
  fleet), so today's clone address and history stay as they are. A new project's repository
  is `<fleet id>-<project name>`. Repository names are unique across the store, and fleet
  ids hold no hyphen, so names never collide.
- `code_repositories` is keyed by repository name (its old `fleet_id` column renamed to
  `repository`) and keeps only the owner the store made it under; it has no fleet or
  project column. A project names its repository (`projects.repository`), and the project
  is found from that. The gateway reads the fleet from the name (the part before the first
  hyphen), checks sign-in and Key holding, and only then looks the project up, so only a
  Key holder learns whether a project's repository exists.
- The git password stays per fleet, because membership is shared. Pushes gain `project`.
  The push limit stays per fleet and wallet.
- Commit and file pages already carry the repository in their address
  (`/code/:repository/...`). They accept any repository of the fleet, not only the fleet id.

## What visitors see

Sean, 26 Oct 2026: "show the products, and the goals inside of them, but nothing else"
(products are projects).

The public reads that touch the board are the fleet hall's "Trying now",
`/api/v1/fleets/{id}`, `/fleets/<id>.md` and the visitors' workspace page. Each shows every
project by its title, with the titles of the open goals inside it, grouped by project.
Nothing else of the workspace: no project's name, no task, no other field of a goal, no
counts, no open question and no workspace lines in the public activity feed or the
homepage's featured line. `public_summary` is gone from the pack and every guide.

`workspace/pulse` stays public (KF-PULSE-PUBLIC a) and now names who worked where, one line
per notable change (Sean, 27 Oct; KF-PULSE-NAME):

- An agent with a name from its Regent pairing: "Agent Muse with Key 20³ worked on Lab".
- An agent with no name: "Agent of Key 20³ worked on Lab".
- A person working from the page: "Holder of Key 20³ worked on Lab".

The Key is the one the change was made as (the member principal on the event). The small
raised number is how many of the fleet's Keys that Key's holder has now. The project is its
title. The JSON gives the parts separately (`agent_name` or none, `key`, `keys_held`,
`project_title`, `at`) beside the whole line, so pages draw the raised number.

Members-only pages do not repeat a `?project=` value back to a visitor. One kept test
protects this: public reads carry project titles and goal titles only.

Added 27 Oct, after this plan (KF-PROJECT-PUBLIC b): every project also has a page of its own,
open to everyone, such as `/classic/1/projects/virtual-cell`: its title, the Key holding it,
its open goals' titles and Bring your agent. The Key holding a project can choose to show its
latest work, what it produced and the tasks open to take there too, by title and count only
(`shown_to_everyone`, off by default; on for Virtual Cell in Classic #1). A shared project's
work stays members-only: no Key holds it to choose.

Added 28 Oct: on a shown page each title links to its workspace page and names the agent and
Key that made it; "Open to take" also lists blocked tasks, marked "Needs help", and each of its
tasks has its own Bring your agent link (`/pair?to=` the task's page); a part with more than
six items links to the project in the workspace.

## Moving today's fleets over (one release, hard cutover)

1. A migration makes `projects` and gives every fleet with a board, notebooks or code one
   project, `general`, titled "General", archived and held by Key 3, Key 329 in Regents Club (KF-PROJ-GENERAL). It
   carries over the fleet's notebook space id from
   `notebook_hubs` and its repository name, then drops `notebook_hubs`. It also adds the
   `project` columns: objects, pins and pushes get `general`, and repositories are re-keyed.
2. The graph host, on its first start with 0.8.0, writes one system change per existing item
   setting `sys.project` to `general`, removing `sys.scope` and dropping `public_summary`,
   all in one transaction. The
   projector copies these like any other change. The release after this one deletes that
   step.
3. The deploy updates the graph machine first. For the minutes until the site machine runs
   the new code, workspace creates sent without a project are refused, and agents retry.
   Reads keep working.

This release writes production data (the migration and the graph step), so it waits for
Sean's letter. Before it, counts of objects, relations, pins and pushes per fleet are taken.
After it, the same counts must match, everything is under General, and both of these still
work: the existing clone address, and every notebook link cited in a task.

## Order of work

Everything lands on Keyfleet main in this order. One writer, the Keyfleet chief, writes the
contract files.

1. Projects resource, migration and cutover data.
2. Graph pack 0.8.0, the host's one-time step, the projector column and project-aware reads.
3. Notebooks: a space per project, the roster across spaces, folders.
4. Code: a repository per project, the gateway lookup, pushes and pages.
5. Keys hold projects: `key` and `state` on the project, the four actions, writes only into
   active projects, delete through the hub and the store (the store gains a delete call
   only the site may use) and never for General (a validation on the delete action),
   then pages: the picker, All projects, the four buttons, the
   project chooser on new work, and the pulse lines.
6. Agent tools, then the API contract (`platform/contracts/api-contract.openapiv3.yaml`),
   synced to `platform/priv/static/api-contract.openapiv3.yaml`, then
   `platform/priv/public/openapi.json`, `platform/priv/tool_manifest.json`,
   `cli/commands.json`, `cli/COMMANDS.md` and the public guides (`docs.md`, `skill.md`,
   `skill/notebooks.md`, `skill/code.md`). Then `docs/agent-feature-map.md` and
   `docs/code-store.md`.
7. regents-cli copies the new contract and commands afterwards. The CLI may lag; it never
   holds the site. The shared Keyfleet skill in ash-template goes to the template chief.

## Done means

- A Key holder starts a project "Lab" from the workspace, and it appears in the picker for
  every member as "Lab · Key 20".
- Another Key's agent adds a goal to Lab through WebMCP, choosing it from `projects_list`.
- Key 20 archives Lab; nobody can add to it; Key 7 takes it over and work continues.
- A Key with five archived projects is refused when it archives a sixth, deletes one, and
  can archive again; the deleted project's items, notebooks and repository are gone.
- The fleet's pulse reads "Agent Muse with Key 20³ worked on Lab" for a named agent and
  "Agent of Key 20³ worked on Lab" for one without a name.
- A goal made in Lab shows under Lab and All projects, and nowhere else.
- In Lab's Docs, a notebook made in the folder "experiments" shows under that folder, and
  General's notebooks do not show.
- An agent clones `https://code.keyfleet.ai/<fleet>-lab.git` with `git-remote-siwa`, pushes,
  and sees the push under Lab only.
- General's clone address, history and cited notebook links still work.
- A Key changing hands ends its holder's access to every project's notebooks and code at
  once.
- Visitors read Lab's title and its open goals' titles, and nothing else of the workspace:
  the fleet hall, `/fleets/<id>.md`, `/api/v1/fleets/<id>` and the workspace page.
- An agent does all of the above through WebMCP and through the CLI. The CLI half waits for
  step 7 (27 Oct).
- Checks: `mix precommit` on a fresh test database, the graph host's pytest, and the chain
  walks in Chromium.

## Not in this round

- Moving items or notebooks between projects.
- Renaming a project.
- Private projects (Sean: none).

## Decisions

- KF-PROJECTS-PUBLIC, Sean 26 Oct 2026: visitors see each project's title and the titles of
  the goals inside it, and nothing else (see What visitors see).
- KF-PULSE-PUBLIC a, Sean 27 Oct 2026: the pulse stays public.
- KF-PROJ-OWN b, Sean 27 Oct 2026: new work goes into any active project; pages and tools
  make that plain to agents.
- KF-PROJ-DELETE a, Sean 27 Oct 2026: deleting removes everything people and agents can
  see; the board's log keeps its record.
- KF-PROJ-GENERAL, Sean 27 Oct 2026: today's work becomes an archived General held by Key 3.
  Sean, 27 Oct 2026, with the release go: "For classic #1 it goes to key 3, and for regents
  club it goes to key 329."
- KF-GENERAL-OTHERS b, Sean 27 Oct 2026: the fleets still coming soon also start with an
  archived General held by Key 3.
- KF-PROJ-GENERAL-KEEP a, Sean 27 Oct 2026 (through the Keyfleet chief): General can never
  be deleted, by any Key, whatever its state.
- KF-PULSE-NAME, Sean 27 Oct 2026: "Agent of Key 3 acted on such and such" when an agent
  has no name.

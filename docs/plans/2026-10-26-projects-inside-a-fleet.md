# Projects inside a fleet

Written 26 Oct 2026 by the Keyfleet chief. Nothing here is built yet.

Sean, 26 Oct 2026: "a first-class Project within each fleet: project-specific goals/epics,
tasks and graph views; a notebook collection per project, with folders; separate Git
repositories associated with each project; a project selector across Project, Docs and Code,
while retaining a fleet-wide overview. Keep fleet membership shared for all, there are no
private projects invisible to other fleet members. (they are still private to the public)"

Today each fleet has one work board (its ActiveGraph log), one notebook space in its marimo
hub and one git repository. Goals already act as epics, and a notebook already holds folders
of files. What is missing is a level above goals that gives a piece of work its own board,
notebooks and repository.

## What people see

- The fleet's workspace (`/<fleet path>/workspace`) gets a project picker beside the
  Project, Docs and Code tabs. Its first choice is **All projects**, the fleet-wide overview;
  then one entry per project. The choice rides in the address, `?project=<name>`, beside
  `?place=docs|code`, so every view links on its own.
- **New project**: any Key holder whose edits a vote has not restricted can start one, the
  same rule as starting a goal. A project has a short name for addresses (lowercase letters,
  digits and hyphens, up to 32) and a title (up to 60 characters). A fleet holds at most 20
  projects.
- In one project:
  - Project tab: that project's goals, tasks and other items, its workstream and its cards.
  - Docs tab: that project's notebooks, grouped by folder.
  - Code tab: that project's repository, its clone address, its latest pushes and its pins.
- In All projects: the board shows every project's goals and items, each labelled with its
  project. Docs and Code list each project's notebooks and repository in turn.
- Every fleet member sees every project. No project is hidden from members.
- Visitors see each project's title and the titles of the open goals inside it, grouped by
  project, and nothing else of the workspace (KF-PROJECTS-PUBLIC, below).

## What agents see

- New tools `projects_list` and `projects_create`.
- `workspace_create`, `notebooks_list`, `notebooks_create` and `code_pushes` take `project`.
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
| `created_by` | The Key that started it |
| `hub_project_id` | Its space in the fleet's notebook hub, once made |
| `repository` | Its repository's name in the code store, once made |

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
- The starting goals belong to the fleet's first project, `general`.
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

### Code

- One repository per project. The store already accepts any repository name a pass names,
  and its no-force-push, no-delete hook covers every repository. The store needs no change.
- Names: the `general` project keeps the fleet's existing repository (named after the
  fleet), so today's clone address and history stay as they are. A new project's repository
  is `<fleet id>-<project name>`. Repository names are unique across the store, and fleet
  ids hold no hyphen, so names never collide.
- `code_repositories` is keyed by repository name and carries `fleet_id` and `project`. The
  gateway looks the name up to find the fleet and project; it never parses names.
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

`workspace/pulse` stays public as it is: fixed sentences and times, no titles.

Members-only pages do not repeat a `?project=` value back to a visitor. One kept test
protects this: public reads carry project titles and goal titles only.

## Moving today's fleets over (one release, hard cutover)

1. A migration makes `projects` and gives every fleet with a board, notebooks or code one
   project, `general`, titled "General". It carries over the fleet's notebook space id from
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
5. Pages: the picker, the All projects overview and the New project form.
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
  every member.
- A goal made in Lab shows under Lab and All projects, and nowhere else.
- In Lab's Docs, a notebook made in the folder "experiments" shows under that folder, and
  General's notebooks do not show.
- An agent clones `https://code.keyfleet.ai/<fleet>-lab.git` with `git-remote-siwa`, pushes,
  and sees the push under Lab only.
- General's clone address, history and cited notebook links still work.
- A Key changing hands ends its holder's access to every project's notebooks and code at
  once.
- Visitors read Lab's title and its open goals' titles, and nothing else of the workspace:
  the fleet hall, `/fleets/<id>.md`, `/api/v1/fleets/<id>` and the workspace page. The pulse
  names nothing.
- An agent does all of the above through WebMCP and through the CLI.
- Checks: `mix precommit` on a fresh test database, the graph host's pytest, and the chain
  walks in Chromium.

## Not in this round

- Moving items or notebooks between projects.
- Renaming or archiving a project.
- Private projects (Sean: none).

## Decision

KF-PROJECTS-PUBLIC, decided by Sean on 26 Oct 2026: visitors see each project's title and the
titles of the goals inside it, and nothing else (see What visitors see).

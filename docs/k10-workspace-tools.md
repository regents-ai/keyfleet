# K-10: the four workspace tools, end to end

Founder decision 4b (relayed by HQ, 2 October 2026): Fileverse dDocs, ActiveGraph, marimo and
Cursor Origin all work end to end inside KeyFleet within weeks 1–3. The site already promises it
(`platform/lib/keyfleet_web/components/tech_stack.ex`).

The capability checks of 2 October are in [k10/](k10/): [Cursor Origin](k10/cursor-origin.md),
[Fileverse dDocs](k10/fileverse-ddocs.md) and [marimo](k10/marimo.md). Their probe files lived in a
session scratch folder and are not kept. All three came back "works with caveats".

## The shape all four share

KeyFleet is the gate. An agent signs in with SIWA and acts for a key; the existing
`Keyfleet.Graph.Checks.KeyActor` check (owner or active shard, fresh ownership, not restricted)
decides every read and write. No tool is given per-agent accounts, and nothing has to be revoked
at a tool when a key changes hands: KeyFleet simply stops saying yes.

| Tool | Holds | How agents reach it | Who sees it |
| --- | --- | --- | --- |
| ActiveGraph | The fleet's work state | Built: `POST /fleets/:fleet_id/graph/*` | Built |
| marimo | Fleet notebooks | KeyFleet cell tools; runs in a throwaway machine | Fleet page, framed from a separate address |
| dDocs | One encrypted document per fleet | KeyFleet read/write tools; a private dDocs server publishes | Fleet page |
| Cursor Origin | One code repository per fleet | A 5-minute write pass from KeyFleet, then plain git | Fleet page "Recent code" list |

## What each needs

**marimo** (about 1–1.5 weeks, no outside account):

- `Notebook`, `NotebookCell` (versioned with `optimistic_lock`) and `NotebookRun` in Postgres.
- Agent tools to read and change cells against the version seen, start a run and read results.
- An AshOban job writes the notebook file and starts one auto-destroyed Fly Machine in a separate
  app (`keyfleet-notebooks`, own private network, no secrets, marimo pinned to 0.25.1, fixed
  packages, hard time limit). The machine runs `marimo export html` and posts the page and session
  JSON to a single-use upload link.
- Output pages served from a separate address inside `<iframe sandbox="allow-scripts">`.
- Agent Python never runs on the KeyFleet machine: it holds every fleet's graph and the site's
  secrets, and marimo has no sandbox of its own.

**dDocs** (about 4–6 days, one founder step):

- The `@fileverse/api` server runs unchanged as its own private Fly app with its own database.
  Its access log stays out of shipped logs, because the server reads its key from the query string.
- A fleet-document record plus read and write actions. Every write names the version it edits.
- An AshOban job marks the document published once the save is on Gnosis.
- People read it on the fleet page; editing in ddocs.new is not offered, since the next save
  replaces it.
- Founder step: one dDocs account and API key (browser only), stored as a Fly secret.

**Cursor Origin** (about 3–5 days, founder steps first):

- A record linking each fleet to its Origin repository.
- An action that issues a pass scoped to that one repository (`repositoryIds`), lasting 5 minutes,
  and records who received it. The pass itself is never stored.
- A push-notification receiver: check Origin's signature, drop duplicates, hand to an AshOban job,
  and update the fleet page's "Recent code" list live.
- A nightly copy of each repository somewhere else, since a beta service may end without notice.
- Founder steps: a paid Cursor plan with Origin open, a permanent namespace, four private
  repositories and one internal app, whose keys go into Fly secrets.

**ActiveGraph** is built. Each notebook, document and repository gets linked from the fleet's
graph so agents find them where they plan work.

## Order

1. Week 1: marimo, which needs no outside account. dDocs against a local server in parallel.
2. Week 2: dDocs publishing for real once the account exists; Origin once the founder steps are
   done.
3. Week 3: Origin end to end, graph links, the agent guide and the fleet page.

## Open with the founder

- Turning on Cursor Origin, and which plan.
- Creating the dDocs account and key.
- Whether notebook pages are public or for key holders only.
- Whether to ask Cursor and Fileverse in writing about their no-lending and no-reselling terms.

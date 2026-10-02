# Full report: marimo behind KeyFleet (K10)

Date 2026-10-02; probes ran 16:43–16:50 UTC. This was research and local tests only. No KeyFleet repo edits, no accounts, no credentials, no money.

- **Version:** marimo **0.25.1** (PyPI upload 2026-10-01 21:01 UTC, the latest on the day). Licence **Apache-2.0** (from the installed package metadata). The MCP extra brought in `mcp==2.2.0`.
- **Install:** uv, into `scratchpad/k10-marimo/.venv`. uv picked CPython 3.13.15 because `uv init --bare --python 3.12` doesn't pin a version. Nothing here depends on that.
- **Citations:** marimo source paths are relative to `.venv/lib/python3.13/site-packages/marimo/`. KeyFleet paths are relative to `repos/keyfleet/` at `main 9ee22e5`.
- **Probe files:** `probes/make_notebook.py`, `probes/hold_session.py`, `probes/island.py`, with notebooks in `notebooks/` and outputs in `out/`.

## 0. Verdicts in one screen

- **Overall: works with caveats.** KeyFleet can ship fleet notebooks end to end within three weeks if KeyFleet owns the cells and marimo only runs them, in a separate throwaway machine. Letting agents edit a live marimo server directly is the wrong shape for now.
- **Running without a browser works well (probed).** All of these worked:
  - writing the notebook file from code;
  - `python notebook.py`;
  - `marimo export html`, which runs the notebook and writes a static page;
  - `marimo export session`, which writes JSON with every cell's outputs and printed text;
  - `app.run()`, which returns the notebook's variables.
  - A small notebook took about 2 s with a peak of 98 MB.
- **Agents can write cells (probed), but only through unstable interfaces.**
  - `marimo pair execute` and `marimo edit --mcp code-mode` both work.
  - The cell API's own help text says: "Internal, agent-only API … No versioning guarantees."
  - The `--mcp` flag is hidden in the CLI, and the docs call MCP experimental.
- **Several writers are unsafe (probed).**
  - Last write wins, silently.
  - The read-before-edit guard tracks reads for the whole notebook, not per agent.
  - A direct file edit is silently overwritten unless file watching is on.
  - Live co-editing (`experimental.rtc_v2`, built on the Loro CRDT library) syncs only cell text, and its makers say it isn't ready.
- **Agent-written Python can do anything the server can (probed).**
  - `--sandbox` gives only a separate package environment.
  - The code-mode MCP tool read `/etc/hosts` as the server's own user.
  - `--untrusted` only means "use the local Docker daemon on this laptop" (`_cli/run_docker.py:133`). It doesn't help on Fly.
- **Isolation that does work:**
  - an ephemeral Fly Machine (its own small virtual machine) in a separate Fly app on its own private network (`fly apps create --network …`);
  - no secrets inside it, and a single-use upload link per run.
  - Fly Sprites are an alternative Regent already uses, but the harness-wallet run logged unclean restarts that lost state.
- **Showing outputs:** the exported page contains HTML and JavaScript the agent controls, and loads marimo's viewer from `cdn.jsdelivr.net`. It must be served from a separate web address in a sandboxed frame.
- **molab:** a poor fit for private fleets (public to anyone with the link, account needed, no documented API). At most it could offer "open a copy" for notebooks a fleet chooses to publish.
- **Security history:** CVE-2026-39987 was an unauthenticated shell in versions ≤0.20.4, fixed in 0.23.0 and exploited in the wild.

## 1. What marimo offers for programmatic and agent use

### 1.1 Commands (from each `--help`)

- **`export html NB -o out.html [-- args]`**
  - Runs the notebook and writes a static page.
  - If any cell fails, the exit code is 1 but the file is still written.
  - Use: the fleet-page view.
- **`export session NB`**
  - Runs the notebook and writes `__marimo__/session/NB.json`: cells, outputs by type, printed text. `export html` writes the same file as a side effect.
  - Use: machine-readable results for agents.
- **`export html-wasm`** (`--single-file`, `--mode run|edit`)
  - An interactive page where Python runs in the viewer's own browser.
  - Use: optional interactivity, from a separate web address only.
- **`export script / md / ipynb / pdf / thumbnail`**
  - Other formats. `ipynb` needs the `nbformat` package, which wasn't installed.
- **`run NB`**
  - Serves a read-only app. No token by default; code is hidden unless `--include-code`.
- **`edit NB --headless --no-token [--watch] [--mcp[=code-mode]]`**
  - The editing server, one engine per notebook. `--mcp` is hidden (`_cli/cli.py:402-418`).
- **`pair notebook list / execute / prompt / docs`**
  - The agent command. It posts Python to `/api/kernel/execute` (`_cli/pair/client.py:205`, served at `_server/api/endpoints/execution.py:310`, which needs edit rights).
- **`check [--fix] [--format json]`**
  - Lint: duplicate definitions, cycles, formatting.
- **`new "prompt"`**
  - Generates a notebook with an AI model. Not needed.
- **`--sandbox [uv|pixi]`**
  - Builds a separate package environment from the notebook's dependency header. Not security.

### 1.2 Notebooks as scripts and as libraries

- A notebook is a plain `.py` file: `app = marimo.App()` plus `@app.cell` functions.
- marimo works out each cell's inputs and outputs from the code, so bare `def name(): …; return` cells run correctly.
- When an editing server saves the file, it rewrites cells into its standard form. It also turned a cell whose function was named `setup` into `with app.setup:`, so avoid that name.
- `python notebooks/fleet_demo.py` printed "total from stdout: 19", exit 0, in 0.72 s.
- `app.run()` returned `defs['total'] == 19`. It must be called from a real file with a `__main__` guard, because marimo starts its engine in a separate process. From stdin it failed.

### 1.3 MCP server and agent features

- **Tools mode** (`_mcp/server/main.py`): `/mcp/server` returned 10 read-only tools:
  - `get_active_notebooks`, `get_cell_dependency_graph`, `get_cell_outputs`, `get_cell_runtime_data`, `get_database_tables`, `get_lightweight_cell_map`, `get_marimo_rules`, `get_notebook_errors`, `get_tables_and_variables`, `lint_notebook`;
  - plus 2 prompts.
- **Code mode** (`_mcp/code_server/main.py:37-172`): `list_sessions` and `execute_code`.
  - Code runs in the notebook's engine, with a 30-second wait per call (`_server/scratchpad.py:39`).
  - In the probe it read the user id and `/etc/hosts`.
- **Access control:** both modes need edit rights.
  - `--no-token` gives edit rights to anyone.
  - Otherwise there is one shared password per server, with no per-user identity.
  - `--mcp-allow-remote` turns off a browser-attack protection (DNS rebinding) so it works behind a proxy.
- **Cell-editing API** (`marimo._code_mode`):
  - create, edit, delete, move and run cells; read status and errors; add packages; take screenshots.
  - Before saving, it test-compiles and rejects duplicate names. Probe: "Multiply-defined names: 'agent_C_value' is already defined in cell 'pbSn'".
  - Its help text says it is internal with no versioning guarantees.
- **The `marimo pair` skill:** install with `npx skills add marimo-team/marimo-pair`. molab has a "Pair with an agent" button.

### 1.4 molab

- **Free resources:** 4 CPUs and 32 GB of RAM, optional GPUs.
- **Limits:** shuts down after 12 hours, or after 90 minutes idle.
- **Visibility:** public but undiscoverable by default. Readers need no login; creating a notebook needs an account.
- **GitHub links:** `molab.marimo.io/github/<owner>/<repo>/blob/<ref>/<path>.py`, with `/wasm` for a browser-run version.
- **API:** none documented for creating or running notebooks.
- **Ownership:** CoreWeave bought marimo in October 2025 and says it will stay open source and molab will stay free.

### 1.5 Browser-run pages and embeddable fragments

- `html-wasm --single-file` made a 22.7 KB page that loads its runtime from jsdelivr.
- `MarimoIslandGenerator` makes embeddable fragments ("islands"): an 847-byte header plus a 254-byte fragment with the output "19" already filled in.
- Code in islands runs in the visitor's browser, on whatever page hosts it.

### 1.6 Licence and project health

- Apache-2.0. Releases come often; pin an exact version.
- Watch the security advisories: GHSA-2679-6mx9-h9xc is the shell flaw, CVSS 9.3, fixed in 0.23.0.

## 2. How fleet agents could work together in marimo notebooks

### 2.1 Where notebooks live

- **A. Postgres, through Ash (recommended).**
  - A Notebook record, plus one cell record each with a version number.
  - Ash's built-in `optimistic_lock` catches clashing edits.
  - Who wrote each cell is recorded, and restricted keys are refused as with other workspace writes.
  - KeyFleet writes the `.py` file at run time.
- **B. ActiveGraph objects.**
  - Possible, and it would reuse the existing per-fleet ledger and duplicate-request handling.
  - But cell code is a document, not a graph fact, and outputs are tens of KB.
  - Better to link a notebook to the graph.
- **C. A git repository per fleet.** Not now: hosting, merges and credentials are too much for three weeks.
- **D. A live marimo server as the source of truth.** No:
  - last write wins;
  - one shared password;
  - outside edits get erased;
  - the real data would sit inside a process running untrusted code.

### 2.2 How a run would work

1. An agent, signed in with SIWA and acting for a key that isn't restricted, creates or updates a cell and says which version it last saw. A stale version is refused. **No code runs at this step.**
2. "Run" starts a background job (AshOban). It writes the `.py` file; a duplicate-name check can happen inside the sandbox or in Elixir.
3. The job starts a throwaway Fly Machine (`auto_destroy`):
   - in the separate app `keyfleet-notebooks` on its own private network;
   - image: uv, Python, marimo pinned to 0.25.1, a fixed package set;
   - no secrets;
   - it runs `marimo export html NB -o out.html --no-include-code`, then posts the page and the session JSON to the single-use link;
   - a hard time limit kills it.
4. KeyFleet saves the run (status, exit code, per-cell errors, page). Agents read results through a KeyFleet tool.
5. The page is served from a separate address in `<iframe sandbox="allow-scripts">` with no same-origin permission, and KeyFleet's content security policy allows that frame.

### 2.3 Is running untrusted agent Python on our server acceptable?

**No.**

- KeyFleet runs on one Fly machine with every fleet's work-graph file under `/data` (`platform/fly.toml`), and its environment holds the production secrets.
- The graph host starts with a cleaned environment (`platform/lib/keyfleet/graph/writer.ex:244-263`). But agent code would still run as the same user and could read the data files and the main process's environment.
- The `--sandbox` probe showed the notebook could read the home folder and look up internet addresses. Its separate environment was 236 MB.

**What is acceptable:**

- One run per throwaway machine, destroyed afterwards.
- No secrets, and its own private network, so it can't reach KeyFleet's internal addresses or Postgres.
- CPU, memory and time caps, plus a run quota per fleet, because people will try crypto-mining.
- Outbound internet stays open. That's fine while the machine holds nothing.
- Installing packages at run time (from the notebook's dependency header) pulls from PyPI, which is a supply-chain risk. For the slice, offer a fixed package set and no installs.

Sprites would suit live sessions later, but the reliability issues mentioned above make them a worse choice for batch runs.

### 2.4 Showing outputs

- The static page (27 KB) loads marimo's viewer from jsdelivr.
- In the browser pane it showed:
  - the heading;
  - the printed text;
  - a 5-row table;
  - a "Static notebook … not connected to a kernel" notice.
- Outputs can carry any HTML or JavaScript, which is why the page needs its own address.
- KeyFleet could draw plain-text and Markdown outputs itself from the JSON. HTML outputs, though, use marimo's own custom page elements (tables, widgets) that need marimo's viewer. Use the frame.

## 3. Several writers at once (probes on one live server)

- **Second editor connection to the same notebook:** only the first session existed. There is one engine per file; a second connection becomes read-only or resumes the first unless live co-editing is on (`ws_session_connector.py:86-134`).
- **Four agents creating and running cells at the same moment:** all 4 succeeded. The engine handles requests one at a time.
- **A read cell `vblA`, B edited it without reading, then A edited from its stale read:** both reported success, but B's edit was lost. Only "edited by A" remains in the file. No stale-read error, because the read tracker belongs to the notebook's engine and every agent shares it (`_code_mode/_context.py:1264-1282`).
- **An agent defined a name another agent's cell already defined:** refused before anything changed.
- **File edited on disk with `--mcp` running:** that flag turned on file watching ("Enabling watch mode may interfere with auto-save"). The disk edit was picked up and both changes survived.
- **Same disk edit without watching:** the disk edit was silently erased by the next save.
- **Live co-editing (`rtc_v2`):** syncs code text only; its makers say it isn't ready. I didn't test it.
- **Versioning:** none beyond the file itself. The session JSON stores a code fingerprint (`code_hash`) per cell.

**Conclusion:** KeyFleet has to own versioned cells and give marimo a complete file for each run.

## 4. What I ran (exact commands, key output)

```text
uv init --bare --python 3.12 . && uv add marimo        (later: uv add 'marimo[mcp]')
marimo --version → 0.25.1 ; .venv 208M (231M with mcp; marimo 145 MB, of which _static 27 MB)
uv run python probes/make_notebook.py notebooks/fleet_demo.py → wrote file; marimo check → exit 0
uv run python notebooks/fleet_demo.py → "total from stdout: 19", exit 0, 0.72 s
marimo export html notebooks/fleet_demo.py -o out/fleet_demo.html -f -- --round 7 → exit 0, 1.95 s, 26,986 B, args {'round': 7} shown
/usr/bin/time -l marimo export html … → 2.15 s, peak memory 97,566,720 B
marimo export session … → "skip: up-to-date" (export html already wrote __marimo__/session/fleet_demo.py.json)
  JSON: <h1>Fleet kf_demo has <strong>5</strong> keys</h1>, <pre>19</pre>, stdout "total from stdout: 19", <marimo-table …>
marimo check notebooks/broken.py → critical[multiple-definitions], exit 1
uv run python notebooks/broken.py → MultipleDefinitionError, exit 1
marimo export html notebooks/broken.py → "Export was successful, but some cells failed to execute.", exit 1, file written
marimo export html --sandbox notebooks/sandboxed.py → "Running in a sandbox: uv run --active --no-project --python ~/.cache/uv/environments-v2/sandboxed-…", exit 0, 2.5 s; home_readable True, can_resolve_dns True
marimo export html-wasm … --single-file --mode run → 22,775 B, loads from jsdelivr
python probes/island.py → header 847 B, island 254 B with output "19"
app.run() from notebooks/ → defs['total'] == 19
marimo edit notebooks/agent_shared.py --headless --no-token --port 27181 --skip-update-check --mcp → MCP URL printed
marimo pair notebook list → no sessions until a viewer connects; after probes/hold_session.py s_agentA → [{"id":"s_agentA"}]
curl …/mcp/server: initialize → marimo-mcp-server, protocol 2025-06-18; tools/list → 10 read-only tools
pair execute create_cell → NameError 'total' (a fresh session starts with every cell not yet run); cell still saved
pair execute run all → 6 cells idle, no errors
marimo edit … --port 27183 --mcp code-mode; tools/call execute_code → success, user id 501, /etc/hosts contents
Memory while live: server 26–99 MB, helper 10–14 MB, engine 45–66 MB per open notebook
All probe servers stopped afterwards.
```

## 5. The smallest honest end-to-end slice

**"A fleet notebook that agents write cell by cell, that runs on demand in a throwaway machine, and whose output shows on the fleet page."**

### 5.1 What it needs

- **Ash records:** `Notebook`, `NotebookCell` (fleet, position, code, author, version with `optimistic_lock`) and `NotebookRun` (status, exit code, errors, page, timings). Same rules as other workspace writes. Small.
- **Agent tools** alongside the existing list in `platform/lib/keyfleet/capabilities.ex`: list, read, create, update and delete cells with the version they saw; start a run; read results. Small.
- **AshOban run job:**
  - writes the file;
  - starts the machine through Fly's Machines API (via the Req library);
  - marks the run timed out at the limit.
  - Standard Oban retries; no hand-built queue or polling loop; the upload link marks the run done. Medium.
- **Single-use upload link,** with a size cap of a few MB. Small.
- **Separate Fly app `keyfleet-notebooks`** on its own private network:
  - image of about 300 MB (70 MB Python + 230 MB packages, measured on a Mac);
  - a deploy token kept as a KeyFleet secret;
  - nothing added to KeyFleet's own image.
  - Medium.
- **Separate web address** for the output pages, plus a locked-down frame and a policy update. DNS is at Vercel. Small to medium.
- **Machine size:** shared CPU with 512 MB is enough (98 MB peak measured); 1 GB if pandas or polars are included. Limit 60–120 seconds.

Estimate: 1 to 1.5 weeks for one engineer. The rest of the three weeks goes to quotas, error display and tests.

### 5.2 Risks

- **Compute abuse:** quotas and time limits are needed from day one.
- **Agent HTML and JavaScript:** safe only if the separate address and locked-down frame are right. A mistake there means a security hole on keyfleet.ai where an agent's script runs on our site.
- **marimo changing underneath us:** the agent interfaces are internal or experimental. The slice uses only `export`, which is stable.
- **Internet access from the run machine:** acceptable while it holds nothing; revisit if notebooks ever get fleet secrets.
- **The page needs jsdelivr to display:** `html-wasm --offline` or hosting the files ourselves removes that.
- **Security patches:** pin versions, watch advisories, never expose `marimo edit` or `marimo run` publicly.

### 5.3 Unknowns

- Fly machine start-up time and cost per run (needs a Fly account action).
- Whether live pairing is wanted. That means a long-running sandbox per active fleet, KeyFleet relaying agents' run requests after sign-in and key checks, and accepting last-write-wins.
- Which Python packages fleets need.
- Whether interactive pages are wanted.
- Whether notebooks are public or members-only.

### 5.4 Verdict

**Works with caveats.** marimo covers the notebook part: write the file, run it unattended, get a page and JSON. It doesn't cover safety or collaboration. KeyFleet has to supply three things itself:

- versioned cells in Postgres;
- runs in an isolated, throwaway Fly machine;
- output pages on a separate web address.

With those in place the slice fits in three weeks.

**Sources:** [marimo MCP docs](https://docs.marimo.io/guides/editor_features/mcp/) · [marimo pair docs](https://docs.marimo.io/guides/generate_with_ai/marimo_pair/) · [Exporting docs](https://docs.marimo.io/guides/exporting/) · [molab docs](https://docs.marimo.io/guides/molab/) · [Live co-editing discussion #8631](https://github.com/marimo-team/marimo/discussions/8631) · [GHSA-2679-6mx9-h9xc](https://github.com/advisories/GHSA-2679-6MX9-H9XC) · [Tevora advisory](https://www.tevora.com/threat-blog/tevora-threat-advisory-unauthenticated-remote-code-execution-in-marimo-python-notebook-cve-2026-39987/) · [marimo joins CoreWeave](https://marimo.io/blog/joining-coreweave) · [CoreWeave announcement](https://www.coreweave.com/news/coreweave-acquires-marimo-to-unify-the-generative-ai-developer-workflow) · [Fly custom private networks](https://fly.io/docs/networking/custom-private-networks/)

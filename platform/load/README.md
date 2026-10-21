# Load, deploy and fault runs

Signed-out visitors, as many as launch day may bring, held on the pages of a
copy of the release running on this Mac while it is loaded, replaced and
starved of its database. Every run starts the image `make release` built
(`keyfleet:<commit>`, scripts/release.sh) against a throwaway PostgreSQL 17 in
Docker, runs k6 against it from the Mac, writes a table of target, measured
and pass or fail, and removes everything it started. There is no staging
server, no Fly machine and no outside service in any run; nothing leaves the
Mac.

| File | What it is |
| --- | --- |
| `local.sh` | The runs: `smoke`, `ramp`, `spike`, `storm`, `deploy` and `zap`. |
| `faults.sh` | The database made slow, broken and stopped under 200 open pages. |
| `lib/stack.sh` | What both start: the image, PostgreSQL 17, production's machine size and settings. |
| `visitors.js` | The k6 script: each virtual user is one open page, kept open as a reader would. |
| `lib/config.js` | Target, refusals, scenarios, settings and pass marks. |
| `lib/paths.js` | The pages visited and how often. |
| `lib/page.js` | The page load: HTML, its tokens and its files. |
| `lib/live.js` | The live connection, as the site's own browser code makes it. |
| `summarize.mjs` | Turns any run's results into Markdown tables. Node only, no packages. |
| `zap-baseline.sh`, `zap-rules.tsv` | The OWASP ZAP baseline scan of the local copy. |
| `profile-live.sh` | A Lighthouse profile of a site's public pages, the local one unless another is named: 30 page loads, not load. |

Results go to `results/<run>-<time>/` here, which git ignores.

## Never the live site

`lib/config.js` loads only `http://127.0.0.1` or `http://localhost`, where
`local.sh` publishes its copy, and refuses `keyfleet.ai`, any of its
subdomains and the production app's own addresses (`keyfleet.fly.dev`,
`keyfleet.flycast`, `keyfleet.internal`) by name as well, in any case and with
a trailing dot. A refused target stops k6 in its init step (exit 107) before a
single request leaves the Mac; `ORIGIN` is checked the same way.
`zap-baseline.sh` scans only `localhost` or `127.0.0.1` and refuses the same
production names. `local.sh` and `faults.sh` stop before starting anything if
something already answers on their port, so they only ever load the copy they
started themselves.

## Before the first run

1. **Docker Desktop's VM.** Settings, Resources: at least **4 CPUs and 8 GB**.
   The server gets exactly production's machine (`fly.toml`: 2 dedicated CPUs,
   4 GB, no swap) as `--cpus 2 --memory 4g --memory-swap 4g`, and PostgreSQL
   and the VM itself need room beside it. The scripts refuse a smaller VM.
2. **The Mac beside the VM.** k6 runs on the Mac, outside the VM. It holds 2
   to 3 MB per open page, 4 to 6 GB at 2,000, and uses two or more cores at
   that count. With the VM's 8 GB, 2,000-page runs want a 16 GB Mac at least
   and 32 GB to be comfortable; quit other heavy apps during a run.
3. **k6 and Node.** `brew install k6` (2.x; the kit was run with k6 v2.3.0)
   and Node, which the platform already needs.
4. **The Club's deployment record.** The Regents Club's `base.deployed.json`,
   the record production was seeded with; it is not committed
   (contracts/README.md). Every run records it with `/app/bin/seed-deployment`
   so the Club has its rooms and keys as on production.
5. **Open files.** The scripts raise the shell's limit to 16,384. If that is
   refused, run `sudo launchctl limit maxfiles 65536 200000` and open a new
   terminal.

## The runs, in order

From the repository root, with the commit under test checked out and nothing
uncommitted (`make release` refuses changes, and every run loads the image of
`HEAD`, so build again after any new commit):

```sh
make release                                   # checks, builds and smoke-checks keyfleet:<commit>
export KEYFLEET_DEPLOYED_RECORD=/path/to/base.deployed.json

platform/load/local.sh smoke    # about 5 minutes: 5 pages, checks the setup
platform/load/local.sh ramp     # about 35 minutes: 2,000 pages
platform/load/local.sh spike    # about 20 minutes: 500 new pages in 30 seconds
platform/load/local.sh storm    # about 25 minutes: 2,000 pages reconnect at once
platform/load/local.sh deploy   # about 45 minutes: the server replaced under 2,000 pages
platform/load/faults.sh         # about 15 minutes: the database slowed, broken, stopped
platform/load/local.sh zap      # about 10 minutes: the ZAP baseline scan
```

Each run first starts PostgreSQL 17 on a Docker network of its own, creates
and seeds the database with the release's own commands (`bootstrap-staging`,
`migrate` and `seed-deployment` with the record), starts the server on `127.0.0.1:4100` (`LOAD_PORT`), checks its health
and that its database pool is 5 connections, then loads it. k6's output
follows in the terminal. Every page is loaded once before the load starts, and
the run stops at once, saying which, if one is missing or the Club is still
coming soon.

**Pass** is the run's last table ending in `Result: pass` and the script
exiting 0 (`echo $?` straight after). Anything else is a fail: a table line
marked `**FAIL**` names the mark that was crossed, and `Run failed: ...` names
a setup step that did not work, with the server's last log lines. k6's own
exits: 99 means a pass mark was crossed, 107 a refused target, 108 a page
missing in setup.

Each results folder holds the summary (`<run>.json`), `k6.log`, each server
container's log, the server's metrics at the start and end
(`metrics/*.prom`), `versions.txt` (commit, image, k6, Docker's VM, the Mac,
the server's pool and schedulers) and `report.md`, the tables. Paste
`report.md` into the launch notes as it is.

## What each visitor does

A virtual user is one open page. It picks a page, by weight:

| Page | Address | Weight |
| --- | --- | --- |
| Home | `/` | 50 |
| Classic #1 | `/classic/1` | 10 |
| Regents Club hall | `/app/fleets/regents_club` | 15 |
| Regents Club key map | `/app/fleets/regents_club?view=map` | 10 |
| Public room | `/app/fleets/regents_club/rooms/general` | 15 |

Then, as the site's own browser code does (`assets/js/app.ts` with Phoenix
LiveView 1.2):

1. It loads the page with an empty cookie jar, as a new visitor, and reads the
   CSRF token and every live view's session from the HTML.
2. On its first visit it fetches the page's stylesheet, scripts and the
   modules they import, fonts and icon, as a browser fills its cache, and
   keeps them for its later visits (`ASSETS=every` fetches them every time).
3. It opens `/live/websocket` (protocol 2.0.0) with the page's session cookie
   and the site's own origin, joins every live view on the page, the main one
   and the harbour's sea, and sends what their hooks send on mount. The
   session cookie is Secure, which a browser sends to `http://localhost` but
   k6's cookie jar never sends over plain HTTP, so the socket carries it
   itself.
4. It sends the heartbeat every 30 seconds and waits for each answer.
5. It stays 2 to 10 minutes (`DWELL_MIN_S`, `DWELL_MAX_S`), leaves, and comes
   back as a new visitor to another page.

When the site misbehaves it does what a browser would: a join refused as
stale reloads the page; a crashed view rejoins after 1, 2, 5 and then 10
seconds; a dropped connection reconnects after 10 ms, 50 ms and so on to 5
seconds; a heartbeat unanswered for 30 seconds closes the socket and
reconnects. A socket not open and answering within 2.5 seconds is counted as
a page that would move to long polling (`app.ts`), though the script keeps to
the socket.

## Scenarios

`local.sh <scenario>` picks one; its settings come from the environment, as in
`PAGES=1000 platform/load/local.sh ramp`.

| Scenario | What it does | Its settings (defaults) |
| --- | --- | --- |
| `smoke` | 5 pages for under two minutes, to check the setup. | `PAGES` (5) |
| `ramp` | 0 to 2,000 pages over 10 minutes, held for 10, down in 2. | `PAGES` (2000), `RAMP` (10m), `HOLD` (10m), `RAMP_DOWN` (2m) |
| `spike` | 500 new pages within 30 seconds, held 5 minutes, optionally on top of a steady crowd. | `SPIKE_PAGES` (500), `SPIKE_IN` (30s), `SPIKE_HOLD` (5m), `SPIKE_BASE` (0), `SPIKE_AFTER` (0s) |
| `storm` | Ramps to `PAGES` over 5 minutes, waits 2, then drops every connection at once, as a network blip does; every page reconnects and rejoins together. | `PAGES`, `STORM_RAMP` (5m), `STORM_WAIT` (2m), `STORM_AFTER` (5m) |
| `deploy` | The ramp with a 20-minute hold, the server replaced 2 minutes into it. | `PAGES`, `RAMP`, `DEPLOY_HOLD` (20m, at least 7m), `RAMP_DOWN` |
| `zap` | No visitors: the ZAP baseline scan of the started copy. | none |

`faults.sh` sets its own scenario, `faults`, with `FAULT_PAGES` (200).

For a spike on a steady crowd of 1,500: `SPIKE_BASE=1500 SPIKE_AFTER=4m
platform/load/local.sh spike`, which lands the spike inside the crowd's hold.

Other settings: `LOAD_PORT` (4100), `IMAGE` (`keyfleet:<commit>`),
`DWELL_MIN_S` and `DWELL_MAX_S` (120 and 600; 30 and 60 in `smoke`, 20 and
60 in `faults`), `ASSETS` (`first` or `every`) and `REJOIN_DEADLINE_S` (120).

## Pass marks

Every run is judged by the launch targets:

| Measure | Pass |
| --- | --- |
| Requests that failed, pages and their files (`http_req_failed`) | under 0.1% |
| Page drawn by the server, dead render (`http_req_duration{kind:page}`) | p95 under 1 s |
| Live joins that failed (`lv_join_errors`) | under 0.1% |
| Live join, request to reply (`lv_join_duration`) | p95 under 1 s |
| Pages whose dropped connection was not joined again within 120 s (`lv_rejoin_lost`) | none |
| Open connections the site dropped (`lv_socket_drops`), except in `deploy` | none |
| Connection attempts that never opened (`lv_ws_connect_failed`), except in `deploy` | none |

In the storm the drops are the test's own (`lv_storm_drops`) and the bar is
that every page comes back. The deploy run's marks are below. The table also
shows, with no pass mark: time to a live page, socket handshake, heartbeat
round trip, rejoin time, stale reloads, crashed views, page and join sizes,
pages saying they couldn't be loaded, the data received, and the server's own
wait for a database connection (p95 and p99, from its metrics at the start
and end of the run), the figure the live site's failures of 18 October were
made of.

## The deploy run

```sh
platform/load/local.sh deploy
```

Production is one Fly machine with a volume, so a deploy cannot start the new
machine beside the old one: Fly runs the release command on a machine of its
own, stops the old machine (its default signal, SIGINT, and 5 seconds to
finish), and starts the new image on the same volume. `local.sh deploy` does
the same, in the same order, while k6 holds 2,000 pages open:

1. It opens the pages over `RAMP` and lets them settle for two minutes.
2. It runs `/app/bin/migrate` in a container of its own, as Fly's release
   command, while the first server keeps serving.
3. It stops the first server with `docker stop --signal SIGINT --time 5`.
4. It starts a second server from the same image, with the same secret (so the
   pages the first one drew join the second), the same `/data` volume and the
   same port, and waits for its health.

Meanwhile it asks the home page twice a second, which gives the gap in which
a new visitor got no answer. Every open connection drops once, by design.

**Pass is `lv_rejoin_lost` = 0**: every open page joined again within 120
seconds of its drop, which is what "zero lost connections during a deploy"
means for a visitor. Page loads are judged before and after the deploy
phase (the two minutes from the release command on) by the usual 0.1%, and
inside it they are measured: every new visitor who arrives in the gap fails,
and that count is the gap's cost. Live joins are judged throughout, so 2,000
pages rejoining the new server at once must still join within a second at
p95. The report's first table gives the release command's time, the stop,
the new server's start to health and the longest time the home page did not
answer; the second has the drops (`lv_socket_drops`), the rejoins and their
time (`lv_rejoin_duration`, p95 and max), the attempts made while no server
answered (`lv_ws_connect_failed`), and the database wait of each server.

## The fault runs

```sh
platform/load/faults.sh
```

It starts what `local.sh` starts, with Toxiproxy between the server and
PostgreSQL, answering to the staging database hostname, so the server and
every release command reach the database only through it. It opens 200 pages
(`FAULT_PAGES`) and then runs the phases back to back, each followed by a
recovery:

| Phase | Fault | `/healthz` should say |
| --- | --- | --- |
| `baseline` | none, 60 s | ok |
| `latency_200` | every database reply 200 ms late, 90 s | ok |
| `latency_1000` | every reply 1 s late, 90 s | either |
| `reset` | every connection reset, 10 s | either |
| `timeout` | the database silent with connections open, 10 s | either |
| `db_down` | PostgreSQL stopped, 60 s | unavailable within 10 s |

Pass, phase by phase: every page load answers (a page saying it couldn't be
loaded is an answer; a 5xx or no answer is not), live joins keep succeeding,
`/healthz` answers within production's 2-second check, the site is whole
again within 30 seconds of each fault ending, and the server never restarts.
The report is one table per phase plus health, recovery and restarts, with
the database queue time per phase from the server's metrics.

## The ZAP scan

```sh
platform/load/local.sh zap
```

It starts the copy and runs `zap-baseline.sh http://localhost:4100` against
it: ZAP's spider walks the site for three minutes and its passive rules read
every answer, sending `X-Forwarded-Proto: https` as Fly's proxy does, so the
answers are the ones production gives. `zap-rules.tsv` says which findings
are intended and why. Pass: `Result PASS` (no rule warned) or `Result PASS
with warnings` (read each WARN in `zap/report.html`); exit 1 means a FAIL rule
fired, such as a cookie without HttpOnly, Secure or SameSite. With a copy
already running, `platform/load/zap-baseline.sh http://localhost:<port>`
scans it alone.

## Reading the results again

```sh
node platform/load/summarize.mjs platform/load/results/ramp-<time>/ramp.json [more.json ...]
node platform/load/summarize.mjs --faults platform/load/results/faults-<time>
```

It prints the same tables and exits 1 when anything failed.

## Watching the server during a run

In a second terminal:

```sh
app="$(docker ps --format '{{.Names}}' | grep -E '^keyfleet-(local|faults)-[0-9]+-app' | head -n 1)"
docker stats "$app"                                         # CPU (200% is both CPUs) and memory of 4 GB
curl -s "$(docker port "$app" 9091/tcp | head -n 1)/metrics" | grep health_
docker exec "$app" /app/bin/keyfleet rpc 'IO.inspect(:erlang.memory(:total))'
docker exec "$app" /app/bin/keyfleet rpc 'Process.list() |> Enum.flat_map(fn p -> case Process.info(p, :dictionary) do {:dictionary, d} -> (case d[:"$process_label"] do {Phoenix.LiveView, view, _} -> [view]; _ -> [] end); _ -> [] end end) |> Enum.frequencies() |> IO.inspect()'
```

The last counts the open live views by view: about one main view per open
page, plus the harbour's sea on every page but the home page. Measured on the
live site on 14 October, each open page costs the machine about 0.9 MB.

## Reading the numbers: a Mac is not a Fly performance-2x

The server has production's 2 CPUs, 4 GB and pool of five, and runs
production's code. Everything around it differs, so read every figure as this
release on a machine of production's size, not as production:

- **Processors.** `--cpus 2` is two CPUs' worth of time spread over the VM's
  cores, not two dedicated cores, and Apple's cores are not Fly's AMD EPYC
  ones; on Apple silicon `make release` also builds the arm64 image where Fly
  runs amd64. CPU headroom here can be more or less than production's. Treat
  a run that passes with the server's CPU near 200% in `docker stats` as a
  fail in waiting.
- **The network.** Every connection is plain HTTP over loopback through
  Docker Desktop's port forwarder, a userland proxy with costs of its own:
  no TLS, no Fly edge, no internet. If figures go bad only at high page
  counts while the server's CPU is not full, suspect the forwarder or k6
  before the site, and look at k6's own CPU in Activity Monitor.
- **The database.** A PostgreSQL 17 of its own beside the server: no PgBouncer,
  no TLS, no other Regent site's load, under a millisecond away. Production's
  is a shared managed cluster across Fly's network through its pooled URL. A
  query holds one of the five connections longer there, so the pool's wait
  here understates production's: a run whose database wait is already above a
  few milliseconds at p95 is a warning for launch day.
- **The data.** The Club's deployment, nothing more: no posts in
  the Public room, no members, no history, no chain reads (no `KEYFLEET_RPC_URL`, so
  the key map draws an empty fleet). Pages are lighter than production's.
- **The deploy.** A container starts in seconds; a Fly machine also fetches
  the image and attaches the volume, and Fly's proxy, not a refused
  connection, meets visitors in the gap. The gap here is a lower bound.
- **One address.** Every visitor comes from 127.0.0.1. The site limits
  requests per address only on `/healthz`, the API, sign-in and browsers'
  timing reports, none of which the visitors send.

## What these runs cannot prove

They show how this release behaves on a machine of production's size with a
pool of five under 2,000 open pages, a spike, a reconnect storm, a
single-machine replacement and a failing database. They cannot prove:

- **Production's machine and network**: the performance-2x in iad, Fly's edge
  and its TLS, and the internet between visitors and the site.
- **The shared production database and its PgBouncer**: other sites' load on
  the cluster regents-platform-prod, the network between, and the pooler's
  own limits.
- **Real phones**: the script is a browser's network traffic, not a browser.
  It draws nothing, runs no page script, fetches only what the HTML names and
  the modules those import, and sends nothing a reader's clicks would. LCP,
  INP and CLS come from real visitors' browsers (`KeyfleetWeb.Vitals`), and
  `profile-live.sh` gives a lab profile in Chromium.
- **Real 4G**: its latency, loss and handovers, and the reconnects they cause.

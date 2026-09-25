# ActiveGraph behind Keyfleet: integration design note

Date: 2026-09-22. Status: research and design only. Nothing in `repos/keyfleet` was edited.

- Upstream pinned at `yoheinakajima/activegraph@8aedb1866cf5dce056af97529152ffd6f468a1ed` (package version 1.10.0). It was cloned to `scratchpad/activegraph` and installed into an isolated uv venv (Python 3.12.14) that pulled only click and pydantic from PyPI.
- Probes live in `scratchpad/probes/p1.py` to `p4.py` and were run against local SQLite files only. Every claim marked "probe" below was observed there.
- Requirements come from `planning-docs/KEYFLEET_ACTIVEGRAPH_ADDENDUM.md` (§13) and `KEYFLEET_HACKATHON_SPEC_v0.3.md` (§2, 6, 7, 10).
- The app facts come from `repos/keyfleet` at `main` `bfa97a0`.

Upstream citations are `path:line` relative to the upstream repository root. Keyfleet citations are relative to `repos/keyfleet/platform/`.

---

## 0. Verdicts in one screen

- **Every addendum claim about upstream holds.** Each one is confirmed below. Nothing in the addendum is false. Two claims understate the problem:
  - `patch_object` performs **no** version check at all, and it also skips schema validation.
  - Pack validation covers only object *creation* and relations with *known* endpoint types. It does not cover patches, unknown types, or dangling relations.
- **One SQLite transaction can hold a whole command.** That means the domain events, our command-ledger record, and any reaction events. Proven by probe. The in-memory projection is *not* inside that transaction, so any failure inside a write must end the Python process.
- **Durable cursor:** the SQLite `events.seq` column (AUTOINCREMENT). The public Python API exposes only event ids (`iter_events(after=event_id)`). The host reads `seq` with its own SQL on the same connection.
- **Host shape:** confirm the chief engineer's leaning. One Python OS process per fleet, run as an Erlang Port, no listener, supervised so there is one writer per fleet. Four deltas:
  1. The per-fleet recheck needs a *key-specific* check, because `FleetMember` cannot be reused as is.
  2. Use `{:packet, 4}` framing rather than newline framing.
  3. Keep idempotency authoritative in SQLite, with no Postgres command queue in v1.
  4. On any timeout, kill the Python process (it cannot be recovered in place).
- **Where it breaks today:**
  - There is no Python in the image and no Fly volume.
  - The agent actor carries no key coordinate or credential reference.
  - There is no proposals projection, so `launch.prepare` is blocked.

---

## 1. Public Python API, with claim checks

### 1.1 Operations Keyfleet needs

| Need | Upstream call | Where | Notes |
|---|---|---|---|
| Open or create a run on a SQLite file | `Graph(run_id="kf_<fleet>")` + `Runtime(graph, persist_to=path, behaviors=[...], tools=[])` | `runtime/runtime.py:332-547`, persist wiring `:505-512` | `persist_to` opens `SQLiteEventStore(path, run_id)` and upserts the run row. |
| Reopen a run | `Runtime.load(path, run_id, behaviors=[...], tools=[])` | `runtime/runtime.py:3250-3391` | Replays every event (`:3317`), reseeds id counters (`:3318`), requeues the suffix after the last `runtime.idle` (`:3370`, `:4101-4177`). It always builds a plain `SQLiteEventStore` (`:3308`), so no subclass can be injected. It does **not** restore pack validators: call `load_pack` again (probe p2). |
| Create an object of a custom type | `graph.add_object(type, data, actor=...)` | `core/graph.py:622-672` | Ids are `"<type>#<n>"` from one global counter (`core/ids.py:63-65`). The version starts at 1 (`graph.py:657`). The pack validator runs only here (`:642-643`). |
| Update fields | `graph.patch_object(id, updates, actor=...)` | `core/graph.py:775-829` | Emits `patch.applied` directly. `expected_version = obj.version` is read from current state (`:800`). **No comparison is made and no schema validation runs**, even though the docstring at `:788` says "version-check". |
| Propose / apply / reject | `propose_patch(target, op, value, proposed_by=...)`, `apply_patch(patch_id, approved_by=...)`, `reject_patch(patch_id, reason)` | `core/graph.py:831-881`, `:883-924`, `:926-964` | `propose_patch` captures the **current** version (`:847-848`). `apply_patch` compares the current version with `patch.expected_version` and on mismatch emits `patch.rejected`; it does not raise (`:899-908`). Applying a non-proposed patch raises `InvalidPatchLifecycleState` (`:894-898`). A patch on a **missing** target has expected version 0 and "applies" with no effect (probe p1). |
| Create / remove a relation | `graph.add_relation(src, tgt, type, data, actor=...)`, `graph.remove_relation(rel_id, actor=...)` | `core/graph.py:674-731`, `:733-752` | Relations have no version. Dangling endpoints are legal. `remove_relation` of an unknown id is a silent no-op and writes no event (`:741-742`). |
| Archive / tombstone | *No native archive.* `graph.remove_object(id)` | `core/graph.py:754-773`; projector `:1023-1037` | `object.removed` drops the object **and cascades away its relations** from the projection. The event is kept. For Keyfleet archive, use a patch on a server field `sys.archived`, not `remove_object`. |
| Read object with version | `graph.get_object(id)` returns `Object(id, type, data, version, provenance)` | `core/graph.py:48-73`, `:230-231` | Returns the **live instance** with no copy (`core/graph_store.py:299`, `:314-315`). Serialize with `to_dict()`, which deep-copies. |
| List by type | `graph.objects(type=..., where=...)`; `graph.relations(source=, target=, type=)`; `graph.neighborhood(id, depth)` | `core/graph.py:313-332`, `:271-288`, `:290-293` | In-memory scans. 20k objects scan in about 1 ms (probe p3). |
| Events since a position | `graph.store.iter_events(after=event_id, until=None)` | `store/sqlite.py:243-258` | Translates the event id into `seq` through `_seq_of` (`:286-318`) and orders by `seq`. See 1.2. |
| Cooperative drain | `runtime.run_quantum(max_queue_events=25, max_seconds=0.25)` | `runtime/runtime.py:1079-1127`, loop `:1262-1300` | Bounds are checked **between** queue events. One behavior call is atomic. Emits `runtime.idle` when it drains (`:2746-2771`). |

### 1.2 The durable cursor

- The `events` table has `seq INTEGER PRIMARY KEY AUTOINCREMENT` and `UNIQUE(id, run_id)` (`store/sqlite.py:57-72`). `seq` is the ordering authority (`:28-29`).
- The event `id` (`evt_001`, and so on) is a per-run logical id (`core/ids.py:67-69`). It is not ordered as a string, and it is not exposed with `seq`: `Event` has no `seq` field (`core/event.py:14-32`).
- **Use `seq` as the cursor.**
  - It never repeats, even after deletes, because of AUTOINCREMENT.
  - It is shared across runs in one file, so with one run per file it is per-fleet monotonic. Forks in the same file make it gappy, but it stays monotonic.
  - With a single writer, commit order equals `seq` order, so a reader never sees `seq` N+1 committed before N.
  - The host reads it with `SELECT seq ... FROM events WHERE run_id=? AND seq>? ORDER BY seq LIMIT ?` on its own connection.
- Never call `truncate_after` (`:273-278`) or compaction `archive_prefix` (`:384-408`). Either would move the cursor base. The host exposes neither.
- `DeliveryContext.sequence` in sinks is `len(graph._events)` (`core/graph.py:584-588`). That counts the in-memory log, it is not durable, and it drifts after a rolled-back transaction. Do not use it.

### 1.3 Addendum claims

| Addendum claim | Verdict | Evidence |
|---|---|---|
| `propose_patch` captures the current version, not the caller's | **Confirmed** | `core/graph.py:847-848`. Probe p1: the client observed v1, the object was at v2, `propose_patch` recorded 2, and `apply_patch` returned `patch.applied`. |
| `patch_object` derives its version from current state | **Confirmed, and worse** | `:800` derives the version, then the method emits `patch.applied` unconditionally (`:814-828`) with no pack validation. Probe p1: `{"status": 123, "paid": true}` was accepted on a model with `extra="forbid"`. |
| Live emit mutates the in-memory projection before the store append | **Confirmed** | `core/graph.py:573-576`: `_events.append`, then `apply_event`, then `store.append`. Probe p2: after a simulated append failure, the object stays in memory. A cross-thread emit also fails *after* mutating memory. |
| Sinks are lossy and replay does not redeliver | **Confirmed** | Bounded queue with default `drop_newest` (`core/graph.py:374-375`, `sinks/dispatch.py:157-163`). Replay goes through `_replay_event`, which calls no sinks (`core/graph.py:610-618`). "Historical events … are never delivered" (`:383`). `replay_export` is "reserved for a future" path (`sinks/base.py:54`). Probe p3: 3 of 50 delivered with capacity 2, and 0 historical events after `load`. |
| Fork / promote require the same SQLite store | **Confirmed** | Fork needs `SQLiteEventStore` (`runtime/runtime.py:3415`, `:3432-3453`) and copies rows inside the same file (`store/sqlite.py:465-597`). Promote needs both stores to be SQLite, the same `path` (`runtime.py:3623-3626`, `:3668`), and a direct lineage (`:3680`). |
| `run_quantum` limit is checked between events | **Confirmed** | `runtime/runtime.py:1085-1090` and `:1264`. |
| Policies are cooperative; direct graph writes bypass approval | **Confirmed** | Approval gating applies only through `ctx.propose_object` (`runtime/runtime.py:191-215`, `:3039-3060`). `graph.add_object` never consults `gated_object_types`. |
| The subprocess trial runner is not a security sandbox | **Confirmed** | `LOCAL_SUBPROCESS_ISOLATION`: `network="unconfined"`, "crash and parent-state isolation only" (`sandbox/executor.py:25-33`). |
| The core ships no HTTP service or NFT authorization | **Confirmed** | There is no server module. The only network code is the `web_fetch` tool and the store URL parsing. |

The addendum's step "if a process stops between proposal and application, reconcile the stored patch state" (§13.7) is **moot** under the transaction design in §3. Proposal and application commit together or not at all, so a stored proposed-but-unapplied patch can never exist.

---

## 2. Packs, validation and actor metadata

**How a pack is declared.** A pack is a `Pack(name, version, object_types=[ObjectType(name, PydanticModel)], relation_types=[RelationType(name, source_types, target_types)], behaviors=[...], policies=[...])` (`packs/__init__.py:388-449`, `:553-600`). `runtime.load_pack(pack)`:
- installs validators on the graph (`packs/loader.py:296-300`, `:835-884`);
- emits a `pack.loaded` event, **once per process start**, because `Runtime.load` keeps no pack state (`:302-314`; probe p4 shows a second `pack.loaded` after restart);
- raises `PackVersionConflictError` if a different version with the same name is already loaded.

**What upstream validates:**
- `add_object` of a pack-owned type runs `schema(**data)` and then `model_dump()` (`loader.py:846-861`).
  - With the Pydantic default `extra="ignore"`, unknown fields are **silently dropped** (probe p1). Declare every model with `ConfigDict(extra="forbid")`.
  - Unknown object types pass through unvalidated (`:849-851`).
- `add_relation` checks endpoint *types* only when both endpoints exist (`core/graph.py:692-699`, `loader.py:864-884`). Undeclared relation types and dangling endpoints are accepted (probe p1).
- Patches are never validated (`core/graph.py:775-924`, `:1059-1070`).

**What we must own** (in the host, before any emit):
- a type allowlist;
- a relation-type allowlist;
- endpoints must exist in this run and must not be archived;
- the merged-state validation `Model(**{**current.data, **diff})` before every patch;
- the rule that patches may not touch the forbidden field set;
- byte-length limits for launch fields (§10.2 of v0.3 counts bytes, while Pydantic `max_length` counts characters).

**Actor metadata:**
- Every builder takes a free `actor: str`, which defaults to `"system"` (`core/graph.py:627`, `:681`, `:737`, `:758`, `:780`). It is stored in `Event.actor` (`core/event.py:29`) and in `provenance.created_by` (`:968-995`).
- Provenance is framework-written. A `provenance` key in caller data raises `ReservedFieldError` (`:114-136`).
- Events have no metadata field beyond `payload`.

So the actor string is an attribution label, not proof. The host must always pass an explicit gateway-composed actor, and must never accept one from a member.

---

## 3. Command provenance, idempotency and transactions

**Facts, from `store/sqlite.py` and probes p2 and p4:**
- The store opens `sqlite3.connect(path, isolation_level=None)` (`:227`). That is autocommit, so each `append` (`:233-241`) is its own implicit transaction. It uses WAL with `synchronous=NORMAL` (`:122-127`).
- `BEGIN IMMEDIATE` issued on `graph.store._conn` makes every later `append` part of one transaction. We can create and write **our own table in the same file and transaction** (probe p2: events plus a `kf_commands` row committed together, and invisible to other connections until `COMMIT`).
- The projection is **in memory** (`InMemoryGraphStore`) and is not covered by the transaction. After a `ROLLBACK`, memory holds events and objects that disk does not (probe p2). After reload, those never-durable ids are reissued (`task#4` reused in probe p2). This is harmless only if no id is revealed before `COMMIT`.
- A custom event type such as `keyfleet.command` is persisted and replayed as a no-op: `apply_event` ignores unknown types (`core/graph.py:1001-1077`), and `IDGen.reseed_from_events` still counts its `evt_` id (`core/ids.py:105-107`).

**Recommendation: one ledger, inside the log.** Each accepted mutation commits as one SQLite transaction in this order:

1. `BEGIN IMMEDIATE`.
2. Run the checks in §7.3 (ledger, existence, version, scope, fields, schema).
3. Emit the domain events (`object.created`, `patch.applied`, `relation.created` or `relation.removed`).
4. Emit a `keyfleet.command` event, actor `keyfleet:gateway`, with payload:
   - `principal`, `command_id`, `body_hash`, `op`;
   - `result` (the object or relation id, the new version, and the event ids);
   - `auth`: key coordinate, ownership epoch, operator wallet, pairing id, credential reference, check time, and the chain block and freshness once the chain projection exists.
   Before it, the host emits the `keyfleet.attention` events the write's reactions ask for (§7.6), so the event ids the ledger records name them too.
5. `run_quantum(...)` to settle the runtime's own bookkeeping. The pack carries no upstream behaviors, so this drains lifecycle events only and must finish idle.
6. `COMMIT`. The last event is now `runtime.idle`, so a restart requeues nothing.

**Why this and not a side table:**
- The log alone then carries full, self-describing provenance, and it travels through fork and migrate. A side table would not.
- The idempotency index is rebuilt at boot from the replayed events: a dict keyed by `(principal, command_id)`.
- Probe p4 shows the complete loop:
  - apply;
  - stale write returns `conflict`;
  - simulated crash after `COMMIT` but before the reply, then restart;
  - retry with the same id and body returns the original result;
  - the same id with a different body returns `duplicate_mismatch`.

**Rules:**
- **Any exception after step 1 means `ROLLBACK` and process exit with a non-zero code.** Never serve after a failed write. The supervisor restarts, and `Runtime.load` rebuilds memory from durable events. This is the addendum's "stop/fence and reload".
- Refusals (conflict, invalid, forbidden, not_found) write nothing and are not remembered. Each is a pure function of input plus state, and versions only increase, so a stale retry stays refused.
- **Never attach EventSinks.** They are offered from inside `emit`, which is *before* our `COMMIT`, so a sink could observe an event that is later rolled back.
- The transaction wrapper depends on two private details of the pinned build: `store._conn`, and autocommit mode (`sqlite.py:227`). `Runtime.load` constructs its own store (`runtime.py:3308`). Pin the version and keep one host test that fails if either detail changes.

---

## 4. Concurrency

The runtime is single-threaded by design:
- "The runtime loop. Single-threaded FIFO" (`runtime/runtime.py:1`).
- `IDGen` says "Not thread-safe" (`core/ids.py:42`).
- `Graph` holds an `RLock` around emit (`core/graph.py:191-196`), but the SQLite connection uses the default `check_same_thread=True` (`store/sqlite.py:227`). Probe p2: an emit from a second thread raises `ProgrammingError` **after** mutating the in-memory projection.
- Multi-process or distributed runtimes are explicitly out of scope (`CONTRACT.md:590`).

**Could one process host four fleets?** It works, if each runtime and its connection are confined to their own thread (probe p3: 4 runs × 2,000 objects in about 0.2 s each). But they would share:
- the GIL;
- module-level registries: `_TOOL_REGISTRY` (`tools/decorators.py:20`), the behavior registry, and the `_LIVE_RUNTIMES` WeakSet (`runtime/_live.py`);
- one crash domain. The "any write error exits the process" rule would take down all four fleets.

**Recommendation: one OS process per fleet.**
- Cost is about 36 MB RSS and 0.16 s import per process (measured), which is fine in the 2 GB VM (`fly.toml`).
- Inside each process: one thread, one runtime, one connection.
- Fence with a non-blocking `fcntl.flock` on `<fleet>.lock` at startup, held for the process lifetime. A second host for the same file exits with code `locked`.

---

## 5. Dependencies

- `requires-python = ">=3.11"` (`pyproject.toml:13`).
- Hard dependencies: `click>=8,<9` and `pydantic>=2` (`:28`). The resolved set is click 8.5.0, pydantic 2.13.5, pydantic-core 2.46.5, annotated-types, typing-extensions and typing-inspection. SQLite is the standard library (`:39`).
- LLM SDKs (anthropic, openai, tiktoken), psycopg, falkordb, prometheus and OpenTelemetry are all optional extras (`:36-60`). **None is installed by default.** `import activegraph` loads the `activegraph.llm.anthropic` and `openai` wrapper modules, but not the SDKs.
- **Network reach by default:** `import activegraph` registers the `web_fetch` tool (urllib) in the global tool registry (`tools/web_fetch.py:33`, `tools/__init__.py:48`). Only LLM behaviors invoke tools. Still, always construct `Runtime(..., behaviors=[explicit list], tools=[])`: `behaviors=None` means "the global decorator registry" (`runtime/runtime.py:951-953`).
- The package installs an `activegraph` console script (`pyproject.toml:94`). It is never exposed.
- Pin through a `uv.lock` with hashes, installing activegraph from the reviewed git SHA, and keep `LICENSE`/`NOTICE` in the image (Apache-2.0).
- Logging defaults to **stderr** (`observability/logging.py:196`). `print_graph`/`print_trace` write to stdout (`runtime.py:3129-3146`); never call them.

---

## 6. Host shape: confirmed, with deltas

### 6.1 Shape

```text
signed HTTP / LiveView (later: CLI, MCP, WebMCP)
  -> Keyfleet.Graph (Ash domain): generic actions, key-actor policy
  -> Keyfleet.Graph.Writer (one GenServer per fleet, Registry name {fleet_id})
       handle_call: recheck key authority -> Port request -> await reply
  -> Port (spawn_executable python -m keyfleet_graph --fleet F --db /data/graph/F.sqlite, {:packet,4}, :exit_status)
  -> Python host: flock, Runtime.load/new, load_pack(keyfleet_work@pinned), command loop
  -> /data/graph/<fleet_id>.sqlite  (Fly volume, single machine)

Keyfleet.Graph.Projector (one GenServer per fleet, beside the writers)
  on a write's await(run_id, head_seq), and every catch_up_interval:
    hello -> changes(after_seq: cursor) page by page
    -> one Repo txn per page: events, objects, links, cursor
    -> PubSub {:graph_head, fleet_id, run_id, watermark}
Postgres: graph_events, graph_objects, graph_relations, graph_cursors (disposable projection)
Reads (get, changes, sync): one repeatable-read, read-only snapshot of those tables
```

### 6.2 What to keep from the chief engineer's leaning

- One long-lived Python process per fleet, an Erlang Port, no listener, and no service credentials in the host.
- OTP supervision: a `Keyfleet.Graph.Supervisor` with a `one_for_one` child per fleet in the catalog, and restart backoff.
- A synchronous call.
- Membership rechecked inside the serialized call.
- A Postgres read projection tailing the durable log from a persisted cursor.

### 6.3 What to change

1. **Framing.** Use `{:packet, 4}` (a 4-byte length plus UTF-8 JSON, max 1 MiB) instead of newline lines. This removes `{:noeol, _}` chunk handling and any stray-newline hazard. The Python side does `os.dup(1)` for the protocol, then `os.dup2(2, 1)` so any stray `print` goes to stderr. The message shapes in §7 do not change.
2. **Authority check.** `Keyfleet.Rooms.Checks.FleetMember.match?/3` only matches an `%Ash.Changeset{}` subject (`lib/keyfleet/rooms/checks/fleet_member.ex:23-26`). Generic actions pass an `Ash.ActionInput`, so it would always refuse. It also answers "some key in the fleet", not "this key".
   - Add `Keyfleet.Graph.Checks.KeyActor`. It passes when the actor is either the owner of `as_key` at the current epoch (Human, the same current-epoch owner condition as `KeyAttachment :identity_in_fleet`, which `Keyfleet.Keys.identity/2` reads) or the active effective operator of `as_key` (Agent, the same condition as `KeyPairing :my_identity_in_fleet`, `key_pairing.ex:241-252`).
   - The Writer calls the same function again inside `handle_call`. The Ash policy is the early refusal; the in-call recheck is the authority.
3. **Idempotency authority lives in SQLite (§3). There is no Postgres command queue in v1.** The GenServer mailbox is the queue, and the recheck runs at execution. The addendum's "queued" HTTP semantics (202) are deferred. See decision 2.
4. **Timeouts are indeterminate, never "failed".** On call timeout or Port exit:
   - reply `{:error, :indeterminate}` (HTTP 503 with `retry_same_command_id: true`);
   - kill the OS process (`Port.info(port, :os_pid)`, then `kill -9`);
   - let the supervisor restart it.
   The flock stops a stuck old process from being joined by a new one. A retry with the same id resolves through the ledger.
5. **Membership freshness stamp.** `handle_call` records `{epoch, pairing_id, checked_at}` in the command's `auth` block. Once the chain projection lands, it also records the projection's block and freshness, and refuses when freshness is unknown.
6. **Projection write path.** There is one path, the fleet's projector; the Writer never writes Postgres.
   - The projector asks the host for `hello`, then loops `changes(after_seq: cursor)` until `has_more=false`. Each page is one Repo transaction: its events, the objects and links they change, and the cursor moved past the page. The cursor moves only from the value the page started at, so of two copies running at once the one that is behind rolls its page back.
   - It runs when a write asks it to reach that write's `head_seq` (`Projector.await/3`, bounded by `projection_wait`) and every `catch_up_interval` regardless, so a lost request or a failed page is made good on the next round.
   - The log names itself with `run_id`, a random id minted when its SQLite file is created and kept in that file. A cursor from another `run_id`, or past the log's head, means the file was replaced: the fleet's read tables are removed and copied again from 0, and the projector forgets the place it had reached.
   - A write answers `watermark`, how far the projection had reached when it answered, 0 when unknown. A Postgres failure never turns an applied command into an error: the graph is authoritative and the projection catches up.
7. **Reads.** `graph.read`, `graph.query` and `graph.changes` read the Postgres projection. They do not read the Writer, so reads survive a writer restart. They return `watermark` (the projected seq).

### 6.4 Where it breaks

| # | Break | Where | Consequence / fix |
|---|---|---|---|
| B1 | No key coordinate or credential reference on the agent actor | `lib/keyfleet_web/plugs/signed_agent.ex:131` builds `%Agent{wallet_address, chain_id, audience}` only; receipt fields are validated then dropped | Commands must name `as_key`. The plug must keep a credential reference, such as a digest of `x-siwa-receipt` plus `x-key-id`, for the audit stamp the addendum requires (§13.3). |
| B2 | Chain freshness | Resolved: the chain projection records each key's ownership epochs from the contract's `OwnershipEpoch` logs (`lib/keyfleet/chain/scanner.ex`), and its cursor says whether that reading is recent enough (`Keyfleet.Chain.fresh?/1`) | The key check fails closed: while the reading is not fresh, a write is refused as `ownership_refreshing` (§7.3). |
| B3 | Level data | Resolved in S4a: completed levels come from the fleet's sold keys as the chain projection records them (`Keyfleet.Chain.minted/2`, `Keyfleet.Fleets.Presets.writable_levels/2`) | Level scopes are granted only while that reading is fresh (§7.3). |
| B4 | No proposals projection | `Rooms.sync` hard-codes `proposals: []` (`lib/keyfleet/rooms.ex:44-50`) | `launch.prepare` and test 13.11 #5 wait for proposals. |
| B5 | The image has no Python | `Dockerfile:81-83` is Debian slim plus coreutils | Add a uv-built venv from `uv.lock` (Python ≥3.11) in a build stage, copied into the runtime stage, run as uid 1001. |
| B6 | No volume | `fly.toml` and `fly.staging.toml` have no `[mounts]` | Add a volume at `/data`. It pins the app to one host and one machine, which `fly.toml:21-22` already requires. A deploy is stop then start, so there is a short write outage. Fly volumes are not replicated: add scheduled `sqlite3 .backup` exports next to Fly snapshots. If someone scales to two machines, each gets its **own** volume and the graphs split silently; flock cannot see across hosts. Keep `fly scale count 1` as a written deploy rule. |
| B7 | Process-death semantics | Upstream design | Any write exception, cross-thread use or append failure means exit (§3). The BEAM Port gets `exit_status` and the supervisor restarts. A reload replays the full log: 40k events took 0.57 s locally (probe p3), and every event stays in memory (`Graph._events`). This is fine at hackathon scale. Measure under the planned load test. |
| B8 | Restart requeue | `runtime.py:4101-4177` | Events after the last `runtime.idle` re-run behaviors on boot. Upstream behaviors would also swallow their own exceptions into `behavior.failed` events and add lifecycle events of their own, so the v1 reactions are not behaviors: they are plain host code run inside the write (§7.6), and nothing is requeued. Each cause's reactions run once, so no dedupe key is asked twice, across replay and restart (§7.6). |
| B9 | Reaction cost holds the transaction | The write's transaction | Reactions are pure and bounded: no I/O, at most `MAX_WORK` reads of the fleet's indexed `depends_on` links and `MAX_ATTENTION` attention events per command, whatever the size of the fleet (§7.6). The settling quantum's `max_queue_events` (64) holds one command's change, its attention and its ledger event. |
| B10 | Private upstream seams | `store._conn`, autocommit mode | A pinned-version test guards them (§3). |
| B11 | `#` in object ids | `core/ids.py:63-65` | URL-encode ids in HTTP paths, or pass ids in JSON bodies only (the signed plug already requires JSON bodies and empty query strings, `signed_agent.ex:54-69`, `:167-170`). |
| B12 | Log noise | A `pack.loaded` on every boot; a `runtime.idle` per command | The feed filters to domain types but still advances the scan cursor past filtered events (§13.7 "last-scanned cursor"). |
| B13 | Writer throughput | One serialized GenServer per fleet | Each command takes about a millisecond (probe p3: roughly 0.1 ms per autocommitted create). The mailbox is unbounded, so keep call timeouts (5 s) and the existing `RequestRateLimiter`. Measure in the 1,000-client polling test. |

---

## 7. Protocol and work-pack schema

### 7.1 Framing and envelope

Each message is a `{:packet, 4}` frame holding one UTF-8 JSON object. The Python side processes strictly one request at a time and answers in order. There is no pipelining; the GenServer never sends a second request before the reply arrives.

**Request:**

```json
{"v": 1, "req": "r_01J…", "op": "patch",
 "command": {"id": "client-idempotency-key ≤128",
             "principal": "member:8453:0xFLEET:17@3/agent:0xWALLET",
             "writable_scopes": ["fleet", "level:2", "level:3"],
             "auth": {"key": {"chain_id": 8453, "contract": "0x…", "token_id": 17},
                      "ownership_epoch": 3, "kind": "agent", "operator_wallet": "0x…",
                      "pairing_id": "uuid", "credential_ref": "sha256:…",
                      "checked_at": "2026-09-22T…Z", "chain_block": null}},
 "body": {…op-specific…}}
```

- Read ops (`hello`, `changes`) omit `command`.
- The run and file are fixed per process by its start arguments, so a request cannot name another fleet's run.
- The host recomputes `body_hash = sha256(json.dumps(body, sort_keys=True, separators=(",",":"), ensure_ascii=False))`. There is a single canonicaliser, and Elixir never hashes.

**Response:**

```json
{"v": 1, "req": "r_01J…", "ok": true, "run_id": "log_…", "replayed": false,
 "result": {…}, "events": [{"seq": 41, "id": "evt_041", "type": "patch.applied", "actor": "…", "timestamp": "…", "payload": {…}}],
 "head_seq": 43}
```

```json
{"v": 1, "req": "r_01J…", "ok": false,
 "error": {"code": "conflict", "message": "…", "details": {…}}}
```

### 7.2 Operations

| op | body | result |
|---|---|---|
| `hello` | `{}` | `{run_id, pack: "keyfleet_work@0.1.0", activegraph: "1.10.0+8aedb18", head_seq}`. `run_id` is the log's own id, minted with its file; a replaced file answers a new one. |
| `changes` | `{after_seq, limit ≤500}` | `{run_id, events: [...], next_seq, has_more, head_seq}`. All events, including lifecycle events; the projector filters. |
| `create` | `{type, scope, data}` | `{id, version: 1}` |
| `patch` | `{id, expected_version, set: {...}, unset: [..] , reason?, evidence?: [ids]}` | `{id, version}` |
| `link` | `{source, target, type, note?}` | `{relation_id, existing: bool}`. An identical live `(source, type, target)` returns the existing relation. |
| `unlink` | `{relation_id}` | `{relation_id}` |
| `archive` | `{id, expected_version, reason?}` | `{id, version}`. Sets `sys.archived=true` through a patch. |
| `system_record` (later) | `{type: "receipt", data}` with an actor of `system:<adapter>` | Accepted only when `command.principal` begins with `system:` **and** the Elixir caller is the trusted adapter module. Member ops can never reach it. |

Everything else is refused as `bad_request`. That includes raw emit, `load_pack`, fork, promote, compaction, CLI commands and any Python import.

### 7.3 Check order inside a write

1. Ledger. The same `(principal, command_id)` with the same hash returns the stored result with `replayed: true`. With a different hash it returns `duplicate_mismatch`.
2. Existence and archive state of every touched id.
3. `expected_version == current.version`.
4. Scope: every touched object's `sys.scope` is in `writable_scopes`. For `link` and `unlink` this means both endpoints; for `create` it means the requested scope. `sys.scope` is set at creation and no member write can change it.

`writable_scopes` is resolved in Elixir by `Keyfleet.Graph.Checks.KeyActor`, at the write's turn and only while the fleet's key ownership is fresh (otherwise `ownership_refreshing`, 503). Every key writes `fleet`. A key of a Fibonacci fleet whose token is in level K also writes `level:K`, and `level:L` for L > K once every key of level L is sold; never L < K. Level L is complete once the fleet's sold keys reach the last token id of that level (2, 5, 10, 18, …). The number sold is the highest key number the chain projection has recorded: the contract numbers keys from 1 in the order it sells them and has no way to burn one (`contracts/src/Keyfleet.sol`, `purchase` and `_update`), and a transfer adds no key. Every read the check makes gets what is left of its time budget, and none starts once it is spent; a check that runs out answers the write as unavailable (503). Classic and Accelerant keys write `fleet` only. The host checks the scope strings against `^(fleet|level:([1-9]|1[0-9]|20))$` and refuses any other as `bad_request`.
5. Field rules: the forbidden set, and the `assignee_key` rule.
6. Schema on the merged data.
7. `BEGIN IMMEDIATE` … `COMMIT` as in §3.

### 7.4 Error codes

| code | HTTP | details |
|---|---|---|
| `conflict` | 409 | `{current_version, object}`: the whole current object, so the client can merge without a second read |
| `invalid` | 422 | `{errors: [{path, message}]}` covering schema, bounds, unknown type or relation, endpoint types, a self-link on `depends_on`, and a patch on an archived object |
| `forbidden_field` | 422 | `{fields: [...]}`, for any write to `sys`, to server-owned fields, or of `assignee_key` to another key |
| `forbidden_scope` | 403 | `{scope}` |
| `not_found` | 404 | `{id}` |
| `duplicate_mismatch` | 422 | `{command_id}`. The command id was already used with a different body. |
| `bad_request` | 400 | Unknown op or malformed envelope |
| `indeterminate` | 503 | Elixir only, on timeout or Port exit. The client retries with the same command id. |

`forbidden` (the principal is not the key's owner or effective operator) is decided in Elixir and never reaches Python.

### 7.5 Work pack `keyfleet_work@0.1.0`

Every model uses `ConfigDict(extra="forbid")`. Strings are trimmed and length-bounded. Lists hold at most 20 items. URIs are limited to `https`, `ipfs`, `ar` and `git+https`, at most 512 bytes each.

**Common to all seven types:**
- `title` (required, ≤200 characters).
- `discussion`: an optional list of `{room: slug, seq: int}` message links, which implements "save to workspace".
- `sys` is **server-owned**. Members can never set it, and it is not in the member input model:
  `{"scope": "fleet" | "level:<L>", "created_by": {key: {chain_id, contract, token_id}, ownership_epoch, kind, wallet}, "archived": false}`.

| Type | Member fields (**required in bold**) |
|---|---|
| `goal` | **title**, **outcome** (≤2000), `success_criteria` [str ≤500], `open_questions` [str ≤500], `status` ∈ open/achieved/dropped (default open) |
| `task` | **title**, `deliverable` (≤2000), `assignee_key` (token_id or null; may be set only to the caller's own `as_key` or cleared), `progress` ∈ todo/doing/blocked/done (default todo), `next_step` (≤1000), `result_ref` (URI) |
| `finding` | **title**, **statement** (≤4000), `confidence` ∈ low/medium/high (default low), `uncertainty` (≤2000) |
| `evidence` | **title**, **source_uri**, `digest` (`sha256:<64 hex>`), `excerpt` (≤4000), `provenance` (≤1000; how it was obtained) |
| `service` | **title**, **customer** (≤500), **problem** (≤2000), **deliverable** (≤2000), `payment_asset` ∈ USDC/REGENT/FLEET_TOKEN, `price_proposal` (decimal string), `implementation_refs` [URI] |
| `launch_card` | **title**, `who_we_serve`, `what_we_sell`, `what_works`, `why_raise`, `commitments` (each ≤4000), `narrative` (≤20000), `name` (≤64 **bytes**), `symbol` (≤16 bytes), `description` (≤512 bytes), `website` (≤256 bytes), `image` (≤256 bytes), `required_regent_raised` (decimal string). Nothing beyond `title` is required while drafting; `launch.prepare` enforces all seven launch fields. |
| `note` | **title**, **body** (≤20000) |

**Relations** (member-writable, no data fields beyond an optional `note` of ≤500 characters):

| Relation | source types | target types |
|---|---|---|
| `supports` | finding, evidence | finding, goal, task, service, launch_card |
| `contradicts` | finding, evidence | finding, goal, service, launch_card |
| `depends_on` | goal, task, service, launch_card | goal, task, service, launch_card (no self-link) |
| `implements` | task, service | goal, service |
| `produces` | task | evidence, finding, note, launch_card |
| `references` | any of the seven | any of the seven |

**Server-owned namespaces:**
- **Object field** `sys`. Only the host writes it. `forbidden_field` covers `sys` and any top-level key outside the member model, for example `paid`, `approved`, `admin` or `treasury_balance`, because `extra="forbid"`.
- **System object types** (not member-writable, and not in v1 except `receipt` at slice 5): `receipt`, `membership`, `proposal`, `launch_binding`. Written only through `system_record` with actor `system:<adapter>` and machine-readable provenance: chain id, transaction hash, log index, block, and confirmation state. Members may link *to* them with `references`, and may never patch them.
- **Actors:**
  - members: `member:<chain>:<contract>:<token>@<epoch>/<human|agent>:<wallet>`;
  - `system:<adapter>` for trusted adapters;
  - `keyfleet:gateway` for the ledger and attention events; a command's principal must be a member, so no request can act under it;
  - `runtime` is upstream's own.
  - The host never lets the default `"system"` actor through; it always passes an explicit actor.
- **Event types:** `keyfleet.command` (the ledger) and `keyfleet.attention` (reaction output, §7.6). Both are emitted only by the host, with actor `keyfleet:gateway`, and both are copied to Postgres and served by `changes` and sync.

### 7.6 Reactions

A write can ask members to look at something. The host runs two reactions after the write's own change, inside its transaction (`keyfleet_graph/reactions.py`). They only emit `keyfleet.attention` events and never change an object or link.

**Payload:** `{"kind": "task_unblocked" | "needs_review", "object_id": <id>, "cause": {"event_id": <the change's event id>}, "dedupe_key": "<run_id>:<kind>:<object_id>:<cause event id>"}`.

**`task_unblocked`.** A target is *finished* when it is archived, or when it is a task marked done; goals, services and launch cards have no finished state of their own. A task *waits* while it is neither archived nor done. The host asks `task_unblocked` for each waiting task whose `depends_on` targets are now all finished, when:
- a task's `progress` becomes `done` (its dependents are checked);
- an unfinished object is archived (its dependents are checked);
- a `depends_on` link to an unfinished target is removed (its source is checked).

**`needs_review`.** The host asks `needs_review` of:
- the target of a new `supports` or `contradicts` link from `evidence`;
- the target of a new `produces` link (only tasks produce);
- a task created with, or patched to, a `result_ref`.

An existing link answered again (`existing: true`) asks nothing.

**Depth.** Only a member's change sets a reaction off. Attention events never do, so the cascade depth is one by construction and needs no counter.

**Dedupe.** A cause is one durable event, and its reactions run once, inside its own transaction, asking each object at most once per kind. The same command again is answered from the ledger and runs nothing. A crash between commit and reply leaves the attention durable with the command, and the retry is a replay. Opening the log runs nothing again, because reactions are not upstream behaviors. So a `dedupe_key` never appears twice, and readers can rely on it. It starts with the log's `run_id` because every log numbers its events alike: without it, the same change in two workspaces would give the same key. The host keeps no set of asked keys: no path could ask one again, so the set would guard nothing.

**Bounds per command**, named in `reactions.py`:
- `MAX_ATTENTION = 50` attention events. A notice is a hint to look, so fifty is more than a fleet acts on at once. Past it the rest are not asked, and the command still commits. One member's command can use all fifty, for example by finishing a task that many tasks wait on, and the tasks past the fiftieth are then not announced. That is a known and accepted limit: a notice is only a hint, and those tasks can be seen as unblocked in the graph. The settling quantum (64 events) must hold the change, all fifty and the ledger event; a pytest fails if `MAX_ATTENTION` grows past that.
- `MAX_WORK = 2000` `depends_on` link reads. The host keeps the fleet's `depends_on` links indexed by source and by target: it gathers them once when it opens the fleet's log and records each link it makes or removes after that. A reaction reads the tasks that depend on the changed object, then each one's own dependencies, one read per link, and every read counts against the bound, so a write's work does not grow with the fleet. Two thousand dictionary lookups take a few milliseconds. A task whose check is cut short is not announced, since it cannot be known to be unblocked.

A storm command (200 tasks waiting on one task and on 100 done tasks, 20,200 links) takes about 1 ms in the host. In a fleet with 200,000 `depends_on` links, a write that unblocks one task takes about 0.3 ms (at most 2 ms over 40 writes); reading every link on each such write took 55 ms. While one fleet runs storms back to back, another fleet's plain writes are answered in the same time as before (median about 0.27 ms before and during, measured in `Keyfleet.Graph.WriterTest`), because each fleet has its own writer and host process.

---

## 8. Slice plan

Each slice lands with ExUnit and pytest (via `uv`) gates green and no stubs left behind.

**S1: Python host and writer supervision (fleet scope only).**
- Delivers the `platform/graph_host/` Python package (`uv.lock`, pinned activegraph SHA, and the pack from §7.5), the protocol ops `hello/get/changes/create/patch/link/unlink/archive`, the SQLite command ledger, flock, and exit-on-write-error. On the Elixir side it adds `Keyfleet.Graph.Writer` and a Port supervisor for the four catalog fleets, plus Python in the Dockerfile and a `/data` volume in the Fly config.
- Done when:
  - pytest covers every error code, the crash-after-commit retry (as in probe p4), append failure leading to exit and a clean reload, the private-seam guard test, and the refusal of every op outside the allowlist;
  - ExUnit starts four writers, kills one mid-command, and sees an indeterminate result, a restart, and a replayed result.
- Covers 13.11 #3 at the protocol level; duplicate commands and lost replies; failed persistence stops the writer; unauthorized raw Python or runtime actions are unreachable; cross-fleet (the run is fixed per process).
- No external dependencies.

**S2: `Keyfleet.Graph` Ash actions and signed HTTP (fleet scope).**
- Delivers generic actions `create/patch/link/unlink/archive` plus reads through the Writer; `KeyActor` (owner or effective operator of `as_key`); the in-call recheck and `auth` stamp; a credential reference kept by `SignedAgent`; and `/api/v1/agent/fleets/:fleet_id/graph/*` routes with body shapes added to the plug.
- Done when:
  - two agents with keys create a goal and a service, and add tasks, evidence and links;
  - a concurrent patch race gives one success and one 409 over HTTP;
  - a key transfer recorded while a command waits in the suspended Writer mailbox makes that command refused, and its earlier edits keep their author.
- Covers 13.11 #1, #3, #6 (with System-recorded epochs), and "forged actor/system events rejected".
- #2 is covered only for the HTTP route: the chat "save to workspace" link lands here, but the CLI and MCP routes wait for the adapter slice.
- #6 depends on the chain projection for *fresh* ownership: the logic is testable now, and fail-closed freshness arrives with P3.

**S3: Postgres projection and `graph` in fleet sync.**
- Delivers `graph_events/objects/relations/cursors` (AshPostgres, public read); the projector, the single path that copies the log into them; `Rooms.sync` extended with `graph: {run_id, events, next_cursor, has_more}` plus `watermark` and `next_poll_seconds`; and PubSub heads for LiveView.
- Done when:
  - an agent disconnects, others edit, and one sync call returns both the graph and the chat backlog;
  - deleting projection rows and restarting rebuilds them identically;
  - notification loss (PubSub dropped) is recovered by the cursor;
  - sync responses stay bounded in the 1,000-client polling test.
- Covers 13.11 #4, "sink notification loss is recoverable from the durable log", and "graph queries and responses remain bounded".

**S4a: Level scope and reactions (built).**
- Delivers `level:L` writable scopes for the two Fibonacci fleets (§7.3): a key writes the fleet, its own level, and each later level once all of that level's keys are sold, read from the chain projection's sold keys while ownership is fresh. Classic and Accelerant keys write the fleet only. It also delivers the two bounded reactions of §7.6, their `keyfleet.attention` events in Postgres, `changes` and sync, and both in the API contract.
- Tested over the signed HTTP routes: a key writes its own level; a later-level key is refused an earlier level (403 `forbidden_scope`); an earlier-level key is refused a later level until its last key is sold, then allowed; stale ownership refuses; Classic and Accelerant refuse every level; links in either direction, patches, archives and unlinks touching an unwritable level are refused; `sys.scope` cannot be patched. pytest covers every reaction trigger and the writes that ask nothing, dedupe across replay and restart, both bounds with the command still committing, and that no member request produces attention or moves a scope. ExUnit measures another fleet's write latency during a storm.
- Covers "cross-fleet/scope links are rejected" and "reaction loops exhaust bounded work without blocking other fleets".

**S4b: The Workspace tab.**
- Delivers the LiveView Workspace tab (cards, related objects, revision history, activity).

**S5: `launch.prepare` and verified receipts.**
- Delivers `launch.prepare`, which freezes selected `launch_card` revisions (by id and version) into immutable bytes, validates the seven launch fields in bytes, forces the treasury, and hashes content plus parameters into the exact `proposeAutolaunch` transaction it returns. Nothing is stored: there is no proposal draft, and the proposal exists only once that transaction lands on chain. It also delivers `system_record` receipts from the verified chain adapter.
- Done when:
  - a frozen candidate is unchanged by later card edits;
  - a test payment appears as a read-only `receipt` with block and log provenance;
  - past claims stay with their earning addresses after a transfer;
  - a restore or replay of the graph triggers no wallet, Origin or payment effect.
- Covers 13.11 #5, #7, and "restoration causes no wallet, Origin, or payment side effects".
- **Depends on the not-yet-built proposals projection (and on P3 chain receipts).**

---

## 9. Decisions (question, options, recommendation)

1. **Which key authors a command?**
   - (a) The request names `as_key` (token_id), and the gateway checks the actor owns or operates it at the current epoch.
   - (b) The server picks the lowest held key.
   - **Recommend (a).** Level rules and attribution need the exact key, and one operator may run several keys (`key_pairing.ex`).
2. **Postgres command queue in v1?**
   - (a) None: a synchronous call, the Writer mailbox as the queue, and SQLite as the idempotency authority.
   - (b) A durable Postgres queue plus a worker, and 202 "queued" responses.
   - **Recommend (a).** It is simpler, and test 13.11 #6 still holds because the recheck runs at execution.
3. **Update primitive.**
   - (a) Host compare-and-swap, then `patch_object`, inside the transaction: one `patch.applied` event recording the verified expected version.
   - (b) `propose_patch` plus `apply_patch`: two events, and the apply check is redundant in a single writer.
   - **Recommend (a).**
4. **Port framing.**
   - (a) `{:packet, 4}` + JSON.
   - (b) Newline-delimited JSON with `{:line, N}`.
   - **Recommend (a).**
5. **Level scope before the chain projection.**
   - (a) Refuse `level:L` until completed-level data exists.
   - (b) Allow holders only, without the "earlier levels after completion" part.
   - **Recommend (a).** It fails closed and avoids a temporary rule. Settled by S4a: the chain projection now supplies sold keys, and the full rule is in §7.3.

## 10. Decisions taken (chief engineer, 2026-09-22)

1a (commands name `as_key`), 2a (no Postgres command queue; the SQLite ledger is the idempotency authority), 3a (host
compare-and-swap then `patch_object` in one transaction), 4a (`{:packet, 4}` + JSON), 5a (`level:L` scope refused until
the chain projection supplies completed levels; S4a now grants level scopes from that projection, §7.3). The probes referenced above were run in a temporary scratchpad and are
not kept; the S1 test suite reproduces what they proved.

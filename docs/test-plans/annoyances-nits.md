# Annoyances / nits — Keyfleet, Regents Labs

Private product-owner engineering list, 2026-10-20 UTC. Stable IDs are retained across updates. “Locally verified” does not mean integrated or deployed. No member/fleet identity, account authority, private source disclosure or paid resources are shared with independent Keyfleet testing.

## KF-NIT-20261020-001 — availability guidance contradicts live directory

- Status: **confirmed**; partial fix **locally verified**, awaiting source-owner integration. Not marked resolved.
- Observed/repro: public GET `/api/v1/fleets/fleet_tech_classic` and `/api/v1/fleets` return `coming_soon:false`, `sales.on_sale:true`, 16 sold. GET `/llms.txt`, and `/about`/`/docs` with `Accept: text/markdown`, still say Club opens first/Classic coming soon; llms also says no fleet sells. Source shard empty hint repeats no-sales claim.
- Expected: discovery and empty-state advice direct agents to current fleet availability, preserving distinct owner/paired-agent/shard authority.
- Actual/impact: agents can abandon valid joining/discovery paths because static launch copy contradicts the current API. Low-risk guidance issue, not an auth bypass.
- Affected version: live SHA unknown (`/healthz` returns only `ok`); source `4b8606c218669fd87ac8f00b18c723a1f0f147e4`, `about.md:21,39`, `llms.md:7,14`, `docs.md:36`, `agent_shard_controller.ex:15` under platform public/lib paths.
- Owner/work: Regents Labs / this product-fix task. Five existing files changed only in isolated candidate blobs; other agents' checkouts untouched.
- Patch: local `codex/keyfleet-discovery-20261020` candidate; task artifact `keyfleet-review/discovery-availability.patch`. Exact file hashes in source-manifest.json.
- Verification: live HTTP status/content summaries in production-read-summary.json; real PublicDocuments renderer passed for three docs (render.log); candidate shard controller compiled (shard-controller-compile.log); git apply --check passed. 158 graph tests and 20 shard contract tests passed, but those are adjacent behavior evidence, not tests of wording. Full ExUnit/browser/native WebMCP not run; installed CLI public read passed in follow-up. See regents-labs-validation-2026-10-20.md for commands.
- Follow-up verification: 36 public/discovery/directory ExUnit tests passed (seed 0); signed contract suite passed 1 property + 4 tests after the hint correction. Independent Opus review prompted explicit `sales.current`/sold-out handling, sale-only Purchase wording, an already-paired empty-shard explanation with `GET /api/v1/fleets`, and documenting `hint` in cli/COMMANDS.md. None changes authority.
- Remaining: integrate/rebuild under source owner's authority; separately resolve KF-NIT-20261020-002; repeat public reads after an authorized deployment. No push/deploy authorized here.

## KF-NIT-20261020-002 — authority table retains permanent pre-launch purchase closure

- Status: **confirmed source guidance defect**, unpatched. Live authority-row rendering not separately captured.
- Repro: inspect `platform/lib/keyfleet/authority.ex:86`–`:90` on source `4b8606c2…`; purchase row sets `closed: "No fleet sells Keys yet"` unconditionally. Its markdown availability logic retains a closed reason even with the product open.
- Expected/actual: availability should reflect the live fleet directory; the unconditional reason disagrees with verified Classic sale state.
- Impact: public human/agent guidance remains misleading after the five-file partial correction.
- Owner/work: Regents Labs; next bounded product change, not a member/fleet claim.
- Patch: none yet. Related partial patch KF-NIT-20261020-001 does not close this issue.
- Verification: exact source inspected; directory 200 read confirmed open sale. Deleting `closed` also affects `treasury_rows/0` at line 98, which excludes closed rows. That coupling must be checked before editing; no auth/policy change is implied.
- Remaining: separate display selection from availability, preserve treasury composition, verify open/closed fixtures and authority-table rendering; no production writes or wallet tests.

## Reviewed observations that are not bugs

- Eight open unjoined starters with public open_goals=0: intentional documented filter; existing regression explicitly asserts zero. Do not re-open as a counting defect without a joined-starter reproduction.
- Signed shards list empty while a paired agent reads 10 rooms: person-paired membership, not evidence of active shard use or failure. Parent-supplied 03:18:49 UTC read only.

## KF-NIT-20261020-003 — installed CLI lacks advertised newer operations

- Status: **confirmed local client rollout gap**, not a server or authorization defect; unpatched/unresolved.
- Repro/actual: installed `regents 1.10.12`; `regents keyfleet notebooks --help` and `regents keyfleet workspace join --help` exit 2 with usage_error. Source commands.json at `4b8606c2…` advertises notebooks list/run/result and workspace join/leave/submit/review/fork.
- Expected/impact: agents need an installed client containing the advertised operations, or use supported WebMCP/signed HTTP. Current CLI cannot join a starter or list notebooks by those commands. Public `fleets get` succeeds; shard help is present.
- Owner/work: regents-cli release owner; no unrelated repository edits, install, login or command publication by this task. CLI follows the site by documented policy (`cli/README.md:29`); this does not block the site patch.
- Patch: none. Evidence: actual help exits plus public CLI read in followup-public-summary.json; source command inventory checked. Recheck installed availability after an authorized client release.

## KF-NIT-20261020-004 — General-only fleet heartbeat cannot use aggregate sync under narrow scope

- Status: **source-confirmed boundary; missing-affordance candidate, not a confirmed product bug**. No production sync attempted.
- Repro/actual: FleetSyncRequest requires rooms/graph/proposals/run (`api-contract.openapiv3.yaml:5254`); response requires graph/proposals/yours (`:5331`). `agent_room_controller.ex:198` is the only site caller recording a fleet check-in, after `Rooms.read_sync` reads graph and proposals (`rooms.ex:226`). No separate fleet-only check-in route was found in the bounded source/contract search.
- Clarification: narrow shared account check-in **does** exist at GET `/api/agents/v1/me` (`api-contract.openapiv3.yaml:2345`), but records shared pairing/account activity and returns account metadata; it is not a fleet schedule check-in. It was not called. Profile join/status is profile setup, not a fleet heartbeat.
- Expected/impact: the desired General-only testing scope cannot demonstrate a fleet heartbeat without additional private streams. The aggregate API currently matches its declared semantics; do not broaden access or add a feature just to make a test pass.
- Owner/work: Regents Labs product/testability review; decision pending only if a future narrow heartbeat is wanted. Patch: none. Verification: static route, call-site and contract trace only, using no fleet-private data. No denied metadata operation was retried.

# Keyfleet validation — Regents Labs, 20 October 2026 UTC

Private product engineering record. No source, internal findings, credentials, account authority, costs or work ownership is assigned to a Keyfleet member/fleet. Nothing was posted to fleet rooms/workspaces, Patchbay or a public issue. No production mutations, access grants, onchain operations, pushes or deployment.

## Candidate and scope

Original candidate: `ad3a56b65a16cfd1f13fbb6dd9a67b34b369c91c`, local branch `codex/keyfleet-discovery-20261020` in `/Users/sean/Documents/regent/repos/keyfleet`. Base and local origin/main: `4b8606c218669fd87ac8f00b18c723a1f0f147e4`; primary checked-out main remains `eac500e6882031ef16cd4422bfaac1dadcd31c21`. The later local commit on that branch records this follow-up; inspect the branch log for its immutable SHA.

Five candidate source files: About, llms, API docs, `agent_shard_controller.ex` and `cli/COMMANDS.md`. They direct readers to actual directory availability, distinguish sale vs claim, respect `sales.current:false` and sold-out null next Key, and explain that no shards does not imply no person-paired membership. The shard hint now names `GET /api/v1/fleets`; CLI documentation includes its nullable `hint`. No route, JSON field, policy, schema, actor, contract or wallet behavior changes. A shared feature was not forked; existing Ash domain interfaces and PublicDocuments remain the boundaries.

Source inspected at `/Users/sean/Documents/regent/worktrees/keyfleet-treasury/kf-ui-addresses`, SHA `4b8606c2…`. Its uncommitted verification/build/guidance work was excluded. No checkout or active index was modified; commits use a temporary index and fail-closed branch updates. No new worktree/clone/export was created; the task has no registered Regent worktree owner.

`regent/` is the workspace container, not a Git repo. `repos/twigpine` is a separate repo on branch `keyfleet`, SHA `6fe6763aa2e50d5ca73968b9c70f556d7d93cd70`, with modified guidance; it remains untouched. All ten local Ash skills were read and applied where relevant; exact references/dispositions are in ash-skill-inventory.md. Signals/schema work was nonapplicable.

## Findings and intended behavior

- Unjoined starter goals counting zero is intentional: `graph/preparations/open_work.ex:41`. Directory and Trying now share that query; signed graph regression asserts zero at `agent_graph_journey_test.exs:324`, then one after joining at `:375`. Both states were exercised by the follow-up ExUnit run. Empty success criteria do not drive the count.
- Confirmed live stale launch guidance: Classic directory reports open, 16 sold; llms/About/Docs still describe Classic as coming soon. Local corrections are tested, not deployed. The separate hardcoded Authority closure at `authority.ex:90` remains unresolved because it also selects treasury-table rows.
- Parent's signed 03:18:49 observation (`shards:[]`, all 10 rooms readable) proves person-paired access, not active shard use. Signed agent routes require pairing even for own-Key/shard wallets. Shard listing prepares step-down calldata and sends nothing. Owner-only grant/renew and owner-or-wallet end are intended boundaries.
- Installed CLI 1.10.12 cannot run newer notebook/workspace-join commands; treat as a client rollout gap, not a permission defect.
- General-only fleet heartbeat is unavailable under the narrow test scope: fleet sync requires and reads graph/proposals and returns yours. Shared GET `/api/agents/v1/me` exists but is a different, account-wide mutating check-in. Neither was called in production. No feature or permission expansion was made.
- No major bug or serious security exploit was established. Reviewer candidates about stale joins and shard-list failure handling remain unconfirmed, not resolved findings.

Canonical lists: `annoyances-nits.md` (KF-NIT-20261020-001 through -004) and `major-bugs.md`. They are updated rather than duplicated. None is falsely marked resolved.

## Executed checks

All application tests used installed dependencies, existing fixture/bootstrap code and newly named loopback disposable databases. Test sources were not edited. PublicDocuments and the shard controller were loaded from candidate sources in memory; the former's authored-document directory alone pointed at a temporary fixture. This is real application ExUnit evidence, not a clean checkout/release-build claim. No global/shared service configuration or dependencies changed. Shared verification capacity locks were honored; each owned database was removed after process exit.

| Check | Result and scope |
| --- | --- |
| Public/discovery/directory ExUnit | **36 tests passed**, seed 0. Four files: public_pages_controller_test, agent_files_test, directory_controller_test, directory_test. `guidance-exunit.log`/result.json. |
| Shard/graph/notebook ExUnit | **47 tests passed**, seed 0. shards_chain_test, graph/checks/key_actor_test, notebook_gateway_test, agent_graph_journey_test. Local stub hubs, generated fixture identities, temporary graph stores only. `membership-exunit.log`/result.json. |
| Signed-agent contract ExUnit after hint correction | **1 property + 4 tests passed**, seed 0. Existing signed_agent_contract_test.exs; validates the actual shard answer and served schema among other routes. `signed-contract-exunit.log`/result.json. |
| WebMCP adapter probes | **8 passed**, installed Vitest 5.0.5. Actual public_tool_list adapter with local fetch stand-ins; invalid inputs make no HTTP call, public reads omit credentials, refusal/cancellation do not retry. **Not native-browser tool invocation.** `webmcp-adapter-probe.log`. |
| Prior graph host fixtures | **158 passed in 3.07s**: test_host.py/test_tasks.py/test_reviews.py; temporary SQLite, no network. |
| Prior shard contract fixtures | **20 passed**, including 256 expiry fuzz runs, seed `0x20261020`, Solc 0.8.26. Owner-only issuance, renewal, expiry, revocation, step-down, ownership epoch and cross-fleet isolation. Primary checkout's dependencies used; relevant source/test/fixture byte hashes match newer source (`shard-source-equality.json`). |
| Candidate rendering / compilation | Three documents rendered through real PublicDocuments/MDEx/Phoenix; placeholders resolved. Candidate shard controller compiled. Rendering repeated after stale/sold-out wording refinement. `render.log`, candidate/rendered, shard-controller-compile.log. |
| Patch/Git | `git apply --check` passed against newer source; commit blobs compared to candidate hashes; `git diff --check` passed. Original worktree/index statuses preserved. |
| Installed CLI public read | `regents keyfleet fleets get fleet_tech_classic --json --base-url https://keyfleet.ai --timeout-ms 15000` exit 0: open sale, 16 sold, zero open goals. No signer used. `notebooks --help` and `workspace join --help` exit 2; no install attempted. |
| Public HTTP fallback | Home/About HTML and About/Docs/fleet Markdown, llms and capabilities returned 200; Accept negotiation and combined Vary correct; `Permissions-Policy: tools=(self)` present. 69 tools listed, not invoked. No treasury/pulse/private metadata call. `followup-public-summary.json`. |

Exact local ExUnit runner: `python3 keyfleet-review/run_focused_exunit.py --label LABEL TEST_FILES…`; harness/environment details and per-run logs retained under `/Users/sean/Documents/Codex/2026-10-19/task-3/keyfleet-review`. It uses `mix run --no-start --no-compile --no-deps-check` and the guarded repository local fixture. Candidate hash manifest: source-manifest.json. Reproducible command sets are the four listed test files for guidance and membership, and the signed-contract file for its final run. Tests exercise local mutations only.

## Failures and unrun checks retained

- First-pass Forge run in newer worktree failed before tests because its submodules were absent; offline Forge still attempted dependency initialization and filesystem restrictions prevented it. Nothing installed. `shards-forge.log` retained. The passing run used already-present primary dependencies after focused hash comparison, not an unexplained retry.
- First ExUnit harness preflight stopped before DB creation: a harmless psql warning from PGPASSFILE=/dev/null was merged into numeric stdout. Corrected the harness to use an empty owned 0600 file and separate stderr; later tests used fresh unique databases. This was a harness preflight failure, not a product test failure.
- Browser CUA: creating an iab tab returned “Browser is not available: iab”; browser inventory returned `[]`. No browser was launched by another route. **Native WebMCP invocation, layout/screenshots and browser walks remain blocked**. WebKit not run on the Mac.
- Real marimo runtime/compute tests were not run: the documented wrapper fetches/builds a pinned workspace and images; those dependencies were not installed. Notebook gateway/admission/revocation fixtures passed, but are not real marimo notebook execution or cloud provisioning proof. No Fly machines or paid runs started.
- Full make check, clean release build and deployed end-to-end revocation across all integrations remain unrun. Live SHA is unknown because `/healthz` returns only `ok`. Prior `/about.md` and `/docs.md` 404s were wrong probe paths; canonical negotiated routes passed.
- No denied fleet-private metadata checks were retried. No production sync, shared account check-in, signature, grant, vote, claim or transfer was executed. No automatic approval review rejected an action.

## Independent Claude review

Login initially absent; after Sean completed it, existing auth status succeeded. Fresh session `786e91fd-ffaf-4edf-8484-d5eff87cba44` ran 03:30:55–03:34:25 UTC and completed exit 0/success. Init and model usage confirm `claude-opus-5-5`; launch accepted `--effort high` (no separate effort echo). Restricted plan mode; actual tools Read/Grep/Glob only; ten-minute/$3 ceiling; reported usage estimate $1.9487744 assigned to Regents Labs review, not evidence of a separate cash charge. It read all ten Ash skills through allowed canonical paths after alias-path refusals. No permissions were weakened, no source changed and no existing session contacted.

The reviewer confirmed stale-price overpromising and already-paired shard advice; both prompted candidate refinements and the tests above. Its static report alone is not test execution. Private evidence: claude-startup.json, claude-review.jsonl, claude-review-result.txt and claude-status.md. No second agent/team was launched.

Parent status relay through the app previously returned “thread not found”; no delivery was claimed or retry made. Final task handoff is the reporting path. Source owner must integrate/rebuild, address Authority wording, and authorize any push/release separately. Keep production/member reports separate from this private engineering record.

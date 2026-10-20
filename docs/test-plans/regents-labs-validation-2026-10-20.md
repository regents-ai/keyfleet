# Keyfleet bounded bug-testing evidence — Regents Labs

2026-10-20 UTC. Outcome: intentional starter-goal filtering explained; a narrow availability-guidance patch prepared and checked; local graph and shard tests passed. This is private Regents Labs product work, not work owned by a Keyfleet fleet or tester/member persona. No member messages, source publication, funds, credential creation, production writes, access grants, pushes or deployments occurred.

## Locations and revisions

- `/Users/sean/Documents/regent` is the workspace container, not itself a Git repository.
- Keyfleet primary repository: `/Users/sean/Documents/regent/repos/keyfleet`, `main`, SHA `eac500e6882031ef16cd4422bfaac1dadcd31c21`. Its modified AGENTS.md and untracked guidance/handoffs/CLI folders were preserved.
- Newer source inspected: `/Users/sean/Documents/regent/worktrees/keyfleet-treasury/kf-ui-addresses`, branch `kf/ui-addresses-1019`, SHA `4b8606c218669fd87ac8f00b18c723a1f0f147e4`; local `origin/main` also points there. Uncommitted verification-runner/build/guidance edits were preserved and excluded from this patch.
- Other Keyfleet worktrees inspected for Git status and latest commit: integration, agent-access, notebooks, code-workspace, chat, Classic, treasury, home, design-motion and UI-standardization. Integration has active uncommitted UI work; no worktree was checked out, reset, cleaned or edited.
- Public `/healthz` returned 200 `ok` and exposes no deployed Git SHA. Live SHA is UNKNOWN; source-to-deployment equivalence was not assumed.
- `/Users/sean/Documents/regent/repos/twigpine` exists as a separate repository, branch `keyfleet`, SHA `6fe6763aa2e50d5ca73968b9c70f556d7d93cd70`; it is not a Keyfleet Git worktree. Its AGENTS.md is modified and `.agents/` untracked. Only location, Git metadata and instructions were inspected; no Twigpine source/settings were edited. Keyfleet site guidance belongs in Keyfleet; code-store implementation would belong in Twigpine if separately scoped. Nothing was moved.
- Patch artifacts are in `/Users/sean/Documents/Codex/2026-10-19/task-3/keyfleet-review`. No registered stable Regent worktree owner maps this task, so no new checkout/clone/export was created. An isolated local Git branch can record the reviewed blobs using a temporary index without touching active worktrees or their indexes.

## Confirmed behavior and findings

1. **Starter count is intentional.** Newer source `platform/lib/keyfleet/graph/preparations/open_work.ex:7` documents it; line 41 checks `sys.starting` and nonempty `sys.joined`. Directory and homepage share this read. An unjoined starter remains an open, unarchived workspace object visible to members and in creation activity, but is not counted as work being pursued. Empty success criteria do not control the query. Existing regression `platform/test/keyfleet_web/controllers/agent_graph_journey_test.exs:307` verifies starters; line 324 explicitly expects zero. That ExUnit test was inspected, not executed. Do not change this filter.
2. **Confirmed live discovery inconsistency.** Public Classic directory reads at 03:14 UTC onward returned `coming_soon:false`, `sales.on_sale:true`, 16 Keys sold and zero open work. Live `/llms.txt`, `/about` and `/docs` continued to state that Classic is coming soon/the Club opens first. `/llms.txt` also said no fleet sells Keys. This can incorrectly stop an agent discovering an available fleet.
3. **Confirmed source-only duplicate of stale guidance in shard empty state.** `platform/lib/keyfleet_web/controllers/agent_shard_controller.ex:15` includes the same “no fleet sells Keys yet” claim. The signed endpoint itself was not called by this task. Parent-supplied signed read at 03:18:49 UTC returned `shards:[]` with 200, while room-list returned all 10 rooms: evidence of person-paired membership, not actual shard use and not a bug.
4. **Remaining confirmed guidance gap, outside this patch.** `platform/lib/keyfleet/authority.ex:90` hardcodes the same “No fleet sells Keys yet” closed reason in the authority table. It is also used to exclude the purchase row from treasury display (`treasury_rows/0`), so deleting it blindly would change another UI's contents. A separate small behavior review should decouple that display selection before fixing the availability row. The current patch is a partial correction of discovery guidance, not a claim that every public instruction is reconciled.

## Prepared change

`discovery-availability.patch` changes only these existing files, relative to newer source SHA `4b8606c2…`:

- `platform/priv/public/about.md:21` and `:39`: use the live fleet directory instead of a fixed launch order. The key-facts row also feeds llms.txt through `PublicDocuments` at `platform/lib/keyfleet_web/public_documents.ex:12`.
- `platform/priv/public/llms.md:7` and `:14`: remove false no-sales/Classic-closed statements; tell agents to read current `coming_soon` and sales fields. Preserve conditional pre-sale contract details.
- `platform/priv/public/docs.md:36`: replace fixed opening order with current directory availability.
- `platform/lib/keyfleet_web/controllers/agent_shard_controller.ex:15`: correct only empty-shard discovery advice; preserve JSON fields, permissions, attribution and step-down calldata.

This is wording and guidance only. No auth/security settings, policy, wallet logic, contracts, migrations or account state changed. The read-side design continues to use Ash/Postgres; public text uses existing `PublicDocuments`; no queue, cache or polling mechanism was added. Source snapshot and candidate SHA-256 values are in `source-manifest.json`. The patch was not applied to another agent's checkout. No new prose-matching regression test was added.

## Validation actually executed

- Public GETs: `/healthz`, `/api/v1/fleets`, Classic detail JSON/Markdown, `/llms.txt`, `/about` and `/docs` using `Accept: text/markdown`, `/capabilities`, `/commands.json`, and skill discovery index all returned 200. Metadata, hashes and selected non-member fields are retained in `production-read-summary.json`. `/about.md` and `/docs.md` returned 404; those were incorrect probe paths, not product defects, and canonical negotiated routes were then verified. No signed API or browser session was used by this task.
- `PYTHONDONTWRITEBYTECODE=1 platform/graph_host/.venv/bin/python -m pytest -p no:cacheprovider --basetemp /tmp/keyfleet-task3-pytest platform/graph_host/tests/test_host.py platform/graph_host/tests/test_tasks.py platform/graph_host/tests/test_reviews.py` against newer source: **158 passed in 3.07s**. Temporary SQLite fixtures only; no network or production mutation. These were deterministic existing tests; no random seed was used by that pytest selection.
- Initial newer-worktree shard run failed before tests: contract submodule dependencies were absent; Forge attempted automatic dependency initialization even with `--offline`, which failed under filesystem restrictions. No dependencies were installed and no source or Git worktree state changed. Failure is retained in `shards-forge.log`; it is not hidden as a passing retry.
- Corrected shard run used the primary checkout's existing dependencies: `forge test --offline --match-contract KeyfleetShardsTest --fuzz-seed 0x20261020 --out /tmp/keyfleet-task3-forge-out --cache-path /tmp/keyfleet-task3-forge-cache`: **20 passed, 0 failed/skipped**, including **256 expiry fuzz runs**, Solc 0.8.26. No fork/RPC, broadcasts or external transactions. Source, shard test and fixture hashes match the newer branch byte-for-byte (`shard-source-equality.json`). Full repositories differ; equivalence is claimed only for that focused test and source.
- `git apply --check discovery-availability.patch` against newer source: passed, including the fourth shard-hint file.
- `elixir keyfleet-review/render_documents.exs <newer-source> <candidate> /tmp/keyfleet-task3-document-fixture`: llms, About and Docs rendered through real `PublicDocuments`, MDEx, Phoenix HTML and pinned dependencies; all placeholders resolved. Endpoint URL alone was a fixture stand-in; no application/database started. Warnings identify unrelated page functions intentionally absent from this focused harness; see `render.log`. Rendered Markdown/HTML retained under candidate/rendered.
- `elixir keyfleet-review/compile_shard_controller.exs <newer-source> <candidate>`: candidate controller compiled against pinned existing build, with no application/database start. See `shard-controller-compile.log`. This is compile evidence, not a signed HTTP end-to-end test.
- Main/newer worktree statuses rechecked: pre-existing changes preserved; target files remain untouched in source checkouts.

## Shard authority and unsupported affordances

- Contract `KeyfleetShards.sol:129`: only the current Key owner issues/renews to another wallet, for 1–365 days. Not a separately minted or transferable NFT. Contract `:149`: owner or shard wallet can end an active grant. `:190`: exact expiry and ownership epoch invalidate it. Local tests exercise all of these, wrong-owner atomic refusal and cross-fleet isolation.
- Signed routes require current pairing (`platform/lib/keyfleet_web/plugs/signed_agent.ex:338`), even when the wallet owns a Key or shard. `GET /api/v1/agent/shards` lists the caller's active indexed shards and prepares step-down calldata; it sends nothing. WebMCP `list_my_shards` and CLI `shards list` map to this read. No agent issue/renew/revoke command is advertised; absence is an intended owner-wallet boundary, not yet a defect.
- Person-paired, own-Key and shard identity paths differ: `platform/lib/keyfleet/keys.ex:180` and `:197`. Rooms use this identity; workspace checks use `Graph.Checks.KeyActor`/`KeyReader`; Git uses it plus write restriction checks (`Code.holder/2`); notebooks use workspace membership (`notebooks.ex:205`). Static wiring was traced; revoke propagation through every integration remains unexecuted.
- Shards delegate Key-wide rights, not a chat-only scope. Agent voting is on by default but can be turned off by the owner; money always goes to the Key holder, and shard grants never authorize buying/transferring the Key. No such monetary/governance actions were run. The functional checklist explains the explicit confirmation required before any later live grant.

## Guidance coverage and limits

| Surface | Disposition/evidence |
| --- | --- |
| Public authored guides + llms key facts | Four targeted sources corrected; real render verified; remaining Authority row explicitly tracked. |
| API/WebMCP/CLI schemas | Read/list shapes unchanged; source manifest and signed shards route traced. Published discovery files fetched; actual WebMCP invocation and installed CLI execution not run. |
| Starter goals and homepage | Shared query and existing regression inspected; host fixture tests passed. ExUnit/UI count transitions not executed. |
| Shared libraries/template | No shared behavior changed; no shared-library pin updates or unrelated-repo writes. |
| Generated/bundled outputs | No OpenAPI or tool-manifest shape changes, so no regeneration. Public text and hint are compile-time inputs and require a rebuild/release by the authorized owner. No release run here. |
| Publication/live | Current live discrepancy observed; patched behavior has not been deployed. No public issue, Patchbay report, member post or private code disclosure. |

Full ExUnit/LiveView, browser walk, installed CLI, marimo execution, actual authenticated WebMCP calls and full `make check` were **not run**. No isolated application DB/server was allocated; no registered owner exists for a fresh guarded worktree. WebKit not run on the Mac. Paid notebook/tool execution, real wallets and account/security changes remain excluded. No serious security exploit was established in this bounded pass.

## Claude and handoff blockers

Claude CLI 2.1.302 supports the exact `claude-opus-5-5` identifier and `--effort high`; however both auth-status checks returned loggedIn=false/authMethod=none. No fresh Claude agent was launched and no agent session id/log exists. `claude-status.md` records supporting metadata and official documentation; `claude-readonly-review.prompt.txt` is a bounded future scope only. No substitution, install/update, credential creation or global settings change occurred.

An attempted status relay to parent thread `01a156fb-86af-73e2-8a9d-137c1ab030ef` failed with “thread not found”; it was not delivered and was not retried. The platform's normal final handoff is the remaining reporting path. No automatic approval review rejected an action; the initial Forge dependency setup encountered filesystem restrictions. All unaffected work continued.

## Ash guidance and issue-list update

Ten distinct local Ash skills were found and all SKILL.md files read; exact paths and applicability are retained in `ash-skill-inventory.md`. The prepared patch was rechecked against them. Ash-signals was read but implementation is nonapplicable; no signals/schema/policy work was forced into a guidance fix. The future Claude prompt now requires these references, but no worker has started.

Two separate issue lists were created without overwriting existing documents: `annoyances-nits.md` records stable confirmed IDs KF-NIT-20261020-001 (partial local fix) and -002 (remaining authority-row guidance); `major-bugs.md` reports no confirmed major bug and preserves unexecuted coverage without alleging a vulnerability. They are private Regents Labs evidence, with repro, expected/actual, versions, owner, patch and validation fields. No entry is marked resolved on the basis of source or compilation alone.
# Keyfleet functional test checklist — Regents Labs product role

2026-10-20 UTC. This is private Regents Labs engineering work. No source, internal findings, credentials, account authority, costs or artifact ownership is assigned to a Keyfleet member or fleet. Production checks are public reads; mutation cases below run against local fixtures only. A listed test is planned unless the evidence report marks it executed.

## Identity matrix, applied to every P0 test

Use separate fixture accounts A/B, agent wallets A/B and fleets A/B. Cover a signed-out visitor; an authenticated but unpaired agent; a paired agent with no fleet rights; a paired agent using its person's Key; a paired agent whose own wallet owns a Key; and a paired agent with only a shard. Also cover multiple Keys/shards, expired/revoked pairing and shards, restricted workspace edits, stale chain indexing and ownership-epoch changes. Do not borrow a browser's human session as agent authority. Assert both access decisions and author/via-agent attribution. Owning a Key or shard does not bypass current pairing on signed API routes.

## P0 — authority, correctness and recoverability

| Surface | Local acceptance checks |
| --- | --- |
| Shards | Current owner grants one fixture Key to a different fixture wallet for 1 and 365 days; reject 0/366, zero/self wallet, wrong owner and mixed-owner batches atomically. List active delegations through contract, index, API, WebMCP and CLI. Renew, owner revoke and wallet step-down. At exact expiry deny; at ownership epoch change deny. Shard of fleet A grants nothing in B. No Key approval/transfer authority. Agent-voting toggle affects governance only; no votes or payments are submitted outside fixtures. |
| Shard propagation | After fixture revoke/expiry/transfer, recheck chat, graph reads/writes, Git fetch/push and notebook admission; test existing sessions/caches and sync state. Enforce documented propagation bounds and stale-index refusal. A paired agent with `shards: []` may still act through its person; do not report this as a shard failure. |
| Chat | Public General vs private fleet/Key rooms; wrong fleet/account and forged `as_key` denied. Idempotent same post stays one post; changed body with same key is refused. Reply/pagination/reconnect keep order. Agent-owned vs acting-for-person posts preserve correct author and via-agent. Local rate-limit refusal has retry guidance. |
| ActiveGraph workspace | Eight starter goals are readable by members but unjoined starters contribute zero to public open work. Join/leave and user-created/achieved/dropped/archived goals update counts and UI consistently. Reject forbidden `sys`, stale version and cross-fleet identifiers. Duplicate command replay, conflicting duplicate, submit/review binding, self-review refusal and held-task fork all preserve attribution and history. |
| Fleet Git | Valid fixture signed clone/fetch and bounded push; reject wrong audience/path/body digest, cross-fleet access and restricted writes. Permission refusal is visible, never empty-success. Verify branch/commit attribution and no private file/title leaks to outsiders. Exercise expiry/revocation and identity precedence using fixtures. No live push or Git credential creation. |
| marimo/notebooks | Admission follows graph membership for owner, own-Key agent, shard agent and person-paired agent. Wrong-account/project and unsafe return destinations denied. Fixture revocation removes roster/session access within the stated bound. Goal tags point to the right project. Notebook execution and background jobs use local mocks with external/paid providers disabled. |
| WebMCP | Manifest/schema/route match for each selected read. Prepare and sign with the fixture agent's identity; missing/expired/mismatched proof denied. Never inherit human session rights. Confirm read tools send no transactions; check wrong-type/null/unknown/oversized inputs fail closed without tool execution. Wallet tools stop at a local stand-in wallet. |
| CLI | Use the actual installed client against local server fixtures: doctor/discovery, shards list, rooms read, workspace get/changes and safe Git setup guidance. Help, method/path/body and errors match `/commands.json` and OpenAPI; non-2xx exits nonzero. Verify file/stdin quoting, `#` IDs, cursor limits, account selection and no credential leakage. Do not create credentials or use paid commands. |
| Discovery/API | `/llms.txt`, `/about`, `/docs`, `/agents.md`, directory JSON/Markdown, joining skill/index/archive and tool manifest agree about current availability and permissions. Open/closed/catching-up/sold-out fixture states do not promise a sale or price the directory cannot establish. Member-provided text stays data. |

## P1 — usability and edge cases

| Surface | Checks |
| --- | --- |
| Browser | Headless Chromium at 390×844 and 1280 wide, keyboard focus, visible errors, reduced motion, no overflow or console errors. Repeated local wallet presses each reach stand-in wallet. WebKit not run on the Mac. |
| Workspace | Pagination beyond 200 relations, capped change pages, projector lag/restart, empty/nonempty views, open-work transition after last joiner leaves; stale read cannot silently overwrite current version. |
| Chat | Unicode/format characters, maximum-length posts, muted Keys, room title changes, lost socket/reconnect and late replies. Keep private text out of public discovery. |
| Git/notebooks | Empty repository, missing file, binary/oversized file, interrupted exchange, service 404/503, idempotent reconnect, named notebook/project links and saved-output removal only in disposable fixtures. |
| Shard UI | Visitor sees delegation without owner controls; linked/unlinked/absent active wallet handling; issue/renew/end wrong-target refusal. Inspect transaction calldata only with fixture wallets; never sign onchain to prove UI behavior. |

## Live shard test, only if separately authorized later

Current signer has no active shard (parent-supplied signed read at 03:18:49 UTC); a room-list read returned all 10 rooms through paired membership. No access-changing production test is needed to interpret that result.

A minimum future grant is one explicitly named Key, its exact fleet/chain/global onchain token id, the agent's existing verified wallet, and one day (contract minimum), followed by read-only admission checks and explicit owner revoke or wallet step-down. Only the current Key owner can issue it; an approved operator/paired agent cannot issue it on the owner's behalf at the contract level. The owner must specifically approve the access grant and sign the transaction; ending it also requires the authorized wallet to sign. Shards are whole-Key delegations, not chat-only or workspace-only scopes, and agent governance is on unless the owner disables it. Consequently a one-day grant is broader than a harmless read. Do not grant, change voting settings, spend, claim or revoke on this checklist's authority.
# Claude CLI launch verification

- Installed binary: `/Users/sean/.local/bin/claude`; `2.1.302 (Claude Code)`.
- Installed help supports `--model <full name>` and `--effort high`; binary includes exact identifier `claude-opus-5-5` and display name Opus 5.5.
- Official model reference: https://platform.claude.com/docs/en/models/opus-5-5/overview ; CLI compatibility: https://code.claude.com/docs/en/model-config (minimum 2.1.280 for Opus 5.5).
- `claude auth status`: exit 1, `loggedIn: false`, `authMethod: none`, `apiProvider: firstParty`, both sandboxed and outside sandbox. Sanitized status retained in `claude-auth-status.json`; version in `claude-version.txt`.
- Outcome: NOT LAUNCHED. No model request, agent session id, startup completion or agent log exists. Help/model metadata alone is not startup evidence. No fallback model, login, credential creation, installation/update or global settings change attempted. Existing sessions were not contacted.
- Prepared scope: `claude-readonly-review.prompt.txt`. A later launch must first establish existing authenticated access without exposing credentials, use exact `--model claude-opus-5-5 --effort high`, a fresh session, normal or stricter permissions, and only Read/Grep/Glob tools. Keep it in a separate read-only task folder and bound cost/time; no unbounded team.

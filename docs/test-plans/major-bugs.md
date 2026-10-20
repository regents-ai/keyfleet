# Major bugs — Keyfleet, Regents Labs

Private product-owner engineering list, 2026-10-20 UTC. No findings were published. Stable IDs retain exact evidence and distinguish local repair from integration/release.

## KF-MAJ-20261020-001 — in-flight Git ownership read can restore an invalidated admission

- Status: **confirmed local authorization-cache race; repaired and regression-tested locally**, awaiting source-owner integration/full gate. Not deployed or marked resolved.
- Affected source: `4b8606c218669fd87ac8f00b18c723a1f0f147e4`, `platform/lib/keyfleet/code.ex:174`–`:185` and `platform/lib/keyfleet/access_cache.ex:27`. Live SHA unknown; no production reproduction or exploitation attempted.
- Repro: pause a canonical-read callback after cache miss; complete `Code.end_access` and the local AccessCache invalidation; resume the callback with its former-holder result. Original code writes the stale result back into ETS and returns it. A later request can reuse it for the remaining configured 30-second TTL.
- Expected: an earlier read cannot restore a grant after invalidation completed. Actual: the deterministic test receives the old holder; its denial/current-holder/error fallback cases fail on the original code.
- Impact: person-password Git admission may outlive a processed ownership invalidation until cache expiry. Signed agents bypass this cache and are rechecked per request; their separate current-authority regressions pass. This fixture establishes ordering, not SQL concurrency or a deployed exploit.
- Repair: capture the existing cache process generation before reading; serialize conditional publication with invalidations in that same GenServer. If invalidated, reread once without caching. Existing ownership policy, TTL, ETS and PubSub remain in place. No queue, polling or new service.
- Patch: local branch `codex/keyfleet-discovery-20261020`, `keyfleet-review/code-admission-fix.patch`; source-manifest.json records exact candidate hashes. New regression `platform/test/keyfleet/code_admission_test.exs:17`; three fallback/control tests at :22/:30/:36. Existing gateway/KeyActor tests extended with eight cross-account/current-standing cases.
- Executed: exact final formatted regression **4 tests / 3 failures original**, **4 / 0 repaired**; hashes identical across runs. Broader loaded-candidate run **1 property + 62 tests / 0 failures**, seed 0. Final formatter, two-module compiler diagnostic check and feature YAML parse passed. Earlier harness failures retained in the main report. No full integrated gate/release proof.
- Independent review: own fresh restricted read-only Opus 5.5 session `f2deef9d-6536-4054-984d-bec17abc83ef` accepted the bounded repair after examining red/green evidence. Its limitations prompted exact-file hashes and fallback assertions; no new major finding. Static review is not execution.
- Owner/work: Regents Labs private product engineering. Remaining: source-owner integration/full gate, partition/reconnect and multi-host behavior, degraded cache-process behavior and authorized release checks. Serious details stay private.

### Remaining verification pass on immutable repair ab29f0a1

- Current upstream authenticated read: `64a50d99921d4a92ee7b935f492673836d05f0ce`. All eleven candidate source-file changes pass `git apply --check --cached` against an owned temporary index at that commit. Upstream Code/AccessCache bytes still equal the tested pre-fix base. No upstream refs or checkout were changed.
- Independent two-node fixture with the actual Code, AccessCache and installed Phoenix.PubSub.PG2: **original 4 tests / 2 failures; repair 4 / 0**, seed 0, identical harness. Failures-before are stale publication after processed remote invalidation and after cache restart. Ordinary remote invalidation and the deliberate delayed-recipient behavior pass in both versions. Existing permanent regression remains R-20261020-code-inflight-invalidation in `platform/test/keyfleet/code_admission_test.exs`; this transport fixture is retained privately under keyfleet-review.
- Guarantee is per receiving cache after it processes the notice. `Code.end_access` returning `:ok` does not acknowledge every remote cache. Pausing recipient B demonstrates an already cached grant can still be served before B processes the notice. No immediate global, partition/reconnect, multi-host or SQL-concurrency guarantee is established. Existing “every node at once/now” wording (`access_cache.ex:7,39,43`, `code.ex:201`) overstates this transport; it remains unchanged in the immutable repair and must not be repeated as a verified guarantee.
- **Full make check / platform mix precommit not run: environment blocked, not denied.** No existing checkout contains ab29f0a1; the primary and newer source trees are dirty and dependency-equipped alternatives belong to other registered lanes. This task/parent has no registered worktree owner. No checkout was borrowed/switched, no guard bypassed via export/clone, no installs or shared DB/settings changes. Source owner must integrate into an assigned isolated checkout and run the gate. Loaded candidate results do not substitute for it.
- Verification disposition: **ready for source-owner review; full integration verification inconclusive**. Narrow stale-publication repair is demonstrated locally. Nothing resolved/deployed in production.

## Remaining candidates and coverage gaps

- Notebook admission still publishes via the old direct `AccessCache.admit/5` after membership/hub work (`platform/lib/keyfleet/notebooks.ex:223`); a similar race is a **candidate**, not separately reproduced or repaired here.
- Browser/native WebMCP unavailable (browser inventory empty); real marimo/cloud execution, full make check and deployed cross-integration revocation remain unrun. No paid runtime, production signatures, grants, votes or transfers.
- Starter-goal zero count and person-paired access without shards are intended behavior. Guidance issues remain KF-NIT-20261020-001/002; client rollout gap is -003; narrow heartbeat affordance candidate is -004.

Evidence: `regents-labs-validation-2026-10-20.md`; prioritized next tests: `functional-checklist.md`. No release, funds, credentials or access authority is implied.

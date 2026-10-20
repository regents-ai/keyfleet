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
- Owner/work: Regents Labs private product engineering. Remaining: source-owner integration, full gate, cross-node propagation, degraded cache-process behavior and authorized release checks. Serious details stay private.

## Remaining candidates and coverage gaps

- Notebook admission still publishes via the old direct `AccessCache.admit/5` after membership/hub work (`platform/lib/keyfleet/notebooks.ex:223`); a similar race is a **candidate**, not separately reproduced or repaired here.
- Browser/native WebMCP unavailable (browser inventory empty); real marimo/cloud execution, full make check and deployed cross-integration revocation remain unrun. No paid runtime, production signatures, grants, votes or transfers.
- Starter-goal zero count and person-paired access without shards are intended behavior. Guidance issues remain KF-NIT-20261020-001/002; client rollout gap is -003; narrow heartbeat affordance candidate is -004.

Evidence: `regents-labs-validation-2026-10-20.md`; prioritized next tests: `functional-checklist.md`. No release, funds, credentials or access authority is implied.

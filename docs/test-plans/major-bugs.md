# Major bugs — Keyfleet, Regents Labs

Private product-owner engineering list, 2026-10-20 UTC. **No major bug was confirmed in this bounded pass.** No unverified security allegation has been posted publicly. New entries must carry stable ID, observed/confirmed status, repro, expected/actual, affected SHA, impact, owner/work state, patch and exact executed/blocked evidence; closure requires checks, not dispatch or compilation alone.

## Coverage gaps, not major-bug findings

- Local shard contract validation passed: 20 tests, including 256 seeded expiry cases, owner-only grant, revoke/step-down, ownership epoch and cross-fleet isolation. This does not establish end-to-end revocation propagation through every integration.
- Queue P0 local tests for shard expiry/revocation across already-open chat/workspace/Git/notebook sessions and caches, unpaired/paired/own-Key/shard identities, and cross-account/fleet behavior. Notebook gateway local tests cover loss of pairing/shard membership and existing connections; whole deployed integrations remain unverified. No incorrect admission has been reproduced; do not label this a vulnerability or claim it is resolved.
- Follow-up passed 88 ExUnit cases/properties, including signed graph and notebook-gateway fixtures, and 8 WebMCP adapter probes. Native WebMCP/browser and real marimo execution remain unrun. Installed CLI public read passed; newer-command gaps are KF-NIT-20261020-003.
- Starter-goal zero count and person-paired access with no shards are intended behavior, not major-bug candidates.

Evidence: `regents-labs-validation-2026-10-20.md`; guidance issues belong in `annoyances-nits.md` as KF-NIT-20261020-001/002. This list has no resolved entries and grants no spending, credentials, publication, access or release authority.

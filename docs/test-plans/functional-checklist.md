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

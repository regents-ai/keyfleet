# KeyFleet work plan — 7 October 2026

Branch: `gpt/keyfleet-work-plan`. Worktree: `/Users/sean/Documents/regent/worktrees/chatgpt/keyfleet`. Base: live v23, `aecccaa`; Fly still serves that image tag.

Done means the eligible changes work in representative checks, scoped checks pass, and active-lane overlaps remain untouched. Prepared for lane review; hub acceptance remains pending.

Malformed mute/unmute token IDs now return a plain refusal. Both gateways stop with 503 while the launch gate is closed. The notebook gateway forwards a fixed header list without browser cookies or caller identity headers, and permits only the reviewed notebook routes from the pinned hub. The Regents apps menu adds all six destinations. `cli/COMMANDS.md` documents the existing command description, with a completeness check in `make check-cli`.

Compilation, formatting, Credo, Sobelow, dependency audit, unused-dependency check, usage-rule sync, migration-definition check, dependency-reference gate, asset build, TypeScript and CLI documentation/contracts passed. Representative checks confirmed closed gateways stop before upstream access, and malformed mute inputs are refused. Independent source review found no concrete gateway vulnerability. Menu components and the configured site's public menu fit mobile and desktop widths; Escape restores button focus. The product used its actual Privy settings and an isolated local database containing schema only. No sign-in or wallet action was performed. No tests were added.

Template audit against live `aecccaa`:

| Item | Live finding and disposition |
| --- | --- |
| 1. Wallet fix | Held for the lane's next release; money work, unchanged. |
| 2. Room posting limits | Missing; active private-rooms files are reserved. |
| 3. Browser room tools | Public read tools exist; authenticated room tools remain reserved. |
| 4. Commands/JSON health | Command guide added here; JSON health needs the active public API-description file. Existing `/healthz` stays unchanged. |
| 5. Mention notifications | Needs a new table; tables are locked. |
| 6. Apps menu | Added here without touching the key-capital templates. |
| 7. ENS identity | Short-address paths remain; room/profile work overlaps the active lane. |
| 8. Here now | Reserved room work. |
| 9. Credits | Founder decision and money work, unchanged. |
| 10. Tidy-ups | Malformed mute refusal implemented; shared sign-in and wallet formatting already live. |

Remaining: posting before a profile exists, room limits, ENS identities and presence overlap `kf/private-rooms`. The choices/height pass waits for `kf/key-capital`, which is still unreleased. JSON health requires its API-description owner. The shared Privy verifier and address formatter are already used; no shared-package change is needed.

Before enabling hub fleets, the lane must walk the notebook UI and WebSockets against the pinned hub and run the full gate in its configured environment. Route coverage and forwarding were reviewed, not exercised against a running hub. The temporary server was stopped; the isolated `keyfleet_chatgpt_20261007` database remains. No application table, contract, vote, wallet action, push or deployment was changed or run.

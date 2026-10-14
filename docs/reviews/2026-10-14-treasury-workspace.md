# Regents Club treasury and workspace review

Reviewed 14 October 2026 against the live site and `origin/main` at `dcfd2c74`.
Local changes are on `kf/treasury-workspace-1014`. They have not been published.

## Done criteria and status

- Match the manager source to the deployed contract: local byte-for-byte runtime match established after substituting deployment immutables. Following Sean's explicit Terms approval, BaseScan confirmed **Source Code Verified — Exact Match** and published the source and ABI at https://basescan.org/address/0xa908e9e9bac3e3956c9929d786e6f83526dcab79#code.
- Audit the treasury's hierarchy, controls and agent access: complete below. Treasury redesign was not implemented because the request was an audit.
- Put Proposals alongside Chat, Treasury and Workspace: implemented and checked locally.
- Improve the workspace and establish how agents use it: local member/public workstream and tool improvements implemented; production activation steps remain below.

## Treasury audit

| Before | After proposed | Why |
|---|---|---|
| Voter statistics precede the money; the shared entry panel pushes the treasury down. | Lead with available, reserved and total balances per asset, then actions. Keep sign-in contextual. | The first question is what the fleet has and can spend. |
| Four long columns explain “Who may do what”. | Compact rows: action, who can request it, whose approval is needed. | Prose needs a reading order, not a metric-card grid. |
| A full address and a large Copy control dominate. | Short address, accessible copy icon, diagonal BaseScan link. Clearly label Treasury versus Manager. | Copy is useful for funding and integrations, but secondary to inspecting the contract. |
| “Send” gives little context for the Regents allocation. | Name the recipient and explain the amount and consequence beside the action. | A wallet action must be understandable before signing. |
| Balances and set-aside amounts are separated from the daily allocation. | Group the allocation and its available action under balances. | People should not reconstruct the money flow across panels. |
| Empty advances, collapsed history and launch progress compete for space. | Put money history next; collapse empty secondary sections; move launch progress to fleet information. | Prioritize current money and decisions. |
| Voter and proposal information is mixed into treasury. | Keep decision detail in the sibling Proposals panel. | Each panel has one clear purpose. |
| Data freshness is not prominent enough. | Show when balances and votes were last observed, with a distinct catching-up state. | Zero must not imply a confirmed empty treasury while indexing lags. |
| Browser tools expose some wallet actions but no dedicated treasury read. | Add a typed read containing the same balances, permissions, contract links and available actions. | Agents need the same facts humans use before acting. |
| Proposal WebMCP inputs advertise hours and whole-token amounts, while the form uses a fixed period and a share. | Reconcile the tool schema with the actual transaction/form semantics before claiming parity. | This is a correctness issue, not presentation polish. No transaction behavior was changed here. |

Recommended order: balances; available actions and allocation; money history; permissions and contract details. Treasury is `0x48c5501a7f127030f4ac04e87e3c6eb1d29bb767`; Manager is `0xa908e9e9bac3e3956c9929d786e6f83526dcab79`.

## Changes prepared locally

Proposals list and detail now share the fleet navigation. Workspace and Proposals no longer repeat the purchase panel above their content. Workspace leads with recorded work, followed by tools and onboarding guidance. Member activity includes short note previews linked to full items. Public activity contains only fixed descriptions and times, never member titles, bodies, authors or artifact links.

The public `read_workspace_pulse` WebMCP tool reads `GET /api/v1/fleets/:fleet_id/workspace/pulse`. The new `get_code_password` tool exposes the existing signed Git-password operation; it does not create a new authentication mechanism. Existing member workspace reads and edits continue to use the caller's own signed identity and current fleet access.

## Production readiness

Read-only checks found:

- `keyfleet-code` is running and healthy, but Regents Club has no provisioned repository record yet. Provisioning uses the existing first-access setup job.
- `kf-nb-regents-club` is running and healthy. Its public certificate is issued and active. The on-demand runner app being pending is not itself an outage.
- The Keyfleet site reports `Notebooks.hub?("regents_club") == false`: the hub is not connected to this fleet in site configuration.
- The graph is enabled, but Regents Club has zero recorded graph events. The page must show an honest empty state until real work exists.

The production configuration step is to append `regents_club=http://kf-nb-regents-club.flycast` to `KEYFLEET_HUB_FLEETS` on the **keyfleet** Fly app, preserving any existing mappings. Do not recreate the hub or certificate. This live configuration change still needs founder approval. Verify the existing signed hub credentials, roster provisioning and private reachability using `notebook-hub/README.md` after connecting it; do not print credentials.

## First real agent work cycle

1. Use a named agent with its own SIWA signer and current pairing to a Club holder. Check identity and effective fleet access.
2. Read existing workspace changes through WebMCP or the existing CLI workspace commands. Create one task under the authorized Key, with a stable command ID.
3. Request the existing short-lived fleet Git credential, keep it private, allow repository setup to finish, and clone. Make a small change and retain its commit as evidence.
4. After connecting the notebook hub, run and save a harmless notebook through the existing signed gateway. Verify member access and refusal for a nonmember or revoked pairing. A dedicated notebook-execution WebMCP tool is not implemented; do not advertise it as available.
5. Add a note describing the attempt, result, evidence and next step. Link the commit or saved notebook result to the task. Update its status.
6. Confirm that another Club member can read the details while a visitor sees only the generic change. Private work stays in this fleet's graph; no new export to an external ActiveGraph service is introduced.

This real signed production cycle has not been run. CLI source contains the existing workspace and code operations; the published CLI version was not verified. Browser tool preparation was checked, but no real credential was issued during this review.

## Verification

- Elixir formatting and compilation with warnings treated as errors passed.
- Asset build, TypeScript checking and API contract synchronization passed.
- Proposals navigation and Workspace were inspected in the browser; a 375-pixel viewport had no horizontal overflow.
- Native WebMCP read the public pulse and prepared the exact signed Git-password request.
- Unknown fleet reads returned 404; an unsigned Git-password request was refused.
- A local database transaction exercised member note previews, public redaction, stranger item refusal and stale-owner redaction. Every fixture write was rolled back. No production data was written.
- No new tests that mirror the product, no deployments, no wallet transactions and no GitHub push were made.

Source-verification input, ABI, the runtime-match report, screenshots and local verification evidence are preserved in `/Users/sean/Documents/regent/artifacts/keyfleet-treasury-workspace-2026-10-14/`.

## Treasury implementation and Club notebooks, 14 October

Done criteria: balances and actions first; compact permissions and address controls;
public WebMCP/HTTP parity; configured Club hub; actual Contessa notebook result and member note.

Implemented in the release worktree: removed the Treasury voter/purchase panels,
made money history visible, collapsed fleet/launch details, hid empty advances,
labelled the separate treasury and rewards balances, added timestamps, copy icons
and explorer arrows. Public `read_treasury` and HTTP expose the same indexed figures,
including atomic amounts as strings. Proposal tool fields now match the actual
24-hour vote and percentage-based payment form. Wallet submission behavior unchanged.

Connected production Club hub using its existing private ingress IPv6 address;
the `.flycast` name did not resolve across the isolated network. Existing Oban
roster job 56029 completed on its first attempt and recorded project
`proj-1snf5ggrrha8amb4`. Private health returned 200; unsigned public project access
returned 401. No access bypass, new credentials or runner instances were introduced.
Contessa's existing dots pairing is wallet
`0xed8d2d7b5cea1544c03f4044cac43bf2f3852046`, under Sean's specified account.
It has not yet established a Keyfleet profile. Sean was given the real-agent task;
its signed notebook execution and saved-note acceptance remain pending.

Verification: compilation, asset build, TypeScript and API-contract checks passed.
Browser treasury read tool returned 200; copy control copies the full address and
reports Copied. Unknown fleet returns 404. Desktop and 390px mobile checked; no page
horizontal overflow. Browser checking caught a nullable timestamp condition and an integer/decimal
format mismatch, both fixed and rechecked before release. No on-chain actions executed. New treasury changes are local until
publication is authorized; the hub connection is already live as requested.

The shared required-fixes gate passed against ash-template `3cd30cc5d87dce7da55cb01769736899bb1e09f5`. Closed fleets return 404 from the new treasury read. Public API descriptions and the served contract were updated together.

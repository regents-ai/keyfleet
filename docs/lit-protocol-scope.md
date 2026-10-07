# Lit Protocol for Keyfleet: one-page scope

6 October 2026, rewritten from Lit's current official documents. Research only:
no contract, site, dependency or account was changed. Each claim names its source
in brackets; the sources are listed at the end. These are Lit's own statements,
not an audit by us.

## What Lit is today

- Lit's current network, "Chipotle" (Lit v3), went live on 1 April 2026 [S1]. The
  previous network, Naga, ended the same day [S2]. Naga had itself gone live in
  January 2026 [S3] and replaced Datil, which shut down on 25 February 2026 [S3a].
  That is two network switches in about ten weeks.
- Code runs in secure hardware (a TEE), and permissions live in Lit's own contracts
  on Base [S4, S5]. The older SDK no longer works because its networks are gone.
  Lit says most old features "have equivalent functionality" built from the new
  pieces [S6].
- Conditions are now written as a small JavaScript program, a "Lit Action". It may
  "verify a signature, read a smart contract state" before it encrypts, decrypts
  or signs [S7]. Any EVM chain can be read, Ethereum mainnet included [S6].
- Running an Action needs a Lit API key [S8]. That key can be a "usage key" handed
  to end users that only pays for the run, while "authority comes from signatures
  the action verifies, never from the key" [S9]. So a holder's or agent's own
  wallet signature can be what grants access.
- Encryption and decryption happen inside the secure hardware [S7]. Lit says this
  is "not a drop-in replacement" for its old access-condition system when
  decryption must be tied to on-chain conditions [S7].

## Self-hosting, governance, licence and keys

| Topic | What Lit says | What it leaves open |
| --- | --- | --- |
| Self-hosting | Documented: you run the API server, Actions runtime, dashboard and contracts yourself, on any secure-hardware host that dstack supports: bare-metal Intel TDX or AMD SEV-SNP, Phala Cloud, Google confidential machines or AWS Nitro Enclaves [S10]. | Fly offers none of these hosts, so a self-hosted Lit would break our rule that every server runs on Fly. |
| Upgrades, hosted | A change needs 2 of 4 Lit-held signers, with no waiting period [S11]. The approved system images are governed by a separate Phala-held Safe [S11]. | — |
| Upgrades, self-hosted | Your own Safe owns upgrades; "There is no forced upgrade" [S10]. | Who governs the system-image and root-key layer in a self-hosted deployment. |
| Licence | The docs call Chipotle "open source" [S10]. | The repository has no licence file and its README says "All rights reserved"; several parts declare Apache-2.0 [S12]. There is no single clear licence. |
| Root key | Held by Phala's key service; only approved builds can use it [S5]. | How the root key is backed up or recovered, hosted or self-hosted. |
| Past migrations | "PKPs will not be migrated from Datil to Naga"; users had to make new keys [S3a]. | Whether anything carried from Naga to Chipotle. |
| Agent wallets | Vincent Yield users were told to withdraw their funds before Datil shut down on 25 February 2026 [S3a]. The current docs don't mention Vincent. | Any successor; the earlier claim that Keychain replaced it was unsupported. |

## What Lit could do for Keyfleet

| Use | How | Contract change | Fit |
| --- | --- | --- | --- |
| **Fleet files usable outside our server** | An Action reads `ownerOf` and `shardOf` on Ethereum, checks the caller's wallet signature, then decrypts. Holders and agents could open a fleet's stored files without trusting Keyfleet's server. | None: both reads exist. | **Useful but narrow.** It suits the "home base, not the edge of the world" direction. marimo, dDocs and the code store still need the plain text on our server, so our own key-and-shard check still runs for them. |
| **Bounded agent operations** | A key held in Lit signs only when an Action's rules pass: a budget cap, an approved vote, an expiry. | Depends on the authority model; anything touching the treasury does. | **The strongest fit**, but it waits on the founder's long-term agent-authority decision and on the current hold on Keyfleet contracts. |
| **Custody for agents** | No current Lit product. | — | Not available. |

**Cost** [S13]:

- $0.01 per second of Action time; read-only calls are free.
- Prepaid credits from $5, by card or crypto through Stripe.
- An optional 25% discount for paying in Lit's own token.
- A protected read costs about a cent.

**Effort:** about 3 to 5 days for the first use. The second needs its rules designed first.

## Decision for Sean (HQ 79)

**Should Keyfleet use Lit, and for what?**

- Using hosted Lit adds Lit's account, upgrade signers and root-key custody to Keyfleet's trust.
- Self-hosting would need confidential hardware outside Fly.
- No contract changes for options a or b.

Options:

- a) **Not now.** Our key-and-shard check keeps guarding every read. Lit becomes the lead candidate for bounded agent operations, revisited when that authority model is decided. *(recommended)*
- b) **A hosted trial for fleet files usable outside our server.** About 3 to 5 days and about a cent per read. Sean creates a Regents Labs Lit account and API key.
- c) **b, plus a rule-gated signing key for agent operations.** This is built only after the authority model is decided and the contract hold is lifted.

## Sources

- S1: https://spark.litprotocol.com/lit-v3-is-live-confidential-compute-and-key-management-in-one-api/
- S2: https://spark.litprotocol.com/naga-network-sunset/
- S3: https://spark.litprotocol.com/v1-live/
- S3a: https://spark.litprotocol.com/sunsetting-lit-v0-datil-migrate-to-v1-naga-within-30-days/ (now unpublished; read via the Wayback Machine copy of 18 February 2026)
- S4: https://spark.litprotocol.com/introducing-lit-protocol-v3-chipotle/
- S5: https://developer.litprotocol.com/architecture/authModel.md
- S6: https://developer.litprotocol.com/lit-actions/migration/changes.md
- S7: https://developer.litprotocol.com/lit-actions/migration/encryption.md
- S8: https://developer.litprotocol.com/management/api_keys.md
- S9: https://developer.litprotocol.com/lit-actions/derived-actions.md
- S10: https://developer.litprotocol.com/architecture/self-hosting.md
- S11: https://developer.litprotocol.com/architecture/verification/upgrade-governance.md
- S12: https://github.com/LIT-Protocol/chipotle (README and component manifests, commit ad7a74f, 2 October 2026)
- S13: https://developer.litprotocol.com/management/pricing.md and https://developer.litprotocol.com/management/litkey.md

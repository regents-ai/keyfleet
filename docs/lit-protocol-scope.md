# Lit Protocol for KeyFleet: one-page scope

5 October 2026. Research only. No contract, site or account was changed.

## The headline

The Lit Protocol most people know no longer exists. On 1 April 2026 Lit replaced its network of nodes with a hosted service called Chipotle ("Lit v3"):

- Lit's code runs inside secure hardware hosted by Phala.
- Permissions are kept in Lit's own contracts on Base.
- The old access conditions, session signatures and capacity credits are gone. A small JavaScript program (a "Lit Action") now decides who gets in.
- Only someone holding an API key from the account owner can run an Action. A wallet cannot call it directly.

This is the fourth Lit network since 2024. Keys made on one network were not carried to the next: in February 2026 users had to make new ones.

## What Lit could do for KeyFleet

| Use | What it would do | Contract change | Fit |
| --- | --- | --- | --- |
| **Access control** | Only a key's holder, or an agent with a live shard, can open a fleet's private files. The Action reads `ownerOf` and `shardOf` on Ethereum, checks the caller's signature, then opens the file. | None. Both reads already exist. | Weak. marimo, dDocs and the code store all need the plain text on a live server, so KeyFleet's own check runs anyway. Lit helps only with files stored at rest. |
| **Signing** | A signing key per fleet or per key, held by Lit and used only when the Action's check is met. | None. | Weak. Agents already sign with their own wallets. Such a key must never hold money, because the owner presses every money action. Key recovery is not documented. |
| **Custody / delegated powers** | Lit's agent product (Vincent) gave agents limited powers over a wallet. | Would need one if it touched the fleet's money. | Not available. Vincent ran on a network that shut down in February 2026. Its successor stores passwords and API keys only. KeyFleet's rule is that the owner signs every money action anyway. |

## On chain and off

- **On chain:** nothing changes in the KeyFleet contracts for any use above. Lit's own permission records live on Base and would be set up through Lit's dashboard or API.
- **Off chain:**
  - KeyFleet's server would hold a Lit API key and pass requests through.
  - One Action would be written in JavaScript and stored on IPFS, with the Ethereum RPC address fixed inside it so a caller can't point it at a fake chain.
  - Files would be encrypted before they are stored.
- **Effort:** about 3 to 5 days for access control on stored files. Signing is about the same.

## Cost

- $0.01 per second of Action time, 1-second minimum, so about **$0.01 per protected read**. Plain reads of Lit's records are free.
- Prepaid credits from $5, by card or crypto through Stripe. There is no free tier and no Lit token is needed.

## Risks

- **Trust:** Lit's hardware sees the plain text, and changes to Lit's code are approved by 2 of 4 Lit-held signers, with no waiting period.
- **Short-lived networks:** four networks in about two years, and keys were lost at one switch.
- **Lock-in:** Actions are written in Lit's own JavaScript format. The self-hosting docs call Chipotle open source, but its repository says "All rights reserved".
- **Not confirmed:** how many machines run the service, and how its root key is backed up.

## Decisions for Sean

1. **Should KeyFleet use Lit at all, given that it is now a hosted service?**
   - a) No, for now. KeyFleet's own key-and-shard check keeps guarding every read. Revisit if Lit ships a self-hostable, openly licensed network. *(recommended)*
   - b) Access control on stored fleet files only: about 3 to 5 days and about $0.01 per read, with no contract change.
   - c) Add signing keys as well, on top of b.
2. **If b or c: which account pays?** A Regents Labs Lit account funded by card. This needs Sean to create the account and issue the API key.

No contract change is proposed. Any later change that touches keys, shards or money comes back to Sean before it is built.

## Sources

- Lit v3 launch: https://spark.litprotocol.com/lit-v3-is-live-confidential-compute-and-key-management-in-one-api/
- Naga sunset: https://spark.litprotocol.com/naga-network-sunset/
- Architecture: https://developer.litprotocol.com/architecture/index.md
- Auth model: https://developer.litprotocol.com/architecture/authModel.md
- Encryption: https://developer.litprotocol.com/lit-actions/migration/encryption.md
- Limits: https://developer.litprotocol.com/lit-actions/limits.md
- Pricing: https://developer.litprotocol.com/management/pricing.md
- Upgrade governance: https://developer.litprotocol.com/architecture/verification/upgrade-governance.md
- Self-hosting: https://developer.litprotocol.com/architecture/self-hosting.md
- Chipotle repository: https://github.com/LIT-Protocol/chipotle
- Keychain: https://developer.litprotocol.com/keychain/index.md
- Vincent: https://heyvincent.ai/ and https://github.com/LIT-Protocol/Vincent

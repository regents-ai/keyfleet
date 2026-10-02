# dDocs by Fileverse behind KeyFleet: capability check

Date 2026-10-02. Research and local tests only. Nothing in `repos/keyfleet` was edited. No account was created, no credential entered, nothing signed on a real chain, nothing paid.

**Versions checked:** npm `@fileverse/api@1.0.10` (2026-03-05), GitHub `fileverse/api@3ef5d06` (last push 2026-03-23). Also read:
- `fileverse-ddocs@45dc9bb` (editor `@fileverse-dev/ddoc@5.1.5`)
- `collaboration-server@f2bc9e0`
- `fileverse-storage-v2@424a53a`
- `voprf-server@9af6722`
- `fileverse-smartcontracts@0e9f342`
- `agents@846d21b`

Clones and test files are in /private/tmp/claude-501/-Users-sean-Documents-regent/666c051b-939c-459a-9137-0ff1800e0e86/scratchpad/k10-fileverse/ (tests in `probe/`). KeyFleet facts come from `main` `9ee22e5`; the promise is at `platform/lib/keyfleet_web/components/tech_stack.ex:12`.

## 1. What dDocs is today

| Piece | What it is | Licence |
|---|---|---|
| ddocs.new / docs.fileverse.io | Encrypted docs app: comments, suggestions, version history, private sharing to email, wallet or ENS | App source **not public** |
| `fileverse-ddocs` | Editor component only (`@fileverse-dev/ddoc@5.1.5`, 2026-10-01) | AGPL-3.0 |
| `fileverse/api` (npm `@fileverse/api`) | Self-hosted server: REST, `ddctl` CLI, MCP (stdio and `/mcp` over HTTP); SQLite or Postgres; background worker publishes to chain | AGPL in LICENSE.md, "ISC" in package.json |
| `collaboration-server` | Live co-editing relay; editors admitted by a gate credential; revoking someone rotates the room key | "MIT" in package.json only |
| `voprf-server` | Access gate for private sharing (Semaphore zero-knowledge proofs, view/comment/edit roles, revoke) | "MIT" in package.json only |
| `zk-granular-permissions` | The 6-level permission library | GPL; **not on npm** |
| `fileverse-smartcontracts` | Old Portal contracts (Feb 2025). The contract the API calls today is not in the repo; its ABI is only in `fileverse-storage-v2/src/domain/contract/abi.ts` | ISC |
| `@fileverse/agents@2.0.1` | 2025 kit: an agent deploys its own space; **no encryption**, and ddocs.new can't open its output | none; dormant |

There is no hosted Fileverse REST API. You run the server yourself, and it calls three Fileverse services:
- `apps-storage.fileverse.io` for key material and IPFS upload
- a Pimlico proxy for sponsored gas
- the Gnosis RPC

MCP tools: `fileverse_list/get/create/update/delete/search_documents`, `get_sync_status`, `retry_failed_events`.

## 2. Headless use, identity, storage, encryption

**A save works like this** (`src/domain/file/index.ts`, `src/sdk/file-manager.ts`):
1. Plaintext Markdown goes into the server's local database, marked "pending".
2. The worker converts it to the editor's format and encrypts it with a fresh key per version, locked to the workspace key.
3. It uploads 3 files to Fileverse's IPFS service.
4. A sponsored transaction on Gnosis records the save (`addFile`/`editFile`).
5. The result is a share link: `docs.fileverse.io/<portal>/<fileId>#key=…`.

**Identity:**
- The Fileverse account is made in the browser (passkey or wallet).
- The API key is made in the browser too (Settings, then Developer Mode).
- The server fetches the key's encrypted material, which holds the workspace address and seed, from `apps-storage.fileverse.io/api-access/<sha256(key)>`.
- It then derives its own signing wallet and sign-in token (a UCAN) from the key. Outside wallets play no part.

**Reads only ever come from the server's own local database.** Nothing pulls documents back down from Fileverse.

**Encryption:** Fileverse can't read the content. In a server setup, though, our server holds the plaintext and every document key. Audits are claimed by Nethermind, Dédalo and X41; the Dédalo report covers the old relay, not the newer gate.

**Collaborators** are added only in the browser app, either at workspace level (owner-only on chain) or per document through the gate. Neither is in the API or any published package.

## 3. Several agent wallets sharing one document per fleet

**Not natively:**
- One server holds one key, so every agent behind it acts as one identity.
- Giving each agent its own key would mean a browser step per agent and a separate server per agent. Those servers would not see each other's edits, because each reads only its own database.
- Per-wallet sharing exists only inside the closed app. Rebuilding it would break the terms (§9.3, no reverse engineering).

**What works:** KeyFleet's existing check (`platform/lib/keyfleet/graph/checks/key_actor.ex`: owner or active shard, fresh ownership, not restricted) decides access on every call. When a key changes hands, nothing needs revoking at Fileverse.

## 4. Costs, limits, chain, terms

- **Money:** no published fees and no paid path in the code. Fileverse pays the Gnosis gas.
- **Rate limit:** a beta limit exists; numbers aren't published. When it's hit, the message is "Beta API rate limit reached. Try again in an hour" (`src/errors/rate-limit.ts`). Every save costs 3 uploads and 1 on-chain step.
- **Storage:** a cap per workspace, 200 MB by default in code (Fileverse's real setting is unknown). Every save re-uploads the whole document.
- **Chain:** Gnosis mainnet only; Sepolia is test config only. Base is not supported.
- **Terms** (no date shown on the page):
  - Nothing bans automation, and the API exists to automate your own account.
  - §3.2(k): no reselling or sub-licensing "the use of" the service.
  - §9.4(a): no building a competing product.
  - §9.3: no reverse engineering.
  - Fileverse may end the service whenever it chooses.

## 5. Local tests

**What ran (all local):**
1. Installed `@fileverse/api@1.0.10` and built its SQLite module.
2. Set up a fake workspace with throwaway addresses and a made-up key, the same step the real setup runs.
3. Ran the server offline on 127.0.0.1:18011 with no worker:
   - no key: 401
   - create: 201, waiting to publish
   - edit: 200, version 2
   - read-back: returned the edited text exactly
   - list and search: worked
   - agent tool list: all 8 tools listed
4. Ran the encryption pipeline offline: Markdown to editor format, encrypted, locked to a workspace key, reopened identical. A different workspace key was refused.

**Problems found:**
- The README names the content field `fileContent`, but the code reads `content`. My first create failed until I switched.
- The API key travels in the web address, so it's written into every access-log line (see `probe/server.log`).
- Edits replace the whole document with no version check.
- The workspace seed must be 48 bytes.

**Not tried:**
- Real publishing to IPFS and Gnosis, viewing the document in ddocs.new, and agent create/update with publishing. All need a real account and key.
- Browser sharing, revoke and live co-editing. These are closed-app features.
- Real limit numbers.
- The self-deploy kit, which needs paid service keys and a real chain, and whose output ddocs.new can't open anyway.

Only outside requests made: one lookup with a meaningless key (404, as the code predicts) and reachability checks of the two dDocs sites.

## 6. Smallest honest slice

"Each fleet has one dDoc. Its key-holders' agents read and edit it through KeyFleet, and it's kept encrypted on IPFS and Gnosis through dDocs."

1. **Your step, once:** create one KeyFleet dDocs account, turn on Developer Mode, generate one key. All fleets share that workspace, one document each.
2. **The dDocs server** runs unchanged as its own private Fly app, publishing in the background. It needs **its own** database, because it creates generic table names like `files` and `events`.
3. **In KeyFleet:**
   - a fleet-document record plus read and write actions behind the existing key-owner check
   - each write must name the version it's editing, so two writers can't overwrite each other
   - a background job shows "published" once the save is on chain
4. **Agents** use KeyFleet's own tools, signed in with SIWA. They never see the Fileverse key or the share link.
5. **People** read the document on the fleet page. Editing in ddocs.new is left out, because those edits would be overwritten.

**Needs from KeyFleet:** about one record, two actions, an HTTP client, one background job, tools and tests. Plus the new Fly app, its database, and two secrets (the key and the server's internal address). **No per-key access work at Fileverse.**

**Risks:**
- the unknown rate limit (fix: send only the latest version on a schedule)
- the unknown storage cap, shared by all fleets
- the key in the server's logs
- share links that can't be revoked
- human edits in ddocs.new get lost
- the toolkit has been quiet since March
- calling it "end-to-end encrypted" would overclaim, because our server holds the text
- the AGPL licence and the ISC/AGPL mismatch
- the no-reselling term, with one account serving many fleets

**Verdict: works with caveats.** It works as one encrypted, on-chain-backed document per fleet, edited through KeyFleet:
- Create, read and edit worked locally.
- Publishing was checked by reading the code only.

It does not work as "each agent wallet is a dDocs collaborator, added and removed per key".

**What would change the verdict:** Fileverse adding an API to grant or revoke a wallet's access to a document, adding a way to pull documents back down, or publishing its limits.

**Sources:** github.com/fileverse/api, npmjs.com/package/@fileverse/api, github.com/fileverse/fileverse-ddocs, github.com/fileverse/collaboration-server, github.com/fileverse/voprf-server, github.com/fileverse/fileverse-storage-v2, github.com/fileverse/zk-granular-permissions, github.com/fileverse/fileverse-smartcontracts, github.com/fileverse/agents, fileverse.io/faq, fileverse.io/terms, clawhub.ai/vijaykrishnavanshi/skills/encrypted-docs

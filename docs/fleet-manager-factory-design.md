# One Key collection, one manager per fleet: design

**Date:** 7 October 2026
**Branch:** `kf/fleet-manager-factory`, from `kf/contracts-v03` at `10260c4`
**Status:** design only, round 1. No `.sol` file changes in this commit. Nothing is deployed, broadcast, signed or pushed. Key sales stay off.

**Sean's request (7 Oct 2026, verbatim):** "For browsing on Opensea I would prefer if all of the Key NFTs in the different sets are part of the same collection address...but I want the NFTs to act as membership keys to different KeyfleetManager contracts that are created from a KeyFleetManagerFactory."

**Relayed from the Keyfleet NFTs lane (7 Oct, not yet a contract requirement):** the first four fleets each get a pre-made 1,000-card deck; a key's random number picks its card from its fleet's deck. Keys 1,001 onward, and fleets 5 onward, use today's trait draw. Card titles count per type ("CLASSIC #1", a later second Classic fleet is "CLASSIC #2"). Section 3.5 covers it.

**Binding sources:** [contracts-build-now-spec-v0.3.md](contracts-build-now-spec-v0.3.md), Sean's answers recorded in [contracts-v0.3-plan.md](contracts-v0.3-plan.md) section 9, [product-spec.md](product-spec.md). Nothing here changes a price, supply, split, vote rule, presence rule, daily split rule or claim rule. Only *where* things live changes.

Words used below: a **fleet** is what Sean calls a "set". A **key** is one ERC-721 token. The **collection** is the one shared ERC-721 contract. A fleet's **manager set** is the per-fleet contracts the factory creates. The **Safe** is the Regents Safe on Base, `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`.

---

## 1. Today, in one paragraph

Each fleet is five contracts with no shared state. `Keyfleet` (14.6 KB runtime) is both the ERC-721 and the sale: it holds the keys, ownership epochs, the VRF reveal, the preset economics (prices, supply, Fibonacci holding limits, Cascade reserve, Accelerant rebate), the owed 10% protocol share, and `firstMintAt`. It deploys its `KeyfleetRewards` ledger (8.4 KB) and `KeyfleetShards` record (3.6 KB) in its constructor; `KeyfleetVotes` (14.5 KB) and `KeyfleetTreasury` (10.8 KB) are deployed next at addresses predicted from the deployer's nonce, and each refuses a fleet that does not name it (`script/KeyfleetStack.sol`). Each `Keyfleet` is its own OpenSea collection with its own name, symbol, metadata base and VRF consumer slot. On chain, nothing stops a deployed fleet from selling: "sales off" today means "no fleet is deployed and the site has recorded none" (`docs/deploy-checklist.md`, "Key sales stay off").

## 2. The shape after the change

```
                       KeyfleetFactory  (one; only the Safe may create a fleet)
                         |   deploys in its constructor
                         v
   KeyfleetKeys  <---- one ERC-721 collection: every key of every fleet
   KeyfleetShards <--- one agent-shard record for every key (keyed by token id)

   createFleet(preset, deck) -> one manager set per fleet, in one transaction:
        KeyfleetManager   the fleet's sale, protected obligations, transfer hook
        KeyfleetVotes     presence + proposals + ballots          (as today)
        KeyfleetTreasury  free capital, exact calls, daily split  (as today)
        KeyfleetRewards   member claims ledger                    (as today)
```

| Contract | How many | Holds | Comes from |
|---|---|---|---|
| `KeyfleetKeys` | one | Who owns each key, which fleet it belongs to, ownership epochs, each key's VRF seed (and deck card, 3.5), the fleet registry, the sales switch per fleet | ERC-721 and reveal parts of `Keyfleet.sol` |
| `KeyfleetShards` | one | Agent shards and agent-voting switches, per key | `KeyfleetShards.sol`, rebound from one fleet to the collection |
| `KeyfleetFactory` | one | Shared bindings (USDC, REGENT, staking, Autolaunch); nothing of value | new |
| `KeyfleetManager` | one per fleet | Preset, prices, `totalMinted`, `firstMintAt`, Cascade reserve, owed protocol share, Fibonacci holding counts | sale and money parts of `Keyfleet.sol` |
| `KeyfleetVotes`, `KeyfleetTreasury`, `KeyfleetRewards` | one each per fleet | Exactly what they hold today | today's files, rebound to the manager and collection |
| four small deployers | one each | Nothing; each holds one per-fleet contract's creation code | new (section 4.3) |

"The manager" in Sean's words is the fleet's whole manager set: `KeyfleetManager` is its front door and address book, and the other three are its parts. It cannot be one contract: the four together are about 43 KB of runtime code against Base's 24,576-byte limit per contract (EIP-170).

---

## 3. The shared Key collection

### 3.1 What OpenSea sees

One contract address, one collection page. `name()` and `symbol()` are fixed at deploy (question 8). `contractURI()` (ERC-7572) returns a fixed URL for the collection page's picture and description. Each key's metadata carries `Fleet type`, `Fleet` (for example `CLASSIC #1`) and `Key number` as attributes, so OpenSea's trait filter lets a buyer narrow the one collection to one fleet. One `setApprovalForAll` to a marketplace now covers a holder's keys in every fleet; that is ordinary ERC-721 and grants nothing in any fleet's votes (spec §5.1).

### 3.2 Which fleet a key belongs to, and its token id

Every fleet gets a number from the collection when it is created: `1, 2, 3, ...` across all types, never reused, never changed. The collection also records the fleet's type and its number within that type (`CLASSIC #1`, `CLASSIC #2`), so the card title is provable on chain. Within a fleet, keys are numbered `1..n` exactly as today; that number drives every price, level, cohort and rebate rule, so `KeyfleetPresets` and `KeyfleetClassicPrices` move over unchanged.

The token id must carry both. Two ways (question 3):

- **(a) Recommended: fleet number and key number in one id.** `tokenId = fleet × 10^10 + key`. Fleet 1's key 72 is `#10000000072`; fleet 2's key 1 is `#20000000001`. The fleet is `tokenId / 10^10`, worked out with no storage read, which makes the cross-fleet check (section 5) cheap and impossible to get wrong. The key number fits under 10^10 because a fleet already stops at 4,294,967,295 keys. Cost: long numbers in OpenSea's URL and detail panel; the card title and name read normally.
- **(b) One running count across the collection.** `#1, #2, #3` in mint order across every fleet. Short ids, but a key's id and its card number differ (Classic #1's key 72 might be `#3410`), and the collection must store the fleet and key number per token (about 22,000 more gas per mint), and every check of a key's fleet is a storage read.

### 3.3 Ownership epochs and transfers

`ownershipEpoch[tokenId]` moves into the collection unchanged: 1 at mint, plus one on every transfer. Token ids are unique across the collection, so one mapping serves every fleet. On every mint and transfer, `KeyfleetKeys._update` does, in today's order:

1. Calls the key's own fleet manager, `managerOf[fleetOf(tokenId)].onKeyMoved(tokenId, from, to)`. The manager settles the key's rewards to `from`, clears its presence in the fleet's Votes, and enforces the Fibonacci holding limit on `to`, exactly what `Keyfleet._update` does today. A transfer only ever calls the one manager the key belongs to.
2. Bumps the epoch and emits `OwnershipEpoch`.
3. Moves ownership (`super._update`).

### 3.4 Reveal, `tokenURI` and ERC-4906

- **VRF moves into the collection, once.** One coordinator, subscription and gas lane for every fleet, and one VRF consumer for the Safe to add, instead of one per fleet. This matters: a Chainlink v2.5 subscription takes at most 100 consumers (to confirm against the Base coordinator in step B1), which per-fleet VRF would hit at fleet 101. Request, retry (`requestReveal`), callback rules, 3 confirmations, native payment and the never-reverting callback stay as written today. The seed stays `keccak256(TAG, chainid, collection, tokenId, word)`; the collection address and a collection-unique id keep every seed distinct.
- **One trait table for every fleet.** The product spec already says every key in every fleet draws from one table, so `TRAIT_TABLE_HASH` (`0x154aa5ac…3e8`) is fixed once on the collection.
- **`tokenURI(id)` = one fixed base + the id**, for example `https://keyfleet.ai/metadata/keys/10000000072`. The site decodes the fleet from the id. Whether the base may ever move is question 5.
- **ERC-4906:** the collection emits `MetadataUpdate(tokenId)` when a seed (and deck card) is written, so OpenSea refreshes that key, as today. The collection is the only contract that needs to emit it, since OpenSea listens to the collection address.

### 3.5 Per-fleet card decks (relayed from the NFTs lane)

The rule the NFTs lane describes: a fleet created with a deck shows, for keys `1..deckSize`, the deck card its random number picks; every other key, and every fleet created without a deck, uses the trait draw. The contract does not need "the first four fleets" written into it: the Safe gives a deck when it creates those four and none afterwards.

What the contract must do so a deck cannot be swapped after the seeds are known (the same reason `TRAIT_TABLE_HASH` is fixed before the first sale):

- `createFleet` takes a deck fingerprint and size (`deckHash`, `deckSize`, for example 1,000). The collection records them with the fleet, forever. Zero means "no deck". The deck file must exist before the fleet is created.
- Whether two keys may show the same card is question 7:
  - **(a) Each card dealt once (recommended).** The callback deals from the fleet's remaining cards with a swap-and-pop map (Fisher–Yates, one step per key): `card = remaining[word mod left]`, the last remaining card moves into its place, `left` drops by one. It is recorded as `cardOf[tokenId]` and announced with the seed. Order is the order answers arrive, which nobody controls. Cost: about three more storage writes in the callback, so the callback gas limit rises from 100,000 to a measured ceiling (estimate 160,000); still far under the coordinator's 2,500,000 cap. The callback still never reverts.
  - **(b) Independent picks.** `card = seed mod deckSize`, worked out off chain; nothing more on chain than the fingerprint. 1,000 keys would land on only about 632 different cards on average, so many repeats.
- `tokenURI` does not change: the site serves the deck card's picture for those keys and the drawn card for the rest. The metadata adds a `Card` attribute.

---

## 4. The factory and each fleet's manager set

### 4.1 What `createFleet` does

`createFleet(preset, deckHash, deckSize)`, callable only by the Safe (question 1), in one transaction:

1. Asks the collection to register a new fleet: the collection assigns the fleet number and per-type number, records the preset, deck and the manager's (predicted) address. The fleet's sales switch starts **off**.
2. Deploys the fleet's `KeyfleetManager`, `KeyfleetVotes`, `KeyfleetTreasury` and `KeyfleetRewards`, each at an address computed in advance (4.3), each bound to the others and to the collection, the shared shards, USDC, REGENT, REGENT staking and the Autolaunch factory.
3. Emits `FleetCreated(fleet, preset, typeNumber, manager, votes, treasury, rewards)`.

The preset is the only economic input, and it picks one of today's four rule sets. The Safe cannot set a price, supply, split, rate, threshold or address for a fleet: those are the presets and the factory's fixed bindings. A fleet of the same type may be created again (Classic #2 is another 1,024 keys from 8 to 80 USDC, with its own treasury and votes).

### 4.2 Clones or full deploys

| | Minimal clones (EIP-1167) | Full deploys (recommended) |
|---|---|---|
| Gas to create a fleet | ~0.3M | ~10–12M (cents on Base; to measure) |
| `DELEGATECALL` | Every call to every fleet goes through one. Contradicts spec §4.2 and fails our own bytecode check (`script/check_bytecode.sh`) by design | None anywhere |
| Wiring | Storage, written by an `initialize` call; needs locked implementations and same-transaction initialisation to avoid hijack | `immutable`, fixed by the constructor, unreadable to change |
| Per-call cost | Each wiring read is a cold storage read (2,100 gas), many per transfer and vote | Immutables cost nothing to read |
| Audit surface | Initializers, implementation lock, proxy forwarding | The same constructors reviewed today |

Recommendation: full deploys. The gas difference is small on Base and only paid once per fleet; the safety and spec fit are not.

### 4.3 How four contracts that point at each other get deployed at once

Votes and Treasury name each other; the manager, Rewards and Treasury name each other. Constructor arguments cannot carry that loop, because each address depends on the others' code. The design uses the pattern Uniswap v3 uses for its pools:

- Each per-fleet contract has **no constructor arguments**. It is deployed with `CREATE2`, salt = fleet number, so its address depends only on its deployer, the fleet number and its fixed creation code. The factory computes all four addresses before deploying any.
- During `createFleet` the factory holds the fleet's wiring (fleet number, preset, the four addresses, the shared bindings) in transient storage. Each constructor reads it back from the factory, stores it in immutables, and refuses to deploy unless its own predicted address is `address(this)`. The transient record is empty outside `createFleet`.
- The factory cannot hold all four creation codes itself (they total ~45 KB against the 24,576-byte limit), so each lives in its own small **deployer** contract, `onlyFactory`. The deployers are deployed first with the factory's address predicted from the deploying account's nonce, and the factory's constructor refuses any deployer that does not name it: today's `KeyfleetStack` technique, used once for the whole system instead of once per fleet.
- The factory's constructor deploys `KeyfleetKeys` and `KeyfleetShards`, so the collection's `FACTORY` is fixed at birth with no window.

Estimated sizes (measured in B1–B4): collection ~10–12 KB, manager ~9 KB (it keeps the 2 KB Classic price table), Votes ~15 KB, Treasury ~11 KB, Rewards ~8.5 KB, Shards ~3.7 KB, factory initcode ~16 KB. All under the limits.

### 4.4 Who trusts whom

| Caller → callee | Allowed because | Checked by |
|---|---|---|
| Safe → factory `createFleet` | Only the Safe creates fleets | `msg.sender == SAFE` |
| Factory → collection `registerFleet` | The collection's own factory | `isFactory[msg.sender]` |
| Safe → collection `openSales(fleet)` | Only the Safe turns a fleet's sales on (section 6) | `msg.sender == SAFE` |
| Manager → collection `mint(to, keyNumber)` | Only a fleet's registered manager mints, and only into **its own** fleet: the collection takes the fleet from `fleetOfManager[msg.sender]`, never from an argument | registry lookup; sales switch; ERC-721 refuses an existing id |
| Collection → manager `onKeyMoved` | The transfer hook | `msg.sender == KEYS` |
| Manager → Votes `onKeyMoved`, → Rewards `enroll/settle/credit/allocate` | As today (manager replaces `Keyfleet`) | `msg.sender == MANAGER` |
| Votes → Treasury `executeBatch`; Treasury → Votes `setEditsRestricted`; Treasury → Rewards funding | As today | as today, plus the split flag |
| Manager → Treasury `depositProtocolShare` | As today | `msg.sender == MANAGER` |

Registry entries are written once and never changed or removed. The collection never calls a manager it did not register, and only for that manager's own keys.

---

## 5. Membership: a key counts only in its own fleet

The danger the shared collection introduces is a key of fleet A acting in fleet B. Today every fleet's contracts look up `ownerOf` on their own `Keyfleet`, so a foreign id simply does not exist there. After the change `KEYS.ownerOf(id)` answers for every fleet's keys, so each per-fleet contract must check the fleet itself. One internal check, `_requireOwnKey(tokenId)` (`tokenId / 10^10 == FLEET`, or a registry read under scheme (b)), runs before any other use of a key in:

- **Votes:** `present`, `presentBySig`, `castBallot`, `castBallotBySig`, `propose` (author key), `cancel`, `setEditsRestricted`, and the signed-message key encoding.
- **Rewards:** `claim` (a foreign key also fails today's `KeyNotEnrolled`, but the explicit check gives one clear refusal).
- **Manager:** `onKeyMoved` is only ever called for its own keys by construction; it asserts it anyway because a wrong call would corrupt holding counts.

What stays per fleet, unchanged: the presence queue and its counts, every proposal's electorate and ballots, the daily split's key count (`manager.totalMinted()`, the fleet's own keys), cohorts, the treasury.

**Transfers:** settle-then-clear-then-epoch, as 3.3; the incoming owner starts from the current indexes in the key's own fleet only.
**Ownership epochs:** global per token; every fleet reads the same value, which is correct because a key is in one fleet.
**Delegation:** one shared `KeyfleetShards`, keyed by token id. A shard grants authority over one key, and that key only counts in its own fleet, so a shard can never reach another fleet. `delegationRevision` stays per key.
**Signatures:** the EIP-712 domain's verifying contract is the fleet's own Votes, and the message names the fleet's manager and globally unique key ids, so a signed Present or Ballot for fleet A cannot be replayed in fleet B.
**Ballot slots:** one per key per proposal, per fleet's Votes, as today.
**Presence ids:** `KeyfleetPresence` packs ids in 32 bits today. Under scheme (a) it widens to 64 bits (`prev`, `next`, `expiresAt` still share one storage slot), which holds up to 1.8 billion fleets.

---

## 6. Key sales stay switched off

Sean: "I do not want the contracts or the frontend site to enable purchases of keys until I explicitly say so."

Today the contracts have no switch; sales are off only because nothing is deployed. A factory changes that: creating a fleet on chain would otherwise make it purchasable at once. So the design adds one choke point:

- **Where:** `KeyfleetKeys.mint` reverts `SalesClosed(fleet)` unless that fleet's `salesOpenedAt` is set. Every purchase in every fleet ends in this one function, so the gate holds even if a manager had a bug. There is no other mint path: no admin mint, no airdrop, no treasury mint, no factory mint.
- **Who opens it:** only `KeyfleetKeys.openSales(fleet)`, only callable by the Safe, one fleet at a time. Nothing else can set it: not the factory, not a fleet's treasury or an approved proposal (the treasury is not the Safe), not time, not the site. Whether it can be closed again is question 2.
- **Every fleet is created with sales off.** Creating a fleet and opening its sales are two separate Safe transactions.
- **The site:** the fleet page reads `salesOpen(fleet)` and, while it is off, shows the buy button disabled with a few words saying sales have not opened (rule 11's exception: a press certain to fail from chain state). The site's own purchase gate (`seed-deployment`, the `build.ex` purchase step) stays as it is; this design adds the chain switch, it does not remove the site's.
- **Proof:** unit tests that `purchase` reverts on a fresh fleet, that every caller but the Safe is refused by `openSales`, and an invariant that a fleet with sales off has `totalMinted == 0` while a handler tries every entry point with random callers.
- **Scripts:** the deploy and create-fleet steps never call `openSales`. Only the anvil lab does, on a local chain, acting as the Safe there, so the site's local buy tests keep working.

---

## 7. Security analysis

### 7.1 Trust boundaries

| Party | Can | Cannot |
|---|---|---|
| Regents Safe | Create a fleet of one of the four presets (with or without a deck); open a fleet's sales; add a newer factory if question 4 is (a) | Mint a key, move or burn anyone's key, touch any fleet's money, votes, claims, rate or treasury, change a fleet after creation, change a price, supply or split |
| Factory | Register and deploy fleets when the Safe asks | Anything after creation; it keeps no rights over a fleet |
| A fleet's manager | Mint its own fleet's next key during a purchase; receive its own keys' transfer hooks | Mint into another fleet; see or touch another fleet's keys |
| A fleet's treasury (approved calls) | Anything an exact approved call can do, as today, including buying or holding other fleets' keys | Reach any `onlySafe`, `onlyFactory`, `onlyManager` or `onlyKeys` function; fund the ledger outside the split |
| Key holders and agents | As today, within their own key's fleet | Act in another fleet with a key |

There is still no upgrade path, proxy, pause, burn, setter of economics, or `delegatecall` in any contract.

### 7.2 Reentrancy across collection and manager

- `purchase` (manager) holds the manager's lock and calls `KEYS.mint`, which calls back into the same manager (`onKeyMoved`) from inside `_update`. That callback must not take the manager's lock, or minting would fail. It is safe because it is `onlyKeys`, makes no token transfer and calls only the fleet's own Rewards and Votes bookkeeping.
- `KEYS.mint` holds a collection-wide lock shared with `requestReveal`, so a receiver contract cannot mint again (in any fleet) or add a second VRF request from inside `onERC721Received`. Transfers do not take that lock, so a receiver may still forward a fresh key from inside `onERC721Received`, as today (the key is enrolled before it is minted).
- Purchase order stays: checks, price, USDC in, split booked, enrol, mint (the only untrusted callback, `onERC721Received`), Cascade completion, reveal request last.
- The transfer hook calls no untrusted code: collection → own manager → own Rewards and Votes, all our immutable code.
- The VRF callback is `onlyCoordinator`, writes once, never reverts, and makes no external call.

### 7.3 Access control

Every privileged function is in the 7.1/4.4 tables, each with one fixed caller, compared against an immutable (`SAFE`, `FACTORY`, `KEYS`, `MANAGER`, `VOTES`, `TREASURY`) or the write-once registry. No `tx.origin`, no roles that can be granted, no ownership transfer. Deployers are `onlyFactory`, and a contract deployed any other way could not finish its constructor, because the factory's transient wiring would be empty.

### 7.4 Cross-fleet confusion

Covered in section 5. The rule: every per-fleet function that takes a key checks its fleet first; the collection never lets a caller choose the fleet it mints into; the collection only ever calls the key's own manager. Tests try every key-taking function with a foreign key.

### 7.5 Griefing

- Only the Safe creates fleets, so nobody can spam the collection with fake fleets that look official on OpenSea.
- Nothing loops over fleets anywhere. The transfer hook cost is bounded as today (one cohort plus at most five split assets), now with one extra hop (~5,000 gas, to measure).
- A receiver that reverts in `onERC721Received` only fails its own purchase. A key whose holder refuses ETH only blocks its own ETH claim, as today.
- A refused or starved VRF request leaves the key waiting for anyone's retry, as today; the purchase stands.
- Fibonacci holding limits stay per fleet, per level, per wallet.

### 7.6 Upgradeability

None. Every contract is final when deployed. The only forward-looking choice is question 4: whether the Safe may later register a *newer* factory for *new* fleets in the same collection. That changes nothing about existing fleets; its risk is that a bad newer factory could create bad new fleets in the official collection, which is why only the Safe could add one.

### 7.7 Invariants to test (Foundry, handler-based)

Run with three fleets of different presets on one collection, plus a handler that tries every privileged and key-taking function with random callers and foreign keys:

1. Every key belongs to exactly one fleet, for ever; its key number is at most its manager's `totalMinted`.
2. The sum of every fleet's `totalMinted` equals the collection's mint count.
3. A fleet with sales off has `totalMinted == 0`; only the Safe ever turned a fleet's sales on.
4. Registry entries never change; fleet numbers only grow.
5. No action in fleet B changes fleet A's presence queue, tallies, electorates, ledger backing, credits, treasury balances or holding counts (snapshot comparison).
6. Ownership epochs only increase; a shard ends when its key moves.
7. The collection and factory hold no tokens or ETH and approve nothing.
8. Each fleet's four contracts point at each other and at nothing else.
9. Every invariant in today's suite (`test/invariant/*`: presence queue, electorate never shrinks, rewards backing, split exactness, segregation, agents never paid, bound launch is the fleet's own) holds in every fleet side by side.
10. With a deck (question 7 a): no card is dealt twice in a fleet, cards dealt never exceed the deck size, keys after the deck have no card.

Plus: `check_bytecode.sh` finds no reachable `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in any contract, and Slither's delegatecall, arbitrary-send and reentrancy detectors run clean or are triaged.

---

## 8. What is deleted and what moves (hard cutover)

| Today | After |
|---|---|
| `src/Keyfleet.sol` | **Deleted.** ERC-721, epochs, VRF reveal, `tokenURI`, ERC-4906 → `KeyfleetKeys.sol`. Sale, presets, Cascade, rebate, protocol share, holding limits, `recognizeSurplus`, `firstMintAt` → `KeyfleetManager.sol`. |
| `Keyfleet.Metadata` (per-fleet name, symbol, metadata base) | **Deleted.** One name, symbol, base and `contractURI` on the collection. |
| `Keyfleet.Randomness`, per-fleet `TRAIT_TABLE_HASH` | Move to the collection, once. |
| `Keyfleet.Companions` and nonce prediction per fleet | **Deleted.** Replaced by CREATE2 + transient wiring (4.3). |
| `KeyfleetShards` per fleet | One shared record bound to the collection. |
| `KeyfleetVotes`, `KeyfleetTreasury`, `KeyfleetRewards` constructors taking a `Keyfleet` | No-argument constructors reading the factory's wiring; `FLEET` becomes `MANAGER` plus `KEYS` and `FLEET` (the number); own-key checks added. Logic otherwise unchanged. |
| `KeyfleetPresence` 32-bit ids | 64-bit ids (scheme a). |
| `script/KeyfleetStack.sol` | **Deleted.** |
| `DeployKeyfleets.s.sol` (one fleet per run) | Deploys the system once: deployers, factory (which deploys collection and shards). |
| (none) | New: create-fleet step that writes the Safe transaction for `createFleet`; on anvil it is sent directly. |
| `RecordKeyfleets.s.sol` | Records the system once, then each fleet from its `FleetCreated` event, reading every value back from chain. |
| `KeyfleetManifest.sol`, `deployments/*.json` | Shared bindings plus collection name, symbol, base and contract URI; per-fleet entries become preset (and deck) only. |
| `AnvilLab.s.sol` | Builds factory, creates a Classic fleet, opens its sales locally, buys two keys. |
| `check_bytecode.sh` | Checks the new contract list. |
| Tests | Fixture goes through the factory; every suite is ported; new suites in section 9. No test keeps a per-fleet collection. |

Nothing is deployed anywhere today (plan §1.2), so no deployed contract, claim or asset needs migrating.

**Site lane, list only (KF-SITE, after B4 fixes the ABI):** one collection address recorded once; the scanner reads one collection's `Transfer`, `OwnershipEpoch`, `KeyRevealed` and `MetadataUpdate` and each fleet's manager, Votes, Treasury and Rewards; key pages and the metadata route move to `/metadata/keys/:token_id`, decoding fleet and key number; purchase targets the fleet's manager, transfers and approvals the collection, shards the shared record; the buy button shows "sales have not opened" from `salesOpen`; `seed-deployment` takes the collection record plus each fleet record; deck cards are served for decked keys.

---

## 9. Build plan

Each step leaves `forge build` and `forge test` green, deletes what it replaces, and updates `contracts/README.md`. Steps B1 and B2 add new files that nothing else uses yet; B3 is the one cutover.

| # | Step | Tests | Size |
|---|---|---|---|
| B0 | This design; Sean's answers recorded here | — | doc |
| B1 | **`KeyfleetKeys` on its own.** Registry (written by a test factory), mint from a registered manager into its own fleet only, token ids (scheme per Q3), epochs, sales switch, reveal and retry, deck dealing (per Q7), `tokenURI`, `contractURI`, ERC-4906. Confirm the VRF consumer limit on a Base fork. | Mint refusals (unregistered, wrong fleet, sales off, existing id), only the Safe opens, ids and decoding, epoch bumps, hook goes only to the key's manager, reveal suite ported, deck: no repeats, deck size bound, callback never reverts and stays under its gas ceiling, golden draws unchanged | ~700 |
| B2 | **`KeyfleetFactory` and deployers.** CREATE2 prediction, transient wiring, constructor refusals, `createFleet` only by the Safe, fleets with and without decks, (Q4) adding a factory. | Wiring points both ways for every contract; wrong caller refused; a deployer called directly cannot produce a contract; transient wiring is empty after the call; sizes under limits; `createFleet` gas measured | ~500 |
| B3 | **Cutover.** `KeyfleetManager` replaces `Keyfleet`; Rewards, Votes, Treasury and Shards rebound; own-key checks; 64-bit presence ids; fixture through the factory; every existing suite ported; `Keyfleet.sol` and `KeyfleetStack.sol` deleted. | All of today's suites pass with unchanged expectations (prices, splits, Cascade, rebate, presence, electorate, signatures, execution, split, launch, Lit); sales-off refusal on every preset; transfer-hook gas ceiling with five split assets | ~1,800, mostly mechanical test moves |
| B4 | **Cross-fleet suite and multi-fleet invariants.** Every key-taking function with a foreign key; signed messages replayed across fleets; section 7.7 invariants with three fleets. | 7.7 at 256 runs × depth 100 or more | ~700 |
| B5 | **Scripts.** Manifest, system deploy, create-fleet Safe transaction, record, anvil lab, bytecode check list. | Deploy and record tests over mocks; refusals per pin; record refuses miswired fleets and a collection not yet a VRF consumer | ~600 |
| B6 | **Release readiness.** Base-fork gas report (`createFleet`, purchase, transfer, reveal callback), README, `docs/deployment.md`, `docs/deploy-checklist.md`. | `make check-contracts` green | ~300 |

---

## 10. Questions only Sean can answer

The build follows each recommendation until Sean answers; a different answer changes only the named steps.

**1. Who may create a new fleet?**
- a) Only the Regents Safe, with its 2-of-3 signatures. Any of the four fleet types, as many times as it chooses, with or without a card deck. *(recommended)*
- b) Anyone. Fleets would appear in the official collection without Regents' say, including fake-looking ones.
- c) The Safe, plus one named Regents operations wallet for speed.

*Changes B2 only.*

**2. Who turns on key sales for a fleet, and can they be turned off again?**
- a) Only the Regents Safe, one fleet at a time, and once on it stays on. Nothing else, including a fleet's own vote, can turn it on. *(recommended: no pause power over a live fleet)*
- b) Only the Safe, and it may turn a fleet's sales off and on again at any time.
- c) No switch: a fleet sells as soon as it is created.

*Changes B1. Every fleet starts with sales off under a or b.*

**3. What number does a key show on OpenSea?**
- a) Fleet number and key number in one: fleet 1's key 72 is #10000000072. The fleet is readable from the number itself, and checks are cheapest and safest. *(recommended)*
- b) One running count across every fleet in buying order (#1, #2, #3…). Shorter, but the number never matches the card's key number, and each purchase costs a little more.

*Changes B1 and B3. The card title (for example CLASSIC #1 · NO. 0072) shows either way.*

**4. When the fleet contracts are improved later, can new fleets join the same collection?**
- a) Yes: the Safe may add a newer factory for new fleets. Existing fleets never change. *(recommended, so the one collection lasts)*
- b) No: an improved version means a new collection on OpenSea.

*Changes B1 and B2.*

**5. Can the address that key pictures and details are read from ever move?**
- a) Never: fixed at keyfleet.ai when the collection is deployed, so keyfleet.ai must be kept for good. *(recommended: no one can change a key's picture source)*
- b) The Safe may move it (a new domain or permanent storage), and OpenSea is told to refresh every key.

*Changes B1. Traits and deck cards are fixed by each key's random number either way; only where pictures are served from differs.*

**6. If Chainlink ever retires the randomness service, what happens to keys bought afterwards?**
- a) Nothing can change it: those keys keep their interim card until a retried request is answered. *(recommended: no one can steer future draws)*
- b) The Safe may point future draws at a new randomness service; keys already drawn never change.

*Changes B1.*

**7. For fleets with a card deck, can two keys show the same card?**
- a) No: each card is dealt once, on chain, in the order the random numbers arrive. Each fleet's deck fingerprint is fixed when the fleet is created and can never change. *(recommended)*
- b) Yes: each key picks independently, so a 1,000-key fleet would show only about 630 different cards. The fingerprint is still fixed at creation.
- c) Decks stay off chain entirely; nothing fixes the deck, so it could be changed after keys are drawn.

*Changes B1 and B2. Each deck file must exist before its fleet is created.*

**8. What is the collection called on OpenSea?**
- a) "KeyFleet Keys", symbol KEYFLEET. *(recommended)*
- b) "KeyFleet", symbol KEYFLEET.
- c) Another name Sean gives.

*Changes B5 manifest only.*

**9. Should the collection ask marketplaces for a fee on resales?**
- a) No fee, as today. *(recommended: the spec keeps sale economics unchanged; marketplaces may ignore it anyway)*
- b) Ask for a fee, a percentage and recipient Sean names.

*Changes B1 only if b.*

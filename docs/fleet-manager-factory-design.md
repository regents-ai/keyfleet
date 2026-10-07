# One Key collection, one manager per fleet: design

**Date:** 7 October 2026
**Branch:** `kf/fleet-manager-factory`, from `kf/contracts-v03` at `10260c4`
**Status:** design only, round 2. No `.sol` file changes. Nothing is deployed, broadcast, signed or pushed. Key sales stay off until the Safe's phase steps (section 6).

**Sean's request, round 1 (7 Oct 2026, verbatim):** "For browsing on Opensea I would prefer if all of the Key NFTs in the different sets are part of the same collection address...but I want the NFTs to act as membership keys to different KeyfleetManager contracts that are created from a KeyFleetManagerFactory."

**Sean's direction, round 2 (7 Oct 2026, verbatim, voice-dictated):**

> 1. So these Key contracts are on Base. Is it possible to have the key cost always be purchased with USDC, but the USDC is automatically converted in the contract to market buy of REGENT from the uni v4 pool which is what is put into the shared treasury.
> 2. I want the site + contracts to work in phases. Phase 1: Only Classic fleet #1 is live Phase 2: The Regents Safe does a tx to make 3 more become available, Syndicate #1, Accelerant #1, and Cascade #1 Phase 3: The Regents Safe unlocks the creation of a keyfleet of any type, by anyone. They set the name of the fleet (goes onchain, 100 character limit) , the optional description onchain (2000 character limit), and can optionally add an image link to the contract (all of these are editable by majority vote of Keys) . Then, they set the starting price of a Key in USDC (10 usdc min, 1000000 max) and must buy the first key at the price they set, which also does the gas cost of creating the KeyfleetManager contract from the factory.
>    1. They can set also optionally set the joining requirements of buying a key to certain addresses. In the UI, by a combination of these allowlists: 'upload a csv of addresses (and our UI converts it into a token list or merkle tree? Idk how best to do it.) or a currently held NFT collection, a currently held token with balance greater than N' , and the UI allows the Keyfleet creator to select multiple of these requirements which . If the address buys the NFT / token required for allowlist and then sells after joining the Keyfleet, that is fine.

> "I want to make sure that people can't 'Look ahead' on the mediaweb links and see unreleased cards. The art / traits should only become known after that Keycard is minted"

**Relayed from the Keyfleet NFTs lane (7 Oct):** the first four fleets each get a pre-made 1,000-card deck; a key's random number picks its card from its fleet's deck. Keys 1,001 onward, and fleets 5 onward, use today's trait draw. Card titles count per type ("CLASSIC #1", a later second Classic fleet is "CLASSIC #2"). Sean's answer on how cards are dealt (7 Oct, verbatim): "The site picks; the deck fingerprint goes in the contract. And as long as it still works for the 1001 card, and N+1 cards to be created for any set of cards in a keyfleet." Section 3.5 covers it.

**Binding sources:** [contracts-build-now-spec-v0.3.md](contracts-build-now-spec-v0.3.md), Sean's answers recorded in [contracts-v0.3-plan.md](contracts-v0.3-plan.md) section 9, [product-spec.md](product-spec.md), as changed by Sean's round 2 words above. What round 2 changes in the money rules: the fleet treasury's share of each purchase arrives as REGENT bought on the market (section 7); fleets made by anyone have a creator-set starting price (section 8). Everything else (supplies, splits, vote, presence, daily split and claim rules) is unchanged. Those docs are updated to match in step B7.

Words used below: a **fleet** is what Sean calls a "set" or "keyfleet". A **key** is one ERC-721 token. The **collection** is the one shared ERC-721 contract. A fleet's **manager set** is the per-fleet contracts the factory creates. The **Safe** is the Regents Safe on Base, `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. The four **founding fleets** are Classic #1, Syndicate #1, Accelerant #1 and Cascade #1. An **open fleet** is one anyone creates in phase 3.

---

## 1. Today, in one paragraph

Each fleet is five contracts with no shared state. `Keyfleet` (14.6 KB runtime) is both the ERC-721 and the sale: it holds the keys, ownership epochs, the VRF reveal, the preset economics (prices, supply, Fibonacci holding limits, Cascade reserve, Accelerant rebate), the owed 10% protocol share, and `firstMintAt`. It deploys its `KeyfleetRewards` ledger (8.4 KB) and `KeyfleetShards` record (3.6 KB) in its constructor; `KeyfleetVotes` (14.5 KB) and `KeyfleetTreasury` (10.8 KB) are deployed next at addresses predicted from the deployer's nonce, and each refuses a fleet that does not name it (`script/KeyfleetStack.sol`). Each `Keyfleet` is its own OpenSea collection with its own name, symbol, metadata base and VRF consumer slot. Every purchase is paid and kept in USDC. On chain, nothing stops a deployed fleet from selling: "sales off" today means "no fleet is deployed and the site has recorded none" (`docs/deploy-checklist.md`, "Key sales stay off").

## 2. The shape after the change

```
                       KeyfleetFactory  (one)
                         |   deploys in its constructor
                         v
   KeyfleetKeys  <---- one ERC-721 collection: every key of every fleet; phase; registry
   KeyfleetShards <--- one agent-shard record for every key (keyed by token id)
   KeyfleetRegentBuyer  one shared, stateless USDC -> REGENT swapper (section 7)

   createFoundingFleet(preset, deck)     Safe only, fleets 1-4, sales closed
   createFleet(terms, first-key inputs)  anyone, phase 3 only, creator buys key 1
        -> one manager set per fleet, in one transaction:
        KeyfleetManager   sale, price, profile, joining requirements, transfer hook
        KeyfleetVotes     presence + proposals + ballots          (as today)
        KeyfleetTreasury  free capital, exact calls, daily split  (as today)
        KeyfleetRewards   member claims ledger                    (as today)
```

| Contract | How many | Holds | Comes from |
|---|---|---|---|
| `KeyfleetKeys` | one | Who owns each key, which fleet it belongs to, ownership epochs, each key's VRF seed, each fleet's deck fingerprint and size (3.5), the fleet registry, the phase and each fleet's sales switch (section 6) | ERC-721 and reveal parts of `Keyfleet.sol` |
| `KeyfleetShards` | one | Agent shards and agent-voting switches, per key | `KeyfleetShards.sol`, rebound from one fleet to the collection |
| `KeyfleetFactory` | one | Shared bindings (USDC, REGENT, staking, Autolaunch); nothing of value | new |
| `KeyfleetRegentBuyer` | one | Nothing between calls; the pinned swap route | new (section 7) |
| `KeyfleetManager` | one per fleet | Type, starting price, prices, `totalMinted`, `firstMintAt`, Cascade reserve, owed protocol share, Fibonacci holding counts, name, description, image link, joining requirements | sale and money parts of `Keyfleet.sol`, plus round 2 |
| `KeyfleetVotes`, `KeyfleetTreasury`, `KeyfleetRewards` | one each per fleet | Exactly what they hold today | today's files, rebound to the manager and collection |
| four small deployers | one each | Nothing; each holds one per-fleet contract's creation code | new (section 4.3) |

"The manager" in Sean's words is the fleet's whole manager set: `KeyfleetManager` is its front door and address book, and the other three are its parts. It cannot be one contract: the four together are about 45 KB of runtime code against Base's 24,576-byte limit per contract (EIP-170).

---

## 3. The shared Key collection

### 3.1 What OpenSea sees

One contract address, one collection page. `name()` and `symbol()` are fixed at deploy (question 19). `contractURI()` (ERC-7572) returns a fixed URL for the collection page's picture and description. Each key's metadata carries `Fleet type`, `Fleet` (for example `CLASSIC #1`), the fleet's name and `Key number` as attributes, so OpenSea's trait filter lets a buyer narrow the one collection to one fleet. One `setApprovalForAll` to a marketplace now covers a holder's keys in every fleet; that is ordinary ERC-721 and grants nothing in any fleet's votes (spec §5.1).

### 3.2 Which fleet a key belongs to, and its token id

Every fleet gets a number from the collection when it is created: `1, 2, 3, ...` across all types, never reused, never changed. The founding fleets are 1 to 4 (section 6). The collection also records the fleet's type and its number within that type (`CLASSIC #1`, `CLASSIC #2`), so the card title is provable on chain. Within a fleet, keys are numbered `1..n` exactly as today; that number drives every price, level, cohort and rebate rule.

The token id must carry both. Two ways (question 15):

- **(a) Recommended: fleet number and key number in one id.** `tokenId = fleet × 10^10 + key`. Fleet 1's key 72 is `#10000000072`; fleet 2's key 1 is `#20000000001`. The fleet is `tokenId / 10^10`, worked out with no storage read, which makes the cross-fleet check (section 5) cheap and impossible to get wrong. The key number fits under 10^10 because a fleet already stops at 4,294,967,295 keys. Cost: long numbers in OpenSea's URL and detail panel; the card title and name read normally.
- **(b) One running count across the collection.** `#1, #2, #3` in mint order across every fleet. Short ids, but a key's id and its card number differ (Classic #1's key 72 might be `#3410`), and the collection must store the fleet and key number per token (about 22,000 more gas per mint), and every check of a key's fleet is a storage read.

### 3.3 Ownership epochs and transfers

`ownershipEpoch[tokenId]` moves into the collection unchanged: 1 at mint, plus one on every transfer. Token ids are unique across the collection, so one mapping serves every fleet. On every mint and transfer, `KeyfleetKeys._update` does, in today's order:

1. Calls the key's own fleet manager, `managerOf[fleetOf(tokenId)].onKeyMoved(tokenId, from, to)`. The manager settles the key's rewards to `from`, clears its presence in the fleet's Votes, and enforces the Fibonacci holding limit on `to`, exactly what `Keyfleet._update` does today. A transfer only ever calls the one manager the key belongs to.
2. Bumps the epoch and emits `OwnershipEpoch`.
3. Moves ownership (`super._update`).

### 3.4 Reveal, `tokenURI` and ERC-4906

- **VRF moves into the collection, once.** One coordinator, subscription and gas lane for every fleet, and one VRF consumer for the Safe to add, instead of one per fleet. This matters more now that anyone can create fleets: a Chainlink v2.5 subscription takes at most 100 consumers (to confirm against the Base coordinator in step B1), which per-fleet VRF would hit at fleet 101. Request, retry (`requestReveal`), callback rules, 3 confirmations, native payment and the never-reverting callback stay as written today. The seed stays `keccak256(TAG, chainid, collection, tokenId, word)`; the collection address and a collection-unique id keep every seed distinct. Every reveal in every fleet, open fleets included, is paid from the Regents subscription (question 14).
- **One trait table for every fleet.** The product spec already says every key in every fleet draws from one table, so `TRAIT_TABLE_HASH` is fixed once on the collection: `0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe`, the table Sean set on 7 Oct (keyfleet main `3172c4a`, `platform/priv/trait_tables/<hash>.json`; each trait's weights sum to 1,000). It replaces the earlier table everywhere; when the build starts, the earlier value appears nowhere in contracts, tests or scripts.
- **`tokenURI(id)` = one fixed base + the id**, for example `https://keyfleet.ai/metadata/keys/10000000072`. It reverts for an id that has not been minted. The site decodes the fleet from the id. Whether the base may ever move is question 17.
- **ERC-4906:** the collection emits `MetadataUpdate(tokenId)` when a seed is written, so OpenSea refreshes that key, as today. The collection is the only contract that needs to emit it, since OpenSea listens to the collection address. A change to a fleet's name, description or image (8.3) emits `BatchMetadataUpdate` over that fleet's id range, so OpenSea refreshes the fleet's keys.

### 3.5 Per-fleet card decks

**Sean's answer (7 Oct, verbatim, relayed by the Keyfleet NFTs lane on KF-DECK-PICK):** "The site picks; the deck fingerprint goes in the contract. And as long as it still works for the 1001 card, and N+1 cards to be created for any set of cards in a keyfleet."

What that means, as chosen: **no repeats**. The site deals each decked key a card from the fleet's remaining cards, in the order the keys' reveals happened on chain, using each key's seed. The chain holds only the deck's fingerprint and size. A fleet created with a deck of `N` cards shows deck cards for keys `1..N`; key `N+1` onward (key 1,001 in a 1,000-card fleet), and every key of a fleet created without a deck, uses the trait draw. Only the four founding fleets have decks; open fleets have none and use the trait draw (question 12).

**On chain (all of it):**

- `createFoundingFleet(preset, deckHash, deckSize)` records the deck fingerprint and size with the fleet, forever. Both zero means "no deck"; one zero and the other not is refused. Neither can ever change, so a deck cannot be swapped after any seed is known (the same reason `TRAIT_TABLE_HASH` is fixed before the first sale). The collection announces them in its fleet-registered event and returns them from `deckOf(fleet)`.
- **No dealing on chain.** The reveal callback is unchanged from today: it writes the seed once, emits, never reverts, and keeps today's 100,000 callback gas limit. There is no card map and no `cardOf`.
- The reveal event carries everything the deal needs: `KeyRevealed(tokenId, fleet, keyNumber, requestId, seed)`. The fleet and key number are in the event so it reads the same under either token id scheme (question 15). The deal order comes from the log itself: block number, then log index. A key whose first randomness request failed and was retried takes its place when its reveal actually lands.

**Deck files (from the NFTs lane):** one file per fleet, JSON `{"fleet", "table", "cards": [1,000 0x-prefixed 32-byte card seeds]}`, cards indexed `0..999`, all bound to trait table `0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe`. `deckHash` is keccak256 of the file's exact bytes; `deckSize` is 1,000. The file must exist, and its fingerprint be fixed, before its fleet is created. The four `createFoundingFleet` inputs (keyfleet branch `kf/fleet-decks` at `44295e5`, local and unpushed):

| Fleet | `deckHash` | `deckSize` |
|---|---|---|
| CLASSIC #1 | `0xe9b1900adb56811096d08f67852af8a64ec509ed2982e94f14f172f687b577e7` | 1000 |
| SYNDICATE #1 | `0x1298cf785709867c5397762ba4dfa3d4a1c1394db0cd26444285c48cc6e57706` | 1000 |
| CASCADE #1 | `0x2942590c4d3873db390aef50e4648137fdb93729a370105a1aa9a62e43222b66` | 1000 |
| ACCELERANT #1 | `0xbac8510a15a85770ff5cb64b4f0fef57244235ee79327ce3e3e375ce629b6d4d` | 1000 |

Decks stay private. Only the rarities are public, as they are now. The contract holds only each deck's fingerprint and size, fixed when the fleet is created.

The reveal order is final only once the reveals' blocks are final, so the site deals from confirmed reveals.

`tokenURI` does not change: the site serves the deck card's picture for decked keys and the drawn card for the rest. The metadata adds a `Card` attribute.

---

## 4. The factory and each fleet's manager set

### 4.1 The two ways a fleet is created

**Founding fleets, `createFoundingFleet(preset, deckHash, deckSize)`, Safe only.** Exactly four, in this fixed order, each refused out of order or a fifth time: fleet 1 Classic, fleet 2 Syndicate, fleet 3 Accelerant, fleet 4 Cascade, each with its deck from the table above. Each uses its type's standard starting price (Classic 8 USDC rising to 80; the others 10 USDC), so founding fleets sell at exactly today's prices. No joining requirements. Their name, description and image start as the Safe sets them in the same call and are then the fleet's own to change by vote (8.3). They are created with sales **closed**; the phase steps open them (section 6). The Safe buys no key.

**Open fleets, `createFleet(terms, firstKey)`, anyone, only once the Safe has moved to phase 3.** Section 8.

Both run the same steps in one transaction:

1. The collection registers a new fleet: it assigns the fleet number and per-type number, and records the type, deck and the manager's (predicted) address.
2. The factory deploys the fleet's `KeyfleetManager`, `KeyfleetVotes`, `KeyfleetTreasury` and `KeyfleetRewards`, each at an address computed in advance (4.3), each bound to the others and to the collection, the shared shards, the REGENT buyer, USDC, REGENT, REGENT staking and the Autolaunch factory.
3. Emits `FleetCreated(fleet, preset, typeNumber, creator, startPrice, manager, votes, treasury, rewards)`.

Round 1 said "the preset is the only economic input". Round 2 replaces that: a fleet's economic inputs are its **type** (one of the four rule sets, with all of its supply, level, holding-limit and split rules) and its **starting price**. Founding fleets use the standard starting prices; open fleets choose one from 10 to 1,000,000 USDC. Nobody can set a split, supply, rate, threshold or address for a fleet: those are the type and the factory's fixed bindings.

### 4.2 Clones or full deploys

| | Minimal clones (EIP-1167) | Full deploys (recommended) |
|---|---|---|
| Gas to create a fleet | ~0.3M | ~10–12M for the four contracts (to measure) |
| `DELEGATECALL` | Every call to every fleet goes through one. Contradicts spec §4.2 and fails our own bytecode check (`script/check_bytecode.sh`) by design | None anywhere |
| Wiring | Storage, written by an `initialize` call; needs locked implementations and same-transaction initialisation to avoid hijack | `immutable`, fixed by the constructor, unreadable to change |
| Per-call cost | Each wiring read is a cold storage read (2,100 gas), many per transfer and vote | Immutables cost nothing to read |
| Audit surface | Initializers, implementation lock, proxy forwarding | The same constructors reviewed today |

Recommendation: full deploys. Now that a creator pays for their own fleet (section 8), the cost matters a little more, but it is still small: Base's gas price read on 7 Oct was 0.006 gwei with ETH at about 2,574 USD, so a ~15M-gas open creation (four deploys, an on-chain profile, the first purchase with its swap) costs about 0.0001 ETH, roughly 0.25 USD, plus a small L1 data fee. To measure in B2.

**Per-transaction gas cap: to confirm.** Ethereum's Fusaka upgrade caps one transaction at 16,777,216 gas (EIP-7825). I could not confirm from chain reads whether Base enforces that cap (Base's block gas limit read on 7 Oct is 400,000,000). If it does, an open creation must stay under about 16.7M gas, so B2 measures it against that cap and the build keeps the profile writes and manager size lean. Founding fleets are created one per transaction, so the cap does not touch phase 2.

### 4.3 How four contracts that point at each other get deployed at once

Votes and Treasury name each other; the manager, Rewards and Treasury name each other. Constructor arguments cannot carry that loop, because each address depends on the others' code. The design uses the pattern Uniswap v3 uses for its pools:

- Each per-fleet contract has **no constructor arguments**. It is deployed with `CREATE2`, salt = fleet number, so its address depends only on its deployer, the fleet number and its fixed creation code. The factory computes all four addresses before deploying any.
- During creation the factory holds the fleet's wiring (fleet number, type, starting price, the four addresses, the shared bindings) in transient storage. Each constructor reads it back from the factory, stores it in immutables, and refuses to deploy unless its own predicted address is `address(this)`. The transient record is empty outside a creation. Strings and requirements (8.3, 9) are not immutables: the factory writes them into the new manager with one `onlyFactory` call during the same creation, after which nothing but the fleet's own vote can change the profile.
- The factory cannot hold all four creation codes itself (they total ~45 KB against the 24,576-byte limit), so each lives in its own small **deployer** contract, `onlyFactory`. The deployers are deployed first with the factory's address predicted from the deploying account's nonce, and the factory's constructor refuses any deployer that does not name it: today's `KeyfleetStack` technique, used once for the whole system instead of once per fleet.
- The factory's constructor deploys `KeyfleetKeys`, `KeyfleetShards` and `KeyfleetRegentBuyer`, so their links to the factory are fixed at birth with no window.

Estimated sizes (measured in B1–B5): collection ~11–13 KB, manager ~13–15 KB (it keeps the 2 KB Classic price table and gains the profile, requirements and swap call), Votes ~15 KB, Treasury ~11 KB, Rewards ~8.5 KB, Shards ~3.7 KB, REGENT buyer ~4 KB, factory initcode ~18 KB. All under the limits; the manager is the one to watch.

### 4.4 Who trusts whom

| Caller → callee | Allowed because | Checked by |
|---|---|---|
| Safe → factory `createFoundingFleet` | Only the Safe creates the four founding fleets, in fixed order | `msg.sender == SAFE`; fleet count < 4; type matches the slot |
| Anyone → factory `createFleet` | Phase 3 lets anyone create | `KEYS.phase() == 3`; input bounds (section 8) |
| Safe → collection `advancePhase()` | Only the Safe moves phases, one way | `msg.sender == SAFE` |
| Safe → collection `setRegentBuyer` | Only if question 4 is (b) | `msg.sender == SAFE` |
| Factory → collection `registerFleet` | The collection's own factory | `isFactory[msg.sender]` |
| Factory → manager `writeProfileAndRequirements`, `sellFirstKey` | Once, during the fleet's own creation | `msg.sender == FACTORY` and a write-once flag |
| Manager → collection `mint(to, keyNumber)` | Only a fleet's registered manager mints, and only into **its own** fleet: the collection takes the fleet from `fleetOfManager[msg.sender]`, never from an argument | registry lookup; sales switch; ERC-721 refuses an existing id |
| Manager → REGENT buyer `buy` | Swaps the manager's own USDC for its own fleet's treasury | the buyer pulls from `msg.sender` and pays the given treasury; it trusts no caller |
| Uniswap v3 pool / v4 PoolManager → REGENT buyer callbacks | Only during a swap the buyer started | `msg.sender` is the pinned pool or PoolManager, and the buyer's transient "swap in progress" flag is set |
| Collection → manager `onKeyMoved` | The transfer hook | `msg.sender == KEYS` |
| Treasury → manager `setProfile` | An approved proposal of that fleet's Keys (8.3) | `msg.sender == TREASURY` |
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

**Transfers:** settle-then-clear-then-epoch, as 3.3; the incoming owner starts from the current indexes in the key's own fleet only. Joining requirements are not checked on transfers unless question 8 says so.
**Ownership epochs:** global per token; every fleet reads the same value, which is correct because a key is in one fleet.
**Delegation:** one shared `KeyfleetShards`, keyed by token id. A shard grants authority over one key, and that key only counts in its own fleet, so a shard can never reach another fleet. `delegationRevision` stays per key.
**Signatures:** the EIP-712 domain's verifying contract is the fleet's own Votes, and the message names the fleet's manager and globally unique key ids, so a signed Present or Ballot for fleet A cannot be replayed in fleet B.
**Ballot slots:** one per key per proposal, per fleet's Votes, as today.
**Presence ids:** `KeyfleetPresence` packs ids in 32 bits today. Under scheme (a) it widens to 64 bits (`prev`, `next`, `expiresAt` still share one storage slot), which holds up to 1.8 billion fleets.

---

## 6. Phases, and key sales staying off until each phase

Sean: "I do not want the contracts or the frontend site to enable purchases of keys until I explicitly say so." Round 2 turns that into three Safe steps. Each step is a Safe transaction Sean signs, so each is his explicit go.

The collection holds `phase`, 0 to 3, which only the Safe changes and only upward, one step at a time, with `advancePhase()`:

| Phase | Reached by | What it opens | Refused unless |
|---|---|---|---|
| 0 | deploy | Nothing sells. The Safe creates the founding fleets (4.1), one per transaction, any time before the step that opens them | — |
| 1 | Safe `advancePhase()` | Classic #1's sales | fleet 1 exists |
| 2 | Safe `advancePhase()` | Syndicate #1, Accelerant #1 and Cascade #1's sales, together | fleets 2–4 exist |
| 3 | Safe `advancePhase()` | `createFleet` for anyone; each open fleet sells from the moment it is created, starting with its creator's key 1 (question 5) | — |

- **Where sales are gated:** `KeyfleetKeys.mint` reverts `SalesClosed(fleet)` unless that fleet is open: fleet 1 from phase 1, fleets 2–4 from phase 2, an open fleet from its creation (which phase 3 alone allows). Every purchase in every fleet ends in this one function, so the gate holds even if a manager had a bug. There is no other mint path: no admin mint, no airdrop, no treasury mint, no factory mint (the creator's key 1 goes through the same `mint`).
- **Nothing else moves a phase:** not the factory, not a fleet's treasury or an approved proposal (the treasury is not the Safe), not time, not the site. No step back (question 5).
- **The site:** the fleet page reads `salesOpen(fleet)` and, while it is closed, shows the buy button disabled with a few words saying sales have not opened (rule 11's exception: a press certain to fail from chain state). The create-a-fleet page does the same from `phase()`. The site's own purchase gate (`seed-deployment`, the `build.ex` purchase step) stays as it is; this design adds the chain switch, it does not remove the site's.
- **Proof:** unit tests that `purchase` reverts on each founding fleet before its phase, that `createFleet` reverts before phase 3, that every caller but the Safe is refused by `advancePhase`, that phases cannot skip or go back, and an invariant that a fleet whose sales are closed has `totalMinted == 0` while a handler tries every entry point with random callers.
- **Scripts:** the deploy and create-founding-fleet steps never call `advancePhase`. Only the anvil lab does, on a local chain, acting as the Safe there, so the site's local buy tests keep working.

---

## 7. Paying in USDC, holding REGENT

Sean: "the key cost always be purchased with USDC, but the USDC is automatically converted in the contract to market buy of REGENT from the uni v4 pool which is what is put into the shared treasury."

### 7.1 The REGENT market on Base (read from chain, 7 Oct 2026, block 52,299,795)

- **There is no REGENT/USDC pool.** REGENT trades against WETH. The main pool is Uniswap v4, pool id `0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed`, read back from the v4 PositionManager and checked by hashing the key:
  - currency0 WETH `0x4200000000000000000000000000000000000006`, currency1 REGENT `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`
  - fee `0x800000` (the hook sets the fee per swap; it read as 1% LP fee in slot0), tick spacing 200
  - hook `0xd60D6B218116cFd801E28F78d011a203D2b068Cc`, whose `factory()` is `0xE85A59c628F7d27878ACeB4bf3b35733630083a9` (I believe that is Clanker's v4 factory; to confirm in B4). Its permission bits are before-initialize, before-add-liquidity, before-swap and after-swap, both of which may change swap amounts. So the hook is third-party code that runs inside every swap and can take a fee from it.
  - PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b` (the same pin Autolaunch uses).
- **Depth.** DexScreener lists about 141,000 USD of liquidity and about 3,400 USD of trading over 24 hours; a second REGENT/WETH pool on Hydrex holds about 36 USD and is ignored. REGENT was about 0.0000107 USD. Quotes from the Uniswap v4 quoter, compared with the pool's own price, all fees included:

| USDC in (as WETH) | REGENT lost to fees and price movement |
|---|---|
| 10 | ~1.2% |
| 1,000 | ~2.7% |
| 10,000 | ~15% |
| 100,000 | ~62% |

  So the pool handles keys of tens to low thousands of USDC well. It cannot absorb large keys, and Sean's maximum starting price (1,000,000 USDC) and the later prices of Accelerant and Fibonacci fleets go far past its depth. Question 3 covers this.
- **USDC to WETH.** The Uniswap v3 USDC/WETH 0.05% pool `0xd0b53D9277642d899DF5C87A3966A349A798F224` is deep: 100,000 USDC moves it about 0.15%, 1,000,000 USDC about 1.4%.

### 7.2 The route

The shared `KeyfleetRegentBuyer` does, for one `buy(usdcIn, minRegentOut, treasury)`:

1. Pulls `usdcIn` USDC from the calling manager.
2. Swaps USDC → WETH directly on the pinned v3 pool (`pool.swap`, paying in `uniswapV3SwapCallback`).
3. Swaps WETH → REGENT on the pinned v4 pool inside `PoolManager.unlock` (`unlockCallback`: `swap` exact-in, `sync` + transfer + `settle` the WETH, `take` the REGENT straight to the fleet's treasury).
4. Checks the treasury's REGENT balance rose by at least `minRegentOut`, and that every USDC and WETH was spent; otherwise it reverts the whole purchase.

It calls the pools directly rather than through Uniswap's Universal Router: no Permit2 approvals, no command bytes from outside, and only two callbacks to check. The constructor pins both pools and refuses a v4 pool key whose hash is not the pool id above. It holds nothing between calls, so anyone may call it with their own USDC; that gives them nothing.

Whether this route is fixed forever or the Safe may point new purchases at a new one (if REGENT's liquidity moves) is question 4. If it is fixed and the pool stops working, every purchase in every fleet reverts until it works again.

### 7.3 Which USDC is swapped

Today a purchase splits like this (`KeyfleetPresets.splitPurchase`). Recommended (question 1 a): only the money that goes into the fleet's treasury becomes REGENT; the promises the contracts make in USDC stay in USDC.

| Part of a purchase | Today | Recommended |
|---|---|---|
| Protocol share, 10% of every purchase | USDC, deposited into REGENT revenue staking through `depositUSDC` | Unchanged: USDC. Staking takes USDC. |
| Classic and Syndicate: the other 90% | USDC to the fleet treasury | **Swapped to REGENT**, into the fleet treasury |
| Accelerant key 1: the other 90% | USDC to the fleet treasury | **Swapped to REGENT** |
| Accelerant later keys: 20% | USDC to the fleet treasury | **Swapped to REGENT** |
| Accelerant later keys: 70% rebate to the previous key's holder | USDC credited in Rewards | Unchanged: USDC |
| Cascade: the other 90% | USDC held as the level reserve | Unchanged: USDC, because it refunds the previous level's buyers in USDC |
| Cascade: the reserve left over when a level completes | USDC released to the fleet treasury | **Swapped to REGENT** in the purchase that completes the level |

Every purchase makes at most one swap: the manager adds up the USDC bound for the treasury in that purchase and swaps it once. A purchase that sends nothing to the treasury (most Cascade purchases) makes no swap.

The treasury needs no change: REGENT is already one of its daily-split assets (split once it holds 100 REGENT). Members' daily split income then comes mostly in REGENT instead of USDC. `recognizeSurplus` (USDC or other tokens sent to the manager by mistake) still forwards them unswapped, as today.

### 7.4 Price protection

- **The buyer's step carries a minimum.** `purchase(receiver, maxPrice, minRegentOut, deadline, proof)`. The site's server-built purchase step quotes the swap at the latest block and sets `minRegentOut` a little below it (for example 1% below). If the swap would deliver less, the purchase reverts: no key, the buyer keeps their USDC. No oracle is involved; the pool's own quote at the latest block is the only price.
- **What it does not stop.** The minimum protects the fleet's treasury only as well as the buyer sets it. A buyer who calls the contract directly can set a weak minimum and trade around their own purchase (buy REGENT just before, sell just after) to take part of the treasury's share. The money at stake is the price the pool gives the swap, so it is small for keys of tens of USDC and real for keys of tens of thousands. Base has no public waiting room for transactions, which makes others' sandwiches harder but does not stop a buyer doing it to their own purchase. Question 3.
- **If the swap cannot fill** (the pool lacks the REGENT, the hook refuses, the price is under the minimum), the whole purchase reverts. The buy button is not blocked for this: a press that only might revert is never blocked (rule 11).
- **Gas.** The v4 swap through this hook quoted about 600,000 gas, plus about 90,000 for the v3 hop. On Base that is about 0.01 USD.

### 7.5 Reentrancy around the swap

The swap runs third-party code: the Uniswap pools and, inside every swap, the pool's hook.

- The manager books everything first (price step, totals, split, Cascade state) and swaps after, under its own lock; a hook calling back into the same manager's `purchase` is refused.
- The buyer has its own lock and a transient flag naming the swap it started; each callback checks `msg.sender` is the pinned pool or PoolManager and the flag is set, so nothing else can make it pay.
- A hook could call another fleet's `purchase` during the swap, but only with its own money, and that fleet's lock and books are separate. The collection's mint lock is not held during the swap; the swap happens before the mint, and the only untrusted callback after it is `onERC721Received`, as today.
- The buyer measures what arrived (the treasury's balance change), never what a pool or hook reports.

---

## 8. Fleets anyone can create (phase 3)

### 8.1 What the creator gives

`createFleet(terms, firstKey)`:

- **Type:** one of Classic, Syndicate, Cascade, Accelerant, with all of that type's rules: supply (Classic 1,024; Accelerant 2,000; Fibonacci types without end), levels, holding limits and purchase split. "Of any type" is read as these four (question 6).
- **Name:** 1 to 100 bytes, on chain. Bytes, not letters: plain letters are one byte each, but an emoji or accented letter takes 2 to 4.
- **Description:** 0 to 2,000 bytes, on chain.
- **Image link:** optional, up to 512 bytes, on chain. The contract stores the text and does not check it.
- **Starting price:** 10 to 1,000,000 USDC.
- **Joining requirements:** optional (section 9).
- **First key:** `minRegentOut` and `deadline` for the creator's key 1.

### 8.2 The creator buys key 1 and pays for the deploy

In the same transaction that creates the fleet, the creator buys key 1 at their starting price: the creator approves the factory (a fixed address; the manager's address is not known until creation) for exactly that USDC, the factory passes it to the new manager, and the manager runs the normal purchase for key 1 to the creator (split, swap, mint, reveal request). The creator pays the transaction's gas, which covers the four deploys. If any part fails, nothing is created.

### 8.3 Name, description and image, changed by vote

They live in the manager. `setProfile(name, description, imageLink)` is callable only by the fleet's own treasury, which means only an approved proposal of that fleet's Keys reaches it, through today's Votes → Treasury exact-call path. The same limits apply. "Majority vote of Keys" is read as today's approval rule: more than half of the proposal's electorate, the Keys marked present (question 11). Founding fleets have the same profile and the same rule.

The collection's `tokenURI` does not change with the profile; the site's metadata reads the profile and the manager emits `ProfileChanged`, which the collection forwards as an ERC-4906 refresh for the fleet's keys.

### 8.4 What "starting price" means for later keys

Recommended (question 6 a): key 1 costs the starting price and later keys follow the type's curve scaled to it, so a creator's fleet behaves like the founding fleet of its type, only dearer or cheaper:

- **Syndicate and Cascade:** level 1 costs the starting price; each later level costs 20% more, as today with 10 USDC replaced by the starting price.
- **Accelerant:** key 1 costs the starting price; each later key costs 5% more, as today.
- **Classic:** today's 1,024-step table from 8 to 80 USDC, multiplied by starting price ÷ 8, rounded up to the cent.

Founding fleets use 8 USDC (Classic) and 10 USDC (others), which gives today's prices exactly. The arithmetic stays inside 256 bits for every type at 1,000,000 USDC (checked in B3).

### 8.5 Contract size, gas and creation risks

- Gas, size and the per-transaction cap: 4.2 and 4.3.
- **Spam and abuse.** Anyone can create a fleet in the official collection for 10 USDC plus cents of gas, with any name, description or image link. Those are on chain and the contracts cannot refuse them. What OpenSea shows comes from keyfleet.ai's metadata, so the site decides what it displays (question 13).
- **Randomness cost.** Every key in every open fleet asks for a Chainlink draw paid from the Regents subscription: cents per key on Base, but it scales with other people's fleets (question 14).

---

## 9. Joining requirements

The creator may set any of these at creation; none means anyone may buy:

- **Address list.** The site turns the creator's CSV into a Merkle tree (OpenZeppelin's standard tree: each leaf is the address, double-hashed) and keeps the list to serve each buyer their proof. The fleet stores only the tree's root. The buyer's purchase carries the proof; the manager checks it with OpenZeppelin `MerkleProof`. One root holds any number of addresses at the same on-chain cost.
- **Holds an NFT.** An ERC-721 collection address: the buyer must hold at least one (`balanceOf > 0`).
- **Holds a token.** An ERC-20 address and an amount N: the buyer must hold at least N.

How they work:

- **Checked once, when buying from the fleet**, at that moment. Selling the NFT or token afterwards is fine, as Sean said. Not checked on resales unless question 8 says so.
- **Whose address:** the wallet receiving the key, since that is who joins; the creator's own key 1 is not checked (question 7).
- **Combining:** Sean's sentence on combining several requirements is cut off ("which ."), so whether a buyer must meet every requirement the creator picked or just one is question 7.
- **Fixed at creation** unless question 9 says the Keys may change them by vote.
- **Calls only read.** The NFT and token checks use read-only calls (`staticcall`), so a hostile token cannot change any state during a purchase. A token that reverts or lies only affects the fleet whose creator chose it. At creation the factory checks only that each named address has code.

Risks Sean should know (question 10):

- **Borrowed balances.** A buyer can borrow the token (a flash loan) or buy and sell it inside the same transaction to pass the token check. That is the same-transaction version of "buys then sells after joining", which Sean said is fine.
- **Fake, rebasing or fee-taking tokens.** The check reads `balanceOf` once; it is only as meaningful as the token the creator picked.
- **ERC-1155** collections (many game items and editions) are not covered by "holds an NFT" as designed.

---

## 10. Security analysis

### 10.1 Trust boundaries

| Party | Can | Cannot |
|---|---|---|
| Regents Safe | Create the four founding fleets in order; move phases forward; set the swap route if question 4 is (b); add a newer factory if question 16 is (a) | Mint a key, move or burn anyone's key, touch any fleet's money, votes, claims, rate, profile or treasury, change a fleet after creation, change a price, supply or split, close sales, step a phase back |
| Anyone (phase 3) | Create a fleet within the input limits, buying its key 1 | Create before phase 3; pass inputs out of bounds; affect any other fleet |
| Factory | Register and deploy fleets; write a new fleet's profile and requirements once; hand the creator's USDC to the new manager | Anything after creation; it keeps no rights over a fleet |
| REGENT buyer | Swap the USDC a manager hands it and pay REGENT to that manager's treasury | Hold value between calls; be paid by anyone but the pools it started a swap with |
| Uniswap pools and the REGENT pool's hook (third-party code) | Run during each swap; take fees; refuse a swap | Make a purchase deliver less than its `minRegentOut` (it reverts) |
| A fleet's creator-chosen requirement contracts (third-party code) | Answer `balanceOf` during that fleet's purchases, read-only | Change state; reach any other fleet |
| A fleet's manager | Mint its own fleet's next key during a purchase; receive its own keys' transfer hooks | Mint into another fleet; see or touch another fleet's keys |
| A fleet's treasury (approved calls) | Anything an exact approved call can do, as today, including its fleet's profile and buying or holding other fleets' keys | Reach any `onlySafe`, `onlyFactory`, `onlyManager` or `onlyKeys` function; fund the ledger outside the split |
| Key holders and agents | As today, within their own key's fleet | Act in another fleet with a key |

There is still no upgrade path, proxy, pause, burn, setter of economics, or `delegatecall` in any contract.

### 10.2 Reentrancy across collection, manager and swap

- `purchase` (manager) holds the manager's lock and calls `KEYS.mint`, which calls back into the same manager (`onKeyMoved`) from inside `_update`. That callback must not take the manager's lock, or minting would fail. It is safe because it is `onlyKeys`, makes no token transfer and calls only the fleet's own Rewards and Votes bookkeeping.
- `KEYS.mint` holds a collection-wide lock shared with `requestReveal`, so a receiver contract cannot mint again (in any fleet) or add a second VRF request from inside `onERC721Received`. Transfers do not take that lock, so a receiver may still forward a fresh key from inside `onERC721Received`, as today (the key is enrolled before it is minted).
- Purchase order: checks (deadline, price, joining requirements), USDC in, split booked, swap of the treasury's part (7.5), enrol, mint (`onERC721Received`), Cascade completion, reveal request last. When a purchase completes a Cascade level, the level's books are settled before the single swap runs.
- The factory's `createFleet` holds its own lock across creation and key 1.
- The transfer hook calls no untrusted code: collection → own manager → own Rewards and Votes, all our immutable code.
- The VRF callback is `onlyCoordinator`, writes once, never reverts, and makes no external call.

### 10.3 Access control

Every privileged function is in the 4.4 and 10.1 tables, each with one fixed caller, compared against an immutable (`SAFE`, `FACTORY`, `KEYS`, `MANAGER`, `VOTES`, `TREASURY`, the pinned pools) or the write-once registry. No `tx.origin`, no roles that can be granted, no ownership transfer. Deployers are `onlyFactory`, and a contract deployed any other way could not finish its constructor, because the factory's transient wiring would be empty.

### 10.4 Cross-fleet confusion

Covered in section 5. The rule: every per-fleet function that takes a key checks its fleet first; the collection never lets a caller choose the fleet it mints into; the collection only ever calls the key's own manager. Tests try every key-taking function with a foreign key.

### 10.5 No look-ahead at unreleased cards

Sean: "The art / traits should only become known after that Keycard is minted." On chain: `tokenURI` reverts for an id not yet minted; a key's seed exists only once the Chainlink answer to its own mint's request arrives; and nothing on chain carries a card, trait or deck content, only each deck's fingerprint and size. A card can therefore not be worked out before its key is minted and revealed. The rest is the site's and media-web's job (listed in 11): serve no metadata, picture or trait for an unminted or unrevealed key, and give no unreleased card a guessable link.

### 10.6 Griefing

- Open creation lets anyone add fleets to the official collection (8.5); each costs at least 10 USDC and touches no other fleet.
- Nothing loops over fleets anywhere. The transfer hook cost is bounded as today (one cohort plus at most five split assets), now with one extra hop (~5,000 gas, to measure).
- A receiver that reverts in `onERC721Received` only fails its own purchase. A key whose holder refuses ETH only blocks its own ETH claim, as today.
- A refused or starved VRF request leaves the key waiting for anyone's retry, as today; the purchase stands.
- A REGENT pool that stops filling stops purchases in every fleet (7.2, question 4); a requirement contract that reverts stops purchases only in its own fleet.
- Fibonacci holding limits stay per fleet, per level, per wallet.

### 10.7 Upgradeability

None. Every contract is final when deployed. Two forward-looking choices, both Sean's: question 16, whether the Safe may later register a *newer* factory for *new* fleets (existing fleets never change); and question 4, whether the Safe may change the swap route for future purchases (it can never reach money).

### 10.8 Invariants to test (Foundry, handler-based)

Run with the four founding fleets and two open fleets on one collection, against mock pools and on a Base fork against the real ones, plus a handler that tries every privileged and key-taking function with random callers and foreign keys:

1. Every key belongs to exactly one fleet, for ever; its key number is at most its manager's `totalMinted`.
2. The sum of every fleet's `totalMinted` equals the collection's mint count.
3. A fleet whose sales are closed has `totalMinted == 0`; the phase only ever rose, one step at a time, by the Safe; no open fleet exists before phase 3; founding fleets are fleets 1–4 with their fixed types and decks.
4. Registry entries never change; fleet numbers only grow.
5. No action in fleet B changes fleet A's presence queue, tallies, electorates, ledger backing, credits, treasury balances, holding counts or profile (snapshot comparison).
6. Ownership epochs only increase; a shard ends when its key moves.
7. The collection, factory and REGENT buyer hold no tokens or ETH after any call and leave no approvals.
8. Each fleet's four contracts point at each other and at nothing else.
9. Every invariant in today's suite (`test/invariant/*`: presence queue, electorate never shrinks, rewards backing, split exactness, segregation, agents never paid, bound launch is the fleet's own) holds in every fleet side by side.
10. A fleet's `deckHash` and `deckSize` never change after creation, and every reveal emits exactly one `KeyRevealed` carrying the key's own fleet and key number.
11. Every purchase's USDC splits exactly as 7.3; the treasury's REGENT rose by at least the purchase's `minRegentOut` whenever a swap ran; protocol share, Cascade reserve and rebates stay USDC.
12. An open fleet's key 1 belongs to its creator at the starting price, and its later prices follow its type's curve scaled to that price.
13. A fleet's profile only changes through its own treasury; its joining requirements never change (question 9 a).

Plus: `check_bytecode.sh` finds no reachable `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in any contract, and Slither's delegatecall, arbitrary-send and reentrancy detectors run clean or are triaged.

---

## 11. What is deleted and what moves (hard cutover)

| Today | After |
|---|---|
| `src/Keyfleet.sol` | **Deleted.** ERC-721, epochs, VRF reveal, `tokenURI`, ERC-4906 → `KeyfleetKeys.sol`. Sale, prices, Cascade, rebate, protocol share, holding limits, `recognizeSurplus`, `firstMintAt` → `KeyfleetManager.sol`. |
| USDC capital paid to the treasury | **Replaced** by the swap to REGENT (7.3). |
| `KeyfleetPresets` prices fixed at Q = 10 USDC and Classic's table | Prices scale from the fleet's starting price (8.4); supplies, levels, holding limits and splits unchanged. |
| `Keyfleet.Metadata` (per-fleet name, symbol, metadata base) | **Deleted.** One name, symbol, base and `contractURI` on the collection; each fleet's name, description and image on its manager. |
| `Keyfleet.Randomness`, per-fleet `TRAIT_TABLE_HASH` | Move to the collection, once. |
| `Keyfleet.Companions` and nonce prediction per fleet | **Deleted.** Replaced by CREATE2 + transient wiring (4.3). |
| `KeyfleetShards` per fleet | One shared record bound to the collection. |
| `KeyfleetVotes`, `KeyfleetTreasury`, `KeyfleetRewards` constructors taking a `Keyfleet` | No-argument constructors reading the factory's wiring; `FLEET` becomes `MANAGER` plus `KEYS` and `FLEET` (the number); own-key checks added. Logic otherwise unchanged. |
| `KeyfleetPresence` 32-bit ids | 64-bit ids (scheme a). |
| `script/KeyfleetStack.sol` | **Deleted.** |
| `DeployKeyfleets.s.sol` (one fleet per run) | Deploys the system once: deployers, factory (which deploys collection, shards and REGENT buyer). |
| (none) | New: create-founding-fleet and advance-phase steps that write the Safe transactions; on anvil they are sent directly. |
| `RecordKeyfleets.s.sol` | Records the system once, then each fleet from its `FleetCreated` event, reading every value back from chain. |
| `KeyfleetManifest.sol`, `deployments/*.json` | Shared bindings (now including both swap pools and the v4 pool key) plus collection name, symbol, base and contract URI; per-fleet entries become the four founding fleets' type, deck and profile. |
| `AnvilLab.s.sol` | Builds the factory, creates Classic #1, moves to phase 1 locally, buys two keys through a local swap route. |
| `check_bytecode.sh` | Checks the new contract list. |
| Tests | Fixture goes through the factory; every suite is ported; new suites in section 12. No test keeps a per-fleet collection or a USDC-capital treasury. |
| `docs/product-spec.md`, the v0.3 spec and plan, `docs/deploy-checklist.md` | Updated to round 2 in B7. |

Nothing is deployed anywhere today (plan §1.2), so no deployed contract, claim or asset needs migrating.

**Site and media-web lanes, list only (after B5 fixes the ABI):**

- **Records and scanning:** one collection address recorded once. The scanner reads the collection's `Transfer`, `OwnershipEpoch`, `KeyRevealed`, `MetadataUpdate`, `BatchMetadataUpdate`, `FleetCreated` and phase events, plus each fleet's manager, Votes, Treasury and Rewards.
- **Key pages and metadata:**
  - Key pages and the metadata route move to `/metadata/keys/:token_id`, decoding fleet and key number.
  - The metadata route and media-web serve nothing for an unminted or unrevealed key, and no unreleased card has a guessable link (10.5).
  - Metadata includes the fleet's on-chain name.
  - Deck cards are served for decked keys.
- **Buying:**
  - A purchase targets the fleet's manager and carries `minRegentOut` from a fresh quote, plus the Merkle proof when the fleet has a list. Transfers and approvals target the collection, shards the shared record.
  - The buy button shows "sales have not opened" from `salesOpen`.
  - The buy button may show "this fleet is for its list" or "needs the required NFT/token" when the receiving wallet certainly fails a requirement at the latest block.
- **Creating a fleet:** a create-a-fleet page for phase 3. It covers the creator's inputs, CSV to Merkle root with stored proofs, and the creator's approval of the factory.
- **Fleet changes by vote:** a proposal builder for profile changes.
- **Records setup:** `seed-deployment` takes the collection record plus each fleet record.

---

## 12. Build plan

Each step leaves `forge build` and `forge test` green, deletes what it replaces, and updates `contracts/README.md`. Steps B1, B2 and B3 add new files that nothing else uses yet; B4 is the one cutover.

| # | Step | Tests | Size |
|---|---|---|---|
| B0 | This design; Sean's answers recorded here | — | doc |
| B1 | **`KeyfleetKeys` on its own.** Registry (written by a test factory), mint from a registered manager into its own fleet only, token ids (scheme per question 15), epochs, phases and sales switches, reveal and retry, deck fingerprint and size per fleet, `tokenURI`, `contractURI`, ERC-4906 incl. fleet-wide refresh. Confirm the VRF consumer limit on a Base fork. | Mint refusals (unregistered, wrong fleet, sales closed, existing id), phase steps only by the Safe, one way, in order, with their preconditions, `tokenURI` reverts for unminted ids, ids and decoding, epoch bumps, hook goes only to the key's manager, reveal suite ported, deck recorded once and refused when half-given, `KeyRevealed` carries fleet, key number and seed, callback never reverts at today's gas limit, golden draws unchanged | ~800 |
| B2 | **`KeyfleetRegentBuyer`.** Pinned v3 and v4 routes, both callbacks, minimum, balance-change check. Confirm the hook's maker. | Mock pools: minimum met and missed, partial fill refused, callbacks from strangers or outside a swap refused, nothing left behind. Base fork: real quotes at 10, 1,000 and 10,000 USDC match the quoter; hook fee taken; gas measured | ~500 |
| B3 | **`KeyfleetFactory` and deployers.** CREATE2 prediction, transient wiring, constructor refusals, founding fleets (Safe, order, decks), open creation (phase 3, bounds, profile, requirements, key 1 bought by the creator), (question 16) adding a factory. | Wiring points both ways for every contract; wrong caller and out-of-order founding refused; every bound on open creation (name 0/1/100/101 bytes, description 2,000/2,001, image 512/513, price 9.99/10/1,000,000/1,000,000.01 USDC); a deployer called directly cannot produce a contract; transient wiring is empty after the call; sizes under limits; open creation gas measured against 16,777,216 | ~700 |
| B4 | **Cutover.** `KeyfleetManager` replaces `Keyfleet`: starting-price curves, the swap of the treasury's part, profile and `setProfile`, joining requirements; Rewards, Votes, Treasury and Shards rebound; own-key checks; 64-bit presence ids; fixture through the factory; every existing suite ported; `Keyfleet.sol` and `KeyfleetStack.sol` deleted. | All of today's suites pass with today's prices and splits on founding fleets; treasury share arrives as REGENT; scaled curves for each type at 10 and 1,000,000 USDC; Merkle, NFT and token requirements met and missed, combined per question 7; requirement contract that reverts or burns gas; profile change through a real proposal; closed-sales refusal on every type; transfer-hook gas ceiling with five split assets | ~2,200, much of it mechanical test moves |
| B5 | **Cross-fleet suite and multi-fleet invariants.** Every key-taking function with a foreign key; signed messages replayed across fleets; section 10.8 invariants with six fleets. | 10.8 at 256 runs × depth 100 or more | ~800 |
| B6 | **Scripts.** Manifest, system deploy, create-founding-fleet and advance-phase Safe transactions, record, anvil lab with a local swap route, bytecode check list. | Deploy and record tests over mocks; refusals per pin (including both pools and the pool key); record refuses miswired fleets and a collection not yet a VRF consumer | ~700 |
| B7 | **Release readiness.** Base-fork gas report (open creation, purchase with and without a swap, transfer, reveal callback), README, `docs/deployment.md`, `docs/deploy-checklist.md`, product spec and v0.3 docs brought to round 2. | `make check-contracts` green | ~400 |

---

## 13. Questions only Sean can answer

The build follows each recommendation until Sean answers; a different answer changes only the named steps. The `KF-SOL` number stays with a question across rounds.

**Answered and retired:**

- **KF-SOL-1** (who creates fleets): answered by round 2. The Safe creates the four founding fleets; from phase 3, anyone creates.
- **KF-SOL-2** (who opens sales, can they close): answered in part by the phases. The Safe opens them in phase steps. What is left moved to question 5 (KF-SOL-14).
- **KF-SOL-7** (deck repeats): answered earlier; section 3.5.
- **KF-SOL-5** (key picture address) is **not** answered by the fleet image link: that link is the fleet's own picture, while KF-SOL-5 is about where every key's metadata is served. It stays as question 17.

**1. (KF-SOL-10) Which part of each Key payment becomes REGENT?**
- a) Only the money that goes into the fleet's treasury, swapped at purchase (90% of Classic and Syndicate, 20% of later Accelerant keys, Cascade's leftover when a level completes). The 10% for REGENT staking, Cascade refunds and Accelerant rebates stay USDC, because those are promises made in USDC. *(recommended)*
- b) Same as a, but Cascade's leftover stays USDC (it can be one large swap at once).
- c) The whole price. Staking, refunds and rebates would then be paid in REGENT, which changes what earlier buyers were promised and how staking is paid.

*Changes B4.*

**2. (KF-SOL-11) Which treasury gets the REGENT?**
- a) Each fleet's own treasury, shared by that fleet's Keys and split daily as today. *(recommended)*
- b) One treasury shared by every fleet.

*Changes B3 and B4.*

**3. (KF-SOL-12) How is the fleet's REGENT protected from a bad price?** The REGENT pool holds about 141,000 USD: a 10,000 USDC swap loses about 15%, a 100,000 USDC swap about 62%.
- a) Each purchase carries a minimum REGENT amount the site works out from a fresh quote; below it the purchase fails. A buyer who goes around the site could still take part of the treasury's share on large keys. *(recommended for now: simplest, and the risk is small at the prices fleets start at)*
- b) As a, and the contract also caps how much one purchase may swap; anything above the cap stays USDC in the treasury for the Keys to swap later by vote.
- c) No swap at purchase: the treasury keeps USDC and the Keys swap by vote. This is not what Sean asked for, but it carries no price risk.

*Changes B2 and B4.*

**4. (KF-SOL-13) If REGENT's main pool ever moves or stops working, what happens?**
- a) Nothing can change the route: Key sales in every fleet stop until that pool works again.
- b) The Safe may point future purchases at a new route. It can never touch any fleet's money, and each purchase's minimum still applies. *(recommended)*

*Changes B1 and B2.*

**5. (KF-SOL-14, replaces KF-SOL-1 and KF-SOL-2) How do phases and the sales switch work?**
- a) The Safe moves phases forward only, one transaction each: phase 1 opens Classic #1, phase 2 opens the other three together, phase 3 lets anyone create. Each step is your go. Fleets made by anyone sell from the moment they're created, starting with the creator's key 1. *(recommended)*
- b) As a, but each fleet made by anyone also waits for the Safe to open its sales (its creator's key 1 is still bought at creation).
- c) As a, and the Safe may also close sales or creation again later.

*Changes B1 and B3.*

**6. (KF-SOL-15) What does a creator's "starting price" mean for later Keys, and what is "any type"?**
- a) A creator picks one of the four types and gets all its rules (supply, levels, holding limits, splits). Key 1 costs the starting price, and later Keys rise on that type's curve, scaled up from it: Classic ×10 over 1,024 keys, Syndicate and Cascade +20% per level, Accelerant +5% per Key. *(recommended)*
- b) Every Key in the fleet costs the starting price; supply and other rules come from the type.
- c) The creator also sets more, such as the top price or the supply.

*Changes B4.*

**7. (KF-SOL-16) With several joining requirements, must a buyer meet all of them or any one?** Your sentence was cut off at "which".
- a) All of them. *(recommended: each requirement the creator ticks narrows who may join)*
- b) Any one of them.

In both cases it's the wallet receiving the Key that must qualify, and the creator's own Key 1 is not checked.

*Changes B4.*

**8. (KF-SOL-17) Do joining requirements also apply when a Key is resold, for example on OpenSea?**
- a) No: only buying from the fleet is checked, and resales are free. *(recommended)*
- b) Yes: a Key can't move to a wallet that fails the requirements, so some OpenSea sales would fail.

*Changes B4.*

**9. (KF-SOL-18) Can a fleet's joining requirements change after it's created?**
- a) Never. *(recommended: simplest, and buyers know the rules up front)*
- b) Yes, by the same Keys' vote that changes the name.

*Changes B4.*

**10. (KF-SOL-19) Which holdings can be a joining requirement?**
- a) The three you named: an address list, holding any NFT from an ERC-721 collection, holding at least N of a token. A balance borrowed and returned in the same transaction passes, which fits "selling after joining is fine." *(recommended)*
- b) As a, plus ERC-1155 collections (many game items and editions).
- c) As a, without the token-balance option.

*Changes B4.*

**11. (KF-SOL-20) What counts as a "majority vote of Keys" for changing a fleet's name, description or image?**
- a) Today's vote rule: more than half of the Keys marked present for that proposal. The same rule covers founding fleets. *(recommended: it already works and can't stall when holders are away)*
- b) More than half of all Keys ever sold in that fleet.

The limits are 100 and 2,000 bytes; the image link is up to 512.

*Changes B4.*

**12. (KF-SOL-21) What does a card from a fleet made by anyone show, and can it have a deck?**
- a) The title stays type and number from the chain ("CLASSIC #2"), the fleet's name shows beside it, and the cards use the trait draw. *(recommended)*
- b) The title is the fleet's name, and cards use the trait draw.
- c) As a, and the creator may also supply a deck.

*Changes the site and NFTs lanes; B3 only if c.*

**13. (KF-SOL-22) If someone gives their fleet an abusive name, description or image, can keyfleet.ai hide it?**
- a) Yes. The site and the metadata it serves to OpenSea may hide it; the chain record stays. *(recommended)*
- b) No. The site always shows what's on chain.

*Changes the site lane only.*

**14. (KF-SOL-23) Who pays for each Key's Chainlink random draw in fleets made by anyone?**
- a) The Regents subscription, as for the founding fleets: cents per Key on Base. *(recommended)*
- b) Each buyer adds a small ETH amount to their purchase.

*Changes B4 only if b.*

**15. (KF-SOL-3) What number does a Key show on OpenSea?**
- a) Fleet number and key number in one: fleet 1's key 72 is #10000000072. The fleet can be read from the number, and checks are cheapest and safest. *(recommended)*
- b) One running count across every fleet in buying order (#1, #2, #3…). Shorter, but it never matches the card's key number, and each purchase costs a little more.

*Changes B1 and B4. The card title (for example CLASSIC #1 · NO. 0072) shows either way.*

**16. (KF-SOL-4) When the fleet contracts are improved later, can new fleets join the same collection?**
- a) Yes: the Safe may add a newer factory for new fleets. Existing fleets never change. *(recommended, so the one collection lasts)*
- b) No: an improved version means a new collection on OpenSea.

*Changes B1 and B3.*

**17. (KF-SOL-5) Can the address that Key pictures and details are read from ever move?**
- a) Never: fixed at keyfleet.ai when the collection is deployed, so keyfleet.ai must be kept for good. *(recommended: no one can change a Key's picture source)*
- b) The Safe may move it (a new domain or permanent storage), and OpenSea is told to refresh every Key.

*Changes B1. Traits and deck cards are fixed by each Key's random number either way; only where pictures are served from differs.*

**18. (KF-SOL-6) If Chainlink ever retires its randomness service, what happens to Keys bought afterwards?**
- a) Nothing can change it: those Keys keep their placeholder card until a retried request is answered. *(recommended: no one can steer future draws)*
- b) The Safe may point future draws at a new randomness service; Keys already drawn never change.

*Changes B1.*

**19. (KF-SOL-8) What is the collection called on OpenSea?**
- a) "KeyFleet Keys", symbol KEYFLEET. *(recommended)*
- b) "KeyFleet", symbol KEYFLEET.
- c) Another name you give.

*Changes the B6 manifest only.*

**20. (KF-SOL-9) Should the collection ask marketplaces for a fee on resales?**
- a) No fee, as today. *(recommended: sale money rules stay unchanged; marketplaces may ignore it anyway)*
- b) Ask for a fee, with a percentage and recipient you name.

*Changes B1 only if b.*

# One Key collection, one manager per fleet: design

**Date:** 7 October 2026
**Branch:** `kf/fleet-manager-factory`, from `kf/contracts-v03` at `10260c4`
**Status:** round 3. Sean's answers to rounds 1 and 2 are recorded below, and the Foundry build has started on this branch. Nothing is deployed, broadcast, signed or pushed. Key sales stay off until the Safe's phase steps (section 6).

**Sean's request, round 1 (7 Oct 2026, verbatim):** "For browsing on Opensea I would prefer if all of the Key NFTs in the different sets are part of the same collection address...but I want the NFTs to act as membership keys to different KeyfleetManager contracts that are created from a KeyFleetManagerFactory."

**Sean's direction, round 2 (7 Oct 2026, verbatim, voice-dictated):**

> 1. So these Key contracts are on Base. Is it possible to have the key cost always be purchased with USDC, but the USDC is automatically converted in the contract to market buy of REGENT from the uni v4 pool which is what is put into the shared treasury.
> 2. I want the site + contracts to work in phases. Phase 1: Only Classic fleet #1 is live Phase 2: The Regents Safe does a tx to make 3 more become available, Syndicate #1, Accelerant #1, and Cascade #1 Phase 3: The Regents Safe unlocks the creation of a keyfleet of any type, by anyone. They set the name of the fleet (goes onchain, 100 character limit) , the optional description onchain (2000 character limit), and can optionally add an image link to the contract (all of these are editable by majority vote of Keys) . Then, they set the starting price of a Key in USDC (10 usdc min, 1000000 max) and must buy the first key at the price they set, which also does the gas cost of creating the KeyfleetManager contract from the factory.
>    1. They can set also optionally set the joining requirements of buying a key to certain addresses. In the UI, by a combination of these allowlists: 'upload a csv of addresses (and our UI converts it into a token list or merkle tree? Idk how best to do it.) or a currently held NFT collection, a currently held token with balance greater than N' , and the UI allows the Keyfleet creator to select multiple of these requirements which . If the address buys the NFT / token required for allowlist and then sells after joining the Keyfleet, that is fine.

> "I want to make sure that people can't 'Look ahead' on the mediaweb links and see unreleased cards. The art / traits should only become known after that Keycard is minted"

**Relayed from the Keyfleet NFTs lane (7 Oct):** the first four fleets each get a pre-made 1,000-card deck; a key's random number picks its card from its fleet's deck. Keys 1,001 onward use today's trait draw. Card titles count per type ("CLASSIC #1", a later second Classic fleet is "CLASSIC #2"). Sean's answer on how cards are dealt (7 Oct, verbatim): "The site picks; the deck fingerprint goes in the contract. And as long as it still works for the 1001 card, and N+1 cards to be created for any set of cards in a keyfleet."

**Sean's answers to the round 2 questions (7 Oct, verbatim, relayed):**

> 1. a 2. a 3. just do a normal swap with no restrictions. the REGENT liquidity will increase over time, and $10 buys are the norm for a long time 4. a 5. a 6. a 7. b 8. a 9. a 10. a 11. a - all votes always use the 'present denominator' 12. no, the cards for new keyfleets come from the same process as the original four. except use the interim art when a Key is minted, and then we have a backend process to create the real metadata and image and publish it, after which a metadata update from the owner will reveal the permanent card. 13. a 14. a - is it a few cents on Base too? 15. show this format: \<fleet type among the 4\>—\<fleet number in 00N format, or 1NNN format for large number\>—\<number in 00N format, or 1NNN format for large numbers\> 1. Also, the traits should have each of: the fleet type and the fleet number 16. a 17. a - but the images come from media.regents.sh I thought? from the media-web repo 18. a 19. 'Keyfleet' with KEYFLEET 20. b , 2.5% to 0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e

**Sean's follow-ups (7 Oct, verbatim, relayed):** "1. a 2. b - the brand is never KeyFleet , always Keyfleet. make a note". So the metadata base is fixed on keyfleet.ai with pictures on media.regents.sh, and the collection is named "Keyfleet".

**Brand rule:** always "Keyfleet", never "KeyFleet", in this doc, contract names, NatSpec, tests and messages. (Sean's round 1 request above is quoted as he wrote it.)

What each answer decides (round 2 numbering → id):

| # | Id | Decision |
|---|---|---|
| 1 | KF-SOL-10 | Only the treasury's share becomes REGENT; protocol share, Cascade refunds and Accelerant rebates stay USDC (7.3) |
| 2 | KF-SOL-11 | Each fleet's own treasury gets its REGENT |
| 3 | KF-SOL-12 | A plain market swap with no minimum (7.4) |
| 4 | KF-SOL-13 | The swap route is fixed forever (7.2) |
| 5 | KF-SOL-14 | Phases move forward only; open fleets sell from creation (section 6) |
| 6 | KF-SOL-15 | A creator picks one of the four types; prices rise on its curve scaled from the starting price (8.4) |
| 7 | KF-SOL-16 | Meeting **any one** joining requirement is enough (section 9) |
| 8 | KF-SOL-17 | Requirements are checked only when buying from the fleet; resales are free |
| 9 | KF-SOL-18 | Requirements never change after creation |
| 10 | KF-SOL-19 | Address list, ERC-721 held, ERC-20 balance ≥ N |
| 11 | KF-SOL-20 | Profile edits, like every vote, use the present denominator |
| 12 | KF-SOL-21 | Every fleet's cards come from a pre-made deck, open fleets included; interim art at mint, permanent card after the backend publishes (3.5) |
| 13 | KF-SOL-22 | keyfleet.ai may hide abusive fleet text or images |
| 14 | KF-SOL-23 | Regents' Chainlink subscription pays every draw: about half a US cent per Key on Base (3.4) |
| 15 | KF-SOL-3 | Token id stays fleet × 10^10 + key; the Key's name reads `CLASSIC—001—072`; traits carry fleet type and fleet number (3.1) |
| 16 | KF-SOL-4 | The Safe may add newer factories for new fleets |
| 17 | KF-SOL-5 | The metadata address is fixed forever, on keyfleet.ai; pictures on media.regents.sh (3.4) |
| 18 | KF-SOL-6 | The Chainlink coordinator is fixed forever |
| 19 | KF-SOL-8 | Name "Keyfleet", symbol KEYFLEET |
| 20 | KF-SOL-9 | ERC-2981 resale fee of 2.5% to the Regents Safe |

**Binding sources:** [contracts-build-now-spec-v0.3.md](contracts-build-now-spec-v0.3.md), Sean's answers recorded in [contracts-v0.3-plan.md](contracts-v0.3-plan.md) section 9, [product-spec.md](product-spec.md), as changed by everything above. Supplies, splits, vote, presence, daily split and claim rules are unchanged. Those docs are brought up to date in step B7.

Words used below: a **fleet** is what Sean calls a "set" or "keyfleet". A **key** is one ERC-721 token. The **collection** is the one shared ERC-721 contract. A fleet's **manager set** is the per-fleet contracts the factory creates. The **Safe** is the Regents Safe on Base, `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. The four **founding fleets** are Classic #1, Syndicate #1, Accelerant #1 and Cascade #1. An **open fleet** is one anyone creates in phase 3. The **keeper** is the Regents backend wallet that records open fleets' decks and asks for card refreshes (3.5).

---

## 1. Today, in one paragraph

Each fleet is five contracts with no shared state. `Keyfleet` (14.6 KB runtime) is both the ERC-721 and the sale: it holds the keys, ownership epochs, the VRF reveal, the preset economics (prices, supply, Fibonacci holding limits, Cascade reserve, Accelerant rebate), the owed 10% protocol share, and `firstMintAt`. It deploys its `KeyfleetRewards` ledger (8.4 KB) and `KeyfleetShards` record (3.6 KB) in its constructor; `KeyfleetVotes` (14.5 KB) and `KeyfleetTreasury` (10.8 KB) are deployed next at addresses predicted from the deployer's nonce, and each refuses a fleet that does not name it (`script/KeyfleetStack.sol`). Each `Keyfleet` is its own OpenSea collection. Every purchase is paid and kept in USDC. On chain, nothing stops a deployed fleet from selling: "sales off" today means "no fleet is deployed and the site has recorded none".

## 2. The shape after the change

```
                       KeyfleetFactory  (one)
                         |   deploys in its constructor
                         v
   KeyfleetKeys  <---- one ERC-721 collection: every key of every fleet; phase; registry; decks
   KeyfleetShards <--- one agent-shard record for every key (keyed by token id)
   KeyfleetRegentBuyer  one shared, stateless USDC -> REGENT swapper (section 7)

   createFoundingFleet(preset, deck, profile)  Safe only, fleets 1-4, sales closed
   createFleet(terms)                          anyone, phase 3 only, creator buys key 1
        -> one manager set per fleet, in one transaction:
        KeyfleetManager   sale, price, profile, joining requirements, transfer hook
        KeyfleetVotes     presence + proposals + ballots          (as today)
        KeyfleetTreasury  free capital, exact calls, daily split  (as today)
        KeyfleetRewards   member claims ledger                    (as today)
```

| Contract | How many | Holds | Comes from |
|---|---|---|---|
| `KeyfleetKeys` | one | Who owns each key, which fleet it belongs to, ownership epochs, each key's VRF seed, each fleet's deck fingerprint and size, the fleet registry, the phase and each fleet's sales switch, the keeper's address | ERC-721 and reveal parts of `Keyfleet.sol` |
| `KeyfleetShards` | one | Agent shards and agent-voting switches, per key | `KeyfleetShards.sol`, rebound from one fleet to the collection |
| `KeyfleetFactory` | one | Shared bindings (USDC, REGENT, staking, Autolaunch); nothing of value | new |
| `KeyfleetRegentBuyer` | one | Nothing between calls; the fixed swap route | new (section 7) |
| `KeyfleetManager` | one per fleet | Type, starting price, prices, `totalMinted`, `firstMintAt`, Cascade reserve, owed protocol share, Fibonacci holding counts, name, description, image link, joining requirements | sale and money parts of `Keyfleet.sol`, plus round 2 |
| `KeyfleetVotes`, `KeyfleetTreasury`, `KeyfleetRewards` | one each per fleet | Exactly what they hold today | today's files, rebound to the manager and collection |
| four small deployers | one each | Nothing; each holds one per-fleet contract's creation code | new (4.3) |

"The manager" in Sean's words is the fleet's whole manager set: `KeyfleetManager` is its front door and address book, and the other three are its parts. It cannot be one contract: the four together are about 45 KB of runtime code against Base's 24,576-byte limit per contract (EIP-170).

---

## 3. The shared Key collection

### 3.1 What OpenSea sees

- **One collection page.** `name()` is "Keyfleet" and `symbol()` KEYFLEET, fixed at deploy (Sean, KF-SOL-8).
- **Collection details.** `contractURI()` (ERC-7572) returns a fixed URL for the collection page's picture and description.
- **Key names.** Each Key's name in its metadata reads `<TYPE>—<fleet number>—<key number>`, with em dashes and each number padded to three digits, or four once it reaches 1,000, for example `CLASSIC—001—072` or `ACCELERANT—001—1204` (Sean, KF-SOL-3). Which fleet number shows is open question 3.
- **Traits.** The traits include `Fleet type` and `Fleet number` (Sean), plus the fleet's name and the key number, so OpenSea's trait filter narrows the one collection to one fleet.
- **Resale fee.** ERC-2981 `royaltyInfo` asks marketplaces for 2.5% of every resale, paid to the Regents Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` (Sean, KF-SOL-9). The rate and recipient are fixed. Marketplaces may choose not to honour it.
- **Approvals.** One `setApprovalForAll` to a marketplace now covers a holder's keys in every fleet; that is ordinary ERC-721 and grants nothing in any fleet's votes.

### 3.2 Which fleet a key belongs to, and its token id

Every fleet gets a number from the collection when it is created: `1, 2, 3, ...` across all types, never reused, never changed. The founding fleets are 1 to 4. The collection also records the fleet's type and its number within that type (`CLASSIC #1`, `CLASSIC #2`). Within a fleet, keys are numbered `1..n` exactly as today; that number drives every price, level, cohort and rebate rule.

**Token id = fleet × 10^10 + key** (KF-SOL-3 a). Fleet 1's key 72 is `#10000000072`. The fleet is `tokenId / 10^10`, worked out with no storage read, which makes the cross-fleet check (section 5) cheap and impossible to get wrong. The key number fits under 10^10 because a fleet stops at 4,294,967,295 keys.

### 3.3 Ownership epochs and transfers

`ownershipEpoch[tokenId]` moves into the collection unchanged: 1 at mint, plus one on every transfer. On every mint and transfer, `KeyfleetKeys._update` does, in today's order:

1. Calls the key's own fleet manager, `managerOf[fleetOf(tokenId)].onKeyMoved(tokenId, from, to)`. The manager settles the key's rewards to `from`, clears its presence in the fleet's Votes, and enforces the Fibonacci holding limit on `to`, exactly what `Keyfleet._update` does today. A transfer only ever calls the one manager the key belongs to.
2. Bumps the epoch and emits `OwnershipEpoch`.
3. Moves ownership (`super._update`).

### 3.4 Reveal, `tokenURI` and ERC-4906

- **VRF moves into the collection, once.** One coordinator, subscription and gas lane for every fleet, and one VRF consumer for the Safe to add, instead of one per fleet (a Chainlink v2.5 subscription takes at most 100 consumers; to confirm in B1). The coordinator is fixed forever (Sean, KF-SOL-6). The request settings (3 confirmations, 100,000 callback gas, native payment), retry (`requestReveal`) and the never-reverting callback stay as written today. The seed stays `keccak256(TAG, chainid, collection, tokenId, word)`.
- **What a draw costs (Sean asked, KF-SOL-23).** Regents' subscription pays every draw, in ETH. The Base coordinator `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` charges the fulfilment gas plus a 60% premium. Sixteen real fulfilments read on 7 Oct cost between 0.0000017 and 0.0000053 ETH each: about 0.4 to 1.4 US cents with ETH at about 2,574 USD. A Key's draw, with a 100,000-gas callback, sits at the low end: **about half a cent per Key**, so less than "a few cents".
- **One trait table for every fleet:** `TRAIT_TABLE_HASH` `0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe`, fixed once on the collection (keyfleet main `3172c4a`). The earlier table appears nowhere in contracts, tests or scripts.
- **`tokenURI(id)` = one fixed base + the id**, and it reverts for an id that has not been minted. The base is fixed forever (Sean, KF-SOL-5).
  - The base points at each Key's **metadata** on keyfleet.ai (the JSON with name, traits and a picture link), `https://keyfleet.ai/metadata/keys/` (Sean, 7 Oct: "1. a").
  - The **pictures** are on media-web, at `https://media.regents.sh/ipfs/<cid>` (`platform/lib/keyfleet/keys/key_art.ex`). The metadata links to them. Sean is right that images come from media.regents.sh.
- **ERC-4906:**
  - The collection emits `MetadataUpdate(tokenId)` when a seed is written.
  - `refreshMetadata(tokenId)` emits it again when the backend has published the permanent card (3.5).
  - A change to a fleet's name, description or image emits `BatchMetadataUpdate` over that fleet's id range.
  - The collection is the only contract that emits these, since OpenSea listens to the collection address.

### 3.5 Card decks for every fleet

**Sean, KF-DECK-PICK:** "The site picks; the deck fingerprint goes in the contract." **Sean, KF-SOL-21:** "the cards for new keyfleets come from the same process as the original four. except use the interim art when a Key is minted, and then we have a backend process to create the real metadata and image and publish it, after which a metadata update from the owner will reveal the permanent card."

So every fleet, founding or open, has a pre-made deck. The site deals each key a card from its fleet's remaining cards, with no repeats, in on-chain reveal order (block number, then log index), using each key's seed. The chain holds only the deck's fingerprint and size. Keys `1..N` of an `N`-card deck get deck cards; key `N+1` onward uses the trait draw.

**The one rule that keeps decks fair:** a deck's fingerprint is fixed before any of its fleet's seeds exists, so nobody can build or change a deck after seeing which random numbers came up. The collection enforces it by **not asking Chainlink for a key's random number until its fleet has a deck**:

- **Founding fleets:** the Safe gives the deck in `createFoundingFleet`, so their keys ask for a draw at mint, as today.
- **Open fleets** are created in one transaction by anyone, before the backend can have built their deck. They start with no deck. Their keys, the creator's key 1 included, mint with interim art and wait for a draw.
  - The backend sees `FleetCreated`, builds the fleet's deck by the same process as the original four, and has the keeper call `setDeck(fleet, deckHash, deckSize)`.
  - `setDeck` takes the fingerprint once, only for a fleet that has none. That fleet's keys have no seed yet, so the deck cannot depend on them.
  - Then anyone, normally the backend, calls `requestReveal` for the keys minted while the fleet waited. Keys minted afterwards ask at mint.
- **Permanent card:** when the backend has published a key's real metadata and picture, it (or the key's holder) calls `refreshMetadata(tokenId)`. The collection emits `MetadataUpdate`, so OpenSea fetches the permanent card. Who presses it is open question 2; the contract allows both the keeper and the holder.

**What the keeper can and cannot do:** it can record the deck for an open fleet that has none, and ask for a refresh. It cannot choose any key's card, since the seeds come later, change a recorded deck, mint, or touch money. If it never records a deck, that fleet's keys keep their interim art and anyone can still trade them. The keeper's address is set at deploy and only the Safe may replace it (open question 1).

**On chain, all of it:** each fleet's `deckHash` and `deckSize`, both fixed once (both zero means "no deck yet"; one zero and the other not is refused), `deckOf(fleet)`, and `KeyRevealed(tokenId, fleet, keyNumber, requestId, seed)`. There is no dealing on chain, no card map and no `cardOf`. The reveal callback keeps today's 100,000 gas limit.

**Founding decks (from the NFTs lane):** one JSON file per fleet, `{"fleet", "table", "cards": [1,000 0x-prefixed 32-byte card seeds]}`, cards indexed `0..999`, bound to trait table `0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe`. `deckHash` is keccak256 of the file's exact bytes; `deckSize` is 1,000.

| Fleet | `deckHash` | `deckSize` |
|---|---|---|
| CLASSIC #1 | `0xe9b1900adb56811096d08f67852af8a64ec509ed2982e94f14f172f687b577e7` | 1000 |
| SYNDICATE #1 | `0x1298cf785709867c5397762ba4dfa3d4a1c1394db0cd26444285c48cc6e57706` | 1000 |
| CASCADE #1 | `0x2942590c4d3873db390aef50e4648137fdb93729a370105a1aa9a62e43222b66` | 1000 |
| ACCELERANT #1 | `0xbac8510a15a85770ff5cb64b4f0fef57244235ee79327ce3e3e375ce629b6d4d` | 1000 |

Decks stay private. Only the rarities are public, as they are now.

The reveal order is final only once the reveals' blocks are final, so the site deals from confirmed reveals.

---

## 4. The factory and each fleet's manager set

### 4.1 The two ways a fleet is created

**Founding fleets, `createFoundingFleet(preset, deckHash, deckSize, profile)`, Safe only.**
- Exactly four, in fixed order: fleet 1 Classic, 2 Syndicate, 3 Accelerant, 4 Cascade. Any other order, or a fifth, is refused.
- Each comes with its deck.
- Each uses its type's standard starting price (Classic 8 USDC rising to 80; the others 10 USDC), so founding fleets sell at exactly today's prices.
- No joining requirements.
- The Safe sets the name, description and image in the same call; after that they are the fleet's own to change by vote (8.3).
- They are created with sales closed; the phase steps open them (section 6). The Safe buys no key.

**Open fleets, `createFleet(terms)`, anyone, only in phase 3:** section 8.

Both run the same steps in one transaction:

1. The collection registers a new fleet: it assigns the fleet number and per-type number, and records the type, deck (founding only) and the manager's predicted address.
2. The factory deploys the fleet's `KeyfleetManager`, `KeyfleetVotes`, `KeyfleetTreasury` and `KeyfleetRewards`, each at an address computed in advance (4.3), each bound to the others and to the collection, the shared shards, the REGENT buyer, USDC, REGENT, REGENT staking and the Autolaunch factory.
3. It emits `FleetCreated(fleet, preset, typeNumber, creator, startPrice, manager, votes, treasury, rewards)`.

A fleet's economic inputs are its **type** (one of the four rule sets, with all of its supply, level, holding-limit and split rules) and its **starting price**. Nobody can set a split, supply, rate, threshold or address for a fleet.

### 4.2 Full deploys, not clones

| | Minimal clones (EIP-1167) | Full deploys (chosen) |
|---|---|---|
| Gas to create a fleet | ~0.3M | ~10–12M for the four contracts (to measure) |
| `DELEGATECALL` | Every call to every fleet goes through one. Contradicts spec §4.2 and fails our own bytecode check | None anywhere |
| Wiring | Storage, written by an `initialize` call; hijack risk | `immutable`, fixed by the constructor |
| Per-call cost | A cold storage read per wiring lookup | Immutables cost nothing to read |

Base's gas price read on 7 Oct was 0.006 gwei with ETH at about 2,574 USD, so a ~15M-gas open creation (four deploys, an on-chain profile, the first purchase with its swap) costs about 0.0001 ETH, roughly 0.25 USD, plus a small L1 data fee.

**Per-transaction gas cap, to confirm:** Ethereum's Fusaka upgrade caps one transaction at 16,777,216 gas (EIP-7825). I could not confirm from chain reads whether Base enforces it. B3 measures open creation against that figure.

### 4.3 How four contracts that point at each other get deployed at once

- Each per-fleet contract has **no constructor arguments**. It is deployed with `CREATE2`, salt = fleet number, so its address depends only on its deployer, the fleet number and its fixed creation code. The factory computes all four addresses before deploying any.
- During creation the factory holds the fleet's wiring (fleet number, type, starting price, the four addresses, the shared bindings) in transient storage. Each constructor reads it back from the factory, stores it in immutables, and refuses to deploy unless its own predicted address is `address(this)`. The transient record is empty outside a creation. Strings and requirements are not immutables: the factory writes them into the new manager with one `onlyFactory`, write-once call during the same creation.
- The factory cannot hold all four creation codes itself (~45 KB), so each lives in its own small **deployer** contract, `onlyFactory`. The deployers are deployed first with the factory's address predicted from the deploying account's nonce, and the factory's constructor refuses any deployer that does not name it.
- The factory's constructor deploys `KeyfleetKeys`, `KeyfleetShards` and `KeyfleetRegentBuyer`, so their links to the factory are fixed at birth.

### 4.4 Who trusts whom

| Caller → callee | Allowed because | Checked by |
|---|---|---|
| Safe → factory `createFoundingFleet` | Only the Safe creates the four founding fleets, in fixed order | `msg.sender == SAFE`; fleet count < 4; type matches the slot |
| Anyone → factory `createFleet` | Phase 3 lets anyone create | `KEYS.phase() == 3`; input bounds (section 8) |
| Safe → collection `advancePhase()` | Only the Safe moves phases, one way | `msg.sender == SAFE` |
| Safe → collection `setKeeper` | Only the Safe names the keeper | `msg.sender == SAFE` |
| Keeper → collection `setDeck` | Records an open fleet's deck once, before any of its seeds exist | `msg.sender == keeper`; fleet has no deck |
| Keeper or key holder → collection `refreshMetadata` | Announces a published permanent card | `msg.sender == keeper` or the key's owner |
| Safe → collection `addFactory` | Newer factories for new fleets (KF-SOL-4 a) | `msg.sender == SAFE` |
| Factory → collection `registerFleet` | The collection's own factories | `isFactory[msg.sender]` |
| Factory → manager `initialize profile and requirements`, `sellFirstKey` | Once, during the fleet's own creation | `msg.sender == FACTORY` and a write-once flag |
| Manager → collection `mint(to, keyNumber)` | Only a fleet's registered manager mints, and only into **its own** fleet: the collection takes the fleet from `fleetOfManager[msg.sender]`, never from an argument | registry lookup; sales switch; ERC-721 refuses an existing id |
| Manager → REGENT buyer `buy` | Swaps the manager's own USDC for its own fleet's treasury | the buyer pulls from `msg.sender`; it trusts no caller |
| Uniswap v3 pool / v4 PoolManager → REGENT buyer callbacks | Only during a swap the buyer started | `msg.sender` is the fixed pool or PoolManager, and the buyer's transient "swap in progress" flag is set |
| Collection → manager `onKeyMoved` | The transfer hook | `msg.sender == KEYS` |
| Treasury → manager `setProfile` | An approved proposal of that fleet's Keys (8.3) | `msg.sender == TREASURY` |
| Manager → Votes `onKeyMoved`, → Rewards `enroll/settle/credit/allocate` | As today | `msg.sender == MANAGER` |
| Votes → Treasury `executeBatch`; Treasury → Votes `setEditsRestricted`; Treasury → Rewards funding | As today | as today, plus the split flag |
| Manager → Treasury `depositProtocolShare` | As today | `msg.sender == MANAGER` |

Registry entries are written once and never changed or removed.

---

## 5. Membership: a key counts only in its own fleet

The danger the shared collection introduces is a key of fleet A acting in fleet B. After the change `KEYS.ownerOf(id)` answers for every fleet's keys, so each per-fleet contract checks the fleet itself. One internal check, `_requireOwnKey(tokenId)` (`tokenId / 10^10 == FLEET`), runs before any other use of a key in:

- **Votes:** `present`, `presentBySig`, `castBallot`, `castBallotBySig`, `propose` (author key), `cancel`, `setEditsRestricted`, and the signed-message key encoding.
- **Rewards:** `claim`.
- **Manager:** `onKeyMoved` is only ever called for its own keys by construction; it asserts it anyway.

What stays per fleet, unchanged: the presence queue and its counts, every proposal's electorate and ballots (the present denominator, Sean KF-SOL-20), the daily split's key count, cohorts, the treasury.

- **Transfers:** settle-then-clear-then-epoch, as 3.3. Joining requirements are not checked on transfers (KF-SOL-17 a).
- **Delegation:** one shared `KeyfleetShards`, keyed by token id; a shard can never reach another fleet.
- **Signatures:** the EIP-712 domain's verifying contract is the fleet's own Votes, and the message names the fleet's manager and globally unique key ids, so a signed Present or Ballot for fleet A cannot be replayed in fleet B.
- **Presence ids:** `KeyfleetPresence` widens from 32-bit to 64-bit ids (`prev`, `next`, `expiresAt` still share one storage slot).

---

## 6. Phases, and key sales staying off until each phase

Sean: "I do not want the contracts or the frontend site to enable purchases of keys until I explicitly say so." Each phase step is a Safe transaction Sean signs, so each is his explicit go (KF-SOL-14 a).

The collection holds `phase`, 0 to 3, which only the Safe changes, only upward and one step at a time, with `advancePhase()`:

| Phase | Reached by | What it opens | Refused unless |
|---|---|---|---|
| 0 | deploy | Nothing sells. The Safe creates the founding fleets, one per transaction | — |
| 1 | Safe `advancePhase()` | Classic #1's sales | fleet 1 exists |
| 2 | Safe `advancePhase()` | Syndicate #1, Accelerant #1 and Cascade #1's sales, together | fleets 2–4 exist |
| 3 | Safe `advancePhase()` | `createFleet` for anyone; each open fleet sells from the moment it is created, starting with its creator's key 1 | — |

- **Where sales are gated:** `KeyfleetKeys.mint` reverts `SalesClosed(fleet)` unless that fleet is open: fleet 1 from phase 1, fleets 2–4 from phase 2, an open fleet from its creation. Every purchase in every fleet ends in this one function. There is no other mint path.
- **Nothing else moves a phase**, and there is no step back.
- **The site:** the fleet page reads `salesOpen(fleet)` and, while it is closed, shows the buy button disabled with a few words saying sales have not opened (rule 11's exception). The create-a-fleet page does the same from `phase()`. The site's own purchase gate stays as it is.
- **Scripts:** the deploy and create-founding-fleet steps never call `advancePhase`. Only the anvil lab does, on a local chain, acting as the Safe there.

---

## 7. Paying in USDC, holding REGENT

### 7.1 The REGENT market on Base (read from chain, 7 Oct 2026, block 52,299,795)

- **There is no REGENT/USDC pool.** REGENT trades against WETH. The main pool is Uniswap v4, pool id `0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed`, read back from the v4 PositionManager and checked by hashing the key:
  - currency0 WETH `0x4200000000000000000000000000000000000006`, currency1 REGENT `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`
  - fee `0x800000` (the hook sets the fee per swap; 1% LP fee in slot0), tick spacing 200
  - hook `0xd60D6B218116cFd801E28F78d011a203D2b068Cc`, whose `factory()` is `0xE85A59c628F7d27878ACeB4bf3b35733630083a9` (I believe Clanker's v4 factory; to confirm in B2). The hook is third-party code that runs inside every swap and can take a fee from it.
  - PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b`.
- **Depth.** About 141,000 USD of liquidity. Lost to fees and price movement, all fees included: 10 USDC ~1.2%, 1,000 USDC ~2.7%, 10,000 USDC ~15%, 100,000 USDC ~62%. Sean (KF-SOL-12): "the REGENT liquidity will increase over time, and $10 buys are the norm for a long time".
- **USDC to WETH:** the Uniswap v3 USDC/WETH 0.05% pool `0xd0b53D9277642d899DF5C87A3966A349A798F224`; 100,000 USDC moves it about 0.15%.

### 7.2 The route, fixed forever

The shared `KeyfleetRegentBuyer` does, for one `buy(usdcIn, treasury)`:

1. Pulls `usdcIn` USDC from the calling manager.
2. Swaps USDC → WETH directly on the fixed v3 pool (`pool.swap`, paying in `uniswapV3SwapCallback`).
3. Swaps WETH → REGENT on the fixed v4 pool inside `PoolManager.unlock` (`unlockCallback`: `swap` exact-in, `sync` + transfer + `settle` the WETH, `take` the REGENT straight to the fleet's treasury).
4. Checks every USDC and WETH was spent; returns the REGENT the treasury received (measured as its balance change).

It calls the pools directly rather than through Uniswap's Universal Router: no Permit2, no outside command bytes, two callbacks to check. The constructor fixes both pools and refuses a v4 pool key whose hash is not the pool id above. The route can never change (Sean, KF-SOL-13 a). If the pool ever stops filling, purchases in every fleet revert until it fills again.

### 7.3 Which USDC is swapped (Sean, KF-SOL-10 a)

| Part of a purchase | Kept as |
|---|---|
| Protocol share, 10% of every purchase | USDC, deposited into REGENT revenue staking (`depositUSDC`), as today |
| Classic and Syndicate: the other 90% | **REGENT**, into the fleet treasury |
| Accelerant key 1: the other 90% | **REGENT** |
| Accelerant later keys: 20% | **REGENT** |
| Accelerant later keys: 70% rebate to the previous key's holder | USDC credited in Rewards, as today |
| Cascade: the other 90% | USDC level reserve, as today (it refunds the previous level in USDC) |
| Cascade: reserve left over when a level completes | **REGENT**, swapped in the purchase that completes the level |

Every purchase makes at most one swap: the manager adds up the USDC bound for the treasury in that purchase and swaps it once. A purchase that sends nothing to the treasury makes no swap. The treasury needs no change: REGENT is already a daily-split asset. `recognizeSurplus` still forwards stray tokens unswapped.

### 7.4 A plain swap (Sean, KF-SOL-12)

The swap takes the pool's price at that moment, with no minimum and no oracle: Sean chose "a normal swap with no restrictions". `purchase(receiver, maxPrice, deadline, proof)` keeps today's protection for the buyer (`maxPrice`, `deadline`). Nothing protects the REGENT amount the treasury receives.

**Risk, in two lines:** anyone who can place transactions right before and after a purchase can move the REGENT price against it and keep the difference. That includes the buyer themselves, inside one transaction. Base has no public waiting room for transactions (one sequencer orders them), which stops outsiders from seeing a purchase and jumping ahead of it, but does not stop a buyer doing this to their own purchase, and does not stop someone who places transactions in the same block. With ~141,000 USD of liquidity, this only pays on large keys.

### 7.5 Reentrancy around the swap

- The manager books everything first (price step, totals, split, Cascade state) and swaps after, under its own lock; a hook calling back into the same manager's `purchase` is refused.
- The buyer has its own lock and a transient flag naming the swap it started; each callback checks `msg.sender` is the fixed pool or PoolManager and the flag is set.
- A hook could call another fleet's `purchase` during the swap, but only with its own money, and that fleet's lock and books are separate.
- The buyer measures what arrived (the treasury's balance change), never what a pool or hook reports.

---

## 8. Fleets anyone can create (phase 3)

### 8.1 What the creator gives

`createFleet(terms)`:

- **Type:** one of Classic, Syndicate, Cascade, Accelerant, with all of that type's rules (KF-SOL-15 a).
- **Name:** 1 to 100 bytes, on chain. Plain letters are one byte each; an emoji or accented letter takes 2 to 4.
- **Description:** 0 to 2,000 bytes, on chain.
- **Image link:** optional, up to 512 bytes, on chain, stored as given.
- **Starting price:** 10 to 1,000,000 USDC.
- **Joining requirements:** optional (section 9).
- **Deadline** for the creation and the creator's key 1.

### 8.2 The creator buys key 1 and pays for the deploy

In the same transaction, the creator buys key 1 at their starting price. They approve the factory (a fixed address; the manager's address is not known until creation) for exactly that USDC; the factory passes it to the new manager, which runs the normal purchase for key 1 to the creator (split, swap, mint). Key 1 waits for its draw until the keeper records the fleet's deck (3.5). The creator pays the transaction's gas, which covers the four deploys. If any part fails, nothing is created.

### 8.3 Name, description and image, changed by vote

They live in the manager. `setProfile(name, description, imageLink)` is callable only by the fleet's own treasury, so only an approved proposal of that fleet's Keys reaches it, through today's Votes → Treasury exact-call path, with the present denominator (Sean, KF-SOL-20: "all votes always use the 'present denominator'"). The same limits apply. Founding fleets have the same profile and the same rule. The manager emits `ProfileChanged`, which the collection forwards as an ERC-4906 refresh for the fleet's keys. keyfleet.ai may hide abusive text or images (KF-SOL-22 a); the chain record stays.

### 8.4 What "starting price" means for later keys (KF-SOL-15 a)

Key 1 costs the starting price and later keys follow the type's curve scaled to it:

- **Syndicate and Cascade:** level 1 costs the starting price; each later level costs 20% more.
- **Accelerant:** key 1 costs the starting price; each later key costs 5% more.
- **Classic:** today's 1,024-step table from 8 to 80 USDC, multiplied by starting price ÷ 8, rounded up to the cent.

Founding fleets use 8 USDC (Classic) and 10 USDC (others), which gives today's prices exactly.

### 8.5 Creation risks

- **Spam and abuse:** anyone can create a fleet in the official collection for 10 USDC plus cents of gas, with any name, description or image link. What OpenSea shows comes from the metadata host, so the site decides what it displays.
- **Randomness cost:** every key asks for a Chainlink draw from the Regents subscription, about half a cent each (3.4).

---

## 9. Joining requirements

The creator may set any of these at creation; none means anyone may buy. A buyer qualifies by meeting **any one** of the requirements the creator set (Sean, KF-SOL-16 b).

- **Address list.** The site turns the creator's CSV into a Merkle tree (OpenZeppelin's standard tree: each leaf is the address, double-hashed) and keeps the list to serve each buyer their proof. The fleet stores only the root. The purchase carries the proof; the manager checks it with OpenZeppelin `MerkleProof`.
- **Holds an NFT.** An ERC-721 collection address: the buyer holds at least one (`balanceOf > 0`).
- **Holds a token.** An ERC-20 address and an amount N greater than zero: the buyer holds at least N.

How they work:

- **Checked once, when buying from the fleet**, against the wallet receiving the key. Selling afterwards is fine (Sean). Resales are never checked (KF-SOL-17 a). The creator's own key 1 is not checked.
- **Fixed at creation** (KF-SOL-18 a).
- **Read-only calls.** The NFT and token checks use `staticcall`, so a hostile token cannot change state during a purchase. A token that reverts or lies only affects the fleet whose creator chose it. At creation the factory checks only that each named address has code.
- **Known and accepted (KF-SOL-19 a):** a balance borrowed and returned in the same transaction passes; fake, rebasing or fee-taking tokens are only as meaningful as the creator's choice; ERC-1155 is not covered.

---

## 10. Security analysis

### 10.1 Trust boundaries

| Party | Can | Cannot |
|---|---|---|
| Regents Safe | Create the four founding fleets in order; move phases forward; replace the keeper; add a newer factory | Mint a key, move or burn anyone's key, touch any fleet's money, votes, claims, rate, profile or treasury, change a fleet after creation, change a price, supply, split, route or royalty, close sales, step a phase back |
| Keeper (Regents backend wallet) | Record an open fleet's deck once, before any of its seeds exist; ask for a metadata refresh | Choose a card, change a recorded deck, mint, touch money |
| Anyone (phase 3) | Create a fleet within the input limits, buying its key 1 | Create before phase 3; pass inputs out of bounds; affect any other fleet |
| Factory | Register and deploy fleets; write a new fleet's profile and requirements once; hand the creator's USDC to the new manager | Anything after creation |
| REGENT buyer | Swap the USDC a manager hands it and pay REGENT to that manager's treasury | Hold value between calls; be paid by anyone but the pools it started a swap with |
| Uniswap pools and the REGENT pool's hook (third-party code) | Run during each swap; take fees; refuse a swap; give a worse price (no minimum, 7.4) | Reach any fleet's books outside the swap |
| A fleet's creator-chosen requirement contracts (third-party code) | Answer `balanceOf` during that fleet's purchases, read-only | Change state; reach any other fleet |
| A fleet's manager | Mint its own fleet's next key during a purchase; receive its own keys' transfer hooks | Mint into another fleet |
| A fleet's treasury (approved calls) | Anything an exact approved call can do, as today, including its fleet's profile | Reach any `onlySafe`, `onlyFactory`, `onlyKeeper`, `onlyManager` or `onlyKeys` function |
| Key holders and agents | As today, within their own key's fleet; ask for their key's metadata refresh | Act in another fleet with a key |

There is still no upgrade path, proxy, pause, burn, setter of economics, or `delegatecall` in any contract.

### 10.2 Reentrancy across collection, manager and swap

- `purchase` holds the manager's lock and calls `KEYS.mint`, which calls back into the same manager (`onKeyMoved`) from inside `_update`. That callback does not take the manager's lock; it is `onlyKeys`, makes no token transfer and calls only the fleet's own Rewards and Votes bookkeeping.
- `KEYS.mint` holds a collection-wide lock shared with `requestReveal`, so a receiver cannot mint again or add a second VRF request from inside `onERC721Received`.
- Purchase order: checks (deadline, price, joining requirement), USDC in, split booked, swap of the treasury's part (7.5), enrol, mint (`onERC721Received`), Cascade completion, reveal request last (when the fleet has a deck).
- The factory's `createFleet` holds its own lock across creation and key 1.
- The transfer hook calls no untrusted code. The VRF callback is `onlyCoordinator`, writes once, never reverts, and makes no external call.

### 10.3 Access control

Every privileged function is in the 4.4 and 10.1 tables, each with one fixed caller, compared against an immutable, the write-once registry, or the keeper address only the Safe sets. No `tx.origin`, no roles that can be granted, no ownership transfer.

### 10.4 Cross-fleet confusion

Every per-fleet function that takes a key checks its fleet first; the collection never lets a caller choose the fleet it mints into; the collection only ever calls the key's own manager. Tests try every key-taking function with a foreign key.

### 10.5 No look-ahead at unreleased cards

Sean: "The art / traits should only become known after that Keycard is minted."
- `tokenURI` reverts for an id not yet minted.
- A key's seed exists only once the Chainlink answer to its own request arrives, and that request is sent only after the key is minted and its fleet has a deck.
- Nothing on chain carries a card, trait or deck content, only each deck's fingerprint and size. So no card can be worked out before its key is minted and revealed.
- The rest is up to the site and media-web: serve the interim art and no traits until the permanent card is published, and give no unreleased card a guessable link.

### 10.6 Griefing

- Open creation lets anyone add fleets to the official collection; each costs at least 10 USDC and touches no other fleet.
- Nothing loops over fleets anywhere. The transfer hook cost is bounded as today.
- A receiver that reverts in `onERC721Received` only fails its own purchase. A refused or starved VRF request leaves the key waiting for anyone's retry.
- A keeper that never records a deck leaves that fleet's keys on interim art; it cannot touch money or other fleets.
- A REGENT pool that stops filling stops purchases in every fleet (route fixed, KF-SOL-13 a); a requirement contract that reverts stops purchases only in its own fleet.

### 10.7 Upgradeability

None. Every contract is final when deployed. The Safe may register a newer factory for new fleets (KF-SOL-4 a); existing fleets never change. The swap route, VRF coordinator, metadata base and royalty are fixed forever.

### 10.8 Invariants to test (Foundry, handler-based)

Run with the four founding fleets and two open fleets on one collection, against mock pools, plus a handler that tries every privileged and key-taking function with random callers and foreign keys:

1. Every key belongs to exactly one fleet, for ever; its key number is at most its manager's `totalMinted`.
2. The sum of every fleet's `totalMinted` equals the collection's mint count.
3. A fleet whose sales are closed has `totalMinted == 0`; the phase only ever rose, one step at a time, by the Safe; no open fleet exists before phase 3.
4. Registry entries never change; fleet numbers only grow.
5. No action in fleet B changes fleet A's presence queue, tallies, electorates, ledger backing, credits, treasury balances, holding counts or profile.
6. Ownership epochs only increase; a shard ends when its key moves.
7. The collection, factory and REGENT buyer hold no tokens or ETH after any call and leave no approvals.
8. Each fleet's four contracts point at each other and at nothing else.
9. Every invariant in today's suite holds in every fleet side by side.
10. A fleet's `deckHash` and `deckSize` are set at most once; no key of a fleet without a deck has a seed or a pending draw.
11. Every purchase's USDC splits exactly as 7.3; protocol share, Cascade reserve and rebates stay USDC; the treasury's part arrives as REGENT.
12. An open fleet's key 1 belongs to its creator at the starting price, and its later prices follow its type's curve scaled to that price.
13. A fleet's profile only changes through its own treasury; its joining requirements never change.

Plus: `check_bytecode.sh` finds no reachable `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and Slither's reentrancy, arbitrary-send and delegatecall detectors run clean or are triaged.

---

## 11. What is deleted and what moves (hard cutover)

| Today | After |
|---|---|
| `src/Keyfleet.sol` | **Deleted.** ERC-721, epochs, VRF reveal, `tokenURI`, ERC-4906 → `KeyfleetKeys.sol`. Sale, prices, Cascade, rebate, protocol share, holding limits, `recognizeSurplus`, `firstMintAt` → `KeyfleetManager.sol`. |
| USDC capital paid to the treasury | **Replaced** by the swap to REGENT (7.3). |
| `KeyfleetPresets` prices fixed at Q = 10 USDC and Classic's table | Prices scale from the fleet's starting price (8.4); supplies, levels, holding limits and splits unchanged. |
| `Keyfleet.Metadata` (per-fleet name, symbol, metadata base) | **Deleted.** One name, symbol, base, `contractURI` and royalty on the collection; each fleet's profile on its manager. |
| `Keyfleet.Randomness`, per-fleet `TRAIT_TABLE_HASH` | Move to the collection, once. |
| `Keyfleet.Companions` and nonce prediction per fleet | **Deleted.** Replaced by CREATE2 + transient wiring (4.3). |
| `KeyfleetShards` per fleet | One shared record bound to the collection. |
| `KeyfleetVotes`, `KeyfleetTreasury`, `KeyfleetRewards` constructors taking a `Keyfleet` | No-argument constructors reading the factory's wiring; own-key checks added. Logic otherwise unchanged. |
| `KeyfleetPresence` 32-bit ids | 64-bit ids. |
| `script/KeyfleetStack.sol` | **Deleted.** |
| `DeployKeyfleets.s.sol` (one fleet per run) | Deploys the system once. |
| (none) | New: create-founding-fleet and advance-phase steps that write the Safe transactions; on anvil they are sent directly. |
| `RecordKeyfleets.s.sol` | Records the system once, then each fleet from its `FleetCreated` event. |
| `KeyfleetManifest.sol`, `deployments/*.json` | Shared bindings (including both swap pools and the v4 pool key, the keeper, the metadata base) plus the four founding fleets' type, deck and profile. |
| `AnvilLab.s.sol` | Builds the factory, creates Classic #1, moves to phase 1 locally, buys two keys through a local swap route. |
| `check_bytecode.sh` | Checks the new contract list. |
| Tests | Fixture goes through the factory; every suite is ported; new suites in section 12. |

Nothing is deployed anywhere today, so nothing needs migrating.

**Site, backend and media-web lanes, list only (after B5 fixes the ABI):**
- One collection address; the scanner reads the collection's `Transfer`, `OwnershipEpoch`, `KeyRevealed`, `MetadataUpdate`, `BatchMetadataUpdate`, `FleetCreated`, `DeckSet` and phase events, plus each fleet's manager, Votes, Treasury and Rewards.
- Metadata at the fixed base, decoding fleet and key number. Key name `CLASSIC—001—072`; traits `Fleet type`, `Fleet number`, the fleet's name, key number, `Card`. Interim art until the permanent card is published; nothing for unminted ids; no guessable links (10.5).
- The deck backend: on `FleetCreated` for an open fleet, build its deck, `setDeck` from the keeper wallet, then `requestReveal` the waiting keys; after publishing each permanent card, `refreshMetadata`.
- Purchase targets the fleet's manager (with the Merkle proof when the fleet has a list); transfers and approvals the collection. The buy button shows "sales have not opened" from `salesOpen`, and may show a requirement reason when the receiving wallet certainly fails all of them at the latest block.
- A create-a-fleet page for phase 3; a proposal builder for profile changes; `seed-deployment` takes the collection record plus each fleet record.

---

## 12. Build plan

Each step leaves `forge build` and `forge test` green, deletes what it replaces, and updates `contracts/README.md`.

| # | Step | Tests |
|---|---|---|
| B0 | This design; Sean's answers recorded here | — |
| B1 | **`KeyfleetKeys` on its own.** Registry, mint into its own fleet only, token ids, epochs, phases and sales switches, keeper and decks, reveal held until a deck, retry, `tokenURI`, `contractURI`, ERC-2981, ERC-4906 incl. refreshes. | Mint refusals, phase steps, deck set once and only before seeds, no draw without a deck, `tokenURI` reverts for unminted ids, royalty, epoch bumps, hook goes only to the key's manager, reveal suite ported, golden draws unchanged |
| B2 | **`KeyfleetRegentBuyer`.** Fixed v3 and v4 route, both callbacks, nothing left behind. | Mock pools: callbacks from strangers or outside a swap refused, nothing left behind. Base fork (read-only): real quotes match; hook fee taken; gas measured |
| B3 | **`KeyfleetFactory` and deployers.** CREATE2, transient wiring, founding fleets, open creation, adding a factory. | Wiring both ways; refusals; every bound on open creation; transient wiring empty after; sizes under limits; open creation gas measured against 16,777,216 |
| B4 | **Cutover.** `KeyfleetManager` replaces `Keyfleet`: starting-price curves, the swap of the treasury's part, profile, joining requirements; Rewards, Votes, Treasury, Shards rebound; own-key checks; 64-bit presence ids; fixture through the factory; every existing suite ported; `Keyfleet.sol` and `KeyfleetStack.sol` deleted. | Today's suites with today's prices and splits on founding fleets; treasury share arrives as REGENT; scaled curves; requirements met and missed, any-one rule; profile change through a real proposal |
| B5 | **Cross-fleet suite and multi-fleet invariants.** | 10.8 at 256 runs × depth 100 or more |
| B6 | **Scripts.** Manifest, system deploy, Safe transactions, record, anvil lab, bytecode check list. | Deploy and record tests over mocks; refusals per pin |
| B7 | **Release readiness.** Gas report, README, deployment docs, product spec and v0.3 docs brought to round 3. | `make check-contracts` green |

---

## 13. Questions only Sean can answer

The build follows each recommendation until Sean answers. Answered questions are in the table at the top.

**1. (KF-SOL-24) Who records the card deck for a fleet made by anyone?**
- a) A Regents backend wallet (the keeper), named at deploy, which the Safe can replace. It can only record a deck once, for a fleet with none, before any of its Keys has a random number, and can't touch money. New fleets get their cards within minutes. *(recommended)*
- b) The Safe signs every deck. Each new fleet's cards wait for two of three signers.

*Changes B1.*

**2. (KF-SOL-25) Who triggers "the metadata update" that reveals a Key's permanent card?** The contract lets both happen.
- a) The backend, automatically, as soon as the card is published. *(recommended)*
- b) The Key's holder presses a "reveal" button.
- c) Both: automatic, plus a button for holders.

*Changes the site and backend lanes only.*

**3. (KF-SOL-26) In a Key's name, which fleet number shows?**
- a) The number within its type, matching the card titles: Syndicate #1's key 5 is `SYNDICATE—001—005`. *(recommended)*
- b) The fleet's number across all fleets: Syndicate #1 is fleet 2, so `SYNDICATE—002—005`.

*Changes the site lane only; the chain records both.*

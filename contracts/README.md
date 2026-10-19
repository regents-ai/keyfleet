# Contracts

A Foundry workspace pinned to Solidity 0.8.26 with OpenZeppelin 5.7.0 and
forge-std 1.9.7 vendored as git submodules under `contracts/lib`. Everything
lives on Base (chain 8453).

Every key of every fleet is a token of one ERC-721 collection, `KeyfleetKeys`,
named "Keyfleet" with the symbol KEYFLEET. Each fleet is four contracts the
factory creates for it: a `KeyfleetManager` that sells its keys and keeps its
profile, a `KeyfleetVotes` controller, a `KeyfleetTreasury` and a
`KeyfleetRewards` ledger. A key counts only in its own fleet.

| Contract | How many | What it holds |
| --- | --- | --- |
| `KeyfleetKeys` | one | Every key's owner and ownership epoch, the fleet registry, the phase that opens sales, each fleet's card deck fingerprint, each key's random seed, the keeper's address |
| `KeyfleetFactory` | one | The bindings every fleet is given; nothing of value |
| `KeyfleetShards` | one | Agent shards and agent-voting switches, per key |
| `KeyfleetRegentBuyer` | one | Nothing between calls; the fixed USDC to REGENT route |
| `KeyfleetClubClaims` | one | Regents Club keys whose Pass holder could not take one yet, until they claim it, with what each earned while it waited |
| four deployers | one each | Nothing; each holds one fleet contract's creation code |
| `KeyfleetManager` | one per fleet | Type, starting price, Accelerant step, keys minted, the Cascade reserve, the owed protocol share, name, description, image link, joining requirements |
| `KeyfleetVotes` | one per fleet | Presence, proposals and ballots |
| `KeyfleetTreasury` | one per fleet | The fleet's free capital; makes approved proposals' exact calls; runs the daily split |
| `KeyfleetRewards` | one per fleet | What each key and each wallet is owed |

`KeyfleetPresets` is a pure library holding every price, supply and
purchase-split rule, with Classic's price table in the generated
`KeyfleetClassicPrices`. `KeyfleetPresence` is the presence queue, a library
inlined into `KeyfleetVotes`. No contract has an administrator, an upgrade path,
a pause, a burn, a proxy or a `delegatecall`, and no contract has a setter for
any price, supply, split, rate bound, route or royalty.

## Status

**9 October founder update:** KF-A-03's conversion-price risk is accepted; Sean
requested no fix. Batch receiver/ownership changes (KF-A-04) were acknowledged,
with the existing probe and claims fallback retained. The Base keeper is the
Regents Safe. Sean supplied the randomness subscription. Club launches alone;
Classic follows testing, then the other founding fleets. Consumer setup, funding
and Safe subscription ownership may wait while all minted Keys use fixed founding
decks. No deployment occurred.

Decided by the founder on 27, 28 and 29 September and 6, 7 and 8 October 2026,
and what the code on this branch does:

- One collection holds every key. A key's token id is its fleet's number times
  10^10 plus its key number, so fleet 1's key 72 is `10000000072`. Fleets are
  numbered 1, 2, 3 and so on across all types, and the collection also records
  each fleet's type and its number within that type.
- Sales open in phases the Regents Safe
  (`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`) moves forward, one step at a
  time and never back: phase 1 opens only the Regents Club, phase 2 opens
  Classic #1, phase 3 opens Syndicate #1, Accelerant #1 and Cascade #1, and phase 4 lets anyone
  create a fleet. Each
  phase step is a Safe transaction the founder signs, naming the moment the
  phase opens, which must be in the future.
- In phase 4 anyone may create a fleet of any of the four sold types: they choose
  its name (1 to 100 bytes), an optional description (up to 2,000 bytes) and
  image link (up to 512 bytes), a starting price from 10 to 1,000,000 USDC in
  whole cents, for an Accelerant fleet its step of 1% to 5% per key, and
  optional joining requirements, and they buy its key 1 at that price in the
  same transaction. Later keys follow the type's curve scaled from the starting
  price.
- A fleet's name, description and image link change only by an approved
  proposal of its keys. Its joining requirements never change. A buyer
  qualifies by meeting any one of them: being on an address list, holding a
  given NFT, or holding at least a given amount of a token. They are checked
  only when buying from the fleet, never on a resale.
- Fleets are fully owned by their key holders. Regents takes 10% of each key
  purchase, once, in USDC, deposited into REGENT revenue staking on Base
  (`0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`) for REGENT stakers. Keyfleet
  takes nothing from money a fleet receives afterwards.
- Keys are paid in USDC. A purchase swaps nothing: the part that goes to the
  fleet's treasury is booked in the fleet's manager and turned into REGENT
  afterwards, in pieces of at most 250 USDC, no faster than 250 USDC every 15
  minutes across all fleets, by anyone who calls for the next piece and may ask
  for a smaller one. Each piece is a
  plain market swap with no minimum through one fixed route: USDC to WETH on a
  Uniswap v3 pool, then WETH to REGENT on a Uniswap v4 pool, and it is refused
  if it moves the route's price by more than 1%. The REGENT goes to the
  treasury. The protocol share, the Cascade reserve and repayments and the
  Accelerant rebate stay USDC.
- The fleet's treasury is its one payment address. Every token it receives is
  treasury capital. Money sent to the fleet's manager outside a purchase is
  forwarded to the treasury unswapped. The treasury spends only by making an
  approved proposal's exact calls, apart from the daily split, which shares a
  small part of its ETH, REGENT and USDC (and OUSD once a vote admits it, and
  the fleet's own token once launched) equally across the fleet's keys that
  were minted at least 2 days before.
- A fleet may launch its own token through Autolaunch Revstake v2 on Base, by a
  vote. Once the launch has sold, anyone may bind its token to the daily split,
  once; only tokens already released to the treasury are split.
- Syndicate and Cascade have no last level: the same Fibonacci supply and 1.2×
  price rule go on for as long as keys sell. Only Classic (1,024 keys) and
  Accelerant (2,000 keys) have a supply limit.
- Accelerant: the first key sends 10% to staking and 90% to the treasury; every
  later key sends 10% to staking, 20% to the treasury and 70% to whoever holds
  the key before it.
- A proposal names the key it is made with, a hash of its text and the exact
  calls the treasury makes if it passes. Every vote lasts exactly 24 hours.
  Each key casts one ballot, Yes, No or Abstain, which can be changed until
  closing. The electorate is the keys present when the proposal opened plus
  every key that joins by casting a ballot; it never shrinks. After closing a
  proposal passes when Yes reaches 60% of that electorate, rounded up (1 of 1,
  2 of 2, 2 of 3, 3 of 4, 3 of 5, 4 of 6, 5 of 7, 5 of 8, 6 of 9, 6 of 10), so
  abstaining and staying silent count against it. Anyone may carry it out for
  48 hours: from closing if it moves no money, or from a day after closing if
  it does. Whoever may vote the key it was made with may cancel it until then.
  During a money proposal's day of waiting any key may still vote No, and the
  proposal is cancelled the moment it would no longer pass. One present key
  alone may pass anything at closing.
- A payment names one asset the treasury holds and a share of the treasury's
  balance of it, from 0.0001% to 99%, worked out when the proposal is carried
  out. A proposal makes at most one payment, and no proposal may move tokens or
  ETH any other way.
- For its first 7 days after its sales open, a fleet's proposals may only
  change its name, description and image, its daily split rate and whether a
  key's edits are restricted; none may move money.
- A key's edits are restricted, or freed again, only by a passed proposal's
  call.
- A new key waits 2 days from its mint before it can take part; a transfer does
  not restart the wait. It is then present on its own for 48 hours, until day
  4. After that a key is present for 48 hours after its owner or an agent
  holding a shard of it renews it, casts a ballot for it, proposes with it or
  cancels with it. A present key stops being present the moment it changes
  hands; a key sold on during its wait keeps its automatic start.
- A wallet may hold any number of a fleet's keys.
- A key's owner may issue shards: time-limited grants to agent wallets, recorded
  on chain and ended the moment the key changes hands. An agent with a shard
  always may mark the key present. It may also vote the key, propose with it
  and cancel with it unless the owner turned the key's agent voting off; every
  new owner starts with it on. One agent may hold shards of many keys, and every
  call about keys takes a list of them.
- Renewals and ballots may be signed and handed to anyone to submit; a signature
  is void once used, after its deadline, and after any of its keys changes hands
  or has its shards or agent voting changed.
- Every fleet's cards come from a pre-made deck, of which only the fingerprint
  and the size are on chain. Decks stay private; only the rarities are public.
  Decided 8 October 2026: on the five founding fleets key N holds card N of its
  fleet's deck, with no random draw. Every other key draws: a founding key past
  its deck, and every key of a fleet anyone creates. A key that draws asks
  Chainlink VRF for its random number once its fleet has a deck; the one answer
  to its one accepted request is the key's. Keys beyond a fleet's deck use the
  trait draw.
- The Regents Club, decided 8 October 2026, is the fifth founding fleet: 1,998
  keys, one for each Regents Club Pass on Base
  (`0x2208aaDBdEcd47D3B4430b5b75a175f6d885D487`, Passes 1 to 1,998), never sold
  and with no price. The Regents Safe gives them in batches it signs: key N to
  whoever holds Pass N at that moment, read at the latest block. A Pass held by
  a contract that cannot take a key, or a Pass burned, has its key sent to
  `KeyfleetClubClaims`, which the contract accepts without asking the Pass, so
  a missing Pass holds up no later key. Whoever holds Pass N may claim key N
  there at any time, with no deadline, together with what it earned while it
  waited. Its treasury starts empty, and
  its resales carry the same royalty to the Safe as every key.
- Resales carry an ERC-2981 royalty of 2.5% to the Regents Safe. Marketplaces
  may choose not to honour it.
- The treasury owns the fleet's Lit account. It signs nothing by itself: it
  answers a signature check (ERC-1271) only for a hash a passed proposal
  approved, and every write to the Lit account is a passed proposal's call.
- Keyfleet Classic, decided 7 October 2026: 1,024 keys, the first at 10 USDC
  and the last at 100 USDC, each key the same percentage dearer than the one
  before, rounded to the nearest cent.

On hold or not yet done:

- The Regents Club is deployed on Base; its deployment record is not yet
  committed here as `deployments/base.deployed.json`. Classic #1 and the other
  founding fleets are not deployed. Before each further deploy: the internal
  audit of every Keyfleet contract the founder chose on 9 Oct in place of an
  outside one, its findings resolved subject to the founder's accepted risks
  above, and the founder's go.
- Key sales stay off until the founder explicitly says so. On chain no key of
  any fleet can be minted before the Safe's phase step that opens it.
- `deployments/base.json` carries the trait table's hash
  (`0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe`, eight
  traits of sixteen values each, every trait's weights adding up to 1,000), the
  five founding fleets' deck fingerprints, the Regents Safe as keeper and Sean's
  verified Base VRF subscription. Recording may defer consumer setup and Safe
  ownership while all minted Keys are within fixed founding decks.
- On Base every deployment refuses any staking contract but REGENT revenue
  staking and any swap route but the pinned one, and the record step refuses a
  randomness subscription not owned by the Regents Safe once a recorded fleet needs
  random draws.
- Lit's own servers (registering the treasury's account, checking its answer to
  a signed request, minting a usage key and running the inbox action) work only
  against a treasury deployed on Base itself, so they are untested until one is.
- Deferred until the Cascade fleet type is next: the reserve of a level that
  never completes.
- The protocol share waits in the fleet's manager, still owed, for as long as
  REGENT staking is paused; the staking contract's owner, the Regents Safe, is
  trusted to unpause it.
- Each drawing key's Chainlink VRF request is paid in ETH from the Regents subscription
  on Base's 2 gwei lane (the 30 gwei lane is also allowed). Sixteen real answers
  on Base read on 7 October 2026 cost about 0.4 to 1.4 US cents each, about half
  a cent for a key's 100,000-gas answer.

## Presets

`KeyfleetPresets` covers five presets: `FibonacciSyndicate`, `FibonacciCascade`,
`FleetTechClassic`, `FleetTechAccelerant` and `RegentsClub`. `RegentsClub` is the
fifth founding fleet's alone: it has a supply, `CLUB_SUPPLY` (1,998), and no price
or split, since its keys are given, never sold. Everything below on prices and
splits is about the other four. It has no storage, holds no tokens
and makes no external calls. Every function is `internal pure` with checked
arithmetic.

Keys are paid in USDC, and every price is in atomic USDC (six decimals). Every
price is scaled from the fleet's starting price, the price of its key 1. The
sold founding fleets start at `Q_USDC`, 10,000,000 (ten USDC), and Classic #1 at
`CLASSIC_START_USDC`, 10,000,000 (ten USDC), too. A fleet anyone creates starts
anywhere from `MIN_START_USDC` (10 USDC) to `MAX_START_USDC` (1,000,000 USDC) in
whole cents (`CENT_USDC`, 10,000). Every ladder is computed iteratively from the
first step, never as a closed-form power, and every step rounds up:

- Fibonacci level price: level 1 costs the starting price, and each further
  level costs `ceilDiv(previous * 120, 100)`. There is no last level. At a
  10 USDC start, level 20 costs 319.48 USDC, level 30 about 1,978 USDC, level 40
  about 12,248 USDC, and a level's price first passes a billion USDC at level
  103.
- Accelerant primary price: the first mint costs the starting price, and each
  further mint costs `ceilDiv(previous * (100 + step), 100)`, where the step is
  the fleet's whole percent from `MIN_ACCELERANT_STEP_PERCENT` (1) to
  `MAX_ACCELERANT_STEP_PERCENT` (5), chosen by its creator; the founding
  Accelerant's is 5. `MAX_ACCELERANT_KEYS` is
  2000. Only primary mints advance the price; resales do not. The manager
  stores the next price in `currentPrice` and steps it after each primary mint.
- Fleet.Tech Classic: `CLASSIC_SUPPLY` is 1024. At a 10 USDC start key n costs
  1000 × 10^((n − 1) / 1023) US cents, rounded to the nearest cent: key 1 costs
  10 USDC, key 144 13.80, key 512 31.59 and key 1024 100 USDC, each key about
  0.2253% dearer than the one before, and all 1,024 together 40,040.48 USDC.
  `classicPrice(keyNumber, start)` reads the cent value from
  `KeyfleetClassicPrices.CENTS`, a table of 1,024 two-byte cent values, and
  returns `ceilDiv(cents * start, 10,000,000) * 10,000`: the table scaled by the
  starting price over 10 USDC and rounded up to the cent. The table is written by
  `scripts/classic_prices.py` at the repository root, which also writes
  `platform/lib/keyfleet/fleets/classic_key_prices.txt`, the same prices the
  site shows; change the script and run `uv run scripts/classic_prices.py`,
  never either file. The preset test walks the curve one key at a time in
  36-decimal fixed point and checks every one of the 1,024 prices against it.

Fibonacci level supplies are 2, 3, 5, 8, 13, ..., 17,711 at level 20, 28,657 at
level 21, and so on without end. Key numbers are 1-based and contiguous across
levels: level 20 ends at key 46,365, level 30 at 5,702,884 and level 40 at
701,408,730. There is no per-wallet holding limit. Every level
function walks the levels from the first, so its cost grows slowly with the
level. A fleet mints at most 4,294,967,295 keys (`KeyfleetKeys.MAX_KEY_NUMBER`);
a Fibonacci fleet would refuse a sale past that with `SoldOut`, long after its
price had passed any real buyer.

A purchase is split into four parts that always sum to exactly the gross price.
`PROTOCOL_BPS` is 1000: 10% of every purchase, rounded down, is the protocol
share for REGENT stakers. The rest depends on the preset:

- Syndicate and Classic: the rest, 90%, is the treasury's part, turned into
  REGENT.
- Cascade: the rest, 90%, goes to the level-completion reserve, in USDC.
- Accelerant after the first key: `ACCELERANT_CAPITAL_BPS` (2000, 20% of gross,
  rounded down) is the treasury's part, turned into REGENT, and the rest, 70% of
  gross plus any rounding dust, is a USDC rebate to the current holder of the
  preceding key. The first Accelerant key has no predecessor and its rest, 90%,
  is the treasury's part.

## The collection

`KeyfleetKeys` is an OpenZeppelin ERC721 with ERC-4906, ERC-2981 and a
transient reentrancy lock. Its name, symbol, metadata base and collection
metadata address are fixed at deployment.

### Fleets and token ids

`tokenIdOf(fleetId, keyNumber)` is `fleetId * 10^10 + keyNumber`, and
`fleetOf(tokenId)` and `keyNumberOf(tokenId)` take it apart with no storage
read. Fleet numbers run from 1 to `MAX_FLEETS`, 999,999,999, so every token id
stays below 10^19 and fits in 64 bits. Key numbers run from 1 to
`MAX_KEY_NUMBER`, 4,294,967,295.

`registerFleet(preset, manager, deckHash, deckSize)` may be called only by a
factory (`OnlyFactory`). It refuses a zero manager (`ZeroAddress`), an account
that already manages a fleet (`ManagerTaken`) and a fleet past `MAX_FLEETS`
(`TooManyFleets`). Before phase 4 it accepts only the five reserved founding
slots, each once with its deck: fleet 1 Classic, 2 Syndicate, 3 Accelerant, 4
Cascade, 5 Regents Club (`foundingPreset(fleetId)`; `NotFoundingFleet` otherwise, `DeckInvalid`
for a missing deck). In phase 4 a fleet is registered without a deck
(`DeckGivenAtCreation` otherwise). It records the manager, the type, the type
number (`typeCount` per type plus one) and the deck, and emits
`FleetRegistered(fleetId, preset, typeNumber, manager, factory)`, plus
`DeckSet(fleetId, deckHash, deckSize)` when a deck is given. Registry entries
are written once and never changed or removed. `fleet(fleetId)`,
`managerOf(fleetId)`, `deckOf(fleetId)`, `fleetCount()`, `typeCount(preset)`
and `fleetOfManager(manager)` read it. `fleetCount` is the highest registered
id; `fleetExists` distinguishes absent founding slots. An unknown fleet reverts with
`UnknownFleet`.

The deploying factory is the first factory (`isFactory`). The Safe may allow
another with `addFactory(factory)`, which refuses an address with no code
(`FactoryMissing`) and emits `FactoryAdded(factory)`. Existing fleets never
change.

### Phases and sales

`phase()` runs from 0 to `FINAL_PHASE`, 4. Only the Safe moves it
(`OnlySafe`), one step at a time and never back, with `advancePhase(opensAt)`,
which emits `PhaseAdvanced(phase, opensAt)`. `opensAt` is the moment the new
phase opens: it must be later than the step's own block, at most
`MAX_OPENING_LEAD` (30 days) after it, and no earlier than the previous phase's
opening (`OpensAtInvalid(opensAt)`), and it is kept in
`phaseOpensAt()`. The phase number changes at once; what the phase opens waits
for `opensAt`, to the second, with nobody acting again.

| Phase | What it opens at `opensAt` | Refused unless |
| --- | --- | --- |
| 0 | Nothing sells. The Safe creates the founding fleets, one per transaction | — |
| 1 | Only the Regents Club's gifts | Club fleet 5 exists (`FleetsMissing(1, present)`) |
| 2 | Classic #1's sales | Club 5 and Classic 1 exist (`FleetsMissing(2, present)`) |
| 3 | Syndicate #1, Accelerant #1 and Cascade #1's sales, together | fleets 1 to 5 exist (`FleetsMissing(5, registered)`) |
| 4 | Anyone may create a fleet; each sells from the moment it is created | all five founding fleets exist |

Past phase 4, `advancePhase` reverts with `NoNextPhase`. `salesOpenAt(fleetId)`
is the time a fleet's sales open: fleet 5's is the `opensAt` of the step
to phase 1, fleet 1's the step to phase 2, fleets 2 to 4's the step to phase 3, and any later
fleet's its registration; it is zero before then and for a fleet that does not
exist. `salesOpen(fleetId)` is true once `salesOpenAt(fleetId)` is set and has
been reached. Until phase 4 has both been stepped to and opened, the collection
registers only the founding fleets and the factory refuses `createFleet`
(`CreationClosed(phase)`). Each fleet's 7-day opening (see Votes) counts from
`salesOpenAt`.

`mint(to, keyNumber)` is the only way a key comes to exist. Only a registered
manager may call it (`OnlyManager`), and only into its own fleet: the fleet is
looked up from the caller, never taken from an argument. It refuses a fleet
whose sales have not opened (`SalesClosed(fleetId)`) and a key number outside 1
to `MAX_KEY_NUMBER` (`KeyNumberOutOfRange`), mints with `_safeMint`, and asks
for the key's random number if its fleet has a deck and the key is not dealt by
number. It shares one reentrancy
lock with `requestReveal`, so a receiver cannot mint again or add a request from
inside `onERC721Received`. The Safe can neither mint nor move any key.

### Transfers and ownership epochs

On every transfer the collection first checks that the caller may move the key,
so a caller without the owner's approval is refused with ERC-721's own
`ERC721InsufficientApproval` before any fleet bookkeeping runs. Then, on every
transfer and before ownership changes, it calls the key's own fleet manager,
`onKeyMoved(tokenId, from)`, which settles the key's rewards to the outgoing
owner and ends its presence. A mint calls no manager; the sale has already
enrolled the key. It then raises the key's `ownershipEpoch` by one (it is 1 at
mint), records `mintedAt(tokenId)`, the mint's block time, on a mint (no
transfer changes it), emits `OwnershipEpoch(tokenId, epoch, from, to)` and moves the key. A transfer only ever calls the one
manager the key belongs to. There is no burn. One `setApprovalForAll` to a
marketplace covers a holder's keys in every fleet; it grants nothing in any
fleet's votes, claims or shards.

### Metadata and royalty

`tokenURI(tokenId)` is the fixed base followed by the token id, and reverts for
an id that has not been minted. `baseTokenURI()` returns the base and
`contractURI()` (ERC-7572) the collection's own metadata address. On Base the
base is `https://keyfleet.ai/metadata/keys/` and the collection metadata
`https://keyfleet.ai/metadata/collection.json`.

`royaltyInfo(tokenId, salePrice)` asks 2.5% (`ROYALTY_BPS`, 250) of every sale
for the Safe, the same for every key. `supportsInterface` reports ERC-721,
ERC-4906 (`0x49064906`) and ERC-2981.

The collection is the only contract that emits ERC-4906 events:
`MetadataUpdate(tokenId)` when a key's seed is written and when the key's owner
or the keeper calls `refreshMetadata(tokenId)` (`NotOwnerOrKeeper` for anyone
else), and `BatchMetadataUpdate` over a fleet's whole id range when its manager
calls `refreshFleet()` after a profile change.

### Card decks and the keeper

Every fleet's cards come from a pre-made deck. The collection keeps only each
deck's fingerprint (`deckHash`, `keccak256` of the deck file's exact bytes) and
size (`deckSize`), each fixed once; both zero means no deck yet, and one zero
without the other, or a size above `MAX_KEY_NUMBER`, is refused (`DeckInvalid`).
Decks stay private; nothing on chain carries a card, a trait or a deck's
content.

The five founding fleets are registered with their decks, and their keys 1 to
the deck's size are dealt by number: key N holds card N of its fleet's deck and
draws nothing (`dealtByNumber(tokenId)`). Their order is fixed by the deck file,
whose fingerprint is on chain before any key exists.

Every other key draws: a founding key past its deck, and every key of a fleet
anyone creates. A deck's fingerprint is fixed before any seed of its fleet
exists, so nobody can build or change a deck after seeing which random numbers
came up. The collection enforces it by asking Chainlink for a drawing key's
random number only once its fleet has a deck:

- A founding key past its deck asks at mint.
- A fleet anyone creates is registered without one. Its keys, the creator's key
  1 included, mint and wait. The keeper records its deck once with
  `setDeck(fleetId, deckHash, deckSize)` (`OnlyKeeper`, `UnknownFleet`,
  `DeckAlreadySet`, `DeckInvalid`), which emits `DeckSet`. Then anyone may ask
  for the waiting keys with `requestReveal(tokenId)`; keys minted afterwards ask
  at mint.

The keeper is a Regents wallet. It is set at deployment and only the Safe may
replace it, with `setKeeper(keeper)` (`ZeroAddress` for zero), which emits
`KeeperSet(keeper)`. It can record a deck for a fleet with none and ask for a
key's metadata refresh. It cannot choose any key's card, change a recorded
deck, mint, move a key or touch money. A fleet whose deck is never recorded
keeps its keys unrevealed; they can still be traded.

On a fleet anyone creates, each key is dealt a card from its fleet's
remaining cards in on-chain reveal order, using the key's seed, by the rule in
`platform/priv/decks/README.md`. Keys 1 to N of an N-card deck get deck cards;
key N + 1 onward, on any fleet, uses the trait draw below.

### Key reveals

Every drawing key's card or traits come from one Chainlink VRF v2.5 random
word. A key's request asks the collection's coordinator for one word, three blocks deep
(`REVEAL_CONFIRMATIONS`), with 100,000 gas for the answer
(`REVEAL_CALLBACK_GAS_LIMIT`), paid in ETH from the collection's subscription.
A purchase never waits for the answer and never fails because of the request.
An accepted request emits `RevealRequested(tokenId, requestId)` and records the
time in `revealRequestedAt(tokenId)`; a refused one emits
`RevealRequestFailed(tokenId)` and the key is still sold.

`requestReveal(tokenId)` lets anyone ask for a minted key that draws, has no
seed and whose fleet has its deck, when the coordinator has accepted no request for it (it was
minted before its fleet's deck was recorded, or every request was refused). It
refuses a key already revealed (`AlreadyRevealed`), one whose request the
coordinator has accepted (`RevealAlreadyRequested(tokenId)`), however long the
answer takes, one dealt by number (`DealtByNumber(tokenId)`) and one whose fleet
has no deck (`DeckNotSet`). A key has at most
one accepted request, so its seed can come from only one answer.

`expireReveal(tokenId)` lets anyone permanently expire an unanswered accepted
request once `revealRequestedAt + REVEAL_TIMEOUT` (24 hours) is reached. It emits
`RevealExpired(tokenId)` and sets `revealExpired(tokenId)`. The Key stays without
a seed, late answers are ignored, and its original accepted request remains
recorded so it can never ask again. Expiry is explicit, not automatic. A call
before the deadline is refused (`RevealTooEarlyToExpire`); a never-requested,
already-seeded or already-expired Key is refused (`RevealNotWaiting`).

The coordinator, the subscription id and the gas lane are one setting,
`randomness()`, which the Safe may replace with `setRandomness(randomness)`
(`OnlySafe`; `CoordinatorMissing` for an address without code). The
constructor and every change emit `RandomnessSet(coordinator, subscriptionId,
keyHash)`. Every request from then on goes to the new setting. Only the current
coordinator may answer, so `revealsWaiting()` counts the keys whose accepted
request has neither given them a seed nor been expired, and while any wait the Safe may change
the subscription and gas lane but not the coordinator
(`RevealsWaiting(waiting)`). A provider change cannot interrupt a request still
waiting for its answer. Keys minted before their fleet's deck and keys whose requests were
refused are asked for through the new setting.

The answer arrives through `rawFulfillRandomWords`, which only the current
coordinator may call (`OnlyCoordinator`). The key's seed is

```
keccak256(abi.encode(TRAIT_SEED_TAG, block.chainid, address(collection), tokenId, word))
```

with `TRAIT_SEED_TAG = keccak256("keyfleet.trait-seed")` and `word` the first
random word. It is stored once in `revealSeed(tokenId)`, and the collection
emits `KeyRevealed(tokenId, fleetId, keyNumber, requestId, seed)` and
`MetadataUpdate(tokenId)`. An answer for a key that already has a seed, for an
request already expired, unknown request, or with no words is ignored without reverting, because a
reverted answer is final and still charged.

The trait draw, for keys beyond their fleet's deck, uses the seed and a
published trait table. `TRAIT_TABLE_HASH` is `keccak256` of that file's bytes
exactly as committed, fixed once on the collection. The rule, for a key with
seed `seed`:

- Traits are drawn in the order the table lists them. The trait listed at
  position `i`, counting from 0, uses word `i`, which is
  `keccak256(abi.encode(seed, i))` with `i` a `uint256`.
- Let `u` be the top 32 bits of word `i`, as a number from 0 to 2^32 - 1, and
  `total` the sum of that trait's weights. The draw is
  `r = floor(u * total / 2^32)`.
- Walk the trait's values in the order the table lists them, adding up their
  weights. The value picked is the first one whose running total is greater than
  `r`.
- Each trait's weights must be whole numbers that add up to less than 2^32, so
  that `u * total` fits in 64 bits and every value with a weight above zero can
  be drawn.

The site draws traits with this rule in `platform/lib/keyfleet/traits.ex`, and
`test/KeyfleetTraitDraw.t.sol` pins the same golden results the site's tests pin.
The table's file format is in [../docs/deployment.md](../docs/deployment.md).

The operator writes a known VRF subscription id into the manifest before deployment.
Funding, consumer setup and Safe ownership may be deferred while all minted Keys
are dealt from their fixed founding decks. Complete them before minting a Key
past its founding deck or any public fleet's Key; recording drawn Keys requires
consumer setup and Safe ownership. A key minted before
that has its request refused and can ask again once the collection is added.
The deploy-day checklist is under Deployment scripts.
The three Chainlink files the collection uses are copied unchanged into
`src/vendor/chainlink`, with their source, commit and checksums in the README
beside them.

### Errors and events

Errors: `ZeroAddress`, `CoordinatorMissing`, `RevealsWaiting`, `TraitTableHashZero`, `OnlySafe`,
`OnlyFactory`, `OnlyManager`, `OnlyKeeper`, `NotOwnerOrKeeper`, `NoNextPhase`,
`OpensAtInvalid`, `FleetsMissing`, `NotFoundingFleet`, `DeckGivenAtCreation`, `TooManyFleets`,
`ManagerTaken`, `UnknownFleet`, `SalesClosed`, `KeyNumberOutOfRange`,
`DeckAlreadySet`, `DeckInvalid`, `DeckNotSet`, `FactoryMissing`,
`OnlyCoordinator`, `AlreadyRevealed`, `RevealAlreadyRequested`,
`DealtByNumber`, and the OpenZeppelin ERC-721 errors.

Events: `FleetRegistered`, `DeckSet`, `PhaseAdvanced`, `RandomnessSet`, `KeeperSet`,
`FactoryAdded`, `OwnershipEpoch`, `RevealRequested`, `RevealRequestFailed`,
`KeyRevealed`, `MetadataUpdate`, `BatchMetadataUpdate`, and the ERC-721
`Transfer`, `Approval` and `ApprovalForAll`.

## The factory

`KeyfleetFactory` creates fleets. Its constructor takes a `Config`: the Safe,
the first keeper, REGENT revenue staking, the Autolaunch factory, the Regents
Club Pass, the collection's identity, the randomness terms, the trait table hash, the REGENT
buyer's route and the four deployers. It refuses a staking, Autolaunch or Pass
address with no code (`BindingMissing`), a USDC that does not report six decimals
(`UsdcDecimalsWrong`) and a deployer that serves another factory
(`DeployerMismatch`). It then deploys the collection, the shared
`KeyfleetShards` bound to the collection, the shared `KeyfleetRegentBuyer` and
the Regents Club's `KeyfleetClubClaims` (`CLUB_CLAIMS`), bound to the collection
and the Pass (`CLUB_PASS`), so their links are fixed at birth. USDC and REGENT are the route's. The factory
holds no money and has no administrator, no upgrade path and no pause.

### Two ways to create a fleet

`createFoundingFleet(preset, deckHash, deckSize, profile)` is for the Safe only
(`OnlySafe`). It creates the next founding fleet: fleet 1 Classic, 2 Syndicate,
3 Accelerant, 4 Cascade, each with its deck, a starting price of 10 USDC, a 5%
step for the Accelerant, and no joining requirements, then 5 Regents Club with
its deck and a starting price of zero. The collection refuses a sixth, one out
of order and one without a deck. Its sales stay closed
until the Safe's phase step opens them. The Safe buys no key.

`createFleet(terms)` is for anyone once phase 4 has been stepped to and its
`opensAt` reached (`CreationClosed(phase)` before). `FleetTerms` names the type, the starting
price, the Accelerant step, the profile, the joining requirements and a
deadline (`Expired` once passed). The starting price must be 10 to 1,000,000
USDC in whole cents (`StartPriceInvalid`). The Accelerant step must be 1 to 5
whole percent on an Accelerant fleet and 0 on any other
(`AccelerantStepInvalid(preset, step)`). The Regents Club type is refused
(`RegentsClubIsFounding`). The creator must have approved the factory for the
starting price; the factory sends that USDC to the new manager, which sells key
1 to the creator through the normal purchase steps. It returns the fleet number
and key 1's token id. The fleet is registered without a deck, so key 1 waits for
its draw until the keeper records the deck. `createFleet` is locked, so the
creator's `onERC721Received` cannot create another fleet from inside it. If any part fails, nothing is created.

Both run the same steps in one transaction: the collection registers the fleet;
the factory deploys its `KeyfleetManager`, `KeyfleetVotes`, `KeyfleetTreasury`
and `KeyfleetRewards`; it writes the profile and requirements into the manager
once; and it emits `FleetCreated(fleetId, preset, typeNumber, creator,
startPrice, accelerantStepPercent, manager, votes, treasury, rewards)`. The creator is the Safe for a
founding fleet.

### How the four contracts are bound

Each fleet contract has no constructor arguments and is deployed with CREATE2,
salt = the fleet number, by its own deployer, so its address depends only on
its deployer, the fleet number and its fixed creation code. `predict(fleetId)`
gives all four addresses before any is deployed. While it deploys them the
factory holds the fleet's wiring (fleet number, type, starting price and the
four addresses) in transient storage at `keccak256("keyfleet.factory.wiring")`,
readable as `wiring()`. Each constructor reads the wiring back through its
deployer, keeps it as immutables together with the factory's shared bindings,
and refuses to deploy anywhere but its own predicted address (`NotWired`). The
wiring is cleared before any other code runs, so it is all zero at every other
moment and a contract deployed outside a creation never finds its own address
in it.

The deployers exist because the factory cannot carry the four creation codes
itself. Each deploys only for the one factory it names (`OnlyFactory`), and is
deployed before the factory, with the factory's address predicted from the
deploying account's nonce; the factory refuses a deployer that names another
address.

### Sizes

Base allows 24,576 bytes of runtime code and 49,152 bytes of deployment code
per contract. Measured with `forge build --sizes`:

| Contract | Runtime (bytes) | Deployment (bytes) |
| --- | --- | --- |
| `KeyfleetClubClaims` | 3,687 | 3,910 |
| `KeyfleetFactory` | 6,387 | 41,277 |
| `KeyfleetKeys` | 12,743 | 14,301 |
| `KeyfleetManager` | 16,383 | 18,376 |
| `KeyfleetManagerDeployer` | 18,866 | 18,997 |
| `KeyfleetRegentBuyer` | 8,098 | 9,832 |
| `KeyfleetRewards` | 9,069 | 10,319 |
| `KeyfleetRewardsDeployer` | 10,809 | 10,940 |
| `KeyfleetShards` | 3,604 | 3,810 |
| `KeyfleetTreasury` | 11,951 | 14,050 |
| `KeyfleetTreasuryDeployer` | 14,540 | 14,671 |
| `KeyfleetVotes` | 19,574 | 21,188 |
| `KeyfleetVotesDeployer` | 21,678 | 21,809 |

## The fleet manager

`KeyfleetManager` is one fleet's sale, money and profile. Its immutables are
`FACTORY`, `FLEET_ID`, `PRESET`, `START_PRICE`, `KEYS`, `USDC`, `REGENT_BUYER`,
`VOTES`, `TREASURY`, `REWARDS`, `CLUB_PASS` and `CLUB_CLAIMS`. It is the only
account that mints its fleet's keys.

### Purchases

`purchase(receiver, maxPrice, deadline, proof)` buys the next primary key. A
zero receiver mints to the caller. The deadline (`Expired`), the price against
`maxPrice` (`PriceAboveMax`, and on a sold-out Classic or Accelerant fleet
`SoldOut`) and the joining requirements, checked against the receiving wallet
with `proof` for an address list (`RequirementNotMet`), are checked before any
USDC moves, because the displayed next key is not reserved. The caller must
have approved the manager for the gross price in USDC, which is then pulled from
the caller. A paused USDC, or
one that blocks the buyer or the manager, stops purchases until it lifts; that
is accepted.

Within a purchase the order is fixed:

1. The key number is checked against `MAX_KEY_NUMBER` (`SoldOut`) and booked
   in `totalMinted`, and `firstMintAt` is written on the first sale.
2. The split is taken from `KeyfleetPresets` and the protocol share added to
   `protocolShareOwed`.
3. The preset's own bookkeeping runs: the Cascade reserve and the level's gross,
   or the Accelerant rebate moved into the ledger and credited to the holder of
   the preceding key, and the next Accelerant price.
4. The key is enrolled in the ledger.
5. `Purchased(tokenId, buyer, receiver, gross, protocol, capital, reserve,
   rebate)` records the split.
6. A Cascade level completes if this was its last key.
7. The treasury's part is booked in `pendingConversion` and the fleet joins the
   REGENT buyer's queue (below). Nothing is swapped.
8. Last the key is minted, which runs the receiver's `onERC721Received` and asks
   for the key's random number when the fleet has a deck.

`purchase` is locked, so a receiver contract cannot buy again from the same
manager inside it, but the receiver may pass the key on: enrolment and a level's repayment are booked before the mint, so a receiver
that passes on a repaid key takes that key's repayment with it as the outgoing
owner.

`nextPrice()` and `quote()` give the next purchase's price and split. On Classic
and Accelerant both revert once the fleet is sold out, and `maxSupply()` and
`remainingSupply()` give the limit and count down to zero. Syndicate and Cascade
never sell out, so on them `maxSupply()` and `remainingSupply()` revert with
`NotFleetTechPreset`. On the Regents Club `purchase`, `nextPrice()` and `quote()`
revert with `NotForSale`, and `maxSupply()` is 1,998. `levelOf` reports the library's answer and reverts with `NotFibonacciPreset` on Classic and Accelerant.

### Regents Club gifts

`give(receivers)` mints the Regents Club's next keys, in order, one to each
address in the list. Only the Regents Safe may call it, and only on the Regents
Club (`OnlySafeGivesClubKeys(caller)`), once phase 1 has opened
(`SalesClosed`). Key N may go only to the wallet that holds Pass N at that
moment or to `KeyfleetClubClaims` (`NotPassHolder(keyNumber, receiver)`), so a
batch built from an older reading of the Pass reverts whole, and nothing past
key 1,998 is given (`SoldOut`). No money moves and nothing is booked: each key is
enrolled in the fleet's votes and rewards like a bought key, `Given(tokenId,
receiver)` is emitted, and the key is minted holding card N. `give` is locked, so
a receiver cannot give again from inside its mint hook.

### The treasury's part becomes REGENT

A purchase never swaps. The manager adds up the USDC bound for the treasury in
that purchase (the capital part, or on a level-completing Cascade purchase the
level's leftover reserve), adds it to `pendingConversion` and asks the shared
REGENT buyer to queue the fleet (`enqueue`), which does nothing if the fleet is
already queued. A purchase that sends nothing to the treasury books nothing.
The booked USDC stays in the manager, counted in `accountedBalance`, so it is
never surplus, never forwarded and never seen by the treasury's split or
payments. The buyer later takes it in pieces through `takePiece(limit)`, which
only the buyer may call (`OnlyRegentBuyer`): it hands over the smaller of what is
booked and `limit`, which the buyer keeps to at most 250 USDC, approved to the
buyer exactly, with the fleet's treasury as the REGENT's recipient. It takes
no lock, so a conversion run from inside another call to the same fleet (a
purchase's mint, or a surplus token's transfer) still converts that fleet's
piece instead of seeing it skipped; every call to the manager makes its outside
call only after its bookings are written (audit KF-A-06 follow-up, 9 Oct). The
protocol share, the Cascade reserve and repayment and the Accelerant rebate stay
USDC.

| Part of a purchase | Kept as |
| --- | --- |
| Protocol share, 10% of every purchase | USDC, owed until sent to REGENT revenue staking |
| Classic and Syndicate: the other 90% | Booked USDC, then REGENT in the fleet's treasury |
| Accelerant key 1: the other 90% | Booked USDC, then REGENT |
| Accelerant later keys: 20% | Booked USDC, then REGENT |
| Accelerant later keys: 70% rebate to the previous key's holder | USDC, credited in the ledger |
| Cascade: the other 90% | USDC, in the level reserve |
| Cascade: reserve left over when a level completes | Booked USDC in the purchase that completes the level, then REGENT |

### Cascade levels

A Cascade level completes in the transaction that mints its last key, once.
Level 1 has no predecessor, so its whole reserve is the treasury's part. From
level 2 the reserve first repays the whole gross the preceding level paid, in
USDC, moved into the ledger and allocated to that level's cohort, which means
whoever holds those keys at that moment; the rest is the treasury's part and the
reserve is emptied. The reserve always covers the repayment: a level has at
least 1.5 times the keys of the one before at 1.2 times the price, and 90% of
every purchase is reserved, so the reserve is at least 1.5 × 1.2 × 0.9 = 1.62
times what is owed. `LevelCompleted(level, reimbursement, surplus)` records it,
and `levelCompleted(level)` and `levelGrossPaid(level)` read it. A level that
never completes keeps its reserve; what happens to it is deferred.

### Joining requirements

`requirements()` returns `{merkleRoot, nft, token, tokenMin}`, each off when
zero; with every part off, anyone may buy. A buyer qualifies by meeting any one
part that is on:

- **Address list.** `merkleRoot` is the root of an OpenZeppelin standard Merkle
  tree of addresses; the leaf is `keccak256(bytes.concat(keccak256(abi.encode(account))))`.
  The purchase carries the receiver's proof.
- **Holds an NFT.** `nft` is a contract whose `balanceOf(account)` must be above
  zero.
- **Holds a token.** `token` is a contract whose `balanceOf(account)` must be at
  least `tokenMin`.

`meetsRequirements(account, proof)` answers for any wallet. Each `balanceOf` is
a read-only call given at most `REQUIREMENT_READ_GAS`, 100,000 gas, of which
only the first 32 bytes of the answer are read; a call that fails or answers
less counts as not met. A contract that burns gas or answers at length cannot
use up the gas a buyer brought for another requirement, and a requirement
contract that misbehaves affects only the fleet whose creator chose it.

Requirements are written once, by the factory, at creation (`initialize`,
`AlreadyInitialized` a second time), and never change. The manager refuses an
NFT or token address with no code, and a `tokenMin` that is zero exactly when
`token` is not, or set when `token` is not (`RequirementsInvalid`), which undoes
the whole creation. It emits
`RequirementsSet(merkleRoot, nft, token, tokenMin)`. They are checked only when
buying from the fleet; resales and transfers are never checked, and the
creator's own key 1 (`sellFirstKey`, factory only, `FirstKeySold` once sold) is
not checked. A balance is read only at the moment of purchase, so one held for
a single transaction, such as a flash loan of the token or a borrowed NFT
returned before the transaction ends, meets the requirement: a requirement shows
that the buyer could command the balance then, not that it holds it. In the same
way, a mature key borrowed and handed back around a daily split run collects
that run's share: the share accrues to the key, and handing it back settles it
to the borrower. Fake,
rebasing or fee-taking tokens are only as meaningful as the creator's choice;
ERC-1155 is not covered.

### Profile

`profile()` returns the fleet's `{name, description, imageLink}`: a name of 1 to
100 bytes (`MAX_NAME_BYTES`), a description of up to 2,000 bytes
(`MAX_DESCRIPTION_BYTES`) and an image link of up to 512 bytes
(`MAX_IMAGE_LINK_BYTES`), stored as given (`ProfileInvalid` otherwise). The
factory writes it at creation. After that only `setProfile(profile)` changes it,
and only the fleet's own treasury may call it (`OnlyTreasury`), so only an
approved proposal of the fleet's keys reaches it. It emits
`ProfileChanged(name, description, imageLink)` and has the collection emit
`BatchMetadataUpdate` for the fleet's keys.

### The transfer hook

`onKeyMoved(tokenId, from)` accepts only the collection (`OnlyKeys`) and only
the fleet's own keys (`ForeignKey`); the collection calls it on transfers only.
It settles the key's rewards to `from` in the ledger and tells the fleet's votes,
which end the key's presence. It takes no lock, makes no token transfer and
calls only the fleet's own ledger and controller. A sale enrols the new key in
both itself: the ledger for its rewards, and the votes for its automatic
presence (`enrollKey`).

### The protocol share

The 10% of every purchase is added to `protocolShareOwed`; a purchase never
sends it, so staking that is paused or refuses a deposit cannot stop a sale.
`sendProtocolShare()` is how it leaves: anyone may call it at any time. It sends
the whole owed amount to the fleet's treasury, and in the same call the treasury
approves REGENT revenue staking for exactly that amount and deposits it with
`depositUSDC`. The deposit carries the source tag
`PROTOCOL_SHARE_TAG = keccak256("keyfleet.protocol_share")`
(`0xd5e47eb51823bc53938260d20f51f3d772c0410bdc18528aee65e4994f00b271`) and the
manager's address as its source reference. Only the manager can ask its
treasury for this (`OnlyManager`). The amount never stays in the treasury.

Staking must report receiving exactly the owed amount and leave no approval
standing, or the treasury reverts with `StakingDepositFailed(amount, received)`.
That revert, a paused staking contract, or any other failure unwinds the whole
call, and the share stays owed in the manager for a later send. The send emits
`ProtocolShareSent(caller, amount)` and reverts with `ZeroAmount` when nothing
is owed. This is the only fee a fleet ever pays.

The staking address is fixed in the factory and every treasury at deployment as
`REGENT_STAKING()`; on Base the manifest must name
`0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`. A plain USDC transfer to it would
not count as revenue there, which is why the share goes through a deposit. The
Regents staking reader indexes deposits without filtering on the tag, so the tag
is Keyfleet's own; the manager in the source reference tells fleets apart.

### Money sent to the manager

The manager holds only three USDC figures: `cascadeReserve`,
`protocolShareOwed` and `pendingConversion`. `accountedBalance(asset)` is their
sum for USDC and zero for every other asset, and `surplus(asset)` is the manager's balance above it:
money sent to the manager outside a purchase and not yet forwarded.
`recognizeSurplus(asset)` sends an asset's whole surplus to the treasury,
unswapped, and emits `ForwardedToTreasury(asset, caller, amount)`. Anyone may
call it at any time; with nothing to forward it returns zero and says nothing.

### Errors and events

Errors: `OnlyFactory`, `OnlyKeys`, `OnlyTreasury`, `OnlyRegentBuyer`, `AlreadyInitialized`,
`Expired`, `PriceAboveMax`, `SoldOut`, `NotFibonacciPreset`,
`NotFleetTechPreset`, `ZeroAmount`, `RequirementNotMet`, `ProfileInvalid`,
`RequirementsInvalid`, `ForeignKey`, `FirstKeySold`, `NotForSale`,
`OnlySafeGivesClubKeys`, `NotPassHolder`.

Events: `Purchased`, `Given`, `LevelCompleted`, `ProtocolShareSent`,
`ForwardedToTreasury`, `ProfileChanged`, `RequirementsSet`.

## Regents Club claims

`KeyfleetClubClaims` holds each Regents Club key the Safe gave it, for a Pass
whose holder could not take one when its batch was built, such as a Pass held
by a contract that refuses NFTs. The factory deploys it, bound for ever to the
collection (`KEYS`) and the Pass (`PASS`). It has no administrator, no upgrade
path and no other way out.

`claim(passId, payee)` gives key `passId` to the caller when the caller holds
Pass `passId` (`NotPassHolder(passId, caller)`), with no deadline. It first
collects the key's rewards from the Regents Club ledger into the claims
contract, then moves the key to the caller with `safeTransferFrom`, then sends
exactly what was collected to `payee` (`ZeroPayee` for the zero address), and
emits `KeyClaimed(passId, tokenId, holder, payee, assets, paid)`. The holder
names the payee, so a Pass held by a contract that refuses ETH still takes its
key and sends the earnings to a wallet that accepts them. The site always names
the claiming wallet. A key already claimed is no longer the contract's, so a second
claim reverts. It accepts only Regents Club keys as they are minted to it
(`OnlyClubMints`), and ETH only from the Regents Club's rewards ledger during a
claim (`OnlyRewards(sender)`). Nobody votes or presents a key while it waits.
There is one claim per Pass; nothing claims the keys of several Passes at once.
On the site, a waiting key's page shows Claim to whoever holds its Pass.

## The REGENT buyer

`KeyfleetRegentBuyer` turns every fleet's booked USDC into REGENT for that
fleet's treasury, at the market price, by one route fixed at deployment: USDC
to WETH on a Uniswap v3 pool, then WETH to REGENT on a Uniswap v4 pool. It is
shared by every fleet, is bound to the collection (`KEYS`), and holds no token,
approval or setting between calls. On Base the route is:

- USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` to WETH
  `0x4200000000000000000000000000000000000006` on the Uniswap v3 0.05% pool
  `0xd0b53D9277642d899DF5C87A3966A349A798F224`;
- WETH to REGENT `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` on the v4 pool
  held by the PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b`, with
  currency0 WETH, currency1 REGENT, fee `0x800000` (the hook sets the fee per
  swap), tick spacing 200 and hook `0xd60D6B218116cFd801E28F78d011a203D2b068Cc`.

The constructor takes the route and the collection. It refuses an address with
no code, a v3 pool that does not hold exactly USDC and WETH, and a v4 key that
does not name exactly WETH and REGENT (`RouteInvalid`). It records
`V4_POOL_ID`, the hash of the key, and `v4PoolKey()` returns the key.

### The queue and the pieces

| Constant | Value |
| --- | --- |
| `PIECE_USDC` | 250 USDC (250,000,000), the most one piece turns into REGENT |
| `MIN_PIECE_USDC` | 1 USDC (1,000,000), the least one piece turns into REGENT, and the least a piece may leave booked |
| `PIECE_INTERVAL` | 15 minutes, the wait after a full piece, across every fleet; a smaller piece waits in proportion |
| `MAX_PRICE_MOVE_BPS` | 100, so a piece may move the route's price by at most 1% |

`enqueue()` puts the calling manager at the back of the queue unless it is
already in it; only a manager the collection registered may call
(`NotManager`), and it emits `Queued(manager)`. Each fleet is in the queue at
most once (`isQueued`). `queueLength()`, `nextInQueue()`, `queueHead()` and
`queueTail()` read it.

`convert(maxUsdc)` may be called by anyone; nothing checks who the caller is.
It refuses any time before `nextPieceAt()` (`PieceTooSoon(opensAt)`) and an
empty queue (`NothingQueued`). It takes the fleet at the front of the queue,
asks that manager for a piece of `maxUsdc` held between `MIN_PIECE_USDC`
(1 USDC) and `PIECE_USDC` (`takePiece`), which the manager cuts to what it has
left, takes it into the buyer, swaps it and returns the
REGENT the treasury received. A piece that would leave the fleet less than
1 USDC booked takes the rest too, so a piece can be up to 250.999999 USDC and
the booking is always nothing or at least 1 USDC. Every sale and every
completed Cascade level books at least 1 USDC, so a piece too small to buy any
WETH (one that would round to nothing in the pool) never reaches the front of
the queue and stops it. A fleet that still has USDC booked afterwards goes
to the back of the queue. The keeper asks for `250000000`; anyone may ask for
less, for example when a full piece would fail the 1% rule.

A fleet whose piece cannot be handed over, because its manager refuses or USDC
will not move its USDC (an issuer freeze, for instance), is skipped: `convert`
emits `PieceSkipped(manager)` and returns 0, the fleet keeps its whole booking
and goes to the back of the queue, and `nextPieceAt` does not move, so the next
call serves the next fleet straight away and one fleet can never hold up the
rest (audit KF-A-06, 9 Oct). The hand-over runs as a separate call of the buyer
to itself (`collectPiece`, which refuses any other caller), with a fixed
`COLLECT_GAS` of 300,000; `convert` refuses with `NotEnoughGas` when too little
gas is left to give it all of that, so no caller can make a working fleet be
skipped by sending too little gas. Everything after the hand-over concerns the
shared route, and a failure there reverts the whole call as before.

Each piece sets `nextPieceAt` to its own time plus 15 minutes times its USDC
over 250 USDC, rounded up to the second:
`nextPieceAt = now + ceil(PIECE_INTERVAL × usdcIn / PIECE_USDC)`. A full piece
waits 15 minutes, a 50 USDC piece 3 minutes and a 1 USDC piece 4 seconds, so
USDC never turns into REGENT faster than 250 USDC every 15 minutes, however the
pieces are cut. Any piece waits at least a second, so two pieces can never run
in one block. `nextPieceAt` is zero until the first piece.

How the next fleet is chosen: the queue is first in, first out, one piece per
turn. A fleet joins at the back when it first books USDC and, after its piece,
goes back to the back if any is left, so every waiting fleet gets one piece
before any fleet gets a second, and a fleet with a large booking cannot hold up
a small one for longer than one piece per fleet ahead of it. `convert` only
reads and writes the front entry and appends at most one entry, so its gas is
the same however long the queue is. A piece that fails the 1% rule keeps its
fleet at the front, and a smaller piece, which moves the price less, can then
be taken, so a thin pool converts slowly instead of stopping the line.
Consequences, accepted: anyone who creates many fleets puts each of them in the
queue, and each takes a turn; and anyone may take a 1 USDC piece just before
the keeper's full one, which sends the front fleet to the back and makes the
full piece wait 4 seconds. Done first in every block, that still converts real
USDC at about nine tenths of the full rate, because no piece is smaller than
1 USDC and each holds the next back 4 seconds; it does the keeper's work for it,
and each try costs its caller a transaction. A pool so thin that 1 USDC moves
its price by 1% stops converting until it deepens.

Each piece swaps exactly its USDC on the v3 pool, paid from the buyer into the
pool in `uniswapV3SwapCallback`, which pays once and refuses a second callback; swaps the WETH that came out
inside one PoolManager `unlock`, in `unlockCallback`; and has the PoolManager
pay the REGENT straight to the treasury. Each leg must spend exactly what it
was given (`SwapIncomplete`) and the REGENT leg must pay something
(`NothingBought`), or the whole call reverts and nothing moves: the fleet keeps
its booking and its place, and no piece is counted. The two callbacks answer
only the fixed pool and the fixed PoolManager, and only while the buyer's own
swap is under way (`UnexpectedCallback`). A piece emits
`RegentBought(manager, treasury, usdcIn, wethMid, regentOut)`.

The 1% rule reads each pool's own square-root price before and after the swap.
Each pool's move is the larger price over the smaller, and the route's move is
the two multiplied together, so a rise counts as much as a fall:
`move = (r_v3 × r_v4)^2 - 1`, in 18-decimal fixed point, and a move above 1%
reverts with `PriceMoved(move)`.

The swap takes the pools' price at that moment, with no minimum and no oracle:
the founder chose a plain swap. The 1% rule measures only the piece's own move,
from just before its swap to just after it, inside `convert`. It does not see a
price that someone moved earlier in the same block: anyone can push the REGENT
price up, let a piece buy at that price, and sell back afterwards. What makes
that unprofitable is the REGENT pool's hook
(`0xd60D6B218116cFd801E28F78d011a203D2b068Cc`), which charges a fee of at least
1% on every swap, so the push and the sale back each pay it, and that costs
more than a piece of at most 250 USDC can give up. Sentinel's estimate is that
the push and sale back would pay only if the hook's fee fell below about 0.4%.
The protection depends on that hook: it is third-party code, the 1% rule does
not cap what it takes, and if it ever charged less, pieces could be front-run.
If the pool stops filling, pieces revert and the USDC stays booked, but
purchases go on in every fleet; the route can never change.

### Depth on Base

Measured on a fork of Base at block 52,322,445 (8 October 2026), with WETH at
about 2,565 USDC on the v3 pool:

| Pool | Moves the price 1% | About |
| --- | --- | --- |
| v4 WETH/REGENT, WETH in (price down) | 0.1219 WETH | 313 USDC |
| v4 WETH/REGENT, REGENT in (price up) | 29.52 million REGENT | 304 USDC |
| v3 USDC/WETH, USDC in (price up) | 344,043 USDC | 344,043 USDC |
| v3 USDC/WETH, WETH in (price down) | 126.1 WETH | 322,000 USDC |

The REGENT pool had 374,331,681,346,167,154,513,793 of liquidity at tick
193,184 and no initialised tick within 1% either side, so its depth is the same
across that range. Its hook raised its fee from 1% with the size of the
expected move. Through the whole route a piece moved the measured price by:

| Piece | Price move |
| --- | --- |
| 10 USDC | 0.03% |
| 50 USDC | 0.16% |
| 100 USDC | 0.32% |
| 150 USDC | 0.48% |
| 200 USDC | 0.64% |
| 250 USDC | 0.81% |

so a full 250 USDC piece passes the 1% rule with about 60 USDC to spare. The
v4 pool is the shallow leg; the v3 pool is about a thousand times deeper.

## Rewards ledger

`KeyfleetRewards` is the per-fleet reward ledger, permanently bound to its
fleet's manager, treasury, the collection and the shared shard record. Two
things fill it, and nothing else can.

The manager writes its USDC obligations (`OnlyManager` for anyone else): the
Accelerant rebate, credited to the holder of the preceding key, and the Cascade
repayment, allocated to the preceding level's cohort. These go through a
cumulative index per cohort, so an allocation writes one number and never loops
over holders. Classic and Accelerant keys are all in cohort 0; a Fibonacci key
is in the cohort of its level, and the ledger takes any cohort id because those
presets have no last level. A newly enrolled key starts at the cohort's current
index and earns nothing from earlier allocations.

The treasury funds the daily split: the same whole amount for every mature key,
in native ETH or a token. A key is mature once `KEY_MATURITY`, 2 days, has passed
since its mint, and since keys are minted in order the mature keys are always
keys 1 to `MANAGER.matureKeys()`. Each asset has one split index, counted in
whole units per key. Every funding that covers more keys than the one before
records where that asset's index stood just before it, and a key starts from the
first such point that covered it (`splitJoinIndex(asset, tokenId)`), or from the
current index while none has. So a key shares only in fundings made after it
matured, and an asset split for the first time later starts from zero, which
every mature key then shares. The ledger accepts this funding only from the
treasury (`OnlyTreasury`), only while the treasury says it is inside its own
split routine (`splitInProgress()`, `NotSplitting` otherwise), and only for
exactly as many keys as are mature (`KeyCountChanged(keys, mature)`). An approved
proposal's call from the treasury to `fundSplit` or `fundSplitNative` is
therefore refused. A key sold in the middle of a split is not mature, so it
neither changes the count nor shares in that split. The ledger has no other way
to take ETH.

`rewardAssets()` lists every asset the ledger pays: USDC first, then each asset
the split has funded, in the order first funded. ETH is the zero address.

Accrued rewards belong to the address that held the key while they accrued. The
manager settles a key to its outgoing owner, in every asset, immediately before
every ownership change, and the incoming owner continues from the current
indexes.

Backing is reserved when money comes in, never when it goes out. Each of the
four ways in requires the money to be sitting in the ledger already: its balance
must cover `backed[asset]` plus the new amount (`InsufficientBacking`). `backed`
only falls when a claim pays out. Cohort indexes are scaled by
`PRECISION = 1e27`; settlement carries the sub-unit remainder forward, so a
key's shortfall stays below one atomic unit and the sliver stays in the ledger
for good, counted as backed and never claimable.

`claim(tokenIds, assets)` can be pressed by a key's holder or by a wallet holding
an active shard of it (`NotKeyHolderOrAgent` otherwise), for many keys of this
fleet (`ForeignKey` for another fleet's) and many assets at once. It settles
each key to the wallet holding it and pays, for each asset, that wallet's whole
credit. The money for a key always goes to the wallet holding it, never to an
agent that pressed claim. The caller is also paid its own credit, which is how a
former holder with no keys left collects what it earned. Each payment is one
asset to one wallet, ETH by `Address.sendValue`, under a reentrancy lock, so a
wallet that refuses ETH stops only a claim that includes ETH for it; the same
claim without ETH goes through and the ETH stays waiting. It returns the total
paid in each asset (`NothingToClaim` when nothing is paid).
`accrued(asset, tokenId)` reports one key's unsettled whole units in both lanes,
and `credits(asset, account)` what is settled and waiting.

Events: `KeyEnrolled`, `Allocated`, `Credited`, `SplitFunded`, `Settled`,
`Claimed`. Other errors: `ZeroAddress`, `UnknownAsset`, `KeyAlreadyEnrolled`,
`KeyNotEnrolled`, `NoEligibleKeys`, `ZeroAmount`, `WrongValue`.

## Treasury

`KeyfleetTreasury` is bound to its fleet for good. It is the fleet's one payment
address, in USDC, REGENT or any other token, and it holds native ETH: anyone may
send it ETH. The treasury's part of every purchase arrives as REGENT. The
treasury itself never swaps.

It spends only through `executeBatch(calls)`, which only the fleet's voting
controller may call (`OnlyVotes`), when a passed proposal is carried out: it
makes the proposal's exact calls in order, each a plain call with its value, and
the first that reverts reverts the whole batch with its reason. Proposing sets
nothing aside: every payment is a share of the balance at the moment it is
carried out, so two approved proposals can never spend the same money, and the
second takes its share of what the first left.

Two of the treasury's own functions accept only the treasury itself as caller
(`OnlySelf`), so only a passed proposal's call reaches them:

- `pay(asset, to, sharePpm)` pays `sharePpm` parts per million
  (`SHARE_DENOMINATOR`, 1,000,000) of the treasury's balance of `asset` at that
  moment, rounded down, and reverts `ShareRoundsToZero(asset, sharePpm, balance)`
  when that is nothing. It pays a token with OpenZeppelin `SafeERC20`, so a token
  that answers `false` instead of paying fails the whole batch, or pays ETH when
  the asset is `NATIVE` (the zero address) with `Address.sendValue`. It emits
  `Paid(asset, to, sharePpm, amount)`.
- `advance(advanceId, operator, asset, sharePpm, purposeHash)` pays a share the
  same way and records the amount under a new id (`AdvanceIdTaken` for one
  already used), as `advances(advanceId)`: the operator, the asset, what is still
  outstanding and the hash of what it is for. It emits
  `Advanced(advanceId, operator, asset, sharePpm, amount, purposeHash)`.

Anyone may return an advance with `returnAdvance(advanceId, amount)`: an ETH
advance by sending exactly `amount` with the call, a token advance by approving
the treasury, which pulls it (`WrongValue` for ETH sent with the wrong amount or
with a token). A return is capped at what is outstanding
(`ReturnAboveOutstanding`), so the same money cannot be returned twice and a
return cannot be labelled against more than was advanced. It emits
`AdvanceReturned(advanceId, from, amount, outstanding)`. The cap is the only
check: someone holding customer income could still return it against an open
advance, which disclosure covers.

Carrying out calls, the protocol share deposit, returning an advance, binding
the launch token and the public split share one reentrancy lock, so a payee
called back by a payment cannot return an advance, send the protocol share or
carry out another proposal from inside it. It follows that a proposal whose
calls include the manager's `sendProtocolShare` or the treasury's own
`returnAdvance` or `bindLaunchToken` always reverts when carried out, since the
batch already holds the lock: these are public buttons, pressed directly instead. The Cascade
reserve, the owed
protocol share and the ledger's backing are never in the treasury and are out of
any vote's reach. Tokens that take a fee when they move, or rebase, are not
supported.

### The daily split

Once a day the treasury shares a fixed part of its balance of each bound asset
equally across every mature key of the fleet, one minted at least `KEY_MATURITY`
(2 days) before the run. The bound assets are ETH,
REGENT and USDC; REGENT is fixed at deployment as `REGENT()`, on Base
`0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`. OUSD has a slot that starts empty:
a passed proposal may fill it once with `admitOusd(token)`, which refuses the
zero address, USDC, REGENT and the launch token (`OusdInvalid`) and a second
admission (`OusdAlreadyAdmitted`), and emits `OusdAdmitted(token, threshold)`.
The fleet's own launched token has a slot that starts empty too (see below).
`splitAssets()` lists the bound assets in the order they are split: ETH (the
zero address), REGENT, USDC, then OUSD once admitted, then the launch token once
bound. Any other token the treasury holds is never split.

For each bound asset, with `B` the treasury's balance of it, `N` the number of
mature keys (`MANAGER.matureKeys()`) and the rate in basis points:

- the cut is `B × rate / 10,000`, rounded down;
- each key's share is the cut divided by `N`, rounded down, in whole units;
- the treasury sends the ledger exactly the share times `N`, and the rounding
  dust stays in the treasury;
- for a token, the ledger is then funded by what it holds above what it already
  owes, divided by `N`, if that is less than the share. A token that arrives a
  unit short, as OUSD's rounding can make it, gives each key a unit less, and a
  ledger left short by an earlier payout is made whole from the next transfer
  before the keys get the rest. If nothing is left over, the asset is skipped
  for that run and the tokens stay in the ledger towards what it owes. So a
  short arrival never makes a run revert.

An asset is skipped, with `SplitSkipped(asset, balance)`, when no key is mature
yet, when `B` is below its threshold, or when the share comes to zero because
there are more keys than units in the cut. The thresholds are 0.05 ETH
(`ETH_THRESHOLD`) and 100 whole units of each token, read from the token's
decimals once (REGENT and USDC at deployment, OUSD when admitted, the launch
token when bound); a balance equal to the threshold qualifies. `B` is only the
treasury's own balance, so what the ledger already holds for the keys is never
counted again. Each asset split emits `SplitAllocated(asset, balance, perKey,
keys)`, with `perKey` the amount each key was given.

The rate starts at 50 basis points (half a percent) and is always between 10 and
200. Only a passed proposal can change it, with `setDailySplitBps(bps)`
(`SplitRateOutOfRange` otherwise); the new rate applies from the next run, with
nothing pending in between. It emits `DailySplitRateSet(bps)`.

Anyone may call `runDailySplit()` once a day (`SPLIT_INTERVAL`) has passed since
the last run; the first run opens a day after the fleet's first key was sold
(`firstMintAt` on the manager). `nextRunAt()` gives that time, or zero before
any key is sold, and an early call reverts with `SplitNotDue(opensAt)`. Days
nobody runs it are not made up later. A passed proposal may also run it at any
time with `runVotedSplit()`, ignoring the clock. Every run, public or voted,
records `lastRunAt` and emits `DailySplitRun(voted, keys, bps)`.

The public run takes the treasury's one reentrancy lock, and the voted run is
only ever made from inside a carried-out proposal, which already holds it. While
a run is under way the treasury raises a flag that lasts only for that
transaction (`splitInProgress()`); the ledger accepts split funding only from the
treasury and only while that flag is up.

ETH is sent with the funding call itself. A token is sent first and the ledger is
funded after; a token that refuses the transfer is skipped with
`SplitTransferFailed(asset, amount)` and the other assets are still split. A
transfer that fails because it ran out of gas reverts the whole run with
`SplitOutOfGas` instead, so nobody can starve one asset of its day by sending
too little gas.

### The fleet's own token

A fleet launches its own token through Autolaunch Revstake v2, whose factory is
fixed at deployment as `AUTOLAUNCH()`; on Base the manifest must name
`0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E`. The launch is a passed proposal's
call from the treasury to the factory's `launch(params)`, with the treasury
itself as `params.treasury`. The factory takes no ETH and no token for it, and
records the treasury as the launcher. The token's name, symbol, description,
website and image are the proposal's own (64, 16, 512, 256 and 256 bytes at
most). Autolaunch's own fees, vesting and liquidity rules are the factory's and
nothing here changes them. Autolaunch opens its factory to launches only when
the Regents Safe unpauses it.

Once the launch has sold, anyone may call `bindLaunchToken(launchId)`, once. It
refuses a launch the treasury did not make or that names another treasury
(`NotOwnLaunch`), so a launch a stranger made naming this treasury is never
bound; a launch whose auction has not sold, still running or failed, as
Autolaunch's strategy records it (`LaunchNotGraduated`); the token already
admitted as OUSD (`LaunchTokenIsOusd`); and any second binding
(`LaunchTokenAlreadyBound`), so the first sold launch bound is the fleet's token
for good. It records `launchToken()`, `launchId()` and a threshold of 100 tokens
by the token's decimals (`launchTokenThreshold()`), emits
`LaunchTokenBound(launchId, token, threshold)` and runs under the treasury's
reentrancy lock, so a proposal's call cannot bind it in the middle of other
calls. The token is split from the next run, last.

Only what the treasury itself holds is split. Of a launch's tokens, 70% vest to
the treasury over a year from the sale in Autolaunch's escrow, which anyone may
ask to release what has vested so far (`release()`); the pool's liquidity stays
locked in Autolaunch's locker; and tokens holders stake stay in the launch's
splitter. None of these is the treasury's balance until it reaches the
treasury.

A sold launch also pays the treasury: at least half of the auction's REGENT
raise at the sale, and, of every payment made through the launch's payment
receiver, what is left after Autolaunch's 2% (to REGENT revenue staking for
USDC, to the Regents Safe for REGENT or the token) and the share of the launch's
stakers. Those arrive as ordinary treasury REGENT and USDC, split like any other.

### Signing for the fleet and its Lit account

The treasury answers ERC-1271's `isValidSignature(hash, signature)` with the
magic value `0x1626ba7e` exactly when `approvedHash(hash)` is true, and with
`0xffffffff` otherwise. The signature bytes are ignored: the treasury has no key,
and nothing is signed for it unless a proposal said so.
`approveLitCreateWallet(issuedAt)` and `revokeLitCreateWallet(issuedAt)` accept
only the treasury itself as caller (`OnlySelf`), so only a passed proposal's call
sets or clears one. Each builds Lit's `CreateWallet(address address,uint256
issuedAt)` request itself, with the treasury, the account's owner, as `address`
and the time the proposal names as `issuedAt` (`LIT_CREATE_WALLET_TYPEHASH`),
and sets or clears its digest under Lit's own domain, `LIT_DOMAIN_SEPARATOR`
(name `Lit ChainSecured`, version `1`, this chain's id, no verifying contract);
`litCreateWalletDigest(issuedAt)` returns that digest. They emit
`LitCreateWalletApproved(digest)` and `LitCreateWalletRevoked(digest)`. So an
approval is only ever the treasury's own `CreateWallet` request: no proposal can
make the treasury sign a token transfer, a permit, a message for any other
verifier, another owner's request or any other kind of Lit request (audit
KF-A-02, 9 Oct). `CreateWallet` is the one request Lit documents asking an owner
to sign; every other step is an on-chain call a proposal makes.

This is how the fleet owns its Lit account. Lit's account contract on Base,
`0xaaaaa9120fe271f653cfdb6bf400db93d2dea7aa` (named by Lit's node
configuration, `GET https://api.chipotle.litprotocol.com/core/v1/get_node_chain_config`),
lets a wallet, a contract included, own an account outright: the account is the
hash of the owner's address, and only that address may write to it. The
treasury is that owner. Every write is a call in a passed proposal, sent from
the treasury: creating the account, adding the inbox action, making one group
with it (Lit numbers it 1), minting one usage key for the operator that may run
that action and nothing else, then replacing or removing that key, and at the
end, if the keys vote for it, handing the account to another owner, after which
Lit refuses the treasury. The fleet's contracts hold no Lit address; it appears
only in proposals' calls.

When Lit wants the owner's signature on a request, such as `CreateWallet` for a
key, a proposal approves that request's EIP-712 digest (domain name
`Lit ChainSecured`, version `1`, Base's chain id, no verifying contract) and Lit
asks the treasury. Lit takes a signed request only within 300 seconds either side
of the time it names, and each digest only once, so the proposal names the time
it will be carried out and the operator sends the request straight after. Lit
does not support wallets that are not yet deployed, so the treasury must be on
chain first. Voting, claims and the daily split never call Lit: a Lit outage
stops nothing on chain.

Other errors: `OnlyManager`, `StakingDepositFailed`.

## Votes

`KeyfleetVotes` is the one collective decision of a fleet. There are no
councils, no moderators, no rule amendments, no quorum classes and no proposal
kinds. Every call that takes a key refuses a key of another fleet
(`ForeignKey`) before any other use of it.

### Proposals

`propose(authorKey, contentHash, calls)` opens a proposal. The caller must be
allowed to vote `authorKey` (below); the key is their standing and nothing else,
and proposing casts no ballot. `contentHash` is the hash of the proposal's text,
kept off chain. Ballots stop at `closesAt`, exactly `VOTING_PERIOD` (24 hours)
after opening. `calls` is the exact ordered batch of `(target, value, data)` calls
the treasury makes if the proposal is carried out; an empty batch records
agreement and moves nothing. An identical proposal made again is a new proposal
with its own id, hash and electorate.

A proposal that moves no money (an empty batch, or only the manager's
`setProfile`, the treasury's `setDailySplitBps` and this controller's
`setEditsRestricted`) may be carried out from `closesAt`. Any other proposal moves
money and waits `MONEY_DELAY` (1 day) after closing. Either way it may then be
carried out for `EXECUTION_WINDOW` (48 hours), until `executionExpiry`.
`executableAt(proposalId)` gives the first moment it may be carried out.

Money leaves only as a share of the treasury, and every proposal is checked when
it is made:

- No call may carry ETH (`CallCarriesValue(index)`).
- A call to the treasury's `pay` or `advance` names a share from `MIN_SHARE_PPM`
  (1, 0.0001%) to `MAX_SHARE_PPM` (990,000, 99%) (`ShareOutOfRange(sharePpm)`).
  A proposal holds at most one money move: one `pay`, one `advance` or one
  `runVotedSplit` (`OneMoneyMovePerProposal`), so a voted split cannot be run
  again and again in one batch.
- No call to any address may use a function that moves or approves tokens
  (`TokenMoveRefused(index, selector)`): ERC-20 `transfer` (`0xa9059cbb`),
  `transferFrom` (`0x23b872dd`), `approve` (`0x095ea7b3`), `increaseAllowance`
  (`0x39509351`) and EIP-2612 `permit` (`0xd505accf`); ERC-721 and ERC-1155
  `setApprovalForAll` (`0xa22cb465`), `safeTransferFrom` (`0x42842e0e`,
  `0xb88d4fde`, `0xf242432a`) and `safeBatchTransferFrom` (`0x2eb2c2d6`); ERC-1363
  `transferAndCall` (`0x1296ee62`, `0x4000aea0`), `transferFromAndCall`
  (`0xd8fbe994`, `0xc1d34b89`) and `approveAndCall` (`0x3177029f`, `0xcae9ca51`);
  ERC-777 `send` (`0x9bd9bbc6`), `operatorSend` (`0x62ad1b83`) and
  `authorizeOperator` (`0x959b8c3f`); and Permit2's
  `approve(address,address,uint160,uint48)` (`0x87517c45`).

For `TREASURY_OPENING`, 7 days from the fleet's `salesOpenAt` (see Phases and
sales), a proposal may carry only calls that move no money, each with no value:
the manager's `setProfile`, the treasury's `setDailySplitBps` and this
controller's `setEditsRestricted`. Any other call, a call with value, or a batch
mixing them is refused with `TreasuryOpening(opensAt)`. An empty batch is always
allowed, and the daily split runs as usual. `treasuryOpensAt()` gives the moment
the opening ends, or zero while the fleet's sales have not opened.

Opening sweeps expired presences, renews the author key and records the exact
count of present keys as `e0` (see Presence). The proposal stores
`actionsHash = keccak256(abi.encode(calls))` and a `proposalHash`:

```
keccak256(abi.encode(chainId, votes, treasury, proposalId, authorKey,
  ownershipEpoch(authorKey), contentHash, actionsHash, closesAt, executionExpiry))
```

`ProposalCreated(proposalId, authorKey, proposer, proposalHash, contentHash,
closesAt, executableAt, executionExpiry, e0, openRevision, calls)` carries the
calls in full.
`proposal(proposalId)` returns the whole record (`UnknownProposal` for none).

A proposal changes the fleet's name, description or image link by a call from
the treasury to the manager's `setProfile`.

### Ballots and the electorate

Each key holds one ballot per proposal: `Yes`, `No` or `Abstain` (numbered 1 to
3; 0 is no ballot, `InvalidChoice`). `castBallot(proposalId, tokenIds, choice)`
casts or replaces the ballots of a list of keys, all with one choice, and renews
each key. The key's owner, or an agent holding an active shard of the key while
the key's agent voting is on (see Shards), may cast it, and whoever acted last
decides it. A batch is cast whole or not at all, and anybody refused for a key
gets `NotAuthorizedForKey(tokenId, account)`. A marketplace approval
(`approve`, `setApprovalForAll`) gives nothing here. Any choice is taken until
closing. During a money proposal's day of waiting only `No` is taken
(`OnlyNoWhileWaiting(proposalId)` for Yes or Abstain), from any key that may vote,
present at the opening or not; a key that was not joins the electorate with its
No as it would before closing. Ballots stop for good once the wait is over, and
on cancelling (`BallotsClosed`). `ballotOf(proposalId, tokenId)` reads a ballot
and `BallotCast(proposalId, voter, choice, tokenIds)` records each call.

The electorate grows and never shrinks. A key that was not present when the
proposal opened joins by casting its first ballot, whatever its choice, and adds
one to `late`; the denominator is `D = e0 + late`. Replacing a ballot moves the
key's one contribution and adds nothing; repeating it changes nothing. A key that
expires, changes hands or abstains stays counted, and a key that changes hands
keeps its one ballot, which its new holder may replace. Renewing a key changes no
open proposal.

### Outcome, cancelling and carrying out

`status(proposalId)` is worked out from the stored facts and the time; nothing
finalises it. In order: `Cancelled` once cancelled; `Executed` once carried out;
`Open` until `closesAt`; then `Rejected` unless `yes >= approvalsNeeded(D)`; then
`Waiting` until `executableAt` (only a money proposal waits), `Approved` until
`executionExpiry` and `ExecutionExpired` from then on (numbered 0 to 6 in the
order Open, Waiting, Approved, Rejected, Cancelled, Executed, ExecutionExpired). `approvalsNeeded(voters)` is `APPROVAL_PERCENT` (60) percent
of the voters rounded up, `(voters * 60 + 99) / 100`, one rule for every vote:

| Voters | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Yes needed | 1 | 2 | 2 | 3 | 3 | 4 | 5 | 5 | 6 | 6 |

A proposal is never approved before closing, and abstaining or staying silent
counts against it. There is no minimum: one present key voting Yes on a
proposal nobody else joins passes it at closing.

During the wait, No ballots still count against the same 60%. If one leaves Yes
below `approvalsNeeded(D)`, with `D` grown by any late voter, the proposal is
cancelled at once and `ProposalCancelled(proposalId, by)` names the voter; a No
that leaves it passing is counted and changes nothing else. So when one key
alone passes a payment in a quiet fleet, any other key that votes No during the
day stops it: 1 Yes of 2 no longer passes.

`cancel(proposalId)` may be called by whoever may vote the author key now, its
current owner or an agent, while the proposal is open, waiting or approved
(`NotCancellable` otherwise). It renews the author key and emits
`ProposalCancelled(proposalId, by)`. The same event marks a cancelling No during
the wait.

`execute(proposalId, calls)` is permissionless and renews no key. The proposal
must be approved (`NotApproved(status)`) and the calls must be exactly its batch
(`ActionsMismatch`): a changed target, value, data or order, or a call added or
left out, is refused. The proposal is marked carried out and the treasury makes
the calls; if any reverts, everything reverts, and the proposal stays approved to
be retried until it expires. It is locked against reentry, so a call cannot carry
out another proposal. `ProposalExecuted(proposalId, executor)` records it.

The one thing the controller records for the fleet is whether a key's edits are
restricted. `setEditsRestricted(tokenId, restricted)` may be called only by the
treasury (`OnlyTreasury`), so only by a carried-out proposal's call, and only for
a key of this fleet already sold (`KeyNotMinted`). It sets
`editsRestricted(tokenId)` and emits `EditsRestrictionSet(tokenId, restricted)`;
the latest one carried out stands. What a restriction stops is decided off chain
from this record.

The controller holds nothing. Claim and reserve solvency, the Cascade reserve and
the owed protocol share hold regardless of any vote.

Casting ballots is the one call whose cost grows with what it is asked, and only
with the number of keys named. A holder with more keys than a block can carry
splits them across calls. Cancelling costs the same on any size of fleet,
carrying out costs the same apart from the calls it makes, and opening costs the
same apart from the expired presences it sweeps.

### Signed renewals and ballots

Whoever may renew keys or cast their ballots may instead sign the request and
hand it to anyone to submit: `presentBySig(tokenIds, signer, deadline, signature)`
and `castBallotBySig(proposalId, tokenIds, choice, signer, deadline, signature)`.
The signer must be allowed to act for every key when it is submitted, exactly as
if they had sent it, and a ballot is recorded under the signer. The submitter
needs no standing and can change nothing that was signed.

The messages are EIP-712 typed data in the domain `KeyfleetVotes`, version `1`,
on Base (8453), at the fleet's own controller's address:

- `Present(address manager,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,address signer,uint256 nonce,uint256 deadline)`,
  where `manager` is the fleet's manager;
- `Ballot(uint256 proposalId,bytes32 proposalHash,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,uint8 choice,address signer,uint256 nonce,uint256 deadline)`,
  where `choice` is 1 for Yes, 2 for No and 3 for Abstain, and `proposalHash` is
  the proposal's, so a signed ballot counts on that proposal alone.

Because the domain is the fleet's own controller, the renewal names the fleet's
manager and the key ids are the collection's token ids, a message signed for one
fleet cannot be used in another. The keys are listed in strictly ascending order
(`KeysNotAscending`; `NoKeys` for none), and for each key the message carries
its `ownershipEpoch` on the collection and its `delegationRevision` on the shard
record, which the controller reads back when the message is submitted. So a
signature stops working the moment one of its keys changes hands, or has a shard
issued, renewed or ended, or its agent voting switched. Each signer has one
nonce (`nonces(signer)`), used by every message they sign, so a message works
once. A ballot the signer casts directly with `castBallot` uses the nonce too, so
a message they signed earlier can never be submitted over a later direct vote. A message past its deadline is refused (`SignatureExpired`), as is a
signature that is not the signer's (`InvalidSignature`). Signatures are checked
with OpenZeppelin `SignatureChecker`, which accepts ordinary wallets and
contract wallets such as a Safe (ERC-1271). `PRESENT_TYPEHASH`,
`BALLOT_TYPEHASH` and `eip712Domain()` give the exact values.

### Presence

A new key waits `KEY_MATURITY`, 2 days from its mint (`KeyfleetKeys.mintedAt`),
before it takes part: until then it cannot be renewed, vote, propose or cancel
(`KeyTooNew(tokenId, maturesAt)`), and `maturesAt(tokenId)` gives the moment. A
transfer does not start the wait again. When the wait ends, the key is present
on its own for 48 hours, exactly as if it had been renewed then: the sale enrols
it (`enrollKey`, `OnlyManager` for anyone else) with that start already
recorded, and `PresenceScheduled(tokenId, startsAt)` records it.

After that a key is present for 48 hours (172,800 seconds, by block time, never
by block count) after its owner or a wallet holding an active shard of it renews
it with `present(tokenIds)` or the signed `presentBySig`, casts a ballot for it,
proposes with it, or cancels a proposal made with it. A shard may renew its key
whether or not the key's agent voting is on. A present key stops being present
the moment it changes hands (the manager calls `onKeyMoved`, `OnlyManager` for
anyone else), and its new owner renews it under the new ownership. A key that
changes hands before its automatic start keeps that start. Nobody else can renew
a key, a batch with one such key renews none, and renewing changes no open
proposal. `isActive(tokenId)` answers for now, and `presentFrom(tokenId)` gives
the start of the key's latest presence (its automatic start, still to come while
it waits, or its latest renewal), zero once it changed hands after that start.
`Present(tokenId, at, blockNumber, epoch)` records each renewal and
`PresenceCleared(tokenId)` each change of hands that ended a presence.

Keys sit in at most one of three lists, each ordered by when its entries fall
due and indexed by the key's 64-bit token id: `Waiting` (sold keys whose
automatic start is still to come, due at that start), `Automatic` (present from
their automatic start, due when it ends) and `Renewed` (present from a renewal,
due when it ends). A renewal moves the key to the back of `Renewed`. Time alone
moves nothing, so the lists may still hold due entries; `sweepExpired(limit)`,
which anyone may call, moves up to `limit` of them from the fronts (a started
key from `Waiting` to `Automatic`, or out if that presence has ended too, and
ended presences out of the other two), returns how many it moved and whether
more are due, and emits `Swept(moved, due)`. Once nothing is due, the count of
present keys is the size of `Automatic` plus `Renewed`.
`presenceList(place)` and `presenceEntry(tokenId)` show the lists.

Opening a proposal first sweeps up to 256 due entries
(`SWEEP_IN_PROPOSE`). If any are still due it reverts with
`MaintenanceRequired` and changes nothing, so a proposal never records a count
that includes expired keys or misses started ones; anyone may sweep the rest and try again. It then
renews the author key and records the opening revision, time and exact count of
present keys (`e0`, never zero) in the proposal and in `ProposalCreated`. Each
enrolment, renewal, change of hands and opening is numbered in order, and each
key keeps a checkpoint of its enrolment, renewals and changes of hands, so
`wasActiveAtOpening(proposalId, tokenId)` answers exactly even for several of
them in one block: renewed, moved, then opened is not present at the opening;
renewed, opened, then moved is. The count starts the proposal's electorate.
Sweeping costs about 26,000 gas for each key whose automatic start has come and
about 5,000 for each ended presence. For 2,000 Accelerant keys sold together
that is about 52 million gas when they start and 10 million when their
presences end, done in several calls; a proposal opening sweeps at most 256
entries itself.

## Shards

`KeyfleetShards` records the shards of every key in the collection: time-limited
grants a key's owner gives to agent wallets. There is one, shared by every fleet
and bound to the collection for good, reachable as `SHARDS()` on the factory.
Shards are kept per token id and wallet; a key's token id names its fleet, so a
shard of one fleet's key never reaches another fleet. One agent wallet may hold
shards of many keys, from one owner or several, in one fleet or several, and a
key may have shards in many wallets. Every call takes a list of keys (`NoKeys`
for none).

- `issue(tokenIds, wallet, days)` is for the current owner of every key named
  (`NotKeyOwner` otherwise; an unsold key reverts with the ERC-721
  `ERC721NonexistentToken`). A shard lasts 1 to 365 days (`DaysOutOfRange`), may
  not go to the zero address (`ZeroAddress`) or the owner (`WalletIsOwner`), and
  records each key's current `ownershipEpoch`. Issuing again renews a shard,
  counting its days from now. It emits `ShardIssued(tokenId, wallet, expiresAt,
  epoch)` per key.
- `end(tokenIds, wallet)` ends a wallet's active shards early. Each key's current
  owner or the shard's own wallet may call it (`NotAllowedToEnd` otherwise;
  `ShardNotActive` for a shard that is not active), and it emits
  `ShardEnded(tokenId, wallet, by)` per key.
- `shardOf(tokenId, wallet)` returns `(expiresAt, epoch, active)`, and
  `isActive(tokenId, wallet)` just the last. A shard is active while it has not
  been ended, its time has not run out, and the key's `ownershipEpoch` is still
  the one it was issued under, so every shard of a key stops the moment the key
  changes hands, with no call to the record, and moving the key back does not
  revive them.
- `setAgentVoting(tokenIds, on)` lets the owner of every key named turn the keys'
  agent voting off or back on, emitting `AgentVotingSet(tokenId, on, epoch)`.
  It is on for every key unless its owner turned it off, and a change of hands
  turns it back on for the new owner. `agentVoting(tokenId)` reads it, and
  `mayGovern(tokenId, wallet)` says whether a wallet's shard may vote, propose
  and cancel with the key now.
- `delegationRevision(tokenId)` goes up on every issue, end and agent-voting
  switch for the key. Signed renewals and ballots carry it (see Votes).

What an active shard lets its wallet do: work in the key's workspace (decided off
chain from this record), mark the key present in its fleet, and, while the key's
agent voting is on, vote the key, propose with it and cancel with it. A shard is
a record, not a token: it cannot be moved, sold or approved, it carries no
money, and its wallet can never move the key, issue shards of it or switch its
agent voting.

## Deployment scripts

The system is deployed once per chain. Fleets are then created through the
factory: the five founding fleets by the Safe, and later fleets by anyone in
phase 4. All scripts read one manifest, named by `KEYFLEET_MANIFEST` (`base` or
`anvil`), from `deployments/<name>.json`, through `script/KeyfleetManifest.sol`.
A manifest holds the Safe, the keeper, REGENT revenue staking, the Autolaunch
factory, the Regents Club Pass, the collection's name, symbol, metadata base and collection metadata
address, the VRF coordinator, subscription and gas lane, the trait table hash,
the REGENT buyer's route, and the deck and profile of each founding fleet.
[../docs/deployment.md](../docs/deployment.md) is how to run each step and what
each refuses.

Every step refuses a manifest for another chain (`WrongChain`), a gas lane the
coordinator does not know (`VrfKeyHashUnknown`) and a subscription it does not
know (the coordinator's own `InvalidSubscription`, which includes the
placeholder `"0"`). On Base each field below must be Base's own, or the step
reverts with `NotBasePin(field)`:

| Field | Base value |
| --- | --- |
| `safe` | `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` |
| `regentStaking` | `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` |
| `autolaunchFactory` | `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` |
| `regentsClubPass` | `0x2208aaDBdEcd47D3B4430b5b75a175f6d885D487` |
| `vrf.coordinator` | `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` |
| `vrf.keyHash` | the 2 gwei lane `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab` or the 30 gwei lane `0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70` |
| `collection.name`, `collection.symbol` | `Keyfleet`, `KEYFLEET` |
| `collection.baseTokenURI` | `https://keyfleet.ai/metadata/keys/` |
| `route.usdc`, `route.weth`, `route.regent` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, `0x4200000000000000000000000000000000000006`, `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` |
| `route.v3Pool` | `0xd0b53D9277642d899DF5C87A3966A349A798F224` |
| `route.poolManager` | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| `route.v4Pool` | currency0 WETH, currency1 REGENT, fee `0x800000` (8388608), tick spacing 200, hooks `0xd60D6B218116cFd801E28F78d011a203D2b068Cc` |

The contracts themselves refuse the rest: an address with no code, a USDC
without six decimals, a zero keeper and a zero trait table hash.

- `script/DeployKeyfleets.s.sol` deploys the system and writes nothing. It sends
  five transactions from one account through `script/KeyfleetSystem.sol`: the
  four deployers, each told the factory's address before it exists (the
  account's fifth contract address from now), then the factory, whose
  constructor deploys the collection, the shard record, the REGENT buyer and the
  Regents Club claims contract. No
  fleet exists afterwards. It moves no token and does not touch the VRF
  subscription.
- `script/KeyfleetSafeSteps.s.sol` makes the Safe's calls, named by
  `KEYFLEET_STEP`: `founding-fleets` (one `createFoundingFleet` per founding
  fleet needed for the current stage (Club, then Classic, then the other three), with the manifest's deck
  and profile), `advance-phase` (one `advancePhase`, opening at the Unix time
  in `KEYFLEET_OPENS_AT`, which must still be in the future when the Safe's
  transaction lands) or `club-gifts` (one `give` per 80 Regents Club keys not
  given yet, `CLUB_GIFT_BATCH`, each key to the holder of its Pass read at the
  latest block, or to the claims contract when that holder is a contract that
  does not answer the NFT receiver check with exactly its selector, when the
  Pass has no holder, or when `KEYFLEET_CLUB_TO_CLAIMS`, a comma-separated list
  of key numbers, names the key); any other
  step reverts with `UnknownStep`. It finds the factory in the deployment step's latest
  broadcast on the chain. On Base it runs every call from the Safe's address
  against the chain's current state, stopping at the first call that would
  revert, then writes each call as its own Safe Transaction Builder file,
  `deployments/safe/<manifest>.<step>.json` (`founding-fleet-1` to
  `founding-fleet-5`, `phase-1` to `phase-4`, `club-gifts-1-80` to
  `club-gifts-1921-1998`), for the Safe's signers to load,
  check and sign. Nothing is signed or sent from it on Base. On a local anvil
  chain (31337) it sends the calls directly from the Safe's address, which anvil
  has unlocked.
- `script/RecordKeyfleets.s.sol` reads the system and every fleet back from the
  chain, checks them against the manifest, and writes
  `deployments/<manifest>.deployed.json`. It refuses a failed or unfinished
  broadcast (`BroadcastIncomplete`, `BroadcastReceiptFailed`,
  `FactoryNotInBroadcast`), a factory with no code (`FactoryMissing`), any
  system value that differs from the manifest (`RecordedMismatch(field)`: the
  Safe, keeper, factory, name, symbol, metadata base, collection metadata
  address, randomness, trait table hash, shard record, staking, Autolaunch, the
  Regents Club Pass and the whole route), a fleet whose four contracts are not where the factory
  places them, hold no code or do not point at each other, or a founding fleet
  of another type or deck than the manifest's (`FleetNotBound(fleetId, part)`),
  a collection needing randomness whose subscription does not list it as a consumer
  (`CollectionNotVrfConsumer`) and, on Base, a subscription the Regents Safe
  does not own (`VrfSubscriptionNotOwnedByRegentsSafe`). It lists every fleet
  in the collection's registry, so it can be rerun at any time to add fleets
  created since.
- `script/AnvilLab.s.sol` is no part of a release. It puts the system with
  its five founding fleets on a plain local anvil for the anvil tests in `platform/`
  (`mix test.external`), with stand-in USDC, WETH, REGENT, a USDC/WETH pool and
  a WETH/REGENT pool manager at a fixed price where 1 USDC buys 1 REGENT, REGENT
  staking, the Autolaunch factory and a VRF coordinator. The sender is the Safe
  and the keeper. It runs in two steps, since a phase must open in the future:
  `run` creates the five founding fleets with a stand-in deck and moves to
  phase 2, opening Club gifts and Classic sales a
  minute later (`OPENING`); once the chain's clock is past that, `sell` buys two
  keys while the coordinator refuses every request, turns the treasury's booked
  USDC into REGENT with one piece, and leaves the sender holding and having
  approved the USDC for a third key.
- `script/BaseForkLab.s.sol` and `script/base-fork-lab.sh` are no part of a
  release either. They put the system with Classic #1 selling on a local anvil
  fork of Base run as chain 31337, for the site on `http://localhost:4097`,
  against Base's own USDC, swap route, REGENT staking and Autolaunch factory
  from `deployments/base.json`, with a stand-in VRF coordinator. The Safe is
  anvil's first default account and the keeper its second. `deploy` deploys,
  creates the five founding fleets with their real decks and moves to phase 2,
  opening Club gifts and Classic sales 10 minutes
  later (`LAB_OPENING`), and the shell script then moves the lab chain's clock
  past that; `record` writes
  `deployments/base-fork-lab.json` through `RecordKeyfleets`, in the shape of
  the release's deployed record; `fulfil` answers every draw still waiting
  (Classic #1's keys 1 to 1,024 hold their cards by number and draw nothing).
  The shell script also gives each buyer named 100 ETH and exactly 1,000 USDC.
  Every step refuses any chain but 31337 (`WrongChain`).

The scripts' cores take and return values, so the suite runs the real
deployment, the real Safe steps and the real record against local stand-ins
without touching a file.

### Deploy-day checklist

Nothing below can be fixed after the fact unless it says so.

1. **Keeper.** Sean selected the Base Regents Safe on 9 October 2026;
   `base.json` now uses the Safe as keeper. It records the deck of every fleet
   created in phase 4 and asks for card refreshes through Safe transactions.
   The Safe can replace it later with `setKeeper`.
2. **Routine public jobs.** Nothing runs by itself. An operator can run a bot
   that presses, as each comes due:
   - the REGENT buyer's `convert(250000000)` whenever `nextPieceAt()` has passed
     and `queueLength()` is above zero, and on `PriceMoved` the same with a
     smaller amount, such as half, until a piece goes through;
   - each fleet's `runDailySplit()` once `nextRunAt()` has passed;
   - each manager's `sendProtocolShare()` whenever `protocolShareOwed()` is
     above zero, at least once a day, since the 10% share waits in the manager
     until someone sends it.
   Anyone may press each of them, so the bot needs no rights, only ETH for gas;
   `convert` costs about 722,000 gas on Base.
3. **The REGENT pool's hook still charges its fee.** Check that the hook at
   `0xd60D6B218116cFd801E28F78d011a203D2b068Cc` still takes at least 1% on every
   swap of the WETH/REGENT pool. The 1% rule measures only each piece's own move
   inside `convert`; what keeps a piece from being front-run is that fee.
   Nothing in Keyfleet can change the route afterwards, so keep watching it.
4. **`collection.contractURI`.** Check the collection page's metadata address in
   the manifest and that it already serves the right file. It is fixed at
   deployment and nothing can change it.
5. **VRF subscription id.** Sean's subscription id is set in `vrf.subscriptionId`.
   Before the first Key that needs randomness, fund it with 0.5 ETH, add the
   collection as consumer and transfer ownership to the Regents Safe. The
   placeholder `"0"` is refused. The balance is checked by hand: top it up
   back to 0.5 ETH when it is below 0.3 ETH, and never leave it below
   0.25 ETH. One answer can cost up to about 0.001 ETH at the
   lane's cap, and a key whose one request waits unanswered for 24 hours never
   gets a seed (see "Keeping the subscription funded" in
   [../docs/deployment.md](../docs/deployment.md)). The Safe can move the
   collection to another subscription or gas lane later with `setRandomness`,
   and to another coordinator once no key waits for its answer.
6. **Add the collection as a VRF consumer.** This may wait during fixed-deck
   minting. Before drawn Keys, add the collection and transfer ownership to the
   Safe; recording such Keys requires both. A key minted before that has its draw refused and asks again later.
7. **REGENT staking is unpaused.** The 10% protocol share goes to REGENT revenue
   staking only while staking accepts deposits. While the Safe has it paused,
   every fleet's share waits in its manager, still owed, and sales go on.
8. **Factories cannot be removed.** The Safe can allow a newer factory with
   `addFactory`, and every factory it ever allows can register fleets for good.
   Allow only an audited factory.
9. **Sales open at a chosen time.** Each phase step names its opening in
   `KEYFLEET_OPENS_AT`; leave enough time for the Safe's signers, since a step
   that lands after that time is refused and must be written again. An opening
   more than 30 days after the step lands is refused too.

## Gas

### Over stand-ins

Measured by the suite against a plain ERC-20 standing in for USDC, stand-in
pools and a stand-in coordinator, with every account cold, each call in a
transaction of its own. The suite asserts each ceiling.

| Call | Gas | Ceiling |
| --- | --- | --- |
| Purchase, Cascade level 1 | 419,071 | 669,000 |
| Purchase, Cascade level 30 | 507,490 | 669,000 |
| Purchase, Cascade level 40 | 519,513 | 669,000 |
| Purchase, a Cascade level's last key | 352,960 | 669,000 |
| Purchase, Syndicate level 1 | 468,881 | 669,000 |
| Purchase, Syndicate level 40 | 560,969 | 669,000 |
| Purchase, Accelerant | 471,465 | 669,000 |
| Purchase, Classic | 470,176 | 669,000 |
| `sendProtocolShare` | 172,190 | 199,000 |
| A key's first renewal | 73,094 | 111,000 |
| A later renewal | 78,094 | 85,000 |
| Sweeping, per ended presence | 5,025 | 6,000 |
| Sweeping, per key whose automatic start came | 26,130 | 32,000 |
| Transfer of a key present from a renewal | 124,785 | 144,000 |
| Transfer of a key present from its automatic start | 84,630 | 144,000 |
| An agent casting first ballots for ten Classic keys | 837,987 | 1,250,000 |
| Each further key (Classic / Fibonacci) | 83,214 / 83,203 | 125,000 |
| Worst-case settlement of one key | 272,533 | 288,000 |
| Transfer of a key with five split assets waiting | 385,319 | 435,000 |
| One wallet claiming ten keys in five assets | 1,727,767 | 1,904,000 |
| The next day's claim of the same ten keys | 582,714 | 694,000 |
| Founding Classic creation | 11,980,376 | 16,777,216 |
| Open creation with key 1: Classic | 12,504,698 | 16,777,216 |
| Open creation with key 1: Syndicate | 12,455,776 | 16,777,216 |
| Open creation with key 1: Accelerant | 12,478,565 | 16,777,216 |
| Open creation with key 1: Cascade | 12,430,502 | 16,777,216 |
| The coordinator's answer to a key, cold | 36,098 | 100,000 given |

The purchase ceiling stays above every first purchase, the dearest of which is
Syndicate level 40. Every purchase enrols its key's automatic presence in the
fleet's votes, and no purchase swaps:
Syndicate, Accelerant and Classic book the treasury's part and put the fleet in
the REGENT buyer's queue, and a Cascade level's last key books its leftover
reserve the same way. The level-1, Accelerant and Classic figures are each
fleet's very first sale, which also writes `firstMintAt` and the fleet's first
place in the queue. The worst-case settlement has USDC pending in
cohort 40 and a split pending in four assets, every slot cold and moving from
zero, so nearly all of it is first writes.
Open creation was measured with a 2,000-byte description, a 512-byte image link
and a 10 USDC starting price, against the 16,777,216-gas cap one transaction may
use on Ethereum since Fusaka (EIP-7825), which the build keeps every creation
under. The least gas that completes a purchase is 289,258; the reveal suite
tries every limit in the few thousand gas above it and finds that every
completed purchase either made its random-number request or said it failed.

### On a fork of Base

Historical figures from the three-phase contracts before Club minting was separated
on 9 October; phase-step gas must be measured again before deployment.

Measured on 8 October 2026 on a fork of Base at its latest block, against the
real USDC (a proxy), the real REGENT pools and hook, REGENT revenue staking, the
Chainlink VRF coordinator and the real Regents Club Pass, with the collection a
consumer of a funded subscription so a key that draws makes its real request.
Each figure is the whole transaction, the 21,000 base and the call data
included, every call run as a transaction of its own
(`test/fork/KeyfleetBaseGas.t.sol`):

| Call | Gas |
| --- | --- |
| `createFoundingFleet`, fleet 1 | 11,804,071 |
| `createFoundingFleet`, fleet 2 | 11,787,005 |
| `createFoundingFleet`, fleet 3 | 11,809,183 |
| `createFoundingFleet`, fleet 4 | 11,787,040 |
| `createFoundingFleet`, fleet 5, the Regents Club | 11,787,108 |
| `advancePhase`, to phase 1 | 70,130 |
| `advancePhase`, to phase 3 | 30,908 |
| `purchase`, Classic #1's first key, dealt by number | 500,971 |
| `purchase`, a later key | 297,990 |
| `purchase`, a key that draws, with its request | 390,684 |
| `give`, the Regents Club's first 80 keys to the real Pass holders | 13,227,593 |
| `convert(250000000)`, one piece through both pools | 717,111 |
| `createFleet`, a Classic fleet at 10 USDC with its key 1 | 12,204,507 |
| `present`, one key | 110,991 |
| `propose`, one payment | 243,206 |
| `castBallot`, one key | 118,977 |
| `sendProtocolShare`, two sales owed | 142,972 |
| `runDailySplit`, ETH, REGENT and USDC | 537,096 |
| `claim`, one key in three assets | 274,456 |
| `transferFrom`, a key with three assets waiting | 286,448 |
| `execute`, a one-payment proposal | 93,893 |
| `executeBatch`, one payment | 56,246 |

`executeBatch` is only ever called by the voting controller inside `execute`;
its line is the treasury's own part. The five transactions that deploy the
system are to measure on a Base fork. To measure again, with `BASE_RPC_URL` set
to a Base endpoint:

```sh
forge test --match-contract KeyfleetBaseGasTest --isolate -vv
```

The coordinator's charge for each answer, paid in ETH from the subscription, is
not in these figures; it is about half a US cent per key (see Status).

## Checks

Run `make check-contracts` from the repository root. It runs, in `contracts/`,
`forge fmt --check`, `forge build`, `forge test` (all but the audit's fork
proofs) and `script/check_bytecode.sh`.

The suites in `test/`, all against local stand-ins, cover the presets, the
collection (registry, phases, sales, decks, the keeper, metadata and royalty),
reveals, cards dealt by number and the trait draw, the factory and its
deployers, the manager, the Regents Club's gifts and claims, the
purchase money and the REGENT buyer, the protocol share and money sent to a
fleet, the treasury's payments and advances, the daily split, the launch token,
the rewards ledger, votes and proposal topics, carrying out proposals, presence,
shards, signed messages, Lit, the deployment, Safe-step and record scripts and
the anvil lab. `test/fork/BaseForkLab.t.sol` runs the Base-fork lab on a fork. Shared set-up is in `test/helpers` and the stand-ins in
`test/mocks`.

`test/invariant/` holds the handler-based invariant suites, which `forge test`
runs with the rest: the collection (founding and open fleets on one collection,
the Regents Club's gifts, and the phases), the money of the founding Cascade and Accelerant fleets, the electorate, presence, and segregation
(random approved batches never lower protected money). The presence suite runs
256 runs, and the fleet, electorate and segregation suites 256 runs × depth 100.
The two collection suites run short every day, 24 runs × depth 80 and
24 runs × depth 40; the `deep` profile runs them at 256 runs × depth 100:

```sh
cd contracts && FOUNDRY_PROFILE=deep forge test --match-path test/invariant/KeyfleetCollectionInvariant.t.sol
```

`script/check_bytecode.sh` disassembles the deployed code of the collection, the
factory, its four deployers, the REGENT buyer, the shard record, the Regents Club
claims contract and a fleet's four contracts with `cast disassemble` and walks it from its entry point,
following every jump target the code pushes, and fails if any of them can reach
`DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. Bytes nothing jumps to, such as
the Classic price table stored at the end of the manager's code, are data and
are not judged. Foundry must be installed; the compiler may be downloaded on
first use.

Tests need no RPC, apart from the five suites in `test/fork/`, which skip
themselves unless `BASE_RPC_URL` is set:

- `KeyfleetBaseFork.t.sol` deploys the system from the committed Base manifest
  through the real deployment and Safe steps and runs fleets against the real
  Chainlink coordinator, USDC, REGENT pools and REGENT staking, including a
  protocol share deposit and a send refused while the Safe has staking paused
  (on the fork only).
- `KeyfleetRegentBuyerFork.t.sol` checks that the pinned v4 pool key names a
  live pool, that a key purchase delivers REGENT to the fleet's treasury through
  both real pools, and that the buyer's and the purchase's own protections hold.
- `KeyfleetLitFork.t.sol` runs the treasury's Lit writes, each carried by a
  passed proposal, against Lit's real account contract, and checks Lit refuses
  anyone else and refuses the treasury once the account is handed on.
- `KeyfleetAutolaunchFork.t.sol` runs a whole launch of a fleet's token through
  Autolaunch v2's real factory, auction, strategy, escrow and payment receiver,
  forked at block 52,272,000; it needs an endpoint that serves older blocks. The
  factory is still paused on Base, so on the fork only the test acts as the
  Regents Safe to open it.
- `KeyfleetBaseGas.t.sol` gives the figures in [On a fork of Base](#on-a-fork-of-base)
  and runs only with `--isolate`.

Run them one suite at a time, as a public endpoint may refuse a burst of
requests.

`test/audit/` keeps the proofs of the internal contract audit (9 Oct): each
repeats a finding's original attack and checks the safe outcome. KF-A-04 checks
the gift-batch behaviour left open by decision. KF-A-05 proves a coordinator
change is refused while an accepted reveal waits, and succeeds after its answer.
Anyone can expire an unanswered request after 24 hours to release its lock on
the coordinator; its Key stays without a seed and cannot request again.
`KeyfleetAuditLocal.t.sol` and `Agent5QueueBrick.t.sol` run on the
local stand-ins with the rest. `KeyfleetAuditFork.t.sol` runs against real Base
USDC, Permit2 and the REGENT route at the pinned block 52,366,000; it fails, and
does not skip, without `BASE_RPC_URL`, and needs an endpoint that serves that
block. `make check-audit-fork` runs it.

OpenZeppelin and forge-std are git submodules, so clone with submodules or run
`git submodule update --init`.

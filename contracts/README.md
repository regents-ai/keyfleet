# Contracts

A Foundry workspace pinned to Solidity 0.8.26 with OpenZeppelin 5.7.0 and
forge-std 1.9.7 vendored as git submodules under `contracts/lib`.

`KeyfleetPresets` is a pure library holding every price, supply, holding-limit
and purchase-split rule, with Classic's price table in the generated
`KeyfleetClassicPrices`. A fleet is five contracts. `Keyfleet` is the fleet
itself: its keys, its purchases, the Cascade reserve and the owed protocol
share. It deploys its own `KeyfleetRewards` ledger and its own `KeyfleetShards`
record in its constructor. Its `KeyfleetVotes` controller and its
`KeyfleetTreasury`, which holds all of the fleet's free capital, are deployed
straight after it, at addresses the fleet was given in advance, and each
refuses to bind to a fleet that does not name it. No contract is shared between
fleets, and no contract has an administrator, an upgrade path, a pause or a
setter. The fleets live on Base (chain 8453).

## Status

Decided by the founder on 27, 28 and 29 September 2026, and what the code on
this branch does:

- Fleets are fully owned by their key holders. Regents takes 10% of each key
  purchase, once, in USDC, deposited into REGENT revenue staking on Base
  (`0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`) for REGENT stakers. Keyfleet
  takes nothing from money a fleet receives afterwards.
- Income in USDC is paid 100% to the keys. The capital part of every purchase,
  a completed Cascade level's surplus and every other token a fleet receives go
  to the fleet's treasury. Nothing can spend the treasury yet: spending by an
  approved proposal's exact calls is a later step. There is no token launch.
- Syndicate and Cascade have no last level: the same Fibonacci supply and 1.2×
  price rule go on for as long as keys sell. Only Classic (1,024 keys) and
  Accelerant (2,000 keys) have a supply limit.
- Accelerant: the first key sends 10% to staking and 90% to the treasury; every
  later key sends 10% to staking, 20% to the treasury and 70% to whoever holds
  the key before it.
- A Decision proposal stays open until more than half of all keys sold vote
  yes, and then anyone may carry it out. A RestrictEdits proposal needs at
  least three fifths. There is no window, deadline or cap.
- No proposal moves money.
- A key's owner may issue shards: time-limited grants to other wallets, recorded
  on chain and ended the moment the key changes hands.
- A key asks Chainlink VRF for its traits once, and can ask again only after a
  refused request.
- Keyfleet Classic, decided 28 September 2026: 1,024 keys, the first at 8 USDC
  and the last at 80 USDC, each key the same percentage dearer than the one
  before, rounded to the nearest cent.
- Referrals, the receipt fee, the 20/80 budget split, the voting window, the pay
  cap and period, execution expiries and the shared asset registry are deleted.

On hold or not yet done:

- Key sales stay off until the founder explicitly says so, and not before these
  contracts are complete and deployed on Base.
- On Base every deployment refuses any staking contract but REGENT revenue
  staking, and the record step refuses a randomness subscription not owned by
  the Regents Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`.
- Before any deploy: an outside audit and the founder's go.
- `deployments/base.json` carries the final trait table's hash
  (`0x154aa5ac0169cf32835eee2e49c284f8626122e17ed66a82c7629257e63be3e8`, eight
  traits of sixteen values each, every trait's weights adding up to 1,000) and a
  VRF subscription of 0, so a Base deployment is refused until the Regents
  subscription id is written in.
- Deferred until each fleet type is next: Fibonacci late-entry capture (a
  level that completes shares in income that was waiting before it) and the
  Cascade reserve of a level that never completes.
- The purchase and send gas figures on a fork of Base have not been measured;
  the figures below are from the suite's stand-ins.
- Each key's Chainlink VRF request is paid in ETH from the Regents subscription
  on Base's 2 gwei lane (the 30 gwei lane is also allowed). The VRF cost of one
  key on Base has not been measured against the 10% Regents takes from that
  key's sale (80 cents on the first Classic key).

## Presets

`KeyfleetPresets` covers four presets: `FibonacciSyndicate`, `FibonacciCascade`,
`FleetTechClassic` and `FleetTechAccelerant`. It has no storage, holds no tokens
and makes no external calls. Every function is `internal pure` with checked
arithmetic.

Keys are paid in USDC, and every price is in atomic USDC (six decimals). The
Fibonacci and Accelerant ladders start from the reference price `Q_USDC`, which
is 10,000,000: ten USDC. Both are computed iteratively from the first step,
never as a closed-form power, and every step rounds up:

- Fibonacci level price: level 1 costs `Q_USDC`, and each further level costs
  `ceilDiv(previous * 120, 100)`. There is no last level: level 20 costs 319.48
  USDC, level 30 about 1,978 USDC, level 40 about 12,248 USDC, and a level's
  price first passes a billion USDC at level 103.
- Accelerant primary price: the first mint costs `Q_USDC`, and each further mint
  costs `ceilDiv(previous * 105, 100)`. `MAX_ACCELERANT_KEYS` is 2000, so mint
  indexes run 0 through 1999. Only primary mints advance the price; resales do
  not. The fleet stores the current price in `currentPrice` and steps it after
  each primary mint.
- Fleet.Tech Classic: `CLASSIC_SUPPLY` is 1024, and key n costs
  800 × 10^((n − 1) / 1023) US cents, rounded to the nearest cent: key 1 costs
  8 USDC, key 144 11.04, key 512 25.27 and key 1024 80 USDC, each key about
  0.2253% dearer than the one before, and all 1,024 together 32,032.45 USDC.
  `classicPrice(tokenId)` reads the price from `KeyfleetClassicPrices.CENTS`, a
  table of 1,024 two-byte cent values, and multiplies it by `CENT_USDC`
  (10,000). The table is written by `scripts/classic_prices.py` at the
  repository root, which also writes
  `platform/lib/keyfleet/fleets/classic_key_prices.txt`, the same prices the
  site shows; change the script and run
  `uv run scripts/classic_prices.py`, never either file. The table adds about
  2.2 KB to the fleet's code and about 1,100 gas to a Classic purchase. The
  preset test walks the curve one key at a time in 36-decimal fixed point and
  checks every one of the 1,024 prices against it.

Fibonacci level supplies are 2, 3, 5, 8, 13, ..., 17,711 at level 20, 28,657 at
level 21, and so on without end. Token ids are 1-based and contiguous across
levels: level 20 ends at token 46,365, level 30 at 5,702,884 and level 40 at
701,408,730. The per-wallet holding limit is one key for levels 1 through 7 and
the level supply divided by 10, rounded down, from level 8 up. Only level zero
and token id zero are refused. Every level function walks the levels from the
first, so its cost grows with the level: a purchase costs about 1,000 gas more
per level. The supply sums first leave 256 bits at level 367, where checked
arithmetic reverts, long after any price anyone could pay.

A purchase is split into four parts that always sum to exactly the gross price.
`PROTOCOL_BPS` is 1000: 10% of every purchase, rounded down, is the protocol
share for REGENT stakers. The rest depends on the preset:

- Syndicate and Classic: the rest, 90%, goes to the fleet's treasury.
- Cascade: the rest, 90%, goes to the level-completion reserve.
- Accelerant after the first key: `ACCELERANT_CAPITAL_BPS` (2000, 20% of gross,
  rounded down) goes to the treasury and the rest, 70% of gross plus any
  rounding dust, is a rebate to the current holder of the preceding key. The
  first Accelerant key has no predecessor and its rest, 90%, goes to the
  treasury.

## Rewards ledger

`KeyfleetRewards` is the per-fleet reward ledger, permanently bound to its fleet.
The fleet is the only writer: it enrolls keys into cohorts, allocates tokens to a
cohort, credits an address directly, and settles a key. It pays exactly one
income token, USDC, fixed at construction. `rewardAssets()` lists it and
`isRewardAsset(asset)` answers for one.

Rewards are distributed through a cumulative index per asset and cohort, so an
allocation writes one index and never iterates over recipients. Classic and
Accelerant keys are all in cohort 0; a Fibonacci key is in the cohort of its
level. The ledger takes any cohort id the fleet gives it, because the Fibonacci
presets have no last level. A newly enrolled key starts at the cohort's current
index and earns nothing from earlier allocations.

Accrued rewards belong to the address that held the key while they accrued. The
fleet settles a key to its outgoing owner immediately before every ownership
change, and the incoming owner continues from the cohort's current index.

Backing is reserved at allocation, never at withdrawal. `allocateToCohort` and
`credit` both require the tokens to be sitting in the ledger already:
`balanceOf(this)` must cover `backed[asset]` plus the new amount. `backed` only
ever falls when a claim pays out.

Indexes are scaled by `PRECISION = 1e27`. An allocation truncates the scaled
index and still records the whole amount as backed. Settlement advances a key's
watermark by exactly the whole units it credited, carrying the sub-unit
remainder into the next settlement, so a key's shortfall stays below one atomic
unit per asset at any moment. The sliver lost to truncation stays in the ledger
for good, counted as backed and never claimable.

`claim(asset, tokenIds, to)` settles the caller's named keys for one asset and
pays the caller's whole credit for that asset to the caller, or to `to` when it
is not zero. One asset per call, so a token that reverts on transfer can only
block itself. `claimable` agrees with `claim` for distinct token ids and returns
zero where `claim` would revert with `NothingToClaim`; callers pass each id at
most once. `accrued(asset, tokenId)` reports one key's unsettled whole units.

Worst-case settlement, with USDC pending on a key in cohort 40 and every slot
cold, measured 53,026 gas; the suite asserts a ceiling of 64,000.

## Fleet

`Keyfleet` is an OpenZeppelin ERC721 with 1-based, contiguous token ids.
`tokenURI` is a fixed base plus the id; the base is set once at construction and
is readable through `baseTokenURI()`. The constructor takes the preset, USDC,
a `Metadata` value (name, symbol, metadata base), a `Randomness` value (VRF coordinator,
subscription, gas lane), the trait table hash and a `Companions` value (the
addresses its `KeyfleetVotes` and `KeyfleetTreasury` will be deployed at,
readable as `VOTES()` and `TREASURY()`). It rejects a zero USDC or companion
address, a USDC that does not report six decimals, a
coordinator that holds no code and a zero trait table hash. It then deploys the
fleet's `KeyfleetRewards` and `KeyfleetShards`.

### Deployment order and sizes

A fleet goes on chain as three transactions from one account: the fleet, then
its voting controller, then its treasury. The fleet is told the controller's and
the treasury's addresses before they exist (the account's next two contract
addresses), and each of the two refuses to deploy for a fleet that does not name
its address, so a wrong address stops the deployment rather than binding the
wrong contract. `script/KeyfleetStack.sol` does this for the deployment
script, the anvil lab and the suite. A purchase made before the treasury is
deployed sends its capital to the treasury's address, where the treasury finds
it once deployed.

The order exists because of Base's size limits: 24,576 bytes of runtime code
and 49,152 bytes of deployment code per contract. Measured with
`forge build --sizes`:

| Contract | Runtime (bytes) | Deployment (bytes) |
| --- | --- | --- |
| `Keyfleet` | 15,314 | 25,528 |
| `KeyfleetRewards` | 5,204 | 5,547 |
| `KeyfleetShards` | 2,216 | 2,407 |
| `KeyfleetVotes` | 5,125 | 5,464 |
| `KeyfleetTreasury` | 1,377 | 1,955 |

A fleet that deployed its controller and treasury itself would carry their
deployment code inside its own; when it did, its deployment code measured
33,693. The controller (presence, ballots, proposals) and the treasury (calls,
the daily split, advances) grow by several times in later steps, which would
take that past 49,152; deployed separately, each stays well inside both limits.

### Purchases

`purchase(receiver, maxPrice, deadline)` is the only way a primary key is
created. A zero receiver mints to the caller. The deadline, the supply bound and
the price against `maxPrice` are checked before any token moves, because the
displayed next key is not reserved. The buyer must have approved the fleet for
the gross price in USDC. No balance-delta check is taken around the pull: USDC is
fixed at deployment and on Base the deployment scripts pin it to native Base
USDC. A paused USDC, or one that blocks the buyer or the fleet, stops purchases until it
lifts; that is accepted.

Within a purchase the order is fixed: the USDC is pulled, the split is taken from
`KeyfleetPresets`, the protocol share is added to `protocolShareOwed`, the
preset's own bookkeeping runs (the capital part sent to the treasury, the
Cascade reserve, or the Accelerant rebate moved into the ledger and credited to
the holder of the preceding key), the key is enrolled in the ledger, the key is minted, a Cascade
level completes if this was its last key, and last the key's traits are
requested. `Purchased(tokenId, buyer, receiver, gross, protocol, capital,
reserve, rebate)` records the split. `purchase` is guarded against reentrancy,
so a receiver contract cannot buy again from inside `onERC721Received`, but it
may forward the key: enrollment happens before the mint.

`nextPrice()` and `quote()` give the next purchase's price and split. On Classic
and Accelerant both revert once the fleet is sold out, and `maxSupply()` and
`remainingSupply()` give the limit and count down to zero. Syndicate and Cascade
never sell out, so on them `maxSupply()` and `remainingSupply()` revert with
`NotFleetTechPreset` rather than answer with a stand-in number. `levelOf`,
`holdingLimit` and `completedLevels` report the library's answers and revert
with `NotFibonacciPreset` on Classic and Accelerant, which have no levels.

A Cascade level completes in the transaction that mints its last key, once. Level
1 has no predecessor, so its whole reserve goes to the treasury. From level 2 the
reserve first repays the whole gross the preceding level paid, moved into the
ledger and allocated to that level's cohort, which means whoever holds those keys
at that moment; the rest goes to the treasury and the reserve is emptied. The
reserve always covers the repayment: a level has at least 1.5 times the keys of
the one before at 1.2 times the price, and 90% of every purchase is reserved, so
the reserve is at least 1.5 × 1.2 × 0.9 = 1.62 times what is owed.
`LevelCompleted(level, reimbursement, surplus)` records it. A level that never
completes keeps its reserve; what happens to it is deferred.

Before any ownership change the fleet settles the key to its outgoing owner,
applies the Fibonacci holding limit to the incoming owner, raises the key's
`ownershipEpoch` by one (it is 1 at mint) and records the block in
`lastMovedBlock`, which is what decides whether the key can vote on a proposal.
There is no burn.

The costliest primary purchase is the first one of a high level on a Cascade
fleet, every slot cold; its cost grows slowly with the level because the level
functions walk the levels from the first. Against a plain ERC-20 standing in for
USDC and a stand-in coordinator it measured, in execution:

| Purchase | Gas |
| --- | --- |
| Cascade, level 1 | 383,352 |
| Cascade, level 30 | 407,890 |
| Cascade, level 40 | 424,010 |
| Syndicate, level 1 | 361,699 |
| Syndicate, level 40 | 396,511 |
| Accelerant | 341,433 |
| Classic | 339,836 |

Syndicate, Accelerant and Classic each include one transfer of the capital part
to the treasury.

The suite asserts a ceiling of 509,000, the level-40 Cascade figure plus a fifth.
That is a regression bound on the fleet's own work. Real Base USDC is a proxy
and costs more per transfer, so the figures to publish must be measured on a
fork of Base.

### The protocol share

The 10% of every purchase is added to `protocolShareOwed`; a purchase never
sends it, so staking that is paused or refuses a deposit cannot stop a sale.
`sendProtocolShare()` is how it leaves: anyone may call it at any time. It
sends the whole owed amount to the fleet's treasury, and in the same call the
treasury approves REGENT revenue staking for exactly that amount and deposits
it with `depositUSDC`. The deposit carries the source tag
`PROTOCOL_SHARE_TAG = keccak256("keyfleet.protocol_share")`
(`0xd5e47eb51823bc53938260d20f51f3d772c0410bdc18528aee65e4994f00b271`) and the
fleet's address as its source reference. Only the fleet can ask its treasury
for this (`OnlyFleet`). The amount never stays in the treasury, and the fleet
itself never approves a token.

Staking must report receiving exactly the owed amount and leave no approval
standing, or the treasury reverts with `StakingDepositFailed(amount, received)`.
That revert, a paused staking contract, or any other failure unwinds the whole
call, and the share stays owed in the fleet for a later send. The send emits
`ProtocolShareSent(caller, amount)` and reverts with `ZeroAmount` when nothing
is owed. This is the only fee a fleet ever pays.

The staking address is fixed in the treasury at deployment as
`REGENT_STAKING()`; on Base the deployment scripts require
`0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`. A plain USDC transfer to it would
not count as revenue there, which is why the share goes through a deposit. The
Regents staking reader indexes deposits without filtering on the tag, so the tag
is Keyfleet's own; the fleet in the source reference tells fleets apart.

Against the stand-in staking contract the send measured 150,200 gas, all
accounts cold; the suite asserts a ceiling of 181,000. Against the real staking
contract on a fork of Base it measured 118,771 gas.

### Income and the treasury

The fleet itself holds only two USDC figures: `cascadeReserve` and
`protocolShareOwed`. It holds no free capital in any token: that is all in its
treasury, reachable as `TREASURY()`. `accountedBalance(asset)` is the sum of the
two figures for USDC and zero for every other asset, and `surplus(asset)` is the
fleet's balance above it: money that has arrived and not yet been sorted. Reward
backing lives in the ledger and is not part of either.

There are no deposit functions. Money reaches a fleet by a plain transfer, and
`recognizeSurplus(asset)` sorts it. Anyone may call it, and the class the money
lands in depends only on the token:

- USDC, the one income token, is moved into the ledger and allocated to the
  keys in full, and
  `IncomeRecognized(asset, caller, amount)` is emitted. Classic and Accelerant
  share it equally per key minted. The Fibonacci presets share it equally across
  the fully minted levels and then equally per key within each level; the
  remainder of the split goes to the last completed level. While no key, or no
  Fibonacci level, can receive it the call reverts with `NoEligibleKeys`, and an
  amount below one atomic unit per eligible level reverts with `ZeroAmount`;
  the balance waits for a later call.
- Every other token is sent on to the treasury, and
  `ForwardedToTreasury(asset, caller, amount)` is emitted.

Sorting USDC on a Fibonacci fleet writes one ledger index per completed level,
so its cost grows with the completed levels and never with the number of keys
or holders. With every slot cold it measured, in execution:

| Completed levels | Keys sold | Gas | Ceiling |
| --- | --- | --- | --- |
| 20 | 46,365 | 665,208 | 804,000 |
| 30 | 5,702,884 | 964,918 | 1,164,000 |
| 40 | 701,408,730 | 1,264,628 | 1,523,000 |

About 30,000 gas per completed level. Each ceiling is the measured figure plus
a fifth.

The treasury is a separate contract bound to its fleet for good. In this version
it only receives: nothing can spend from it yet. Spending by the exact calls an
approved proposal names, and the daily split of its USDC, come in later steps.
The Cascade reserve, the owed protocol share and the ledger's backing are never
in the treasury and are out of any vote's reach. The only ways USDC leaves the
fleet itself are the protocol share sent through the treasury to staking, the capital part
and the released Cascade surplus sent to the treasury, the Accelerant rebate,
the Cascade repayment and income moved into the ledger. No token a fleet holds
is ever swapped or converted. Tokens that take a fee when they move, or rebase,
are not supported.

## Votes

`KeyfleetVotes` is the one collective decision. There are no councils, no
moderators, no rule amendments, no windows, delays, expiries, periods or caps, no
cancellation and no delegation by signature.

Every key is one vote on every kind of proposal. A proposal records the block it
opened in. A key may vote on it only if the key last moved (its mint or latest
transfer) in an earlier block, so buying or moving a key after a proposal opens
can never add a vote to it, while every key sold still counts toward the total.
The key's owner, or the one address that owner registered with
`setVotingDelegate(address)` (zero clears it), may vote the key with
`vote(proposalId, tokenIds, support)` and may change its vote until the proposal
is carried out; voting the same way twice reverts with `AlreadyVoted`.
`withdrawVote(proposalId, tokenIds)` takes a key's vote away. A vote cast before
a key moved stays counted after it moves, and the key's current holder or their
delegate may withdraw it but cannot cast a new one. A batch of keys is voted or
withdrawn whole or not at all.

A Decision proposal is approved at any moment
`yesVotes * 2 > FLEET.totalMinted()`: yes must be more than half of all the keys
sold so far, so a silent key counts against it. A RestrictEdits proposal is
approved at `yesVotes * 5 >= FLEET.totalMinted() * 3`: at least three fifths,
so three of five keys pass and 599 of 1,000 do not. The test is live, so a later
sale can take an approved proposal back to open. `state(proposalId)` reports
`Open`, `Approved` or `Executed`. `execute(proposalId)` is permissionless and
carries out an approved proposal once. The proposal is marked carried out before
the fleet is called, and any revert inside the fleet undoes the mark with
everything else, so a failed attempt consumes nothing and the proposal stays
open.

Proposing needs standing: the proposer names a key they own or are the delegate
of. Naming a key is not a vote. There are two kinds, numbered in this order
from 0:

- `Decision`: `proposeDecision(tokenId, text, digest)`. Records agreement and
  has no on-chain effect beyond `DecisionRecorded`. The text is emitted in
  `ProposalCreated` and stored nowhere; the optional digest pins an exact
  artifact or commit.
- `RestrictEdits`:
  `proposeRestrictEdits(tokenId, targetTokenId, restricted, text, digest)`.
  Names any key already sold (`KeyNotMinted` otherwise) and whether its edits
  should be restricted or no longer restricted. Carrying it out sets
  `editsRestricted(targetTokenId)` and emits
  `EditsRestrictionSet(targetTokenId, restricted, proposalId)`; the latest one
  carried out stands. It moves no money. What a restriction stops is decided
  off chain from this record.

No proposal moves money, and the controller holds nothing. A majority of keys can
approve a decision the rest did not want; claim and reserve solvency and the
owed protocol share hold regardless of any vote. The controller is deployed
straight after its fleet, at the address the fleet was given for it
(`VOTES()`), and refuses to deploy for a fleet that names another
(`WrongFleet`).

Voting is the one call whose cost grows with what it is asked, and only with the
number of keys named. Ten Classic keys in one vote measured 284,514 gas and each
further key about 25,400, the same on a Fibonacci fleet; the suite asserts
ceilings of 342,000 and 31,000. A holder with more keys than a block can carry
splits the vote across calls. Creating and carrying out a proposal cost the same
on any size of fleet.

## Shards

`KeyfleetShards` records the shards of one fleet's keys: time-limited grants a
key's owner gives to other wallets. It is bound to its fleet for good and is
reachable as `SHARDS()` on the fleet.

- `issue(tokenId, wallet, days)` is for the key's current owner only
  (`NotKeyOwner` otherwise; an unsold key reverts with the ERC-721
  `ERC721NonexistentToken`). A shard lasts 1 to 365 days (`DaysOutOfRange`), may
  not go to the zero address or the owner (`WalletIsOwner`), and records the
  key's current `ownershipEpoch`. It emits
  `ShardIssued(tokenId, wallet, expiresAt, epoch)`.
- A wallet holds at most one active shard in a fleet, under whichever key issued
  it; another key cannot issue it one (`ShardAlreadyActive`). A key may have any
  number of shards. A new shard replaces a wallet's inactive one, and the key's
  owner renews an active shard by issuing it again, which counts its days from now.
- `end(tokenId, wallet)` ends an active shard early. The key's current owner or
  the shard's own wallet may call it (`NotAllowedToEnd` otherwise), and it emits
  `ShardEnded(tokenId, wallet, by)`.
- `shardOf(wallet)` returns the wallet's latest shard as
  `(tokenId, expiresAt, epoch, active)`. A shard is active while it has not been
  ended, its time has not run out, and the key's `ownershipEpoch` is still the
  one it was issued under, so every shard of a key stops the moment the key
  changes hands, with no call to the record, and moving the key back does not
  revive them.

A shard is a record, not a token: it cannot be moved, sold or approved, and it
carries no vote, no money and no authority on chain. What a shard's wallet may do
is decided off chain from this record.

## Key reveals

Every key's traits come from one Chainlink VRF v2.5 random word. As its last
step, each purchase asks the fleet's coordinator for one word: three blocks deep
(`REVEAL_CONFIRMATIONS`), with 100,000 gas for the answer
(`REVEAL_CALLBACK_GAS_LIMIT`), paid in ETH from the fleet's subscription. A
purchase never waits for the answer and never fails because of the request. An
accepted request emits `RevealRequested(tokenId, requestId)` and records the
time in `revealRequestedAt(tokenId)`; a refused one emits
`RevealRequestFailed(tokenId)` and the key is still sold.

`requestReveal(tokenId)` lets anyone ask again, but only for a key whose every
request so far was refused. Once a request is accepted the key waits for that
answer and is never asked for again, so a seed can only come from one answer.

The answer arrives through `rawFulfillRandomWords`, which only the coordinator
may call. The key's seed is

```
keccak256(abi.encode(TRAIT_SEED_TAG, block.chainid, address(fleet), tokenId, word))
```

with `TRAIT_SEED_TAG = keccak256("keyfleet.trait-seed")` and `word` the first
random word. It is stored once in `revealSeed(tokenId)`, and the fleet emits
`KeyRevealed(tokenId, requestId, seed)` and ERC-4906 `MetadataUpdate(tokenId)`.
An answer for a key that already has a seed, for an unknown request, or with no
words is ignored without reverting, because a reverted answer is final and still
charged. `supportsInterface` reports ERC-4906 (`0x49064906`).

The traits are drawn off chain from the seed and a published trait table.
`TRAIT_TABLE_HASH` is `keccak256` of that file's bytes exactly as committed, fixed
per fleet at construction. The draw rule, for a key with seed `seed`:

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

The site draws every key's traits with this rule in
`platform/lib/keyfleet/traits.ex`, and `test/KeyfleetTraitDraw.t.sol` pins the
same golden results the site's tests pin. The table's file format is in
[../docs/deployment.md](../docs/deployment.md).

Before a fleet is deployed the operator creates the VRF subscription, funds it in
ETH, moves its ownership to the Regents Safe, and writes its id and the trait
table hash into the manifest. After the fleet is deployed the Safe adds it to the
subscription as a consumer, and only then does the record step accept it. Keys
sold before that are sold without a request and can ask again once the fleet is
added. The three Chainlink files the fleet uses are copied unchanged into
`src/vendor/chainlink`, with their source, commit and checksums in the README
beside them.

## Deployment scripts

Each fleet is deployed and recorded on its own, named by `KEYFLEET_FLEET`
(`syndicate`, `cascade`, `classic` or `accelerant`) beside `KEYFLEET_MANIFEST`
(`base` or `anvil`). There is nothing shared to deploy first.

`script/DeployKeyfleets.s.sol` deploys the named fleet and writes nothing. It
sends three transactions from one account through `script/KeyfleetStack.sol`:
the fleet, its voting controller and its treasury, in that order. The
staking contract comes from the manifest's `regentStaking`. It refuses a
manifest whose `chainId` is not
the chain it runs on. On Base it refuses a USDC other than native Base USDC
`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, a VRF coordinator other than
`0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`, a gas lane other than the 2 gwei
lane `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab` or
the 30 gwei lane
`0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70` (from
Chainlink's VRF v2.5 supported-networks page), and a staking contract other
than REGENT revenue staking `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`. On
any chain it refuses a staking address that holds no code, a coordinator that
holds no code, a gas lane or subscription
the coordinator does not know, a zero trait table hash and an unknown fleet
name.

`script/RecordKeyfleets.s.sol` runs straight after, against the same chain,
because Forge's `run-latest.json` holds only the latest broadcast. It refuses a
transaction without a receipt or a failed receipt, applies the same manifest
refusals, reads the fleet back from the chain and refuses a preset other than the
named fleet's, any value that differs from the manifest (the treasury's
staking contract included), a ledger, controller,
treasury or shard record that holds no code or does not name the fleet as its
own (`CompanionNotBound`), a fleet the subscription
does not list as a consumer and, on Base, a subscription the Regents Safe does
not own. Only then does it write
`deployments/<name>.<fleet>.deployed.json`, the fleet's published manifest: the
fleet, ledger, controller, treasury and shard record addresses, the fleet's code hash, the
deployment block, the staking contract and the protocol share tag, the supply limits of Classic and
Accelerant, the reference price, the fee basis points, the randomness terms, the
trait table hash, the income token and the terms the release discloses.

All three scripts share `script/KeyfleetManifest.sol`, which reads
`deployments/base.json` and `deployments/anvil.json`. Their cores take and return
values, so the suite runs the real deployment and the real record against local
mocks without touching a file. [../docs/deployment.md](../docs/deployment.md) is
how to run each step and what each refuses.

`script/AnvilLab.s.sol` is no part of a release. It puts one Classic fleet and
its controller and treasury, with
stand-in USDC, VRF coordinator and REGENT staking, on a plain local
anvil for the anvil tests in `platform/` (`mix test.external`).

## Checks

Run `make check-contracts` from the repository root to check formatting, build,
and run the preset, ledger, purchase, income, treasury, voting, shard, reveal,
trait-draw and deployment tests. Foundry must be installed; the compiler may be
downloaded on first use. Tests need no RPC, apart from
`test/fork/KeyfleetBaseFork.t.sol`, which skips itself unless `BASE_RPC_URL`
is set. It then reads the pinned Base addresses (USDC, REGENT, REGENT staking,
the Regents Safe, the coordinator and both gas lanes) and runs a fleet against
the real Chainlink coordinator, USDC and REGENT staking on a fork of Base,
including a protocol share deposit and a send refused while the Safe has staking
paused (on the fork only). The public
`https://mainnet.base.org` is enough for it.

OpenZeppelin and forge-std are git submodules, so clone with submodules or run
`git submodule update --init`.

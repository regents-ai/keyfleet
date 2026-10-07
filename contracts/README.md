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

Decided by the founder on 27, 28 and 29 September and 6 October 2026, and what the code on
this branch does:

- Fleets are fully owned by their key holders. Regents takes 10% of each key
  purchase, once, in USDC, deposited into REGENT revenue staking on Base
  (`0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`) for REGENT stakers. Keyfleet
  takes nothing from money a fleet receives afterwards.
- The fleet's treasury is its one payment address. All USDC a fleet receives
  outside a purchase is treasury capital, as is every other token, the capital
  part of every purchase and a completed Cascade level's surplus. Money sent to
  the fleet contract itself by mistake is forwarded to the treasury. The
  treasury spends only by making an approved proposal's exact calls, apart from
  the daily split, which shares a small part of its ETH, REGENT and USDC (and
  OUSD once a vote admits it, and the fleet's own token once launched) equally
  across all keys.
- A fleet may launch its own token through Autolaunch Revstake v2 on Base, by a
  vote. Once the launch has sold, anyone may bind its token to the daily split,
  once; only tokens already released to the treasury are split.
- Syndicate and Cascade have no last level: the same Fibonacci supply and 1.2×
  price rule go on for as long as keys sell. Only Classic (1,024 keys) and
  Accelerant (2,000 keys) have a supply limit.
- Accelerant: the first key sends 10% to staking and 90% to the treasury; every
  later key sends 10% to staking, 20% to the treasury and 70% to whoever holds
  the key before it.
- A proposal names the key it is made with, a hash of its text, a closing time
  at most 48 hours away and the exact calls the treasury makes if it passes.
  Each key casts one ballot, Yes, No or Abstain, which can be changed until
  closing. The electorate is the keys present when the proposal opened plus
  every key that joins by casting a ballot; it never shrinks. After closing a
  proposal passes when Yes is more than half of that electorate, so abstaining
  and staying silent count against it, and anyone may carry it out within 48
  hours. Whoever may vote the key it was made with may cancel it until then.
- A key's edits are restricted, or freed again, only by a passed proposal's
  call.
- A key is present for 48 hours after its owner or an agent holding a shard of
  it renews it, casts a ballot for it, proposes with it or cancels with it, and
  stops being present the moment it changes hands. A proposal records how many
  keys were present when it opened, and that count starts its electorate.
- A key's owner may issue shards: time-limited grants to agent wallets, recorded
  on chain and ended the moment the key changes hands. An agent with a shard
  always may mark the key present. It may also vote the key, propose with it
  and cancel with it unless the owner turned the key's agent voting off; every
  new owner starts with it on. One agent may hold shards of many keys, and every
  call about keys takes a list of them.
- Renewals and ballots may be signed and handed to anyone to submit; a signature
  is void once used, after its deadline, and after any of its keys changes hands
  or has its shards or agent voting changed.
- A key asks Chainlink VRF for its traits once, and can ask again only after a
  refused request.
- The treasury owns the fleet's Lit account. It signs nothing by itself: it
  answers a signature check (ERC-1271) only for a hash a passed proposal
  approved, and every write to the Lit account is a passed proposal's call.
- Keyfleet Classic, decided 28 September 2026: 1,024 keys, the first at 8 USDC
  and the last at 80 USDC, each key the same percentage dearer than the one
  before, rounded to the nearest cent.

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
- Lit's own servers (registering the treasury's account, checking its answer to
  a signed request, minting a usage key and running the inbox action) work only
  against a treasury deployed on Base itself, so they are untested until one is.
- Deferred until the Cascade fleet type is next: the reserve of a level that
  never completes.
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

`KeyfleetRewards` is the per-fleet reward ledger, permanently bound to its fleet,
its treasury and its shard record. Two things fill it, and nothing else can.

The fleet writes its USDC obligations: the Accelerant rebate, credited to the
holder of the preceding key, and the Cascade repayment, allocated to the
preceding level's cohort. These go through a cumulative index per cohort, so an
allocation writes one number and never loops over holders. Classic and
Accelerant keys are all in cohort 0; a Fibonacci key is in the cohort of its
level, and the ledger takes any cohort id because those presets have no last
level. A newly enrolled key starts at the cohort's current index and earns
nothing from earlier allocations.

The treasury funds the daily split: the same whole amount for every minted key,
in native ETH or a token. Each asset has one split index, counted in whole units
per key, and a new key starts from the current index of every asset already
split. An asset split for the first time later starts from zero, which every key
then shares. The ledger accepts this funding only from the treasury, only while
the treasury says it is inside its own split routine (`splitInProgress()`), and
only for exactly as many keys as have been minted. An approved proposal's call
from the treasury to `fundSplit` or `fundSplitNative` is therefore refused, and a
key minted in the middle of a split makes that split revert rather than share
it. The ledger has no other way to take ETH.

`rewardAssets()` lists every asset the ledger pays: USDC first, then each asset
the split has funded, in the order first funded. ETH is the zero address.

Accrued rewards belong to the address that held the key while they accrued. The
fleet settles a key to its outgoing owner, in every asset, immediately before
every ownership change, and the incoming owner continues from the current
indexes.

Backing is reserved when money comes in, never when it goes out. Each of the
four ways in requires the money to be sitting in the ledger already: its balance
must cover `backed[asset]` plus the new amount. `backed` only falls when a claim
pays out. Cohort indexes are scaled by `PRECISION = 1e27`; settlement carries the
sub-unit remainder forward, so a key's shortfall stays below one atomic unit and
the sliver stays in the ledger for good, counted as backed and never claimable.

`claim(tokenIds, assets)` can be pressed by a key's holder or by a wallet holding
an active shard of it, for many keys and many assets at once. It settles each
key to the wallet holding it and pays, for each asset, that wallet's whole
credit. The money for a key always goes to the wallet holding it, never to an
agent that pressed claim. The caller is also paid its own credit, which is how a
former holder with no keys left collects what it earned. Each payment is one
asset to one wallet, ETH by `Address.sendValue`, under a reentrancy lock, so a
wallet that refuses ETH stops only a claim that includes ETH for it; the same
claim without ETH goes through and the ETH stays waiting. It returns the total
paid in each asset. `accrued(asset, tokenId)` reports one key's unsettled whole
units in both lanes, and `credits(asset, account)` what is settled and waiting.

Worst-case settlement, with USDC pending in cohort 40 and a split pending in
four assets, every slot cold and moving from zero, measured 239,798 gas; the
suite asserts a ceiling of 288,000. Each split asset adds about 46,000 to that
worst case, nearly all of it first writes.

In a whole fleet with all five bound assets split, moving a key costs 357,671
gas with every slot cold. One wallet claiming ten keys in all five assets costs
1,578,156 the first time, because each key's watermark in each asset is written
from zero, and 570,051 for the next day's claim of the same ten keys. The suite
asserts ceilings twenty percent above each.

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
fleet's `KeyfleetShards`, and its `KeyfleetRewards` bound to the fleet, its
treasury's address and that shard record.

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
| `Keyfleet` | 14,592 | 29,523 |
| `KeyfleetRewards` | 8,396 | 8,878 |
| `KeyfleetShards` | 3,604 | 3,810 |
| `KeyfleetVotes` | 14,531 | 15,647 |
| `KeyfleetTreasury` | 10,776 | 12,359 |

A fleet that deployed its controller and treasury itself would carry their
deployment code inside its own; when it did, its deployment code measured
33,693, before the controller held proposals and ballots and the treasury made
calls and ran the daily split. With those, it would pass 49,152; deployed
separately, each stays well inside both limits.

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
`NotFleetTechPreset` rather than answer with a stand-in number. `levelOf` and
`holdingLimit` report the library's answers and revert with `NotFibonacciPreset`
on Classic and Accelerant, which have no levels.

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
`ownershipEpoch` by one (it is 1 at mint) and tells the voting controller, which
ends the key's presence. A sale does not tell it: a new key has never been
present. There is no burn. `firstMintAt` is the time the first key was sold, zero
until then, and never changes afterwards. Token ids stop at 4,294,967,295, the
most the presence record indexes; a Fibonacci fleet would refuse a sale past that
with `SoldOut`, long after its price had passed any real buyer.

The costliest primary purchase is the first one of a high level on a Cascade
fleet, every slot cold; its cost grows slowly with the level because the level
functions walk the levels from the first. Against a plain ERC-20 standing in for
USDC and a stand-in coordinator it measured, in execution:

| Purchase | Gas |
| --- | --- |
| Cascade, level 1 | 383,343 |
| Cascade, level 30 | 385,740 |
| Cascade, level 40 | 401,860 |
| Syndicate, level 1 | 361,690 |
| Syndicate, level 40 | 374,361 |
| Accelerant | 341,424 |
| Classic | 339,827 |

Syndicate, Accelerant and Classic each include one transfer of the capital part
to the treasury. The level-1, Accelerant and Classic figures are each fleet's
very first sale, which also writes `firstMintAt`; later sales skip that write.

The suite asserts a ceiling of 509,000, the level-40 Cascade figure plus a fifth.
That is a regression bound on the fleet's own work. Real Base USDC is a proxy
and costs more per transfer; the figures against it are in
[Gas on Base](#gas-on-base).

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

Against the stand-in staking contract the send measured 150,155 gas, all
accounts cold; the suite asserts a ceiling of 181,000. Against the real staking
contract on a fork of Base it measured 118,771 gas.

### The treasury and money sent to the fleet

The fleet itself holds only two USDC figures: `cascadeReserve` and
`protocolShareOwed`. It holds no free capital in any token: that is all in its
treasury, reachable as `TREASURY()`, which is the address anyone paying the
fleet pays, in USDC or any other token. `accountedBalance(asset)` is the sum of
the two figures for USDC and zero for every other asset, and `surplus(asset)` is
the fleet's balance above it: money sent to the fleet contract itself and not yet
forwarded. Reward backing lives in the ledger and is not part of either.

There are no deposit functions. `recognizeSurplus(asset)` sends an asset's whole
surplus to the treasury, USDC exactly as any other token, and emits
`ForwardedToTreasury(asset, caller, amount)`. Anyone may call it at any time,
before or after any key is sold; with nothing to forward it returns zero and
says nothing. None of it reaches the keys directly: it reaches them only from
the treasury, through the daily split.

The treasury is a separate contract bound to its fleet for good. It holds native
ETH as well as tokens: anyone may send it ETH. It spends only through
`executeBatch(calls)`, which only the fleet's voting controller may call
(`OnlyVotes`), when a passed proposal is carried out: it makes the proposal's
exact calls in order, each a plain call with its value, and the first that
reverts reverts the whole batch with its reason. Proposing sets nothing aside,
so two approved proposals can never spend the same money: whichever is carried
out second fails if the money is gone, and stays approved to be retried.

Two of the treasury's own functions accept only the treasury itself as caller
(`OnlySelf`), so only a passed proposal's call reaches them:

- `pay(asset, to, amount)` pays a token with OpenZeppelin `SafeERC20`, so a
  token that answers `false` instead of paying fails the whole batch, or pays
  ETH when the asset is `NATIVE` (the zero address) with `Address.sendValue`.
  Proposals pay tokens through here rather than with a raw `transfer` call. It
  emits `Paid(asset, to, amount)`.
- `advance(advanceId, operator, asset, amount, purposeHash)` pays the same way
  and records it under a new id (`AdvanceIdTaken` for one already used), as
  `advances(advanceId)`: the operator, the asset, what is still outstanding and
  the hash of what it is for. It emits `Advanced`.

Anyone may return an advance with `returnAdvance(advanceId, amount)`: an ETH
advance by sending exactly `amount` with the call, a token advance by approving
the treasury, which pulls it (`WrongValue` for ETH sent with the wrong amount or
with a token). A return is capped at what is outstanding
(`ReturnAboveOutstanding`), so the same money cannot be returned twice and a
return cannot be labelled against more than was advanced. It emits
`AdvanceReturned(advanceId, from, amount, outstanding)`. The cap is the only
check: someone holding customer income could still return it against an open
advance, which disclosure covers.

Carrying out calls, the protocol share deposit and returning an advance share
one reentrancy lock, so a payee called back by a payment cannot return an
advance, send the protocol share or carry out another proposal from inside it.
The Cascade reserve, the owed protocol share and the ledger's backing are never
in the treasury and are out of any vote's reach. The only ways USDC leaves the
fleet itself are the protocol share sent through the treasury to staking, the
capital part, the released Cascade surplus and USDC sent to the fleet forwarded to
the treasury, and the Accelerant rebate and the Cascade repayment moved into the
ledger. No token a fleet holds
is ever swapped or converted. Tokens that take a fee when they move, or rebase,
are not supported.

### The daily split

Once a day the treasury shares a fixed part of its balance of each bound asset
equally across every key minted so far. The bound assets are ETH, REGENT and
USDC; REGENT is fixed at deployment as `REGENT()`, on Base
`0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`. OUSD has a slot that starts empty:
a passed proposal may fill it once with `admitOusd(token)`, which refuses the
zero address, USDC, REGENT and the launch token (`OusdInvalid`) and a second admission
(`OusdAlreadyAdmitted`), and emits `OusdAdmitted(token, threshold)`. The fleet's
own launched token has a slot that starts empty too (see below).
`splitAssets()` lists the bound assets in the order they are split: ETH (the
zero address), REGENT, USDC, then OUSD once admitted, then the launch token once
bound. Any other token the treasury holds is never split.

For each bound asset, with `B` the treasury's balance of it, `N` the number of
keys minted and the rate in basis points:

- the cut is `B × rate / 10,000`, rounded down;
- each key's share is the cut divided by `N`, rounded down, in whole units;
- the treasury sends the ledger exactly the share times `N`, and the rounding
  dust stays in the treasury.

An asset is skipped, with `SplitSkipped(asset, balance)`, when no key has been
minted, when `B` is below its threshold, or when the share comes to zero
because there are more keys than units in the cut. The thresholds are 0.05 ETH
and 100 whole units of each token, read from the token's decimals once (REGENT
and USDC at deployment, OUSD when admitted, the launch token when bound); a balance equal to the threshold
qualifies. `B` is only the treasury's own balance, so what the ledger already
holds for the keys is never counted again. Each asset split emits
`SplitAllocated(asset, balance, perKey, keys)`.

The rate starts at 50 basis points (half a percent) and is always between 10 and
200. Only a passed proposal can change it, with `setDailySplitBps(bps)`
(`SplitRateOutOfRange` otherwise); the new rate applies from the next run, with
nothing pending in between. It emits `DailySplitRateSet(bps)`.

Anyone may call `runDailySplit()` once a day has passed since the last run; the
first run opens a day after the first key was minted (`firstMintAt`).
`nextRunAt()` gives that time, or zero before any key is minted, and an early
call reverts with `SplitNotDue(opensAt)`. Days nobody runs it are not made up
later. A passed proposal may also run it at any time with `runVotedSplit()`,
ignoring the clock. Every run, public or voted, records `lastRunAt` and emits
`DailySplitRun(voted, keys, bps)`.

The public run takes the treasury's one reentrancy lock, and the voted run is
only ever made from inside a carried-out proposal, which already holds it. While
a run is under way the treasury raises a flag that lasts only for that
transaction (`splitInProgress()`); the ledger accepts split funding only from the
treasury and only while that flag is up. A proposal's call to the ledger's
funding functions is therefore refused, and a key minted while a token is on its
way to the ledger makes the whole run revert rather than share an allocation
worked out before it existed.

ETH is sent with the funding call itself. A token is sent first and the ledger is
funded after; a token that refuses the transfer is skipped with
`SplitTransferFailed(asset, amount)` and the other assets are still split. A
transfer that fails because it ran out of gas reverts the whole run with
`SplitOutOfGas` instead, so nobody can starve one asset of its day by sending
too little gas.

### The fleet's own token

A fleet launches its own token through Autolaunch Revstake v2, whose factory is
fixed in the treasury at deployment as `AUTOLAUNCH()`; on Base the deployment
scripts require `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E`. The launch is a
passed proposal's call from the treasury to the factory's
`launch(params)`, with the treasury itself as `params.treasury`. The factory
takes no ETH and no token for it, and records the treasury as the launcher. The
token's name, symbol, description, website and image are the proposal's own
(64, 16, 512, 256 and 256 bytes at most). Autolaunch's own fees, vesting and
liquidity rules are the factory's and nothing here changes them. Autolaunch
opens its factory to launches only when the Regents Safe unpauses it.

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
`approveSignatureHash(hash)` and `revokeSignatureHash(hash)` accept only the
treasury itself as caller (`OnlySelf`), so only a passed proposal's call sets or
clears a hash, and they emit `SignatureHashApproved(hash)` and
`SignatureHashRevoked(hash)`.

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

## Votes

`KeyfleetVotes` is the one collective decision. There are no councils, no
moderators, no rule amendments, no quorum classes and no proposal kinds.

### Proposals

`propose(authorKey, contentHash, closesAt, calls)` opens a proposal. The caller
must be allowed to vote `authorKey` (below); the key is their standing and
nothing else, and proposing casts no ballot. `contentHash` is the hash of the
proposal's text, kept off chain. `closesAt` is when ballots stop: after now and
at most 48 hours from now (`ClosingOutOfRange`). `calls` is the exact ordered
batch of `(target, value, data)` calls the treasury makes if the proposal is
carried out; an empty batch records agreement and moves nothing. The proposal can
be carried out until `executionExpiry`, 48 hours after closing. An identical
proposal made again is a new proposal with its own id, hash and electorate.

Opening sweeps expired presences, renews the author key and records the exact
count of present keys as `e0` (see Presence). The proposal stores
`actionsHash = keccak256(abi.encode(calls))` and a `proposalHash`:

```
keccak256(abi.encode(chainId, votes, treasury, proposalId, authorKey,
  ownershipEpoch(authorKey), contentHash, actionsHash, closesAt, executionExpiry))
```

`ProposalCreated(proposalId, authorKey, proposer, proposalHash, contentHash,
closesAt, executionExpiry, e0, openRevision, calls)` carries the calls in full.
`proposal(proposalId)` returns the whole record.

### Ballots and the electorate

Each key holds one ballot per proposal: `Yes`, `No` or `Abstain` (numbered 1 to
3; 0 is no ballot). `castBallot(proposalId, tokenIds, choice)` casts or replaces
the ballots of a list of keys, all with one choice, and renews each key. The
key's owner, or an agent holding an active shard of the key while the key's agent
voting is on (see Shards), may cast it, and whoever acted last decides it. A
batch is cast whole or not at all, and anybody refused for a key gets
`NotAuthorizedForKey(tokenId, account)`. A marketplace approval (`approve`,
`setApprovalForAll`) gives nothing here. Ballots stop at closing and on
cancelling (`BallotsClosed`). `ballotOf(proposalId, tokenId)` reads a ballot and
`BallotCast(proposalId, voter, choice, tokenIds)` records each call.

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
`Open` until `closesAt`; then `Rejected` unless `yes > floor(D / 2)`; then
`Approved` until `executionExpiry` and `ExecutionExpired` from then on (numbered
0 to 5 in the order Open, Approved, Rejected, Cancelled, Executed,
ExecutionExpired). A proposal is never approved before closing, a tie fails, and
abstaining or staying silent counts against it. One present key voting Yes on a
proposal nobody else joins passes it at closing.

`cancel(proposalId)` may be called by whoever may vote the author key now, its
current owner or an agent, while the proposal is open or approved
(`NotCancellable` otherwise). It renews the author key and emits
`ProposalCancelled(proposalId, by)`.

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
a key already sold (`KeyNotMinted`). It sets `editsRestricted(tokenId)` and emits
`EditsRestrictionSet(tokenId, restricted)`; the latest one carried out stands.
What a restriction stops is decided off chain from this record.

The controller holds nothing. Claim and reserve solvency, the Cascade reserve and
the owed protocol share hold regardless of any vote. The controller is deployed
straight after its fleet, at the address the fleet was given for it (`VOTES()`),
and refuses to deploy for a fleet that names another (`WrongFleet`).

Casting ballots is the one call whose cost grows with what it is asked, and only
with the number of keys named. An agent casting first ballots for ten Classic
keys in one call through its shards measured 1,040,721 gas and each further key
about 103,500, the same on a Fibonacci fleet; the suite asserts ceilings of
1,250,000 and 125,000. An owner casting their own keys' ballots pays a little
less. A holder with more keys than a block can carry splits them across calls.
Cancelling costs the same on any size of fleet, carrying out costs the same
apart from the calls it makes, and opening costs the same apart from the expired
presences it sweeps.

### Signed renewals and ballots

Whoever may renew keys or cast their ballots may instead sign the request and
hand it to anyone to submit: `presentBySig(tokenIds, signer, deadline, signature)`
and `castBallotBySig(proposalId, tokenIds, choice, signer, deadline, signature)`.
The signer must be allowed to act for every key when it is submitted, exactly as
if they had sent it, and a ballot is recorded under the signer. The submitter needs no
standing and can change nothing that was signed.

The messages are EIP-712 typed data in the domain `KeyfleetVotes`, version `1`,
on the chain the controller is on (Base, 8453), at the controller's address:

- `Present(address fleet,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,address signer,uint256 nonce,uint256 deadline)`
- `Ballot(uint256 proposalId,bytes32 proposalHash,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,uint8 choice,address signer,uint256 nonce,uint256 deadline)`,
  where `choice` is 1 for Yes, 2 for No and 3 for Abstain, and `proposalHash` is
  the proposal's, so a signed ballot counts on that proposal alone.

The keys are listed in strictly ascending order (`KeysNotAscending`), and for
each key the message carries its `ownershipEpoch` on the fleet and its
`delegationRevision` on the shard record, which the controller reads back when
the message is submitted. So a signature stops working the moment one of its keys
changes hands, or has a shard issued, renewed or ended, or its agent voting
switched. Each signer has one nonce (`nonces(signer)`), used by every message
they sign, so a message works once. A message past its deadline is refused
(`SignatureExpired`), as is a signature that is not the signer's
(`InvalidSignature`). Signatures are checked with OpenZeppelin
`SignatureChecker`, which accepts ordinary wallets and contract wallets such as a
Safe (ERC-1271). `PRESENT_TYPEHASH`, `BALLOT_TYPEHASH` and `eip712Domain()` give
the exact values.

### Presence

A key is present for 48 hours (172,800 seconds, by block time, never by block
count) after its owner or a wallet holding an active shard of it renews it with
`present(tokenIds)` or the signed `presentBySig`, casts a ballot for it,
proposes with it, or cancels a proposal made with it.
A shard may renew its key whether or not the key's agent voting is on. It stops being present the moment it changes
hands, and its new owner renews it under the new ownership. Nobody else can
renew a key, a batch with one such key renews none, and renewing changes no open
proposal. `isActive(tokenId)` and `lastActiveAt(tokenId)` answer for now.
`Present(tokenId, at, blockNumber, epoch)` records each renewal and
`PresenceCleared(tokenId)` each change of hands.

Present keys sit in one queue ordered by expiry, one entry per key: a renewal
moves the key's entry to the back. Time alone removes nothing, so the queue may
still hold expired entries; `sweepExpired(limit)`, which anyone may call,
removes up to `limit` of them from the front, returns how many it removed and
whether more are due, and emits `Swept(removed, due)`. `presenceQueue()` and
`presenceEntry(tokenId)` show the queue.

Opening a proposal first sweeps up to 256 expired entries. If any are still due
it reverts with `MaintenanceRequired` and changes nothing, so a proposal never
records a count that includes expired keys; anyone may sweep the rest and try
again. It then renews the author key and records the opening revision, time
and exact count of present keys (`e0`, never zero) in the proposal and in
`ProposalCreated`. Each renewal, change of hands and opening is numbered in
order, and each key keeps a checkpoint of its renewals and changes of hands, so
`wasActiveAtOpening(proposalId, tokenId)` answers exactly even for several of
them in one block: renewed, moved, then opened is not present at the opening;
renewed, opened, then moved is. The count starts the proposal's electorate (see
Votes).

Measured in a transaction of their own with every account cold: a key's first
renewal 91,407 gas, a later one 69,958, sweeping 4,871 per expired entry, and a
transfer of a present key 113,461 against 83,457 for one never renewed. The
suite asserts each plus a fifth. A full sweep of 2,000 Accelerant keys expiring
together is about 10 million gas, done in several calls.

## Shards

`KeyfleetShards` records the shards of one fleet's keys: time-limited grants a
key's owner gives to agent wallets. It is bound to its fleet for good and is
reachable as `SHARDS()` on the fleet. Shards are kept per key and wallet, so one
agent wallet may hold shards of many keys, from one owner or several, and a key
may have shards in many wallets. Every call takes a list of keys.

- `issue(tokenIds, wallet, days)` is for the current owner of every key named
  (`NotKeyOwner` otherwise; an unsold key reverts with the ERC-721
  `ERC721NonexistentToken`). A shard lasts 1 to 365 days (`DaysOutOfRange`), may
  not go to the zero address or the owner (`WalletIsOwner`), and records each
  key's current `ownershipEpoch`. Issuing again renews a shard, counting its days
  from now. It emits `ShardIssued(tokenId, wallet, expiresAt, epoch)` per key.
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
chain from this record), mark the key present, and, while the key's agent voting
is on, vote the key, propose with it and cancel with it. A shard is a record, not a token: it
cannot be moved, sold or approved, it carries no money, and its wallet can never
move the key, issue shards of it or switch its agent voting.

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
than REGENT revenue staking `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`, and a
REGENT other than `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` (the manifest's
`regent`), and an Autolaunch factory other than Revstake v2's
`0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` (the manifest's
`autolaunchFactory`). On any chain it refuses a staking address, a REGENT or an
Autolaunch factory that holds no code, a coordinator that
holds no code, a gas lane or subscription
the coordinator does not know, a zero trait table hash and an unknown fleet
name.

`script/RecordKeyfleets.s.sol` runs straight after, against the same chain,
because Forge's `run-latest.json` holds only the latest broadcast. It refuses a
transaction without a receipt or a failed receipt, applies the same manifest
refusals, reads the fleet back from the chain and refuses a preset other than the
named fleet's, any value that differs from the manifest (the treasury's
staking contract, REGENT and Autolaunch factory included), a ledger, controller,
treasury or shard record that holds no code or does not name the fleet as its
own (`CompanionNotBound`), a fleet the subscription
does not list as a consumer and, on Base, a subscription the Regents Safe does
not own. Only then does it write
`deployments/<name>.<fleet>.deployed.json`, the fleet's published manifest: the
fleet, ledger, controller, treasury and shard record addresses, each with its
code hash, the deployment block, the staking contract and the protocol share tag, the supply limits of Classic and
Accelerant, the reference price, the fee basis points, the randomness terms, the
trait table hash, REGENT, the Autolaunch factory, the assets the daily split shares at deployment
(`splitAssets`) and the terms the release discloses.

All three scripts share `script/KeyfleetManifest.sol`, which reads
`deployments/base.json` and `deployments/anvil.json`. Their cores take and return
values, so the suite runs the real deployment and the real record against local
mocks without touching a file. [../docs/deployment.md](../docs/deployment.md) is
how to run each step and what each refuses.

`script/AnvilLab.s.sol` is no part of a release. It puts one Classic fleet and
its controller and treasury, with
stand-in USDC, REGENT, VRF coordinator, REGENT staking and Autolaunch factory, on a plain local
anvil for the anvil tests in `platform/` (`mix test.external`), and returns the
addresses of the fleet's five contracts and the stand-in staking.

## Gas on Base

Measured on 6 October 2026 on a fork of Base, against the real USDC (a proxy),
REGENT, REGENT revenue staking and Chainlink VRF coordinator, with a Classic
fleet a consumer of a funded subscription so each purchase makes its real
randomness request. Each figure is the whole transaction, the 21,000 base and
the call data included, every call run as a transaction of its own
(`test/fork/KeyfleetBaseGas.t.sol`):

| Call | Gas |
| --- | --- |
| `purchase`, the fleet's first key | 394,246 |
| `purchase`, a later key | 286,593 |
| `present`, one key | 124,195 |
| `propose`, one payment | 221,965 |
| `castBallot`, one key | 110,803 |
| `runDailySplit`, ETH, REGENT and USDC | 360,765 |
| `claim`, one key in all three | 233,324 |
| `transferFrom`, a key with all three waiting | 287,030 |
| `execute`, a one-payment proposal | 91,075 |
| `executeBatch`, one payment | 53,946 |

`executeBatch` is only ever called by the voting controller inside `execute`;
its line is the treasury's own part. Deploying one fleet on a fork of Base took
6,045,638 gas for the fleet with its ledger and shard record, 3,210,157 for the
controller and 2,443,275 for the treasury: 11,699,070 in all. To measure again:

```sh
BASE_RPC_URL=https://mainnet.base.org forge test --mc KeyfleetBaseGasTest --isolate -vv
```

The VRF cost of one key's answer, paid in ETH from the subscription, is not in
these figures and has not been measured.

## Checks

Run `make check-contracts` from the repository root to check formatting, build,
and run the preset, ledger, purchase, money-sorting and protocol share, treasury,
payment and advance, daily split, launch token, voting, presence, shard,
signature, Lit, reveal, trait-draw and deployment tests, with the presence queue's invariants run
over random renewals, transfers, sweeps, openings and the passing of time, the
growing electorate's over random proposals, ballots, transfers, renewals,
sweeps, sales and the passing of time, and segregation's over random batches of
calls a proposal could make against all five contracts, USDC, Autolaunch and the
fleet's own token once a launch has sold and been bound partway through, the
daily split, its rate and binding included: none lowers the owed protocol share,
the Cascade reserve outside a level completion, or any wallet's credit or any
key's accrual in USDC or the bound token, and the fleet and the ledger always
hold what they have booked.

The fleet-wide invariants (`test/invariant/KeyfleetFleetInvariant.t.sol`) run a
Cascade fleet and an Accelerant fleet through random purchases, key transfers,
shards given to agents, money sent to the treasury and the fleet, payments out,
public and voted daily splits, rate changes, OUSD admission, token launches
through a stand-in Autolaunch factory that sell or fail, vested tokens released
to a launch's treasury, attempts by anyone to bind any launch to either fleet,
claims by holders, former holders and agents, and the passing of time. In ETH,
REGENT, OUSD and every launched token the ledger holds exactly what it owes,
which is exactly what the split sent it less what claims paid; in USDC it holds
at least what it owes, short by under a unit per key at most. The rate stays
between 10 and 200, the split's funding flag is never left up, an OUSD not
admitted or a launched token the fleet has not bound is never split, a bound
launch is always the fleet's own sold launch, and an agent is never paid. Every
public run goes through exactly when it is due, every run gives each key exactly
the formula's share of the treasury's own balance, every claim pays exactly what
is owed to exactly the right wallets, and a launch binds exactly when the rules
allow. Every invariant suite runs
256 sequences of 100 calls or more.

Last, `script/check_bytecode.sh` disassembles the deployed code of the five
contracts with `cast disassemble` and walks it from its entry point, following
every jump target the code pushes, and fails if any of them can reach
`DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. Bytes nothing jumps to, such as
the Classic price table stored at the end of the fleet's code, are data and are
not judged. Foundry must be installed; the compiler may be
downloaded on first use. Tests need no RPC, apart from the four suites in
`test/fork/`, which skip themselves unless `BASE_RPC_URL` is set.
`KeyfleetBaseFork.t.sol` reads the pinned Base addresses (USDC, REGENT, REGENT staking,
the Regents Safe, the coordinator and both gas lanes) and runs a fleet against
the real Chainlink coordinator, USDC and REGENT staking on a fork of Base,
including a protocol share deposit and a send refused while the Safe has staking
paused (on the fork only). `KeyfleetLitFork.t.sol` runs the treasury's Lit
writes, each carried by a passed proposal, against Lit's real account contract,
and checks Lit refuses anyone else and refuses the treasury once the account is
handed on. `KeyfleetAutolaunchFork.t.sol` runs a whole launch of a fleet's
token through Autolaunch v2's real factory, auction, strategy, escrow and
payment receiver: the fleet launches by a passed proposal, the launch is refused
binding while it runs and a stranger's launch naming the treasury is refused,
one bid sells it, the treasury receives REGENT from the raise, anyone binds it, a
USDC payment through the launch's receiver reaches the treasury less 2% to
REGENT staking, and after half a year the released half is split across the
keys. The factory is still paused on Base, so on the fork only the test acts as
the Regents Safe to open it. `KeyfleetBaseGas.t.sol` gives the figures in
[Gas on Base](#gas-on-base) and runs only with `--isolate`. The public
`https://mainnet.base.org` is enough for all four; run them one suite at a
time, as it may refuse a burst of requests.

OpenZeppelin and forge-std are git submodules, so clone with submodules or run
`git submodule update --init`.

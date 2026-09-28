# Contracts

A Foundry workspace pinned to Solidity 0.8.26 with OpenZeppelin 5.7.0 and
forge-std 1.9.7 vendored as git submodules under `contracts/lib`.

There are four contracts. `KeyfleetPresets` is a pure library holding every
price, supply, holding-limit, purchase-split and launch-threshold rule.
`Keyfleet` is one fleet: its keys, its purchases and its money. Each fleet
deploys its own `KeyfleetRewards` ledger and its own `KeyfleetVotes` controller
in its constructor, so a fleet, its ledger and its vote are born bound to each
other. No contract is shared between fleets, and no contract has an
administrator, an upgrade path, a pause or a setter.

## Status

Decided by the founder on 27 September 2026, and what the code on main does:

- Fleets are fully owned by their key holders. Regents takes 2% of each key
  purchase, once. Keyfleet takes nothing from money a fleet receives
  afterwards; Autolaunch's splitter takes its own share before paying a fleet.
- Income in USDC, REGENT or the fleet's launched token is paid 100% to the keys.
  Everything else a fleet holds is shared money, spent only by a vote.
- A proposal stays open until more than half of all keys sold vote yes, and then
  anyone may carry it out. There is no window, deadline or cap.
- Every payment is matched: every key that did not vote yes can collect the same
  amount per key as the payment cost the yes keys.
- One Autolaunch at a time. A failed launch can be followed by another; a
  graduated launch is the fleet's last.
- A key asks Chainlink VRF for its traits once, and can ask again only after a
  refused request.
- Referrals, the receipt fee, the 20/80 budget split, the voting window, the pay
  cap and period, execution expiries and the shared asset registry are deleted.

On hold or not yet done:

- Key sales stay off until the founder explicitly says so, and not before these
  contracts are complete and deployed on Base.
- Before any deploy: a fork test against the real Autolaunch contracts on Base,
  an outside audit, and the founder's go.
- Deferred until each fleet type is next: Fibonacci late-entry capture (a
  level that completes shares in income that was waiting before it), the
  Cascade reserve of a level that never completes, and a sensible Accelerant
  key cap.
- The purchase and send gas figures on a fork of Base have not been measured
  since the change; the figures below are from the suite's stand-ins.

## Presets

`KeyfleetPresets` covers four presets: `FibonacciSyndicate`, `FibonacciCascade`,
`FleetTechClassic` and `FleetTechAccelerant`. It has no storage, holds no tokens
and makes no external calls. Every function is `internal pure` with checked
arithmetic.

Keys are paid in USDC, and every price is in atomic USDC (six decimals) from the
reference price `Q_USDC`, which is 10,000,000: ten USDC. Both ladders are
computed iteratively from the first step, never as a closed-form power, and
every step rounds up:

- Fibonacci level price: level 1 costs `Q_USDC`, and each further level costs
  `ceilDiv(previous * 120, 100)`. `MAX_FIBONACCI_LEVEL` is 20.
- Accelerant primary price: the first mint costs `Q_USDC`, and each further mint
  costs `ceilDiv(previous * 105, 100)`. `MAX_ACCELERANT_KEYS` is 2000, so mint
  indexes run 0 through 1999. Only primary mints advance the price; resales do
  not. The fleet stores the current price in `currentPrice` and steps it after
  each primary mint.
- Fleet.Tech Classic: `CLASSIC_SUPPLY` is 144 and every primary key costs
  `Q_USDC`.

Fibonacci level supplies are 2, 3, 5, 8, 13, ... through 17711 at level 20.
Token ids are 1-based and contiguous across levels, so `FIBONACCI_MAX_TOKEN_ID`
is the cumulative supply through level 20, 46365. The per-wallet holding limit is
one key for levels 1 through 7 and the level supply divided by 10, rounded down,
from level 8 up.

A purchase is split into four parts that always sum to exactly the gross price.
`PROTOCOL_BPS` is 200: 2% of every purchase, rounded down, is the protocol share
for the Regents staking contract. The rest depends on the preset:

- Syndicate and Classic: the rest becomes shared money.
- Cascade: the rest goes to the level-completion reserve.
- Accelerant after the first key: `ACCELERANT_CAPITAL_BPS` (1000, 10% of gross)
  becomes shared money and the rest, 88% of gross, is a rebate to the current
  holder of the preceding key. The first Accelerant key has no predecessor and
  its rest becomes shared money.

A fleet may propose an Autolaunch once it has sold
`FIBONACCI_AUTOLAUNCH_MIN_KEYS` (86, the last key of level 7) on Syndicate and
Cascade, or `FLEET_TECH_AUTOLAUNCH_MIN_KEYS` (100) on Classic and Accelerant.

## Rewards ledger

`KeyfleetRewards` is the per-fleet reward ledger, permanently bound to its fleet.
The fleet is the only writer: it enrolls keys into cohorts, allocates tokens to a
cohort, credits an address directly, and settles a key. It pays exactly three
income tokens: USDC and REGENT, fixed at construction, and the fleet's launched
token, which the fleet sets with `setLaunchedToken` when a launch is created and
replaces when a launch follows a failed one. `rewardAssets()` lists them and
`isRewardAsset(asset)` answers for one. A failed launch's token never had an
allocation, so replacing it strands nothing.

Rewards are distributed through a cumulative index per asset and cohort, so an
allocation writes one index and never iterates over recipients. Classic and
Accelerant keys are all in cohort 0; a Fibonacci key is in the cohort of its
level. Cohort ids run `0..31` (`MAX_COHORTS = 32`). A newly enrolled key starts
at the cohort's current index and earns nothing from earlier allocations.

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

Worst-case settlement, with all three income tokens pending on one key and every
slot cold, measured 139,300 gas; the suite asserts a ceiling of 168,000.

## Fleet

`Keyfleet` is an OpenZeppelin ERC721 with 1-based, contiguous token ids.
`tokenURI` is a fixed base plus the id; the base is set once at construction and
is readable through `baseTokenURI()`. The constructor takes the preset, USDC,
REGENT, the Regents revenue staking contract, the Autolaunch factory, a
`Metadata` value (name, symbol, metadata base), a `Randomness` value (VRF
coordinator, subscription, gas lane) and the trait table hash. It rejects a zero
USDC, REGENT, staking or factory address, a USDC that does not report six
decimals, a coordinator that holds no code and a zero trait table hash. It then
deploys the fleet's `KeyfleetRewards` and `KeyfleetVotes`.

### Purchases

`purchase(receiver, maxPrice, deadline)` is the only way a primary key is
created. A zero receiver mints to the caller. The deadline, the supply bound and
the price against `maxPrice` are checked before any token moves, because the
displayed next key is not reserved. The buyer must have approved the fleet for
the gross price in USDC. No balance-delta check is taken around the pull: USDC is
fixed at deployment and on Base the deployment scripts pin it to Base USDC. A
paused USDC, or one that blocks the buyer or the fleet, stops purchases until it
lifts; that is accepted.

Within a purchase the order is fixed: the USDC is pulled, the split is taken from
`KeyfleetPresets`, the protocol share is added to `protocolShareOwed`, the
preset's own bookkeeping runs (shared money, the Cascade reserve, or the
Accelerant rebate moved into the ledger and credited to the holder of the
preceding key), the key is enrolled in the ledger, the key is minted, a Cascade
level completes if this was its last key, and last the key's traits are
requested. `Purchased(tokenId, buyer, receiver, gross, protocol, capital,
reserve, rebate)` records the split. `purchase` is guarded against reentrancy,
so a receiver contract cannot buy again from inside `onERC721Received`, but it
may forward the key: enrollment happens before the mint.

`nextPrice()` and `quote()` give the next purchase's price and split, and both
revert once the fleet is sold out; `remainingSupply()` counts down to zero.
`levelOf` and `holdingLimit` report the library's answers and revert on Classic
and Accelerant, which have no levels.

A Cascade level completes in the transaction that mints its last key, once. Level
1 has no predecessor, so its whole reserve becomes shared money. From level 2 the
reserve first repays the whole gross the preceding level paid, moved into the
ledger and allocated to that level's cohort, which means whoever holds those keys
at that moment; the rest becomes shared money and the reserve is emptied. The
reserve always covers the repayment: a level has at least 1.5 times the keys of
the one before at 1.2 times the price, and 98% of every purchase is reserved.
`LevelCompleted(level, reimbursement, surplus)` records it. A level that never
completes keeps its reserve; what happens to it is deferred.

Before any ownership change the fleet settles the key to its outgoing owner,
applies the Fibonacci holding limit to the incoming owner, raises the key's
`ownershipEpoch` by one (it is 1 at mint) and records the block in
`lastMovedBlock`, which is what decides whether the key can vote on a proposal.
There is no burn.

The worst primary purchase is the first one on a fresh Cascade fleet, every slot
cold. Against a plain ERC-20 standing in for USDC and a stand-in coordinator it
measured 391,092 gas in execution (Syndicate 366,216, Accelerant 345,518, Classic
342,865), and the suite asserts a ceiling of 470,000. That is a regression bound
on the fleet's own work. Real Base USDC is a proxy and costs more per transfer,
so the figures to publish must be measured on a fork of Base.

### The protocol share

The 2% of every purchase is added to `protocolShareOwed`; a purchase never calls
the staking contract, so a paused staking contract cannot stop a sale.
`sendProtocolShare()` is how it leaves: anyone may call it at any time, and it
sends the whole owed amount as registered revenue with
`depositUSDC(amount, SOURCE_TAG, PROTOCOL_SHARE_REF)`, where `SOURCE_TAG` is
`keccak256("keyfleet")` and `PROTOCOL_SHARE_REF` is
`keccak256("keyfleet.protocol-share")`. The call must report receiving the whole
amount and must spend the approval it was given down to nothing, or it reverts
with `StakingRegistrationFailed` and the amount stays owed. It emits
`ProtocolShareSent(caller, amount)` and reverts with `ZeroAmount` when nothing is
owed. This is the only fee a fleet ever pays. Against the mock staking contract
the send measured 217,556 gas, most of it the mock's own bookkeeping; the suite
asserts a ceiling of 262,000.

### Income and shared money

A fleet holds three separate USDC figures: `freeCapital[USDC]` (shared money),
`cascadeReserve` and `protocolShareOwed`. For every other asset it holds only
`freeCapital[asset]`. `accountedBalance(asset)` is their sum and
`surplus(asset)` is the fleet's balance above it: money that has arrived and not
yet been sorted. Reward backing lives in the ledger and is not part of either.

There are no deposit functions. Money reaches a fleet by a plain transfer, and
`recognizeSurplus(asset)` sorts it. Anyone may call it, and the class the money
lands in depends only on the token:

- An income token (USDC, REGENT, or the launched token once a launch is
  recorded) is moved into the ledger and allocated to the keys in full, and
  `IncomeRecognized(asset, caller, amount)` is emitted. Classic and Accelerant
  share it equally per key minted. The Fibonacci presets share it equally across
  the fully minted levels and then equally per key within each level; the
  remainder of the split goes to the last completed level. While no key, or no
  Fibonacci level, can receive it the call reverts with `NoEligibleKeys`, and an
  amount below one atomic unit per eligible level reverts with `ZeroAmount`;
  the balance waits for a later call.
- Every other token becomes shared money, and
  `SharedMoneyRecognized(asset, caller, amount)` is emitted.

Two receipts from the fleet's own launch are shared money although they arrive in
income tokens, and they are booked from the launch contracts' own records before
anything is sorted or paid, so each is booked exactly once whatever the order of
calls:

- At graduation the strategy sends the fleet the REGENT the auction raised that
  the pool did not use (`currencyRaised - lpRegentUsed`, at least a quarter of
  the raise), booked with `GraduationHoldingsBooked(REGENT, amount)`. The
  strategy sends the fleet no launched token at graduation: what it has left
  goes to the escrow and vests to the fleet with the 65%.
- After graduation, every launched token the vesting escrow releases, booked from
  the growth of the escrow's `totalReleased` with
  `VestingBooked(subject, amount, totalReleased)`.

Worst-case sorting, a Fibonacci fleet with all twenty levels complete and every
slot cold, measured 677,492 gas in execution; the suite asserts a ceiling of
813,000. The cost is bounded by the preset, never by the number of keys or
holders.

Shared money leaves only through `payFromBudget`, which only the fleet's own
voting controller can call, on an approved Pay proposal. The Cascade reserve, the
owed protocol share and the ledger's backing are out of a vote's reach. The only
ways USDC leaves a fleet are the protocol share sent to staking, the Accelerant
rebate, the Cascade repayment and income moved into the ledger, and a payment
the keys voted for with its matches. No token a fleet holds is ever swapped or
converted. Tokens that take a fee when they move, or rebase, are not supported.

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

A proposal is approved at any moment `yesVotes * 2 > FLEET.totalMinted()`: yes
must be more than half of all the keys sold so far, so a silent key counts
against it. The test is live, so a later sale can take an approved proposal back
to open. `state(proposalId)` reports `Open`, `Approved` or `Executed`.
`execute(proposalId)` is permissionless and carries out an approved proposal
once. The proposal is marked carried out before the fleet is called, and any
revert inside the fleet or the factory undoes the mark with everything else, so a
failed attempt consumes nothing and the proposal stays open.

Proposing needs standing: the proposer names a key they own or are the delegate
of. Naming a key is not a vote. There are three kinds:

- `Decision`: `proposeDecision(tokenId, text, digest)`. Records agreement and
  has no on-chain effect beyond `DecisionRecorded`. The text is emitted in
  `ProposalCreated` and stored nowhere; the optional digest pins an exact
  artifact or commit.
- `Autolaunch`: `proposeAutolaunch(tokenId, envelope)`, described under
  Autolaunch below.
- `Pay`: `proposePay(tokenId, asset, amount, recipient, text, digest)`. The
  recipient may not be zero, the fleet, the controller or the ledger. A payment
  may be proposed at any time, before or after a launch.

Every payment is matched. When a Pay is carried out, the fleet computes
`share = ceil(amount / yesVotes)` and `matched = share * (keysSold - yesVotes)`,
and requires `amount + matched` to fit in the asset's shared money, or it reverts
with `AboveYesShare` and the proposal stays open for later. The recipient
receives exactly `amount`, `matched` moves to the voting controller, and
`BudgetPaid(asset, recipient, amount, share, matched)` records it. A payment
therefore spends at most the yes keys' share of that token. The controller
stores the share and the keys sold; `collect(proposalId, tokenIds)` then pays
`share` for each named key that was among those keys sold, did not vote yes and
has not collected, to whoever holds that key when it is collected. Anyone may
call `collect`, and the money goes only to the key holders.

This does not stop a majority. A majority of keys can approve a launch, a
decision or a payment the rest did not want. Matching means a payment only ever
spends the majority's own share; claim and reserve solvency and the owed
protocol share hold regardless of any vote.

Voting is the one call whose cost grows with what it is asked, and only with the
number of keys named. Ten Classic keys in one vote measured 285,300 gas and each
further key about 25,400, the same on a Fibonacci fleet; the suite asserts
ceilings of 342,000 and 31,000. A holder with more keys than a block can carry
splits the vote across calls. Creating and carrying out a proposal cost the same
on any size of fleet.

## Autolaunch

An `Autolaunch` proposal creates a launch through the pinned
`RegentsAutolaunchFactoryV2`, with the fleet itself as launcher and treasury.
The factory is fixed when the fleet is deployed. The strategy is never stored:
the fleet reads it from the factory on every call. Only minimal interfaces are
declared for either, so nothing of the factory's governance surface is reachable
from a fleet. [../docs/autolaunch-target.md](../docs/autolaunch-target.md)
describes the target.

The envelope carries the launched token's name, symbol, description, website and
image, the auction's floor price (`floorPriceQ96`, REGENT per token times
`2^96`), the keys' own minimum raise in REGENT (zero for none) and a digest of
the narrative behind the launch.
There is no treasury field and no expiry. The envelope is stored whole and never
edited; `keccak256(abi.encode(envelope))` is emitted in `AutolaunchProposed` and
recorded again on the fleet when it launches.

`proposeAutolaunch` refuses a fleet that has not sold its preset's launch
threshold (`LaunchNotYetEligible`), an empty metadata field or one over the
factory's byte cap, a floor or minimum the strategy's
`requiredRegentRaisedFor` refuses (a floor below the auction's lowest or off the
grid of a hundred bid ticks, or a minimum no auction could raise, with the
strategy's own errors), and a fleet whose launch has graduated. The caps are
read from the factory, and the floor and minimum are put to the strategy, in the
proposing call. A launch may be proposed while another is running, because it
can be carried out if that one fails.

Carrying it out calls `Keyfleet.executeAutolaunch(proposalId, openedBlock,
envelope)`, which only the fleet's controller may call. It first books the
current launch, then refuses with `LaunchAlreadyCreated` while an auction is
running or once a launch has graduated, and with `StaleLaunch` when the current
launch failed and the proposal opened in or before the block that launch was
created in. It calls the factory once and then checks the factory's own record:
the launch must name this fleet as launcher and treasury, carry the token,
auction and escrow the call returned, and map the token back to the same launch
id, or it reverts with `LaunchProvenanceMismatch`. The new launch replaces any
failed one in `launchRecord()`, and its token becomes the ledger's third income
token. The call moves no tokens and grants no allowance.

A launch is `NotCreated`, `AuctionCreated`, `Graduated` or `EconomicallyFailed`.
`syncLaunch()` is the permissionless way to read the strategy's verdict;
`recognizeSurplus`, `payFromBudget` and `executeAutolaunch` make the same booking
first. An auction that has ended but has not been migrated is still
`AuctionCreated`. Graduation records the splitter, the payment receiver, the
pool and the locked LP position and books the graduation REGENT. Graduation is
final; a failure lasts until another launch. `launchDistribution()` passes the
strategy's live record through for the app.

Executing an Autolaunch measured 1,458,480 gas against a mock factory, and the
suite asserts a ceiling of 1,750,000. Most of it is the mock's own writing; the
real factory deploys a token, an escrow and an auction and spends far more.

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
refuses a manifest whose `chainId` is not the chain it runs on; on Base, a USDC
other than `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, a REGENT other than
`0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`, a VRF coordinator other than
`0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` or a gas lane other than the 2 gwei
lane `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab`; on any
chain, a REGENT or coordinator that holds no code, an Autolaunch factory that
holds no code (a lab manifest may waive that, and the waiver is ignored on Base),
a gas lane or subscription the coordinator does not know, a zero trait table hash
and an unknown fleet name.

`script/RecordKeyfleets.s.sol` runs straight after, against the same chain,
because Forge's `run-latest.json` holds only the latest broadcast. It refuses a
transaction without a receipt or a failed receipt, applies the same manifest
refusals, reads the fleet back from the chain and refuses a preset other than the
named fleet's, any value that differs from the manifest, a fleet the subscription
does not list as a consumer and, on Base, a subscription the manifest's Safe does
not own. Only then does it write `deployments/<name>.<fleet>.deployed.json`, the
fleet's published manifest: addresses and code hashes, the deployment block, the
numeric bounds, the reference price, the fee basis points, the Autolaunch binding
with the factory's and strategy's code hashes, the randomness terms, the trait
table hash, the income tokens and the terms the release discloses.

All three scripts share `script/KeyfleetManifest.sol`, which reads
`deployments/base.json` and `deployments/anvil.json`. Their cores take and return
values, so the suite runs the real deployment and the real record against local
mocks without touching a file. [../docs/deployment.md](../docs/deployment.md) is
how to run each step and what each refuses.

`script/KeeperLab.s.sol` is no part of a release. It puts one Classic fleet, with
stand-in USDC, staking and VRF coordinator, on a plain local anvil for the
keeper's external test in `platform/`; [../docs/keeper.md](../docs/keeper.md)
says how.

## Checks

Run `make check-contracts` from the repository root to check formatting, build,
and run the preset, ledger, purchase, income, treasury, voting, Autolaunch,
reveal, trait-draw and deployment tests. Foundry must be installed; the compiler
may be downloaded on first use. Tests need no RPC, apart from the two in
`test/fork`, which skip themselves unless their environment is set:

- `test/fork/KeyfleetLaunchIncomeFork.t.sol` needs `KEYFLEET_FORK_RPC_URL`
  naming a chain with the Autolaunch v2 contracts deployed and
  `KEYFLEET_FORK_FACTORY` naming its factory. On a local fork it runs the whole
  path: the keys vote a launch at the default floor with a higher minimum, a
  bidder graduates it, the unused REGENT (at least a quarter of the raise) and
  the vested launched token become shared money, USDC and REGENT from the
  splitter reach the keys, keys claim, and a Pay vote spends shared money. Run
  it against your own Anvil fork of the v2 practice chain, never the practice
  chain itself:
  `anvil --port 58741 --fork-url http://127.0.0.1:58705 --prune-history --silent`,
  then `KEYFLEET_FORK_RPC_URL=http://127.0.0.1:58741
  KEYFLEET_FORK_FACTORY=0xcc0dF8493B348bFD7C58730A2c5e97b3A73aCb00 forge test
  --match-path test/fork/KeyfleetLaunchIncomeFork.t.sol -vv`.
- `test/fork/KeyfleetRevealBaseFork.t.sol` needs `BASE_RPC_URL` and runs a
  fleet against the real Chainlink coordinator on a fork of Base.

OpenZeppelin and forge-std are git submodules, so clone with submodules or run
`git submodule update --init`.

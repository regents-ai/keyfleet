# Contracts

A Foundry workspace pinned to Solidity 0.8.26 with OpenZeppelin 5.7.0 and
forge-std 1.9.7 vendored as git submodules under `contracts/lib`.

`KeyfleetAssetRegistry` is shared by fleets. Its constructor permanently binds
`REGENT_SAFE` and `BASE_USDC` to nonzero addresses supplied at construction. The
caller must supply the intended Safe contract and canonical Base USDC address;
the registry does not verify their identity or chain. The deployment scripts do:
on Base they refuse any USDC but `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. Neither address receives
implicit token approval.

Only calls from `REGENT_SAFE` can change the factory-wide or fleet-specific token
flags. Individual Safe owners have no direct authority. `isTokenAllowed(fleet,
token)` requires both flags and rejects zero addresses. Each setter emits its
scope, affected addresses, and new flag value, including repeated assignments.
Disabling one scope leaves the other scope unchanged.

This registry controls new deposit admission only. It holds no deposit accounting
or claim history and cannot transfer tokens or spend fleet funds. `Keyfleet`
consults it on every new external receipt, as described below, and a fleet's own
USDC address is checked against `BASE_USDC` when the fleet is deployed. There is
no administrator transfer and no upgrade path. The deployment script deploys one
registry for a release and sets no flag on it, so every admission decision that
has ever been taken was taken by the Safe.

`KeyfleetPresets` is a pure internal library and the single source of truth for
the supply, price, holding-limit and purchase-split arithmetic of the four
presets: `FibonacciSyndicate`, `FibonacciCascade`, `FleetTechClassic` and
`FleetTechAccelerant`. It has no storage, holds no tokens, and makes no external
calls. Every function is `internal pure` with checked arithmetic. `Keyfleet`
holds the state and calls into it; the library never calls back.

Keys are paid in USDC, and every price is in atomic USDC (six decimals) from
the reference price `Q_USDC`, which is 10,000,000: ten USDC. Both ladders are
computed iteratively from the first step, never as a closed-form power, and every
step rounds up:

- Fibonacci level price: level 1 costs `Q_USDC`, and each further level costs
  `ceilDiv(previous * 120, 100)`. `MAX_FIBONACCI_LEVEL` is 20.
- Accelerant primary price: the first mint costs `Q_USDC`, and each further mint
  costs `ceilDiv(previous * 105, 100)`. `MAX_ACCELERANT_KEYS` is 2000, so mint
  indexes run 0 through 1999. Only primary mints advance the price; secondary
  sales do not, so the caller must count primary mints when choosing a mint index.
- Fleet.Tech Classic: `CLASSIC_SUPPLY` is 144 and every primary key costs
  `Q_USDC`.

At those bounds the largest intermediate product stays far inside 256 bits, which
the tests assert directly at level 20 and at Accelerant index 1999.

Fibonacci level supplies are 2, 3, 5, 8, 13, ... through 17711 at level 20. Token
ids are 1-based and contiguous across levels, so `FIBONACCI_MAX_TOKEN_ID` is the
cumulative supply through level 20, 46365. The per-wallet holding limit is one key
for levels 1 through 7 and the level supply divided by 10, rounded down, from
level 8 up.

Purchase splits are stated in basis points of gross: `PROTOCOL_BPS` 500 to the
Regents treasury on every purchase, `REFERRAL_BPS` 1000 charged only when a
referrer is supplied, and `ACCELERANT_CAPITAL_BPS` 1000 on Accelerant purchases
that have a predecessor. Each fee is rounded down and the preset's main part
absorbs the dust, so the five parts always sum to exactly the gross amount.
Syndicate and Classic send the remainder to capital, Cascade sends it to the
level-completion reserve, an Accelerant purchase with a predecessor pays capital
its 10% and rebates the rest to the holder of the preceding key, and the first
Accelerant mint sends the remainder to capital. A gross amount of zero reverts.

`KeyfleetRewards` is the per-fleet reward ledger. One instance is deployed per
fleet and permanently bound to that fleet's address at construction. The fleet is
the only writer: it registers reward assets, enrolls keys into cohorts, allocates
backing tokens to a cohort, credits an address directly, and settles a key. The
ledger knows nothing about prices, levels, or deposit rules; the fleet decides
which cohort a key belongs to and therefore what it is eligible for.

Rewards are distributed through a cumulative index per asset and cohort, so an
allocation writes one index and never iterates over recipients. A key carries a
watermark into that index. Settlement converts the gap into a pull credit for the
address named by the fleet, and iterates only over the reward asset list, which
is bounded at `MAX_REWARD_ASSETS = 8` for the lifetime of the contract. The list
is append-only; nothing is ever removed, so historical settlement cannot be
changed by a later admission decision. Cohort ids run `0..31`
(`MAX_COHORTS = 32`).

Accrued rewards belong permanently to the address that earned them. The fleet
settles a key to its outgoing owner immediately before every ownership change,
and the incoming owner continues from the cohort's current index, so nothing
earned under a previous owner travels with the key. A newly enrolled key
snapshots the current index and earns nothing from earlier allocations.

Backing is reserved at allocation, never at withdrawal. `allocateToCohort` and
`credit` both require that the tokens are already sitting in this contract:
`balanceOf(this)` must cover `backed[asset]` plus the new amount, or the call
reverts. `backed` only ever falls when a claim pays out.

Indexes are scaled by `PRECISION = 1e27`. Two roundings are deliberate and
conservative. An allocation divides by the cohort size and truncates the scaled
index, and the whole allocated amount is still recorded as backed. Settlement
advances a key's watermark by exactly the whole units it credited rather than to
the full index, carrying the sub-unit remainder into the next settlement. A key's
carried fraction is therefore paid as soon as a later allocation pushes it over a
whole unit, and frequent settlement costs a holder nothing: the shortfall stays
below one atomic unit per key and asset at any moment instead of losing a
fraction on every settlement. Only the sliver lost when the scaled index itself is
truncated stays in the contract for good. It remains counted as backed, is never
claimable and is never treated as free balance.

Claims are per asset and pay at most one outgoing transfer, so a reward token
that reverts on transfer can only block itself; the other assets remain claimable
and the blocked credit is preserved. A claim settles the keys it is given, which
must be owned by the caller, then pays the caller's whole credit balance for that
asset to the caller or to a recipient the caller names. Transfers use
OpenZeppelin `SafeERC20` and `claim` is guarded by OpenZeppelin
`ReentrancyGuard`. `claimable` agrees with `claim` for distinct token ids: it
rejects unknown assets, keys the account does not own and unenrolled keys exactly
as `claim` does, and returns zero where `claim` reverts with nothing to pay. A
repeated id is counted again by the view but settles once in `claim`, so callers
pass each id at most once.

Worst-case settlement, with all eight reward assets registered, a pending accrual
on every one and every per-key storage slot cold and moving from zero, measured
369,212 gas. The suite asserts a ceiling of 443,000, which is the measurement
plus twenty percent, and that is the figure the deployment manifest should quote.

The ledger deliberately has no administrator, no upgrade path, no pause, and no
withdrawal other than a claim, including for the retained remainder. It does not
transfer keys, read prices or levels, decide cohort membership, or enforce
deposit admission; those belong to the fleet and to `KeyfleetAssetRegistry`.
Reward assets cannot be removed or replaced and keys cannot be unenrolled or
moved between cohorts.

Two obligations sit with the fleet. `settleKey` reverts for a key that was never
enrolled, so the fleet must enroll every key when it mints it, before the first
transfer. The backing check compares `balanceOf(this)` with the amount recorded
as backed, which assumes reward assets are ordinary non-rebasing tokens whose
balances only change through transfers; `KeyfleetAssetRegistry` is where that
admission decision is made.

`Keyfleet` is one fleet: its keys, its primary purchases and the USDC
accounting behind them. It is an OpenZeppelin ERC721 with 1-based, contiguous
token ids and no enumerable or per-token URI storage. `tokenURI` is a fixed base
string plus the id; the base is set once at construction, has no setter, and is
readable before any key exists through `baseTokenURI()`. The
constructor takes the preset, USDC, the Regents
treasury, the shared asset registry, the Regents revenue staking contract, the
pinned Autolaunch factory, the voting window in seconds, and one `Metadata` value
holding the name, symbol and metadata base. It rejects any zero address, a voting window outside the
controller's bounds of one hour to thirty days, a USDC address that is not the
`BASE_USDC` the registry is bound to, so a token other than the registry's can
never be wired in and can never take the staking fee route, and a USDC that does
not report six decimals, the unit every price is written in. That the registry's
USDC is Base USDC itself is the deployment scripts' check, made on Base. It then deploys the fleet's own `KeyfleetRewards` and
registers USDC as its first reward asset, and its own `KeyfleetVotes`, so a
fleet, its ledger and its vote are born bound to each other and no deployment
step can point a fleet at someone else's. Everything the constructor sets is
immutable.

`purchase(receiver, referrer, maxPrice, deadline)` is the only way a primary key
is created. A zero receiver mints to the caller; a referrer may be any address,
including the caller, and a zero referrer means no referral deduction at all. The
deadline, the supply bound and the quoted price against `maxPrice` are all
checked before any token moves, because the displayed next slot is not reserved
and an earlier purchase can move a Fibonacci level or step the Accelerant price.
`maxPrice` is atomic USDC. Payment is USDC and nothing else. No balance-delta
check is taken around the pull: USDC is fixed at deployment, and on Base the
deployment scripts pin it to Base USDC, which is non-rebasing and without a
transfer fee, so the amount transferred is the amount credited by construction. USDC can be paused and
can block an address; while it is paused, or for a blocked buyer, fleet or
treasury, purchases revert, and that is accepted. Every preset price is at least
ten USDC, so the 10% referral share, which the ledger refuses to record as zero,
always exists.

Within a purchase the order is fixed: the buyer's USDC is pulled, the split is
taken from `KeyfleetPresets`, the treasury's share is transferred out
immediately, the referral is moved into the ledger and credited, the preset's own
bookkeeping runs, the key is enrolled in the ledger, the key is minted, and only
then can a Cascade level complete. Every reward obligation is recorded in the
same transaction that moves the tokens backing it into the ledger, and nothing is
ever pushed to a list of recipients. `purchase` is guarded by OpenZeppelin
`ReentrancyGuard`, so a receiver contract cannot buy again from inside
`onERC721Received`. Enrollment happens before the mint, so a router or custody
wrapper may forward a key straight on from inside that hook: the forwarded key
settles a freshly enrolled key, which owes nothing, and simply moves. Anything
the purchase does after the mint, including a Cascade level completion, sees the
forwarded holder.

Syndicate and Classic send the whole post-fee amount to free capital. Cascade
sends it to the completion reserve instead and records the gross paid for that
level. Accelerant sends 10% of gross to capital and credits the rest to the
current holder of the preceding key, read before the mint, so a secondary sale
before the next primary mint moves the rebate with the key; the first Accelerant
mint has no predecessor and sends everything post-fee to capital. Accelerant is
also the one preset that persists a price: `currentPrice` starts at `Q_USDC` and
is stepped with `accelerantNextPrice` after each primary mint, so only primary
mints advance the ladder and secondary sales never do. The gross paid, the split,
`levelGrossPaid` and the Cascade repayment are all USDC.

A Cascade level completes in the transaction that mints its last key, once and
only once; resales can never reopen it. Level 1 has no predecessor, so its whole
reserve becomes free capital. From level 2 the reserve first repays the preceding
level's original gross mint cost, as far as it stretches, by moving that amount
into the ledger and allocating it to the preceding level's cohort, which means
whoever holds those keys at that moment. The remainder becomes free capital and
the reserve is emptied. There is no guaranteed repayment and no refund for an
unfinished level: repayment requires the next level to complete.

Working capital is `freeCapital`, keyed by asset: purchases write the USDC
entry and deposits write the entry of any admitted asset, USDC included, so
purchase capital and deposited USDC capital are one spendable figure. The Cascade
completion reserve is a separate USDC-only figure and is never spendable capital.
Reward backing is not counted here at all, because it lives in the ledger. The
invariant is that the fleet's balance of an asset is at least what it has booked
for that asset, which is `freeCapital[asset]` plus, for USDC, `cascadeReserve`. Anyone
may send tokens to the fleet, and anything above those buckets is ignored until
it is recognized, because a bare transfer is not capital. The purchase suite
asserts the tighter form, exact equality, after every step of randomized purchase
and transfer sequences on all four presets, because nothing in it donates.

Before any ownership change the fleet settles the key to its outgoing owner, so
accrued rewards stay with the address that earned them and the incoming owner
continues from the cohort's current index. Only that key is settled, because the
ledger's accruals are per key. Each key also carries an ownership epoch: 1 at
mint and one more on every transfer, including a key returning to an earlier
owner, which therefore carries a strictly higher epoch than it did before. There
is no burn function, so a key's epoch only ever rises.

The two Fibonacci presets apply the per-wallet holding limit from
`KeyfleetPresets` on a mint and on an incoming transfer alike: one key per wallet
in levels 1 through 7, then a tenth of the level supply from level 8, which is
five of level 8's fifty-five keys. Selling frees the slot again. `levelOf` and
`holdingLimit` report the library's answers and revert on the two Fleet.Tech
presets, which have no levels and no per-wallet cap; Classic still has its 144
seats. `nextPrice` and `quote(hasReferrer)` state the USDC price and the exact
split the next purchase would perform, and both revert once the fleet is sold out;
`remainingSupply` counts down to zero.

Purchases were measured paying real Base USDC on an anvil fork of Base at block
51,660,773, in total gas per transaction, the 21,000 base cost included: the
first referred Syndicate purchase 380,413; the first unreferred Cascade purchase
306,442; the referred Cascade purchase that completes level 1 344,464; a referred
Classic purchase 339,962; and Accelerant mints 1, 2 (referred) and 3 at 266,155,
315,418 and 228,158. The most expensive primary purchase is the first referred
purchase on a fresh fleet, because every accounting slot it touches is written
from zero, and among the presets Cascade's is the dearest. The suite measures that
purchase against a plain ERC-20 standing in for USDC, with every account starting
cold, at 345,059 gas in execution, and asserts a ceiling of 414,000, the
measurement plus twenty percent. That ceiling is a regression bound on the fleet's
own work, not a figure to quote: Base USDC is a proxy and costs more per transfer
than the stand-in, so the fork figures above are the ones to publish.

Non-key money arrives by one of two named paths, and both take the same 2%
external-receipt fee before anything is booked. `depositCapital(asset, amount)`
turns the net into free working capital. `depositRevenue(asset, amount,
paymentRef)` turns the net into member reward backing and records the payer's
reference in the event. Only a new external receipt is charged: moving tokens
into the ledger, settling a key and paying a claim are internal movements and are
never charged again, and a primary purchase keeps its own 5% and 10% rules
instead. The fee is a flat `DEPOSIT_FEE_BPS` of 200 basis points of the accepted
gross, rounded down, so a receipt below fifty atomic units pays nothing and is
kept whole rather than rounded up against the payer.

Both paths, and surplus recognition, first ask `KeyfleetAssetRegistry` whether
the asset is allowed for this fleet, before anything moves. Disabling an asset
afterwards stops new receipts and nothing else: booked capital stays booked,
recorded reward indexes and pending claims are untouched, and the asset stays on
the ledger's append-only historical list so past earnings still settle and pay
out. Current deposit eligibility and historical claim eligibility are separate
questions, and only the registry answers the first one. No balance-delta check is
taken around a deposit pull, for the same reason as on a purchase: rejecting
fee-on-transfer, rebasing and hostile-callback tokens is the registry's job, done
once at admission, not a general token framework inside the fleet.

USDC's fee is registered revenue, not a plain transfer to a staking address. The
fleet approves the staking contract for exactly the fee with `forceApprove` and
calls `depositUSDC(fee, SOURCE_TAG, paymentRef)`, where `SOURCE_TAG` is
`keccak256("keyfleet")` and the payment reference is the payer's own, or zero for
a capital deposit or a recognized surplus. The call must report receiving the
whole fee back, and the approval it was given must be spent down to nothing;
either check failing reverts with `FeeRegistrationFailed`. The second check is
what stops a staking contract that credits the fee without ever pulling it, which
would otherwise leave the tokens in the fleet under a live approval for a later
call to recognize as surplus and book twice. A paused staking contract likewise
reverts the whole deposit, which is deliberate: there is no deferred-fee
subsystem and no fallback that would let a bare transfer be labelled registered
revenue. Only the fleet's USDC, checked against the registry at construction,
takes this route. Every other admitted asset pays its fee to the
Regents treasury in that same asset, which must not be the fleet itself: a fee
paid back to the fleet would simply be recognized as surplus again, and the
deployment manifest is where that address is fixed.
`FeeCharged` reports the gross, the fee and the destination on every receipt,
including the ones whose fee floored to zero.

A revenue deposit moves the whole net amount into the ledger and allocates it in
the same transaction, so an obligation is never recorded without the tokens
behind it, and allocation writes one index per eligible cohort rather than
iterating over keys or holders. Classic and Accelerant have a single cohort, so
the net is shared equally by every key minted at that moment. The two Fibonacci
presets share it equally across the fully minted levels first and then equally
per key inside each level, which is why a small early level earns more per key
than a large later one. A level counts as complete when its last token id has
been minted, derived from the mint count alone, so no extra bookkeeping can drift
out of step with it; `completedLevels()` reports the figure and refuses to answer
for the two Fleet.Tech presets. An unfinished level earns nothing, and a key
minted later starts at the index the deposit left behind. The remainder of the
equal split across levels goes to the last completed level, so the whole net
amount is backed and nothing is stranded in the fleet. At most twenty levels can
ever be eligible. Revenue is refused with `NoEligibleKeys` when no key is minted
or no Fibonacci level is complete; `depositCapital` stays available in that
state. A net amount smaller than the number of eligible levels cannot be divided
and is refused by the ledger, which binds below twenty atomic units.

The first revenue deposit of an asset registers it in the ledger. Counting from
USDC, which the constructor registers, a fleet can therefore take revenue in
seven further assets, and the ninth is refused outright by the ledger's lifetime
bound: that fleet can never take revenue in it, though it can still take it as
capital, which registers nothing.

Tokens that simply arrive, with no deposit call behind them, create nothing.
`recognizeSurplus(asset)` is the permissionless way to reconcile them: it is
admission-checked like any other receipt, works from the fleet's balance minus
what it has already recorded a purpose for, charges the same 2%, and books the
net as free working capital. What it treats as accounted is `freeCapital[asset]`
plus, for USDC, the Cascade completion reserve, so an incomplete level's
reserve can never be turned into spendable capital by anyone. Reward backing sits
in the ledger and is not part of this balance at all, so no recorded liability
can be reclassified. `accountedBalance(asset)` and `surplus(asset)` report the
two figures, and a fully accounted balance reverts with `NoSurplus`. Unknown
assets remain unsupported: nothing here can turn one into capital.

All three entry points are guarded by OpenZeppelin `ReentrancyGuard`, so a token
that calls back into the fleet from inside a transfer cannot book a receipt twice
or read a half-updated balance. The suite proves that with a token that re-enters
each of them in turn, and holds the general invariant by fuzzing receipts,
revenue and bare transfers against `balanceOf(fleet) >= accountedBalance(asset)`.

The worst case of a revenue deposit is a Fibonacci fleet with all twenty levels
complete taking an asset it has never seen before, with every slot it touches
cold: twenty cohort indexes move and the asset is registered in the ledger. That
measured 788,159 gas in execution. The suite asserts a ceiling of 946,000, which
is the measurement plus twenty percent, and that is the execution figure the
deployment manifest should quote, with the 21,000 base transaction cost on top of
it. The cost is bounded by the preset, not by how many keys or holders the fleet
has, so revenue can always be paid in however large the fleet gets. The figure is
measured against a plain ERC-20; a proxied token such as the real Base USDC adds
its own delegatecall overhead to each of the two transfers a deposit makes, and a
USDC deposit adds the staking contract's registration cost on top of that.

`KeyfleetVotes` is the one collective decision, and there is only one. The fleet
deploys it in its own constructor, exactly as it does the reward ledger, so a
fleet and its controller are born bound to each other. The constructor takes the
window in seconds and accepts one hour to thirty days, `MIN_VOTING_WINDOW` to
`MAX_VOTING_WINDOW`, rejecting anything outside that with
`VotingWindowOutOfBounds`: a window too short to notice and a window long enough
to outlive the question are both deployment mistakes, and neither can be
corrected afterwards. Production is 24 hours and a testnet fleet uses a shorter
one, which the app should label from `VOTES.VOTING_WINDOW()`.
There is no setter, no councils or moderators, no rule amendment, no quorum
tuning, no pause and no cancellation.

Weight comes from the preset and nothing else. A Fleet.Tech key is one whole
vote, `WEIGHT_SCALE = 1e18`. A Fibonacci key is `WEIGHT_SCALE` divided by its
level supply, rounded down, so a level carries one vote shared equally by its
keys: half a vote for each of level 1's two keys, a seventeen-thousandth for each
of level 20's. The floor is the fixed-precision approximation the product asks
for; it loses less than one atomic unit per key in a level, so all twenty levels
together are worth a shade under twenty votes rather than exactly twenty.

A proposal freezes everything it will be judged by in the transaction that
creates it. Its eligible set is the token ids `1..snapshotMinted`, where
`snapshotMinted` is the fleet's minted count at that moment, and its total weight
is computed there and then by walking at most twenty levels and never a single
key. A key minted afterwards is outside that snapshot: it cannot vote on that
proposal and was never counted in the weight it has to clear. Proposing needs
standing, so the proposer names an eligible key and must be its owner or that
owner's registered delegate; naming a key is not a vote and leaves it free to
vote.

A key votes at most once per proposal. Transfers move the right to vote a key
that has not voted yet, and can never recharge one that has, so neither a resale
nor a later mint can produce a second vote. A vote may be cast by the key's
current owner or by the one address that owner registered with
`setVotingDelegate(address)`, which zero clears; an attached chat credential
gets nothing from this, because financial authority is registered on chain and
only there. A batch of keys is voted whole or not at all.

There are three kinds. A `Decision` records agreement and has no
automatic external effect; its text is carried in the creation event and stored
nowhere, and an optional digest pins the exact artifact or commit. A
`TransferCapital` names an asset, a nonzero amount and a nonzero recipient, and
nothing is checked against the fleet's balance at creation, because a proposal
the free capital cannot cover is meant to fail at execution rather than at
proposal time. An `Autolaunch` carries the exact launch the fleet would create,
and is described below. There are no arbitrary calls, no arbitrary approvals and
no way to add a fourth kind.

Voting is open strictly before `closesAt` and execution strictly from it, so the
two never overlap. A proposal passes only if `yesWeight * 2 > totalWeight`: YES
must exceed half of the whole eligible snapshot weight, so a key that stayed
silent counts against it exactly as a NO would, and exactly half fails.
`state(proposalId)` reports Active, Defeated, Passed or Executed. Execution is
permissionless, because the result is the vote's and not the caller's, and the
proposal is marked executed before the fleet is called so a token that calls back
cannot execute it twice. `execute` is guarded by OpenZeppelin `ReentrancyGuard`.

`Keyfleet.transferCapital(asset, amount, recipient)` is what a passed
`TransferCapital` calls, and the fleet's own controller is its only permitted
caller. It spends free working capital and nothing else: the Cascade completion
reserve is a separate figure this path never reads, and reward backing does not
sit in the fleet at all, so no vote can borrow an incomplete level's reserve or
withdraw a member's claim. The shortfall is checked explicitly and reverts with
`InsufficientFreeCapital`, naming the asset, the amount asked for and the amount
available, rather than leaving it to a bare arithmetic panic. That revert rolls
the execution mark back with it, so a proposal the capital could not cover stays
executable and pays out later once the capital exists. Admission is not
rechecked here, because the asset is one the fleet already booked capital in and
disabling deposits in an asset does not freeze capital already booked in it.
`CapitalTransferred` reports every payout.

This deliberately does not solve a majority takeover. A majority of snapshot
weight can authorize a harmful free-capital transfer, and no hidden creator
signer is introduced to disguise that. What is protected regardless of any vote
is claim and reserve solvency, which the suite demonstrates directly against both
buckets.

Two calls cost more than a flat amount, and neither of them grows with how many
keys the fleet has sold. Creating a proposal grows with the preset's twenty
levels: the worst case is a Fibonacci fleet at the level-20 ceiling with every
slot it touches cold, which measured 185,902 gas in execution, while the same
call on a fleet holding two keys in a single level measured 146,494, so the other
nineteen levels cost about two thousand gas each. The suite asserts a ceiling of
223,000, which is the measurement plus twenty percent, and that is the execution
figure the deployment manifest should quote, with the 21,000 base transaction
cost on top of it. Voting grows with how many keys the caller names in the one
call, at about 25,000 gas a key, almost all of it the one-vote-per-key record and
the ownership read behind it; a Fibonacci fleet, which also looks each key's
level up, came out at 25,800. Ten keys in one vote measured 271,298 gas, so a
holder with more keys than one block can comfortably carry simply splits the vote
across several calls, which the one-vote-per-key rule makes safe to do in any
order. Nothing else in the controller depends on the size of the fleet: executing
a proposal costs the same on a fleet of two keys and one at the ceiling.

The third kind of proposal is `Autolaunch`: the one launch a fleet may create
through the pinned `RegentsAutolaunchFactoryV1`, with the fleet itself as both
the recorded launcher and the treasury. The factory address is fixed when the
fleet is deployed and there is no setter. The strategy is never stored: the fleet
reads it from the factory on every call, so a fleet can never disagree with its
factory about which strategy is canonical. Only two minimal interfaces are
declared for either of them, copied field for field from the frozen ABI, so
nothing of the factory's governance surface or the strategy's writing surface is
reachable from a fleet.

Any fleet may propose an Autolaunch as soon as it has a key to propose with. The
vote is the only gate in front of it: there is no level requirement, no
separate opening step and no administrator who has to agree first.

A proposal carries a launch envelope: the SUBJECT's name, symbol, description,
website and image, the required REGENT raise, a digest of the narrative behind
the launch, and an execution expiry. There is deliberately no treasury field.
The fleet passes `address(this)` and no proposal can name anyone else. The chain,
the factory, the start block, the auction length, the supply split and the pool
settings are not in the envelope either, because the factory and the strategy fix
all of them and presenting them as choices would be a promise the vote could not
keep. The envelope is stored whole, is never edited, and any change to it is a
new proposal. `keccak256(abi.encode(envelope))` is emitted when the proposal is
created and recorded again on the fleet when it executes, so what was approved
and what was launched can be compared byte for byte.

Everything that would make the approved call impossible on its own terms is
checked when the proposal is made, so the keys are never asked to vote on a
launch that could never happen: the five strings must be nonempty and within the
factory's byte caps, which are byte caps and not character caps; the raise must be
positive and no larger than the largest raise an auction can ever settle on; the
expiry must fall after the vote closes; and the fleet must not have created a
launch already. The factory and the strategy are the authority on those caps and
on that ceiling, and the controller asks them for the figures in the proposing
call rather than keeping a copy of them, so a fleet can never judge an envelope by
a stale number and refuse a launch the real target would have taken. Both check
their own rules again on the call itself. Nothing about the factory's own state is
predicted at proposal time, because it is not the fleet's to predict.

Execution goes through `Keyfleet.executeAutolaunch(proposalId, envelope)`, a
typed entry point whose only permitted caller is the fleet's own controller.
There is no `execute(target, calldata)` anywhere. It rechecks the launch state
and the expiry, calls the factory once, and then believes only the factory's own
record: the launch the factory recorded must name this fleet as launcher and as
treasury and must carry the same SUBJECT, auction and escrow the call returned,
and the factory must map that SUBJECT back to the same launch id. Anything else
reverts with `LaunchProvenanceMismatch` and nothing is written down. A returned
address, a submitted token, an event or a backend answer is never taken as proof
of a launch. The record also carries the proposal that authorized the launch, so
the authorising vote can be read straight off the fleet without replaying an
event. The call moves no tokens and grants no allowance: the factory charges gas
and nothing else.

A revert anywhere in that path — a paused factory, a treasury the factory
refuses, a raise the strategy refuses, an expired envelope, a launch that already
exists — reverts the controller's execution with it, including the mark that the
proposal executed. The attempt consumes nothing, and a proposal that failed
against a closed factory stays executable and lands unchanged once the factory is
open, as long as its envelope has not expired. One created launch per fleet is
the rule, and it holds from both ends: a second proposal is refused outright once
a launch exists, and a second proposal made earlier cannot execute afterwards.

Creation is not graduation. The fleet tracks `NotCreated`, `AuctionCreated`,
`Graduated` and `EconomicallyFailed`, and `syncLaunch()` is the permissionless
way to move between them. It reads the strategy's own lifecycle for the recorded
auction and copies nothing else. An auction that has ended but has not been
migrated is still `Active` on the strategy, which is deliberately not treated as
failure: the sync leaves the state alone and emits nothing until the strategy
settles. Graduation additionally records the splitter, the canonical receiver,
the pool and the locked LP position. A terminal state is terminal, and a later
sync reverts with `LaunchSettled` rather than churning. A sync can never replace
the recorded SUBJECT, auction or escrow, redirect the treasury, admit an asset
for deposits or authorize a second launch. `launchRecord()` reports what the
fleet stored and `launchDistribution()` passes the strategy's live record
straight through for the app to read.

Deposit admission is untouched by all of this and defaults off. A launched
SUBJECT is an ordinary token to the fleet until the Regents Safe admits it in the
shared registry, exactly like any other asset.

**Two separate 2% deductions, and the app must say so.** Autolaunch's own
splitter skims 2% of the revenue it recognizes before it pays the fleet, and
Keyfleet charges its own 2% on the new external receipt when that payout is
deposited into the fleet. They are two different charges, taken by two different
contracts, for two different things, and they compose: money arriving through
both systems is reduced twice. The app must present them as two deductions and
must never describe the pair as a single 2% charge. Nor does a gross REGENT raise
mean spendable USDC; the actual liquidity, vesting and treasury outcomes are read
from the strategy rather than inferred from the raise.

Executing an Autolaunch measured 740,178 gas against a mock factory, and the
suite asserts a ceiling of 889,000, which is the measurement plus twenty percent
rounded up to the nearest thousand. That
figure is a regression bound on this side of the call and not a prediction: most
of it is the mock's own writing, and the real factory deploys a token, an escrow
and an auction and spends far more.

No token a fleet holds is ever swapped or
converted. The fleet has no administrator, no upgrade path, no pause and no
burn: the only ways tokens leave it are the treasury share of a purchase, the
deposit fee, the referral, Accelerant rebate and Cascade repayment paid into the
ledger, the revenue backing moved into the ledger, and a capital transfer the
keys have voted for. An Autolaunch moves nothing out at all.

`KeyfleetDirectory` names the four fleets of one release and does nothing else.
It deploys nothing: `Keyfleet` initcode is 37,806 bytes, so a contract carrying
a `new Keyfleet` would exceed the 24,576-byte runtime limit and a constructor
deploying all four would exceed the 49,152-byte initcode limit. The script
deploys the fleets and hands them to the directory, whose constructor is its
only check: each slot must hold the preset that belongs to it — Syndicate,
Cascade, Classic, Accelerant, in that order — and all four must share the same
treasury, asset registry, staking contract, Autolaunch factory and voting
window, or it reverts with the slot that did not fit. USDC needs no
comparison of its own: a fleet refuses any USDC but its registry's, and the
registry is compared. `fleets()` and `isFleet(address)` are the whole of its
surface. It has no owner, no setter and no upgrade path, holds no authority over
any fleet, and a different set of fleets means a different directory. The app
seeds from this one address, and a later factory that reads a fleet's public
immutables learns exactly what this constructor learned.

A release is deployed in two steps. `script/DeployKeyfleets.s.sol` deploys the
shared registry when the manifest does not name one, then the four fleets, then
the directory, and writes nothing: Forge simulates a script in full before it
broadcasts, so any file this step wrote would also be written by a dry run or a
broadcast that failed partway. It refuses a manifest whose `chainId` is not the
chain it is running on; on Base, a USDC other than Base USDC
`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` or a REGENT other than Base REGENT
`0x6f89bcA4eA5931EdFCB09786267b251DeE752b07`; on any chain, a REGENT address that
holds no code; and an Autolaunch factory address that holds no code — a manifest
may waive that for a lab, and the waiver is ignored on Base. It sets no
allowlist flag and moves no token: admitting USDC and REGENT is the Safe's own
transaction afterwards.

`script/RecordKeyfleets.s.sol` runs after the broadcast, against the same chain.
It reads Forge's broadcast log, refuses a transaction without a receipt or a
receipt that failed, applies the same manifest refusals as the deployment step,
takes the directory from the broadcast, and reads the release back from the chain
through that directory, refusing any value that differs from the manifest. Only then does it write
`deployments/<name>.deployed.json`, the published deployment manifest the app and
the product copy are seeded from: addresses, the deployment block, the numeric
bounds, the ten-USDC reference price, the fee basis points, the fixed vote window, the Autolaunch binding with
the code hashes of the factory and strategy, the asset flags awaiting the Safe,
and the terms the release discloses. Addresses and fleet values come from the
chain; the supply and split constants come from the `KeyfleetPresets` the script
was compiled with, and the runtime code hash of the directory and of each fleet
is recorded so they can be checked against the deployed code.

Both scripts share `script/KeyfleetManifest.sol`, which reads the inputs
`deployments/base.json` and `deployments/anvil.json`, one per chain. Their cores —
`deploy`, `parseManifest`, `parseBroadcast` and `record` — take and return
values, so the suite runs the real deployment and the real record against local
mocks without reading or writing a file. `docs/deployment.md` is how to run both
steps, what each refuses, and what the Safe does next.

Run `make check-contracts` from the repository root to check formatting, build,
and run the focused authorization, admission, preset-arithmetic, reward-ledger,
fleet-purchase, deposit-and-surplus, voting, Autolaunch, fleet-directory and
deployment tests. Foundry must be installed; the compiler may be downloaded on
first use. Tests require no RPC. OpenZeppelin 5.7.0 and forge-std 1.9.7 are
vendored as git submodules under `contracts/lib`, so clone with submodules or
run `git submodule update --init`.

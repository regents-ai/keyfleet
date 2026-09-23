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
the supply, price, holding-limit, purchase-split and launch-threshold arithmetic
of the four presets: `FibonacciSyndicate`, `FibonacciCascade`, `FleetTechClassic`
and `FleetTechAccelerant`. It has no storage, holds no tokens, and makes no external
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

Purchase splits are stated in basis points of gross: `PROTOCOL_BPS` 500 for
the Regents staking contract on every purchase, `REFERRAL_BPS` 1000 charged only when a
referrer is supplied, and `ACCELERANT_CAPITAL_BPS` 1000 on Accelerant purchases
that have a predecessor. Each fee is rounded down and the preset's main part
absorbs the dust, so the five parts always sum to exactly the gross amount.
Syndicate and Classic send the remainder to capital, Cascade sends it to the
level-completion reserve, an Accelerant purchase with a predecessor pays capital
its 10% and rebates the rest to the holder of the preceding key, and the first
Accelerant mint sends the remainder to capital. A gross amount of zero reverts.
The product spec (§63) sent the 5% protocol share to the Regents treasury; the
founder's decision of 22 September 2026 sends it to the Regents staking contract
instead, and that decision is what the fleet implements.

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
can block an address; while it is paused, or for a blocked buyer or fleet,
purchases revert, and that is accepted. Every preset price is at least
ten USDC, so the 10% referral share, which the ledger refuses to record as zero,
always exists.

Within a purchase the order is fixed: the buyer's USDC is pulled, the split is
taken from `KeyfleetPresets`, the stakers' share is added to
`protocolShareOwed`, the referral is moved into the ledger and credited, the preset's own
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

The 5% protocol share of every purchase is registered as revenue with the
Regents staking contract, which credits REGENT stakers their staked share and
keeps the rest as treasury residual. A purchase only sets it aside: it adds the share to `protocolShareOwed` and never
calls the staking contract. `sendProtocolShare()` is how it leaves. Anyone may
call it at any time, with no threshold and no timer, and it always sends the
whole owed amount through the same registration a USDC deposit fee uses:
`depositUSDC(amount, SOURCE_TAG, PROTOCOL_SHARE_REF)`, where
`PROTOCOL_SHARE_REF` is `keccak256("keyfleet.protocol-share")`, with the same
two checks described below. It emits `ProtocolShareSent` with the caller and the
amount, and reverts with `ZeroAmount` when nothing is owed. The Regents staking
contract rejects `depositUSDC` while it is paused, which is why the share is not
paid inside the purchase: a paused, under-reporting or non-pulling staking
contract reverts the send and leaves the whole amount owed, while purchases
carry on adding to it. The owed share is never free capital and never
surplus, and no vote can reach it.

Free capital is `freeCapital`, keyed by asset: purchases write the USDC
entry and deposits write the entry of any admitted asset, USDC included, so
purchase capital and deposited USDC capital are one figure. It is the fleet's
budget, and its one way out is a passed Pay vote once the launch has graduated or
failed, capped per asset for each thirty-day pay period as described under "After
the launch" below. Before the launch settles no call and no vote moves it. The Cascade
completion reserve and the owed protocol share are separate USDC-only figures and
are never free capital. Reward backing is not counted here at all, because
it lives in the ledger. The invariant is that the fleet's balance of an asset is
at least what it has booked for that asset, which is `freeCapital[asset]` plus,
for USDC, `cascadeReserve` and `protocolShareOwed`. Anyone
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
51,661,303, in total gas per transaction, the 21,000 base cost included: the
first referred Syndicate purchase 382,189; the first unreferred Cascade purchase
325,318; the referred Cascade purchase that completes level 1 343,740; a referred
Classic purchase 358,838; and Accelerant mints 1, 2 (referred) and 3 at 285,031,
314,694 and 247,034. A purchase made while nothing is owed to stakers, which is
the first purchase of a fleet and the first after each `sendProtocolShare`,
writes the owed share from zero and costs about 17,100 gas more than one made
while a share is already owed: a cold write from zero costs 22,100 and a cold
write of a slot already holding a value costs 5,000; a referred Classic purchase straight after a send
measured 239,138. The most expensive primary purchase is the first referred
purchase on a fresh fleet, because every accounting slot it touches is written
from zero, and among the presets Cascade's is the dearest. The suite measures that
purchase against a plain ERC-20 standing in for USDC and a stand-in randomness
coordinator whose request writes what the real one writes, with every account
starting cold, at 445,417 gas in execution, and asserts a ceiling of 535,000, the
measurement plus twenty percent rounded up to the nearest thousand. That ceiling
is a regression bound on the fleet's own work, not a figure to quote: Base USDC is
a proxy and costs more per transfer than the stand-in, so the fork figures above
are the ones to publish. They were taken before every purchase began asking for
its key's traits, which is described below. On a fork of Base, against the real
Chainlink coordinator, asking again for a key's traits measured 96,899 gas in
execution with everything cold, and a purchase now pays about that on top of the
figures above; they are to be measured again before they are published.

On the same fork, against the real Regents staking contract, `sendProtocolShare`
measured 121,915 gas in total the first time any fleet sent and 108,970 for each
fleet after that. The suite measures it against the mock staking contract at
217,710 gas in execution, most of it the mock's own bookkeeping, and asserts a
ceiling of 262,000 as a regression bound only.

Non-key money arrives by one of two named paths, and both take the same 2%
external-receipt fee before anything is booked. `depositCapital(asset, amount)`
turns the net into free capital. `depositRevenue(asset, amount,
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
either check failing reverts with `StakingRegistrationFailed`. The protocol-share
send goes through the same registration and the same two checks. The second check is
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
capital, which registers nothing. Anyone can use up a slot with a tiny revenue
deposit in any admitted asset, so the Regents Safe must never admit more than
seven assets besides USDC to one fleet. Once the launch has settled, income in a
ninth asset cannot be recognized at all, because the keys' part of it has nowhere
to go.

Tokens that simply arrive, with no deposit call behind them, create nothing.
`recognizeSurplus(asset)` is the permissionless way to reconcile them: it is
admission-checked like any other receipt, works from the fleet's balance minus
what it has already recorded a purpose for, and charges the same 2%. Until the
launch has graduated or failed it books the whole net as free capital and emits
`SurplusRecognized`; after that it splits the net between the budget and the
keys, as described under "After the launch" below. What it treats as accounted is `freeCapital[asset]`
plus, for USDC, the Cascade completion reserve and the owed protocol share, so
an incomplete level's reserve can never be turned into free capital by
anyone and the stakers' share can never be swept into it. Reward backing sits
in the ledger and is not part of this balance at all, so no recorded liability
can be reclassified. `accountedBalance(asset)` and `surplus(asset)` report the
two figures, and a fully accounted balance reverts with `NoSurplus`. Unknown
assets remain unsupported: nothing here can turn one into capital.

All three entry points, and the budget payment described below, are guarded by
OpenZeppelin `ReentrancyGuard`, so a token that calls back into the fleet from
inside a transfer cannot book a receipt twice or read a half-updated balance. The
suite proves that with a token that re-enters each of them in turn, and a paid
asset that calls back from inside a budget payment, and holds the general
invariant by fuzzing receipts, revenue and bare transfers against
`balanceOf(fleet) >= accountedBalance(asset)`.

The worst case of a revenue deposit is a Fibonacci fleet with all twenty levels
complete taking an asset it has never seen before, with every slot it touches
cold: twenty cohort indexes move and the asset is registered in the ledger. That
measured 788,080 gas in execution. The suite asserts a ceiling of 946,000, which
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

Every key is one vote, on every kind of proposal and every preset. A Fibonacci
level-1 key and a level-20 key count the same; the early keys' advantage is in
what they are paid, not in how they vote. `VoteCast` lists the keys a vote
counted, and `yesVotes` and `noVotes` on the proposal are key counts.

A proposal freezes everything it will be judged by in the transaction that
creates it. Its eligible set is the token ids `1..snapshotMinted`, where
`snapshotMinted` is the fleet's minted count at that moment, and that count is
also the number of votes it is measured against. A key minted afterwards is
outside that snapshot: it cannot vote on that proposal and was never counted in
what it has to clear. Proposing needs
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

There are three kinds, numbered in this order. A `Decision` (0) records
agreement and has no automatic external effect; its text is carried in the
creation event and stored nowhere, and an optional digest pins the exact
artifact or commit. An `Autolaunch` (1) carries the exact launch the fleet would
create, and is described below. A `Pay` (2) carries an asset, an amount and a
recipient, and pays that amount from the fleet's budget; it is described under
"After the launch" below. There are no arbitrary calls, no arbitrary approvals
and no way to add a fourth kind, and the only tokens a vote can move are the
budget's, within its cap.

Voting is open strictly before `closesAt` and execution strictly from it, so the
two never overlap. A proposal passes only if `yesVotes * 2 > snapshotMinted`: YES
must exceed half of all the keys in the snapshot, so a key that stayed silent
counts against it exactly as a NO would, and exactly half fails.
`state(proposalId)` reports Active, Defeated, Passed or Executed. Execution is
permissionless, because the result is the vote's and not the caller's, and the
proposal is marked executed before the fleet is called so a token that calls back
cannot execute it twice. `execute` is guarded by OpenZeppelin `ReentrancyGuard`.

This deliberately does not solve a majority takeover. A majority of keys can
approve a launch or a payment the rest of the fleet did not want, and no hidden
creator signer is introduced to disguise that. Anyone can buy a majority with
new keys; on a Fibonacci fleet at eighty-six keys that is roughly eighty-seven
keys from levels 8 and 9. What limits the damage is the pay cap and the pay
expiry: a majority can take at most a fifth of an asset's budget in each pay
period, which is up to about 36% within moments across a period boundary, and a
passed payment it leaves behind expires thirty days after its vote closes, so it
cannot be taken after those keys have been sold. What is protected
regardless of any vote is claim and reserve solvency and the stakers' owed
share, because no vote can reach any of them.

Only voting costs more than a flat amount, and it grows with how many keys the
caller names in the one call, never with how many the fleet has sold. Creating a
proposal records the minted count and nothing else, so it costs the same on a
fleet of two keys and one at the ceiling, and so does executing one. A vote costs
about 24,000 gas a key, almost all of it the one-vote-per-key record and the
ownership read behind it, and the preset makes no difference: a Classic key
measured 24,210 and a Fibonacci key 24,415. Ten keys in one vote measured 268,630
gas, and the suite asserts a ceiling of 290,000, so a holder with more keys than
one block can comfortably carry simply splits the vote across several calls,
which the one-vote-per-key rule makes safe to do in any order.

The second kind of proposal is `Autolaunch`: the one launch a fleet may create
through the pinned `RegentsAutolaunchFactoryV1`, with the fleet itself as both
the recorded launcher and the treasury. The factory address is fixed when the
fleet is deployed and there is no setter. The strategy is never stored: the fleet
reads it from the factory on every call, so a fleet can never disagree with its
factory about which strategy is canonical. Only two minimal interfaces are
declared for either of them, copied field for field from the frozen ABI, so
nothing of the factory's governance surface or the strategy's writing surface is
reachable from a fleet.

A fleet may propose its Autolaunch only once it has sold enough keys. A
Fibonacci fleet, Syndicate or Cascade, must have sold the last key of level 7,
which is key 86 (`KeyfleetPresets.FIBONACCI_AUTOLAUNCH_MIN_KEYS`); a Classic or
Accelerant fleet must have sold 100 keys
(`KeyfleetPresets.FLEET_TECH_AUTOLAUNCH_MIN_KEYS`). Anything earlier is refused
with `LaunchNotYetEligible(minted, required)` before the factory is asked
anything. Past that there is no separate opening step and no administrator who
has to agree first: the vote, one key one vote, decides.

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

**Two separate 2% deductions, and the app must say so.** Autolaunch keeps 2%
and pays SUBJECT stakers their part (and a payment link may pay its creator up to
2.5%). Keyfleet then keeps 2% of whatever reaches the fleet. Only after both is
the rest split 20% to the budget and 80% to the keys. SUBJECT released from the
vesting escrow and REGENT returned by the launch reach the fleet directly and
pay only the fleet's 2%. The app must present the two charges as two deductions
and must never describe the pair as a single 2% charge. Nor does a gross REGENT
raise mean spendable USDC; the actual liquidity, vesting and treasury outcomes
are read from the strategy rather than inferred from the raise.

Executing an Autolaunch measured 740,016 gas against a mock factory, and the
suite asserts a ceiling of 889,000, which is the measurement plus twenty percent
rounded up to the nearest thousand. That
figure is a regression bound on this side of the call and not a prediction: most
of it is the mock's own writing, and the real factory deploys a token, an escrow
and an auction and spends far more.

**After the launch.** Once `syncLaunch` has recorded the launch as `Graduated`
or `EconomicallyFailed` (`launchSettled()` reports it), income the fleet
recognizes is split by a fixed rule no vote can change. `recognizeSurplus(asset)`
takes the 2% fee from the gross, then `BUDGET_BPS` (2,000, a fifth) of the rest,
rounded down, becomes free capital, the budget, and the remainder goes to the
keys: it is moved into the ledger and allocated in the same transaction by the
exact rule a revenue deposit uses, equally across completed Fibonacci levels
and then equally per key within a level, or equally per key on Classic and
Accelerant. At eighty-six Fibonacci keys a level-1 key, one of two, receives
seventeen times what a level-7 key, one of thirty-four, receives; a Classic key
and an Accelerant key receive the same. `LaunchIncomeSplit(asset, caller, gross,
fee, toBudget, toKeys)` records it, and `gross == fee + toBudget + toKeys`
exactly. The keys' part follows the ledger's rules: an amount smaller than the
number of completed levels cannot be split equally and reverts with `ZeroAmount`,
leaving the surplus where it is until more arrives, and a ninth distinct reward
asset is refused, which is why the Safe admits at most seven besides USDC.

Only fully sold Fibonacci levels share income, and a level shares in everything
recognized after its last key sells, including income that had been waiting
before then. Whoever recognizes income therefore picks the moment the split is
taken: someone who buys the last key of a level and recognizes at once brings
that level into income that built up earlier. Regent runs a regular job that
releases vested SUBJECT and recognizes income promptly, so little waits between
one recognition and the next. Recognition first syncs a launch the strategy has settled but nobody has
synced yet, so income can never be booked the old way after the launch is over.
Anyone may call it, and nobody chooses where the money goes. The fleet never
swaps, sells or stakes what it receives; holders decide that for themselves.

The budget is spent only by a passed `Pay` proposal, made with
`proposePay(tokenId, asset, amount, recipient, text, digest)`, which is refused
with `LaunchNotSettled` before the launch has graduated or failed and with
`RecipientNotAllowed` when the recipient is zero, the fleet, its voting controller
or its ledger, where the money would be stuck for good or charged the fee again.
The text is the reason for the payment; like a Decision's, it is carried in
`ProposalCreated` and stored nowhere. `PayProposed(proposalId, asset, amount,
recipient, executionExpiry)` is emitted beside it, and `executionExpiry` is
`closesAt + PAY_EXECUTION_WINDOW`, thirty days after the vote closes. Execution calls
`Keyfleet.payFromBudget(asset, amount, recipient)`, whose only permitted caller
is the fleet's own controller, and which again requires a settled launch. Each
asset has its own pay period of `PAY_PERIOD`, thirty days. A period begins with
the first payment after the previous one ended, and its cap is `PAY_CAP_BPS`
(2,000, a fifth) of that asset's free capital measured at that first payment;
income recognized later in the period does not raise it. Payments accumulate
against the cap, and one that would take the period past it reverts at execution
with `PayCapExceeded(asset, amount, remaining)`, so several proposals passed side
by side can never together take more than the cap. The limit is per period, not a
rolling thirty days: a new period can open the second the last one ends, with a
fifth of what is left, so payments either side of that boundary can take up to
about 36% of an asset's budget within moments. A reverted payment consumes
nothing and the proposal stays executable until its expiry, so one over what is
left of the cap can still be paid once the next period opens. From the second
after `executionExpiry` it is refused with `ProposalExpired` and can never
execute. `payPeriod(asset)` reports the period's start, cap and amount spent,
and `BudgetPaid(asset, recipient, amount, periodStart, spentInPeriod)` records
each payment. Only free capital is reachable: the Cascade completion reserve, the
owed protocol share and the keys' reward backing are separate figures a payment
never touches. A failed launch unlocks the same rule, so a fleet whose launch
failed never has its own capital stranded.

No token a fleet holds is ever swapped or converted. The fleet has no
administrator, no upgrade path, no pause and no burn: the only ways tokens leave
it are the owed protocol share sent to the staking contract, the deposit fee, the
referral, Accelerant rebate and Cascade repayment paid into the ledger, the
revenue backing and the keys' share of launch income moved into the ledger, and a
budget payment the keys voted for. An Autolaunch moves nothing out at all.

Every key gets its traits from a random number that nobody, the team included,
can choose or see in advance. The number comes from Chainlink VRF v2.5, which
proves on chain that it was drawn fairly. Each purchase, as its last step, asks
the Chainlink coordinator for one random number: three blocks deep, with 100,000
gas for the answer, paid in ETH from one subscription the Regent Safe owns. A
purchase never waits for the answer and never fails because of the request: if
the coordinator refuses it, or the buyer sent too little gas for it, the key is
still sold and the fleet emits `RevealRequestFailed(tokenId)`. When the request
is accepted the fleet emits `RevealRequested(tokenId, requestId)` and records
when it asked, in `revealRequestedAt(tokenId)`.

The answer arrives in a later transaction from the coordinator, through
`rawFulfillRandomWords`, which refuses any other caller. The fleet does not
inherit Chainlink's consumer base contract; it checks the caller against its own
fixed `VRF_COORDINATOR`. The key's seed is

```
keccak256(abi.encode(TRAIT_SEED_TAG, block.chainid, address(fleet), tokenId, word))
```

with `TRAIT_SEED_TAG = keccak256("keyfleet.trait-seed")` and `word` the first
random word. It is stored in `revealSeed(tokenId)`, and the fleet emits
`KeyRevealed(tokenId, requestId, seed)` and ERC-4906 `MetadataUpdate(tokenId)`,
so marketplaces refresh the key. A seed is written once: the first answer wins,
and an answer for a key that already has a seed, for a request the fleet never
made, or with no words at all is ignored without reverting, because a reverted
answer is final and still charged to the subscription. The answer measured about
29,000 gas with everything cold, well inside the 100,000 it is given.
`supportsInterface` reports ERC-4906 (`0x49064906`).

If a key has no seed, anyone may ask again with `requestReveal(tokenId)`: at once
if no request for it was ever accepted, or once an hour has passed since the last
accepted one. There is no other way to give a key a seed.

The traits themselves are drawn off chain from the seed and a published trait
table. The table is one file: the file the art agent delivers, committed to the
repository at a path chosen then. `TRAIT_TABLE_HASH` is `keccak256` of that
file's bytes, exactly as committed, with nothing normalised or re-encoded first,
so anyone can hash the published file and compare. Every fleet takes the hash as
its own constructor argument, `traitTableHash`, so the table is fixed before the
first key is sold and cannot be changed after the seeds are known. A constructor
refuses a zero hash.

The draw rule, for a key with seed `seed`:

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
same golden results the site's tests pin, so the two copies cannot drift. The
table's file format is in `docs/deployment.md`.

Before a release is deployed the operator creates the subscription, funds it in
ETH, moves its ownership to the Regents Safe, and writes its id into the
manifest's `vrf` block and the trait table's hash into its `traitTableHash`. The
fleets are deployed with the coordinator, the subscription, the gas lane and the
trait table fixed; the Safe then adds each fleet to the subscription as a
consumer, and only after that does the record step accept the release. On Base
the record step also requires the subscription to be owned by the manifest's
Safe. Keys sold in between are sold without a request and can ask
again as soon as their fleet is added. The three Chainlink files the fleet uses
are copied unchanged into `src/vendor/chainlink`, with their source, commit and
checksums in the README beside them.

`KeyfleetDirectory` names the four fleets of one release and does nothing else.
It deploys nothing: `Keyfleet` initcode is 41,304 bytes and its runtime 21,865, so a contract carrying
a `new Keyfleet` would exceed the 24,576-byte runtime limit and a constructor
deploying all four would exceed the 49,152-byte initcode limit. The script
deploys the fleets and hands them to the directory, whose constructor is its
only check: each slot must hold the preset that belongs to it — Syndicate,
Cascade, Classic, Accelerant, in that order — and all four must share the same
treasury, asset registry, staking contract, Autolaunch factory, voting
window, randomness coordinator, subscription, gas lane and trait table hash, or
it reverts with the slot that did not fit. USDC needs no
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
may waive that for a lab, and the waiver is ignored on Base. It also refuses, on
Base, a VRF coordinator other than `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634`
or a gas lane other than the 2 gwei lane
`0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab`; on any
chain, a coordinator without code, a gas lane the coordinator does not know, a
subscription it does not know, and a zero trait table hash. It sets no
allowlist flag and moves no token: admitting USDC and REGENT is the Safe's own
transaction afterwards.

`script/RecordKeyfleets.s.sol` runs after the broadcast, against the same chain.
It reads Forge's broadcast log, refuses a transaction without a receipt or a
receipt that failed, applies the same manifest refusals as the deployment step,
takes the directory from the broadcast, and reads the release back from the chain
through that directory, refusing any value that differs from the manifest, any
fleet the subscription does not yet list as a consumer and, on Base, a
subscription the manifest's Safe does not own. Only then does it write
`deployments/<name>.deployed.json`, the published deployment manifest the app and
the product copy are seeded from: addresses, the deployment block, the numeric
bounds, the ten-USDC reference price, the fee basis points, the fixed vote window, the Autolaunch binding with
the code hashes of the factory and strategy, the randomness terms (coordinator and
its code hash, subscription, gas lane, confirmations, answer gas and retry wait),
the trait table hash, the asset flags awaiting the Safe, and the terms the release
discloses. Addresses and fleet values come from the
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
fleet-purchase, deposit-and-surplus, protocol-share, voting, Autolaunch, post-launch budget, key-reveal, fleet-directory and
deployment tests. Foundry must be installed; the compiler may be downloaded on
first use. Tests require no RPC, apart from the two in `test/fork`, which skip
themselves unless their environment is set.
`test/fork/KeyfleetLaunchIncomeFork.t.sol` needs `KEYFLEET_FORK_RPC_URL` naming a
chain with the Autolaunch graph deployed and `KEYFLEET_FORK_FACTORY` naming its
factory. It runs the whole path on a local fork: the keys vote a launch, a
bidder graduates it, SUBJECT vests out of the escrow, USDC and REGENT pass
through the splitter, the fleet splits each, keys claim, and a Pay vote spends
budget. `test/fork/KeyfleetRevealBaseFork.t.sol` needs `BASE_RPC_URL` and runs
a fleet against the real Chainlink coordinator on a fork of Base. OpenZeppelin 5.7.0 and forge-std 1.9.7 are
vendored as git submodules under `contracts/lib`, so clone with submodules or
run `git submodule update --init`.

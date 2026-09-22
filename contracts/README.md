# Contracts

A Foundry workspace pinned to Solidity 0.8.26 with OpenZeppelin 5.7.0 and
forge-std 1.9.7 vendored as git submodules under `contracts/lib`.

`KeyfleetAssetRegistry` is shared by fleets. Its constructor permanently binds
`REGENT_SAFE` and `BASE_USDC` to nonzero addresses supplied at construction. The
caller must supply the intended Safe contract and canonical Base USDC address;
the registry does not verify their identity or chain. Neither address receives
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
no administrator transfer, upgrade path, or deployment script.

`KeyfleetPresets` is a pure internal library and the single source of truth for
the supply, price, holding-limit and purchase-split arithmetic of the four
presets: `FibonacciSyndicate`, `FibonacciCascade`, `FleetTechClassic` and
`FleetTechAccelerant`. It has no storage, holds no tokens, and makes no external
calls. Every function is `internal pure` with checked arithmetic. `Keyfleet`
holds the state and calls into it; the library never calls back.

Prices are derived from a reference price `q` in atomic REGENT units, accepted
only within `1 <= q <= MAX_Q` where `MAX_Q` is `1e24`; anything outside reverts.
Both ladders are computed iteratively from the first step, never as a closed-form
power, and every step rounds up:

- Fibonacci level price: level 1 costs `q`, and each further level costs
  `ceilDiv(previous * 120, 100)`. `MAX_FIBONACCI_LEVEL` is 20.
- Accelerant primary price: the first mint costs `q`, and each further mint costs
  `ceilDiv(previous * 105, 100)`. `MAX_ACCELERANT_KEYS` is 2000, so mint indexes
  run 0 through 1999. Only primary mints advance the price; secondary sales do
  not, so the caller must count primary mints when choosing a mint index.
- Fleet.Tech Classic: `CLASSIC_SUPPLY` is 144 and every primary key costs `q`.

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
Reward assets cannot be removed or replaced, keys cannot be unenrolled or moved
between cohorts, and there is no deployment script.

Two obligations sit with the fleet. `settleKey` reverts for a key that was never
enrolled, so the fleet must enroll every key when it mints it, before the first
transfer. The backing check compares `balanceOf(this)` with the amount recorded
as backed, which assumes reward assets are ordinary non-rebasing tokens whose
balances only change through transfers; `KeyfleetAssetRegistry` is where that
admission decision is made.

`Keyfleet` is one fleet: its keys, its primary purchases and the REGENT
accounting behind them. It is an OpenZeppelin ERC721 with 1-based, contiguous
token ids and no enumerable or per-token URI storage. `tokenURI` is a fixed base
string plus the id; the base is set once at construction and has no setter. The
constructor takes the preset, the reference price `q`, REGENT, USDC, the Regents
treasury, the shared asset registry, the Regents revenue staking contract, and
the name, symbol and metadata base. It rejects a `q` outside `1..MAX_Q`, any zero
address, and a USDC address that is not the canonical Base USDC the registry is
bound to, so a look-alike token can never be wired in at deployment and can never
take the staking fee route. It then deploys the fleet's own `KeyfleetRewards` and
registers
REGENT as its first reward asset, so a fleet and its ledger are born bound to
each other and no deployment step can point a fleet at someone else's ledger.
Everything the constructor sets is immutable.

`purchase(receiver, referrer, maxPrice, deadline)` is the only way a primary key
is created. A zero receiver mints to the caller; a referrer may be any address,
including the caller, and a zero referrer means no referral deduction at all. The
deadline, the supply bound and the quoted price against `maxPrice` are all
checked before any token moves, because the displayed next slot is not reserved
and an earlier purchase can move a Fibonacci level or step the Accelerant price.
Payment is REGENT and nothing else. No balance-delta check is taken around the
pull: REGENT is one fixed, known, non-rebasing, fee-free token chosen at
deployment, so the amount transferred is the amount credited by construction. A
fee-on-transfer token would be mispriced here, which is why REGENT is immutable.
One consequence of paying a referral as a backed credit, which the ledger refuses
to record as zero, is that a referred purchase needs a reference price of at
least ten atomic REGENT units for the 10% share to exist; every preset price is
at least `q`, so this binds only at absurdly small reference prices.

Within a purchase the order is fixed: the buyer's REGENT is pulled, the split is
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
also the one preset that persists a price: `currentPrice` starts at `q` and is
stepped with `accelerantNextPrice` after each primary mint, so only primary mints
advance the ladder and secondary sales never do.

A Cascade level completes in the transaction that mints its last key, once and
only once; resales can never reopen it. Level 1 has no predecessor, so its whole
reserve becomes free capital. From level 2 the reserve first repays the preceding
level's original gross mint cost, as far as it stretches, by moving that amount
into the ledger and allocating it to the preceding level's cohort, which means
whoever holds those keys at that moment. The remainder becomes free capital and
the reserve is emptied. There is no guaranteed repayment and no refund for an
unfinished level: repayment requires the next level to complete.

Working capital is `freeCapital`, keyed by asset: purchases write the REGENT
entry and deposits write the entry of any admitted asset. The Cascade completion
reserve is a separate REGENT-only figure and is never spendable capital. Reward
backing is not counted here at all, because it lives in the ledger. The invariant
is that the fleet's balance of an asset is at least what it has booked for that
asset, which is `freeCapital[asset]` plus, for REGENT, `cascadeReserve`. Anyone
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
seats. `nextPrice` and `quote(hasReferrer)` state the price and the exact split
the next purchase would perform, and both revert once the fleet is sold out;
`remainingSupply` counts down to zero.

The most expensive primary purchase is the first referred purchase on a fresh
fleet, because every accounting slot it touches is written from zero.
On a Cascade fleet, with the treasury already holding REGENT as it will after its
first sale, that measured 330,980 gas in execution; Syndicate measured 302,091,
Accelerant 279,308 and Classic 278,765. The suite asserts a ceiling of 397,000
for the Cascade figure, which is the measurement plus twenty percent, and that is
the execution figure the deployment manifest should quote, with the 21,000 base
transaction cost on top of it. Later purchases are cheaper; the Cascade key that
completes a level, which also pays and allocates the preceding level's repayment,
measured 273,084 because the buckets it writes are warm by then.

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
revenue. Only the canonical USDC address, checked against the registry at
construction, takes this route. Every other admitted asset pays its fee to the
Regents treasury in that same asset, which must not be the fleet itself: a fee
paid back to the fleet would simply be recognized as surplus again, and the
deploying factory slice is where that address is fixed.
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
REGENT, which the constructor registers, a fleet can therefore take revenue in
seven further assets, and the ninth is refused outright by the ledger's lifetime
bound: that fleet can never take revenue in it, though it can still take it as
capital, which registers nothing.

Tokens that simply arrive, with no deposit call behind them, create nothing.
`recognizeSurplus(asset)` is the permissionless way to reconcile them: it is
admission-checked like any other receipt, works from the fleet's balance minus
what it has already recorded a purpose for, charges the same 2%, and books the
net as free working capital. What it treats as accounted is `freeCapital[asset]`
plus, for REGENT, the Cascade completion reserve, so an incomplete level's
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
measured 788,253 gas in execution. The suite asserts a ceiling of 946,000, which
is the measurement plus twenty percent, and that is the execution figure the
deployment manifest should quote, with the 21,000 base transaction cost on top of
it. The cost is bounded by the preset, not by how many keys or holders the fleet
has, so revenue can always be paid in however large the fleet gets. The figure is
measured against a plain ERC-20; a proxied token such as the real Base USDC adds
its own delegatecall overhead to each of the two transfers a deposit makes, and a
USDC deposit adds the staking contract's registration cost on top of that.

Votes, capital transfers, Autolaunch, the deploying factory and any ETH or
currency conversion are outside this slice. The fleet has no administrator, no
upgrade path, no pause, no burn and no withdrawal: the only ways tokens leave it
are the treasury share of a purchase, the deposit fee, the referral, Accelerant
rebate and Cascade repayment paid into the ledger, and the revenue backing moved
into the ledger.

Run `make check-contracts` from the repository root to check formatting, build,
and run the focused authorization, admission, preset-arithmetic, reward-ledger,
fleet-purchase and deposit-and-surplus tests. Foundry must be installed; the compiler may be downloaded on first use.
Tests require no RPC. OpenZeppelin 5.7.0 and forge-std 1.9.7 are vendored as git
submodules under `contracts/lib`, so clone with submodules or run
`git submodule update --init`.

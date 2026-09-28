# The Autolaunch target Keyfleet pins

Updated 2026-09-27 for Autolaunch v2, checked against the source. The v1 pin
this replaces is in git history (the previous version of this file, at
`985dc31`).

## Status

- **v2 is the target.** It is the Revstake package `contracts/revstake-v2` on
  the Autolaunch branch `feat/contracts-v2` at `da2519b` (worktree
  `worktrees/autolaunch/contracts-v2`). It is a candidate: not pushed, not
  deployed on Base, not audited, and it has no addresses yet. Its interface
  can still change until it is deployed. The lane's `5effdb1` (local, not
  pushed) corrects the page, README, SECURITY notes and one code comment after
  this document's review; the interface and behaviour are those of `da2519b`.
- **The founder's terms** are in that branch's `contracts/docs/launch-profiles.md`,
  "Founder decisions, 27 September 2026". They replace the Safe-adjustable
  ranges and hard ceilings this document used to expect: no v2 contract has
  any.
- **Keyfleet's code keeps building against v1** until v2 is deployed and the
  founder says to switch. The switch is a hard cutover: a fleet's factory is
  fixed when the fleet is deployed, and no Keyfleet code will speak both
  versions.

## What the code builds against today

`RegentsAutolaunchFactoryV1` at `0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e`,
with the shared strategy `RegentLBPStrategy` at
`0x69c13CCd9312e21d66fd162896E39bFC5f886F95`, as named in Autolaunch's
`contracts/v1/deployments/base-mainnet/deployed-manifest.json` (branch
`feat/autolaunch-robinhood-stocks`). Its `launch` takes a
`uint128 requiredRegentRaised` and sells 10%, pools 5% and vests 85%.
`contracts/src/interfaces/` copies that interface, and the Anvil lab
`contracts/v1/bin/local-base-lab.py` in the Autolaunch worktree runs it.

## The contracts

All paths are under `contracts/revstake-v2` at `da2519b`.

| Contract | Source | Frozen ABI |
| --- | --- | --- |
| `RegentsAutolaunchFactoryV2` | `src/factory/RegentsAutolaunchFactoryV2.sol` | `abi/RegentsAutolaunchFactoryV2.json` |
| `RegentLBPStrategyV2` | `src/strategy/RegentLBPStrategyV2.sol` | `abi/RegentLBPStrategyV2.json` |
| `ConditionalVestingEscrowV2` | `src/escrow/ConditionalVestingEscrowV2.sol` | `abi/ConditionalVestingEscrowV2.json` |
| `RegentFeeHook`, `SubjectSplitterV1`, `PaymentReceiverV1`, `RevstakeLPLocker` | `src/hook/`, `src/revenue/` | `abi/` |

The hook, splitter, receiver and locker are the v1 sources; a v2 deployment
creates new instances bound to the new factory and strategy. The factory
deploys the strategy and the hook in its own constructor, so the factory
address is the only one Keyfleet needs: it takes the factory as a deployment
argument and reads the strategy from `factory.strategy()`, as today.

## The call

```
struct LaunchParams { string name; string symbol; string description; string website; string image;
                      address treasury; uint256 floorPriceQ96; uint128 minimumRegentRaised; }
function launch(LaunchParams) returns (uint256 launchId, address subject, address auction, address escrow)
function launches(uint256 launchId) returns (Launch{launcher, subject, auction, escrow, treasury})
function launchIdOfSubject(address subject) returns (uint256)
```

`launch` refuses, and nothing else:

- in the factory: launches paused; any of the five strings empty or over 64,
  16, 512, 256 and 256 bytes (they are stored on the token verbatim);
- in the escrow: a zero treasury, or the escrow itself;
- in the strategy: a treasury that is the factory, the strategy, the hook, the
  PoolManager, the PositionManager, live staking or the LP locker; a floor
  below the auction's minimum, `2^32 + 1` (`FloorPriceTooLow`); a floor that is
  not a multiple of 100 (`FloorPriceNotOnGrid`); a bid tick under 2
  (`TickSpacingTooSmall`); a minimum above what the auction could ever raise
  (`UnreachableRequiredRaise`); a CCA factory that charges a protocol fee.

The caller pays gas only: no REGENT moves, no allowance, no signature, no
launch fee. The caller is recorded as launcher for provenance and holds no
authority. Any revert undoes everything; there is no per-launcher state,
counter or limit, and a retry after a revert costs nothing but gas.

**Pausing.** The factory is born paused. Only the Governance and Regent Safe
(`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`) can call `unpauseLaunches` and
`pauseLaunches`, and they gate `launch` alone: auctions, migration, refunds,
claims, vesting, staking and payments never pause. That is the whole mutable
surface. There is no owner, setter, upgrade or adjustable bound.

**Floor price.** `floorPriceQ96` is REGENT base units per SUBJECT base unit
times `2^96`. Both tokens have 18 decimals, so it is also REGENT per whole
token times `2^96`. The bid tick is `floorPriceQ96 / 100`.

**Minimum raise.** The auction must raise
`requiredRegentRaisedFor(floorPriceQ96, minimumRegentRaised)`, a pure view on
the strategy:

```
max(ceil(20,000,000,000e18 × floorPriceQ96 / 2^96), minimumRegentRaised)
```

`minimumRegentRaised` is the launcher's own higher minimum, zero for none. The
result is never zero, so an auction nobody bids in never graduates.

The Autolaunch site's default floor is 0.000001 REGENT. That is not a whole
number on the grid: `0.000001 × 2^96` is 79,228,162,514,264,337,593,543.95…
Rounded down to a multiple of 100 it is `79228162514264337593500`, whose floor
minimum is 19,999.999999999999999989 REGENT. So the default floor means a
minimum raise of about 20,000 REGENT. From `5effdb1`, `launch-profiles.md`
states the grid and that the Autolaunch site rounds an entered floor down to
it.

**Rounding at the minimum.** The pinned auction counts a bid placed in its
first block in full and a bid placed later up to one REGENT base unit short. A
raise of exactly the minimum graduates only if it arrives in the first block;
the minimum plus one base unit graduates in any block. Bidders should be asked
for the minimum plus one base unit.

## The events and views

Factory:

```
event LaunchCreated(uint256 indexed launchId, address indexed launcher, address indexed subject,
                    address auction, address escrow, address treasury, uint256 floorPriceQ96,
                    uint128 requiredRegentRaised, uint64 startBlock, uint64 endBlock)
event LaunchesPaused(); event LaunchesUnpaused();
event PaymentReceiverCreated(uint256 indexed launchId, address indexed receiver, address indexed creator,
                             address beneficiary, uint16 referralBps)
views: launches, launchIdOfSubject, launchIdOfPaymentReceiver, nextLaunchId, launchesPaused,
       strategy, hook, uerc20Factory, TOTAL_SUPPLY, PENDING_ALLOCATION, DISTRIBUTION_PULL, MAX_*_BYTES
```

Strategy:

```
event DistributionCreated(uint256 indexed launchId, address indexed auction, address indexed subject,
                          address escrow, address treasury, uint64 startBlock, uint64 endBlock,
                          uint256 floorPriceQ96, uint128 requiredRegentRaised, uint128 reserve)
event LaunchGraduated(address indexed auction, address indexed subject, PoolId indexed poolId,
                      address splitter, address receiver, uint160 finalSqrtPriceX96, uint256 lpTokenId,
                      uint128 lpRegentUsed, uint128 lpSubjectUsed)
event LaunchSettled(address indexed auction, uint256 regentRaised, uint256 regentToTreasury,
                    uint256 subjectToEscrow)
event LaunchRetired(address indexed auction, address indexed subject, uint256 subjectReturned)
event HookBound(address indexed hook)
views: distribution, auctionOfSubject, requiredRegentRaisedFor, bidTickSpacingFor,
       maxReachableRaiseFor, poolKeyOf, lpLocker, hook, and the constants below
```

`distribution(auction)` returns 19 fields, in this order: `lifecycle` (None,
Active, Graduated, Failed), `startBlock`, `endBlock`, `claimBlock`,
`migrationBlock`, `requiredRegentRaised`, `reserve`, `lpRegentUsed`,
`lpSubjectUsed`, `finalSqrtPriceX96`, **`floorPriceQ96`** (new in v2),
`launchId`, `subject`, `escrow`, `treasury`,
`splitter`, `receiver`, `poolId`, `lpTokenId`.

Escrow: `EscrowInitialized`, `VestingActivated`, `SubjectReleased`,
`LaunchFailed`, `LateFailedSubjectRetired`; views `lifecycle` (Pending,
Graduated, Failed), `subject`, `treasury`, `strategy`, `vestingStart`,
`totalReleased`; `release()` and `retireLateFailedSubject()` are permissionless.

## Graduation and failure

`strategy.migrate(auction)` is permissionless from the migration block on. The
Regent bot sends it; anyone else may. It checkpoints the auction and settles
the launch once: a second call reverts with `LaunchNotActive`.

If the auction raised its minimum, it graduates, in one transaction:

1. The strategy sweeps the raise and the SUBJECT the auction did not sell.
2. The official SUBJECT/REGENT pool opens at the raise divided by the 20B sale
   allocation.
3. One full-range position pairs the whole 15% reserve with up to three
   quarters of the raise, taking what it can pair from a three-quarter budget,
   and is locked in the LP locker for good.
4. The rest of the raise, `raise − lpRegentUsed`, at least a quarter, goes to
   the treasury (`LaunchSettled.regentToTreasury`). The tests hold the pool's part to three
   quarters within one part in a million.
5. Every SUBJECT still held for this launch goes to the escrow
   (`LaunchSettled.subjectToEscrow`), as in v1, and vests to the treasury on
   the same schedule as the 65%.
6. The splitter and the canonical payment receiver are created, and the escrow
   starts vesting its 65% to the treasury over 365 days from that block's
   timestamp.

Otherwise it fails. The unsold 20% and the 15% reserve go to the escrow, which
retires the whole 100 billion to the dead address. The auction refunds every
bidder. The treasury gets nothing.

**No share-out.** An earlier v2 draft let each bid claim a share of the
SUBJECT left over after graduation. The founder removed it on 2026-09-28: the
pinned auction rolls supply one block does not sell into the blocks after it
and never lowers its price, so an auction that reaches its minimum sells its
whole 20%, and the pool pairs the whole reserve. What is left is rounding
crumbs plus any SUBJECT someone sent to the strategy before migration, and it
goes to the escrow. Bidders claim what they won from the auction, as in v1.

## What is fixed and what is set per launch

Set per launch: the five metadata strings, the treasury, `floorPriceQ96` and
`minimumRegentRaised`. Nothing else.

Fixed by the factory and the strategy:

| Term | Value |
| --- | --- |
| Supply | 100,000,000,000 SUBJECT, 18 decimals |
| Auction | 20% (20,000,000,000) |
| Pool reserve | 15% (15,000,000,000) |
| Vesting to the treasury | 65% (65,000,000,000), linear over 365 days from graduation |
| Start | 300 blocks after the launch block (about 10 minutes) |
| Auction length | 86,401 blocks (48 hours and one block), the thirteen-step v1 schedule |
| Claim / migration | 64 / 128 blocks after the auction ends |
| Bid tick | floor ÷ 100 |
| Pool price | raise ÷ 20B |
| Raise into the pool | up to three quarters; the rest, at least a quarter, to the treasury |
| Pool | 0.30% LP fee, tick spacing 60, `RegentFeeHook` |
| Hook fee | 2% on every swap, on top of the LP fee: 1% to Regent (to REGENT staking when the fee is in REGENT, to the Regent Safe when it is in the launched token) and 1% to stakers through the launch's splitter; none below 50 base units |
| Splitter skim | 2% (USDC to live staking, REGENT and SUBJECT to the Regent Safe) |
| Custom receiver referral cap | 2.5% |

Every timing value is in blocks, and Base makes one every 2 seconds.

## How the seven gaps resolve

1. Identity: none exists. The fleet calls `launch` with `treasury = address(this)`.
2. Caller checks: only the ones above. Nothing checks caller code, `owner()`,
   EIP-1271 or modules, and nothing in a launch asks the fleet for ETH.
3. Metadata: all five fields go on the token and are required, as before.
4. Start block: not a parameter; computed at execution, all schedule values fixed.
5. Fee: none. The launch costs gas only.
6. State: `strategy.distribution(auction)` returns the lifecycle and the
   schedule, as before, with one field added in the middle
   (`floorPriceQ96`). Keyfleet's copy of the
   struct must change, because every field from `launchId` on would otherwise
   decode from the wrong place. The rest holds: the terminal state is written
   only by `migrate`; until then the launch stays Active even after the auction
   ends; `auction.isGraduated()` is the raise test; Failed is
   `Lifecycle.Failed`, with no separate recovered flag.
7. One launch per fleet: unchanged. Nothing on the factory side; Keyfleet
   allows one launch at a time. After a failed launch the keys can carry out
   another launch proposal, as long as it opened after the block the failed
   launch was created in; after graduation, never again.

## The new gaps under v2

8. **Floor price instead of a required raise.** The keys now approve a floor
   and an optional higher minimum, not a raise. The required raise follows from
   them through the strategy's pure `requiredRegentRaisedFor`, so the vote
   contract can check an envelope at proposal time by calling it, and the site
   can show the raise the envelope implies. The floor must already be on the
   grid (a multiple of 100 in Q96, at least `2^32 + 1`) when it is proposed,
   because the contract takes no rounding of its own; the server rounds the
   entered price.
9. **Minimum-raise rounding.** A raise of exactly the minimum can fail by one
   base unit. Keyfleet does not bid, so this reaches Keyfleet only as wording:
   pages that tell people how much is needed say "at least the minimum plus
   one smallest unit", or point to the Autolaunch site, which asks for it.
10. **A bid naming the fleet.** A fleet cannot bid: its contract has no call
    into the auction. Anyone can place a bid naming the fleet as owner, though,
    and the auction pays a bid's tokens and refund to its owner whoever sends
    the exit and claim. So the fleet need do nothing, and anyone may claim for
    it. What such a bid brings in arrives in REGENT or the launched token; to
    the fleet it is a gift (question 4 below), sorted as income to the keys
    (rule 5 sorts by token alone). No keeper job claims for it.
11. **The fleet as treasury.** At graduation the fleet receives
    `raise − lpRegentUsed` in REGENT, at least a quarter of the raise (v1 sent
    only what the position did not use), and the escrow vests 65% of the
    supply to it over 365 days. Both stay shared money, booked from the
    strategy's, the auction's and the escrow's own records. The formula
    `_syncLaunch` books already equals the strategy's `regentToTreasury`, so
    the booking needs no change. The fleet receives no SUBJECT at graduation: the unused
    tokens go to the escrow and vest to it, as in v1.
12. **Graduation sent by the Regent bot.** Keyfleet's keeper also sends
    `migrate(auction)` once the migration block passes and the launch is still
    Active. Both are permissionless and the first to land settles the launch.
    The keeper reads the lifecycle before sending, so it normally sees the
    bot's settlement and skips; if both land in the same block, the keeper's
    reverts and costs a little gas. `syncLaunch()` stays the keeper's job:
    nobody else calls it.

## What the treasury receives and may do

- Escrow: on graduation, 65% of the supply vests linearly over 365 days to the
  treasury; `escrow.release()` is permissionless and cannot be redirected. On
  failure the whole supply is retired, bidders are refunded by the auction,
  and the treasury gets nothing.
- Graduation: `raise − lpRegentUsed` in REGENT, at least a quarter of the raise.
- Splitter (created at graduation): as in v1. It recognizes USDC, REGENT and
  SUBJECT revenue, skims 2%, pays stakers the fraction of the net equal to the
  staked share of total supply, and sends the rest to the treasury. `stake`,
  `unstake`, `claim` and `claimAll` are plain caller-only calls, so the fleet
  may stake its own SUBJECT. Recoveries are permissionless and go to the
  treasury.
- Canonical payment receiver: as in v1. Beneficiary and note editor are the
  treasury; `pay` and `sweep` are permissionless; `setReceiverNote(bytes32)` is
  the only treasury-only call in the graph. Anyone may create custom receivers
  with `factory.createPaymentReceiver(launchId, beneficiary, referralBps)`
  after graduation.
- Pool and LP position belong forever to the fee-only locker; nobody has pool
  authority. The token's creator is the factory; nobody can mint, pause or
  upgrade.

The treasury needs no interface: it only holds and moves ERC-20 balances, and
is never asked to sign or take ETH. Keyfleet sorts what arrives by token, as
today:

- The REGENT the strategy sends at graduation and the SUBJECT the escrow
  releases are shared money, booked from the strategy's and the escrow's
  records.
- Any other USDC, REGENT or SUBJECT, such as what the splitter or the payment
  receiver sends on, or what a bid in the fleet's name brings in, is income
  and goes 100% to the keys when anyone calls `recognizeSurplus`.
- Any other token is shared money.

## What Keyfleet changes to adopt v2

None of this is done yet. It waits for v2 to be deployed and for the founder
to say to switch (see the questions below). Each change replaces the v1 shape
outright.

**Contracts**

1. `contracts/src/interfaces/IRegentsAutolaunchFactoryV1.sol` becomes
   `IRegentsAutolaunchFactoryV2.sol`: `LaunchParams` ends in
   `uint256 floorPriceQ96; uint128 minimumRegentRaised` and is checked against
   `abi/RegentsAutolaunchFactoryV2.json`. Why: v2's `launch` has a different
   selector and struct.
2. `IRegentLBPStrategy.sol`: `Distribution` gets `floorPriceQ96` after
   `finalSqrtPriceX96`;
   `MAX_REACHABLE_RAISE()` is replaced by
   `requiredRegentRaisedFor(uint256,uint128)`. Why: the v1 struct decodes v2
   wrongly, and v2 has no `MAX_REACHABLE_RAISE`.
3. `IAutolaunchAuction.sol` and `IAutolaunchEscrow.sol`: unchanged calls;
   their comments now name the v2 contracts and the 65%. Why: the pinned
   auction and the escrow's `totalReleased` are the same.
4. `Keyfleet.LaunchEnvelope`: `uint128 requiredRegentRaised` becomes
   `uint256 floorPriceQ96` and `uint128 minimumRegentRaised`.
   `executeAutolaunch` passes both; its provenance checks stay as they are.
   Why: they are what v2's `launch` takes, and the envelope hash must cover
   exactly what the keys approved.
5. `KeyfleetVotes.proposeAutolaunch`: the `RaiseOutOfBounds` check becomes a
   call to `factory.strategy().requiredRegentRaisedFor(floor, minimum)`, whose
   own errors refuse a bad floor or an unreachable minimum; `RaiseOutOfBounds`
   is deleted. Why: every launch proposal would otherwise revert on the
   missing `MAX_REACHABLE_RAISE`, and the strategy's rule is the only one that
   counts.
6. `Keyfleet._syncLaunch` and the contract's NatSpec: the formula stays;
   "every unused unit goes to the escrow" stays true, and the header names
   `RegentsAutolaunchFactoryV2`. Why: the booking and its explanation both
   still hold; only the factory's name changes.
7. Income rules: no change. REGENT and SUBJECT stay income tokens, and the
   launch's two receipts stay shared money. The NatSpec adds that a bid in the
   fleet's name brings in income. Why: rule 5 of the contract plan sorts by
   token, and v2 does not change which receipts come from the launch.
8. Scripts: `RecordKeyfleets.AUTOLAUNCH_FACTORY_ABI` becomes
   `"RegentsAutolaunchFactoryV2"`; `DeployKeyfleets.s.sol` and
   `KeeperLab.s.sol` use the new interface; the Base manifest's
   `autolaunchFactory` becomes the v2 address once it exists. Why: the
   deployment records which ABI a fleet speaks.

**Keeper** (`platform/lib/keyfleet/keeper`, `docs/keeper.md`)

9. `calls.ex`: the `launch_distribution` view decodes 19 fields, with one
   `uint256` field, `floor_price_q96`, after `final_sqrt_price_x96` and its name
   in `@distribution_fields`; comments name `ConditionalVestingEscrowV2`. Why: it
   decodes the struct `Keyfleet.launchDistribution()` returns.
10. `income.ex`: no change to `migrate`, `syncLaunch`, `release`, `collect`,
    `sweep` or the surplus calls. `docs/keeper.md`
    says the Regent bot normally sends graduation and the keeper's `migrate`
    is a backstop. Why: gap 12.

**Chain reader** (`platform/lib/keyfleet/chain`, `docs/chain-reader.md`)

11. `launch_envelopes.ex` decodes `[bytes ×5, uint256, uint128, bytes32]`.
    The `LaunchEnvelope` resource replaces `required_regent_raised` with
    `floor_price_q96` (positive) and `minimum_regent_raised` (zero allowed),
    with a migration and snapshot. Why: the envelope the vote contract returns
    changes shape.

**Server-built step** (`platform/lib/keyfleet/wallet_steps/build.ex`,
`platform/lib/keyfleet_web/wallet/wallet_words.ex`)

12. `propose_launch` takes a floor price in REGENT per token and an optional
    minimum raise in REGENT. It converts the floor to Q96, rounded down to a
    multiple of 100, and encodes
    `proposeAutolaunch(uint256,(string,string,string,string,string,uint256,uint128,bytes32))`.
    It reads `requiredRegentRaisedFor` at the latest block for the words. The
    words become, for example: "Proposes a launch at a floor of 0.000001
    REGENT per token that must raise at least 20,000 REGENT, with key 12."
    Input parsing refuses only what cannot be encoded, as `Typed.amount` does
    today, and every press still reaches the wallet. Why: the step builds the
    exact call the vote contract takes.

**Site figures and wording**

13. Launch form (`proposals_live.ex`): "REGENT to raise" becomes "Floor price
    (REGENT per token)", filled in with 0.000001, plus "Higher minimum raise
    (optional)", and the page shows the raise that follows. The proposal page
    shows the floor, the minimum and the required raise. The "Who benefits"
    line says the fleet's shared money keeps at least a quarter of the REGENT the
    auction raises, and the launched tokens as they vest. Why: new inputs and
    new money.
14. Launch plan: the workspace `launch_card` field, the graph pack's
    `LaunchCard` (`platform/graph_host/src/keyfleet_graph/pack.py`, pinned as
    `keyfleet_work@0.1.0`), `launch_plan_digest.ex`, its "ready" check in
    `graph/object.ex` and the plan-mismatch comparison in `proposals_page.ex`
    move from `required_regent_raised` to the floor and the minimum, under a
    new pack version. Why: the plan must name the same values the proposal
    fixes, or every plan reads as mismatched.
15. `proposal_json.ex` and the OpenAPI contract
    (`platform/contracts/api-contract.openapiv3.yaml` and its served copy)
    publish `floor_price_q96`, `minimum_regent_raised` and the required raise.
    Why: agents read launches through the API.
16. `platform/priv/public/opportunities.md`, Autolaunch: 20% sold, 15% into
    the pool, 65% released evenly over a year; bidders receive the whole 20%;
    the pool opens at the raise divided by the tokens sold; the fleet receives
    at least a quarter of the raise; the minimum raise is the whole 20% at the
    floor, or the proposal's higher minimum; the proposal fixes the floor and
    the minimum. "About 48 hours" and "about 10 minutes" stay. Why: the page
    states the contracts' money rules.

**Terms** (`platform/priv/public/terms.md`)

17. "the REGENT raised when the launch succeeds" becomes "the part of the
    REGENT raised that the launch sends it when it succeeds". The rest of the
    launch paragraph holds. Why: the fleet now receives a quarter of the raise,
    not the raise.

**Tests**

18. Contracts: `test/mocks/MockAutolaunch.sol` models v2 (floor rules,
    `requiredRegentRaisedFor`, the 19-field distribution, a quarter of the
    raise to the treasury, no SUBJECT to the treasury at graduation);
    `KeyfleetAutolaunch.t.sol`, `KeyfleetIncome.t.sol`,
    `KeyfleetTreasury.t.sol`, `KeyfleetVotes.t.sol`,
    `KeyfleetVotesTopics.t.sol`, `Keyfleet.t.sol`, `DeployKeyfleets.t.sol` and
    `RecordKeyfleets.t.sol` follow. The fork test
    `test/fork/KeyfleetLaunchIncomeFork.t.sol` runs against v2 on a Base fork,
    with its own auction and strategy declarations updated.
19. Platform: `wallet_steps_test.exs`, `wallet_steps_anvil_test.exs`,
    `proposals_chain_test.exs`, `proposals_test.exs`,
    `graph/launch_plan_digest_test.exs`, `graph/projection_test.exs`,
    `keeper/calls_test.exs`, `activity_test.exs`, the proposals and workspace
    page tests, the fixtures in `test/support` and the browser specs.

## Questions, answered

1. **Should fleet launches offer the higher minimum?** Founder, 2026-09-27:
   yes. Both the minimum raise and the floor price are set in the launch
   proposal before launch.
2. **How is the entered floor rounded?** Answered by `launch-profiles.md` at
   `5effdb1`: down to a multiple of 100 in Q96, as the Autolaunch site does, and
   no lower than `2^32 + 1`. Keyfleet rounds the same way, so the same price
   gives the same floor on both sites.
3. **Does Keyfleet's keeper still send `migrate`?** Answered by the
   Autolaunch UI lane on 2026-09-27: yes, as a backstop to the Regent bot.
   `migrate(auction)` is open to anyone; before the migration block it reverts
   with `MigrationNotYetAllowed`, and once one call has settled the launch
   every later call reverts with `LaunchNotActive` and changes nothing. The
   worst case is one reverted call.
4. **What a bid in the fleet's name brings in.** Founder, 2026-09-27: a
   fleet does not bid, and what it holds reaches it only at its own contract
   address, sent, gifted or bought there. The pinned auction takes any
   nonzero owner and v2 sets no validation hook, so a stranger's bid naming
   the fleet as owner is possible; to the fleet it is a gift, sorted by token
   under rule 5 like any other. Agents always act on their own: their
   wallets and tokens are theirs, as a person's are in a DAO. Only the fleet's
   contract address, and later any sub-addresses the fleet's admin address
   owns and assigns to agents or groups of agents, belong to the fleet.
5. **Where is v2 tested on a Base fork?** Answered by the Autolaunch UI lane
   on 2026-09-27: there is no v2 fork or lab tooling yet. The Base fork suite
   and the deployment ceremony stay in `contracts/v1` and are a separately
   authorised step before any deployment. Founder, 2026-09-28: the Autolaunch
   lane builds a v2 lab on a Base fork before the v2 deployment ceremony, and
   sends Keyfleet its ports and addresses when it is up. Until then Keyfleet
   builds against `revstake-v2`'s hermetic suite and its ABIs in
   `revstake-v2/abi`, and the fork test waits for that lab.
6. **When does the Keyfleet change start?** Founder, 2026-09-27: wait. The
   change starts once v2 is pushed and its ABIs are frozen, and merges only
   after v2 is deployed and the founder says to switch.

## Testing

No Base Sepolia deployment exists or can, because the bindings are Base
mainnet addresses. Until v2 is deployed, Keyfleet's contract tests run against
the v2-shaped mock, and a fork test needs the v2 graph deployed on an Anvil
fork of Base (question 5 below). The v2 package's own proof is its hermetic
suite, `bin/gate.sh` in `contracts/revstake-v2`, against real PoolManager,
PositionManager, CCA factory and UERC20 bytecode. After the v2 ceremony a Base
fork carries the real factory.

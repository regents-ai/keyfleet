# What Keyfleet needs from the Autolaunch target

Written 2026-09-22 for the Autolaunch lane. It states what a Keyfleet fleet
contract must be able to do with the Autolaunch factory, why, and where the
factory as it stands today (`repos/regents/contracts/src/autolaunch/AutolaunchFactoryV1.sol`,
interface `interfaces/IAutolaunchFactoryV1.sol`) does not yet fit. Items marked
**gap** need an answer from the Autolaunch side before the Keyfleet Autolaunch
slice is built. Everything here follows section 10 of the Keyfleet spec
(`KEYFLEET_HACKATHON_SPEC_v0.3.md`).

## 1. The fleet contract is the launcher and the treasury

A fleet is a `Keyfleet` contract: an ERC-721 with its own reward ledger, a
one-fixed-vote controller, free working capital, and no signer of any kind.
When its members approve an Autolaunch proposal, the fleet contract itself
calls the factory. That call is the only launcher role. The wallet paying gas,
the proposing agent, and the platform backend never occupy it.

The fleet must also be the recipient of everything the launch produces for
its launcher: the vesting wallet's beneficiary, the subject owner in the
subject registry, the revenue-share treasury, the fee vault's recipient, and
anything else the factory today hands to `msg.sender`. The factory records
`msg.sender` as the launcher, so the fleet calling directly gives the right
provenance for free. The fleet must never be asked to sign anything: it does
not implement EIP-1271 and will not.

**Gap 1, identity.** `launch` requires `IERC721Identity(IDENTITY_REGISTRY).ownerOf(params.agentId) == msg.sender`
against the canonical identity registry at `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`.
A fleet has no identity NFT. Options we can build against:

- (a) each fleet is issued an identity NFT into the fleet contract before it
  may launch (the fleet will implement `onERC721Received` to accept it; we
  need to know who mints it and whether it may be transferred in);
- (b) the factory accepts a fleet by provenance instead, for example
  `KeyfleetFactory.isFleet(msg.sender)`, with `agentId` unused for fleets;
- (c) something else the Autolaunch side prefers.

Please say which is possible. Keyfleet's preference is (b), because it keeps
the fleet free of a second identity system; (a) is acceptable.

**Gap 2, caller checks.** `launch` requires `msg.sender.code.length != 0`
(fine, a fleet is a contract) and `msg.sender != operationsSafe` (fine). Please
confirm nothing else in the factory, strategy, vesting wallet, revenue share,
ingress or payment-link path assumes the launcher is a Safe (module calls,
EIP-1271 checks, `owner()` on the caller, ETH refunds to the caller).

## 2. The approved envelope

The members vote on a fixed envelope. Anything the factory needs at execution
time must either be in that envelope or be derivable by the fleet at
execution from the envelope plus the chain. The envelope binds:

| Field | Source | Notes |
|---|---|---|
| chain id | fixed 8453 | the factory is `onlyBaseMainnet` |
| factory address | immutable on the fleet at deployment | pinned target and version |
| `tokenName`, `tokenSymbol` | envelope | nonempty, byte limits 64 and 16 |
| `description`, `website`, `image` | envelope | byte limits 512, 256, 256, nonempty; **gap 3** below |
| `requiredRegentRaised` | envelope | validated by the factory, REGENT-denominated |
| `floorPrice` | envelope | must be a multiple of the factory's `AUCTION_TICK_SPACING`; the fleet validates before proposing |
| `startBlock` | derived at execution | **gap 4** below |
| `expectedFee` | derived at execution, bounded by the envelope | **gap 5** below |
| `launchFeeHookSalt` | derived by the fleet | keccak of fleet address and proposal id |
| narrative digest | envelope | content-addressed reference to the human prose |
| execution expiry | envelope | after it the proposal can never execute |

**Gap 3, metadata.** The factory creates the token with empty
`description`, `website` and `image`. The spec wants the members to approve
those three fields verbatim and have them on the token. Can `LaunchParams`
carry them, or is the token metadata fixed empty for every launch? If fixed,
Keyfleet will keep them only in the narrative digest and say so in the UI.

**Gap 4, start block.** The factory requires `startBlock >= block.number + 300`
and `startBlock` is part of `LaunchParams`. A Keyfleet proposal is open for 24
hours (about 43,200 Base blocks) before it can execute, and execution happens
whenever someone calls it after the window. The fleet therefore cannot bind an
absolute `startBlock` at proposal time. Keyfleet intends to bind a delay in
blocks (at least 300) and compute `startBlock = block.number + delay` at
execution. Please confirm the factory has no other constraint on the start
block that would make a computed value wrong, and whether the auction length
(`AUCTION_BLOCKS = 86,401`), migration delay and sweep delay are fixed or per
launch.

**Gap 5, launch fee.** `launch` reverts unless `params.expectedFee == launchFee`,
and governance can change `launchFee` at any time. The fleet will read
`launchFee()` at execution and pass it, provided it is at or below the maximum
the envelope approved; above that the execution reverts and the proposal
stays pending. The fee (today 1,000,000e18 REGENT) is pulled from the fleet
by `transferFrom` with exact-allowance and exact-delta checks, and the fleet
pays it from free capital only, never from the Cascade reserve or reward
backing. The fleet will approve exactly the fee immediately before the call and
verify the allowance is zero afterwards. Please confirm the fee for a fleet is
the ordinary fee and that it is still forwarded to the live staking contract.

## 3. Results, provenance and state

From `LaunchResult` and the `LaunchCreated` event the fleet records: token,
auction, strategy, vesting wallet, revenue share, default ingress, canonical
payment link, subject id, pool id, plus the approved envelope digest and the
block. It never trusts a token address, name or symbol from anywhere else.

**Gap 6, canonical state reads.** The fleet needs to expose
`NotCreated -> AuctionCreated -> Graduated | EconomicallyFailed`, treating an
unresolved or reverting migration as still pending. Please name the exact
views to read for that on the strategy and auction (`auction.isGraduated()`
is visible in the strategy source; we need the "economically failed and
recovered" signal too, which looks like `failedAuctionRecovered` on the
strategy). A permissionless `syncLaunch()` on the fleet will read them and
record verified artifacts only; it cannot change the token, redirect anything
or enable payments.

**Gap 7, one launch per fleet.** Keyfleet allows one created launch per fleet
in V1. A reverted `launch` call consumes nothing. Please confirm the factory
has no per-launcher state that would block a retry after a revert, and that a
successful launch cannot be repeated for the same launcher by accident on the
factory side (Keyfleet blocks it on its side regardless).

## 4. What the fleet does with the outcome

- Vesting: the fleet must be able to release vested SUBJECT into itself by a
  plain call (`releaseLaunchToken()` looks permissionless; please confirm) and
  must never need a beneficiary signature. Released SUBJECT sits in the fleet
  as an ordinary token balance until the Regent Safe admits SUBJECT as a
  deposit asset for that fleet; only then can a surplus recognition charge the
  2% and book it as capital. Vesting receipts are never member revenue by
  themselves.
- Revenue share, ingress, payment link: the fleet needs to know which of
  these carry an authority that only the launcher can exercise, and whether
  every such call is a plain contract call the fleet can route through its
  fixed vote. Anything that requires a signer is unusable by a fleet.
- Fee vault, pool: same question.
- The fleet is not the token's `creator()` and holds no mint, pause or
  upgrade authority; Keyfleet will state this in the UI rather than pretend
  otherwise.

## 5. Testing

The factory is `onlyBaseMainnet`, so the fleet's Autolaunch tests need either
a Base mainnet fork with the live factory or a factory build whose chain check
can be satisfied on a fork of a test chain. Please say which of these the
Autolaunch lane supports today, and whether a Base Sepolia deployment exists.
Keyfleet will test against a mock factory that enforces the same caller,
identity, fee and parameter checks in the meantime.

## 6. What Keyfleet will not ask for

No arbitrary calls, no `execute(target, calldata)`, no editing of deposit
allowlists through a launch, no invented `launcherType` argument on the
existing ABI, no second official token after an economically failed auction
without a later explicit policy, and no cross-chain path.

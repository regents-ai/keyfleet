# The Autolaunch target Keyfleet pins

Recorded 2026-09-22 from the founder's answer to the requirements note, checked
against the source. This replaces the earlier requirements note, which had been
written against the older `AutolaunchFactoryV1` in the Regents repo; that
design is not going to Base.

## The contract

`RegentsAutolaunchFactoryV1`, in the Autolaunch repo at
`contracts/v1/src/factory/RegentsAutolaunchFactoryV1.sol` (branch
`feat/autolaunch-robinhood-stocks`, worktree
`worktrees/autolaunch/robinhood-stocks`), frozen ABI at
`contracts/v1/abi/RegentsAutolaunchFactoryV1.json`. Not deployed yet. The
rehearsed ceremony predicts the factory at Base
`0x635615cCEF2Ef24D0655fC2eBC47a14e005FEF6e` and the shared strategy
`RegentLBPStrategy` at `0x69c13CCd9312e21d66fd162896E39bFC5f886F95`. Both are
predictions until the deployed manifest names them; Keyfleet takes the factory
address as a deployment argument and reads the strategy from the factory.

## The call

```
struct LaunchParams { string name; string symbol; string description; string website; string image;
                      address treasury; uint128 requiredRegentRaised; }
function launch(LaunchParams) returns (uint256 launchId, address subject, address auction, address escrow)
event LaunchCreated(uint256 indexed launchId, address indexed launcher, address indexed subject,
                    address auction, address escrow, address treasury, uint128 requiredRegentRaised,
                    uint64 startBlock, uint64 endBlock)
function launches(uint256 launchId) returns (Launch{launcher, subject, auction, escrow, treasury})
function launchIdOfSubject(address subject) returns (uint256)
```

The factory checks, and nothing else: launches are not paused (the governance
Safe opens the factory once); the five strings are nonempty and within 64, 16,
512, 256 and 256 bytes and are stored on the token verbatim; the treasury is
nonzero and not one of seven system addresses (factory, strategy, hook,
PoolManager, PositionManager, live staking, LP locker); the required raise is
positive and at most the strategy's `MAX_REACHABLE_RAISE`. The caller pays gas
only: no REGENT moves, no allowance, no signature. The caller is recorded as
launcher for provenance and holds no authority anywhere. Any revert undoes
everything; there is no per-launcher state, counter or per-caller limit.

Fixed by the strategy, never per launch: start at execution block + 300,
auction 86,401 blocks, claim delay 64, migration eligible 128 blocks after the
end; 100 billion supply split 10% auction, 5% LP reserve, 85% escrow; official
pool 0.30% fee with tick spacing 60; the hook takes two 1% lanes (Regent Safe
and the splitter).

## How the seven gaps resolve

1. Identity: none exists. The fleet calls `launch` with `treasury = address(this)`.
2. Caller checks: only the ones above. Nothing checks caller code, `owner()`,
   EIP-1271 or modules, and every contract refuses ETH.
3. Metadata: all five fields go on the token and are required, exactly as the
   spec wants.
4. Start block: not a parameter; computed at execution, all schedule values fixed.
5. Fee: none.
6. State: `strategy.distribution(auction)` returns the lifecycle (None, Active,
   Graduated, Failed) with startBlock, endBlock, claimBlock, migrationBlock,
   subject, escrow, treasury, splitter, receiver, poolId and lpTokenId; the
   escrow exposes the same lifecycle. The terminal state is written only when
   anyone calls `strategy.migrate(auction)` at or after the migration block;
   until then it stays Active even after the auction ends, and
   `auction.isGraduated()` is the raise test. Failed is `Lifecycle.Failed`;
   there is no separate recovered flag.
7. One launch per fleet: nothing on the factory side; retries after a revert
   are free. Keyfleet enforces one created launch per fleet itself.

## What the treasury receives and may do

- Escrow: on graduation, 85% of supply plus unsold auction tokens vest linearly
  over 365 days to the treasury; `escrow.release()` is permissionless and
  cannot be redirected. On failure the escrow retires the whole supply to the
  dead address, bidders are refunded by the auction, and the treasury gets
  nothing.
- Graduation: REGENT raised beyond what the LP position used goes to the treasury.
- Splitter (created at graduation): recognizes USDC, REGENT and SUBJECT
  revenue, skims 2% (USDC to live staking, REGENT and SUBJECT to the Regent
  Safe), pays stakers the fraction of the net equal to the staked share of
  total supply, and sends the rest immediately to the treasury. `stake`,
  `unstake`, `claim` and `claimAll` are caller-only plain calls, so the fleet
  may stake its own SUBJECT. Recoveries are permissionless and go to the treasury.
- Canonical payment receiver: beneficiary and note editor are the treasury;
  `pay` and `sweep` are permissionless; `setReceiverNote(bytes32)` is the only
  treasury-only call in the graph. Anyone may create custom receivers through
  `factory.createPaymentReceiver(launchId, beneficiary, referralBps)` after
  graduation.
- Pool and LP position belong forever to the fee-only locker; nobody has pool
  authority. The token's creator is the factory; nobody can mint, pause or
  upgrade. There is no fee vault.

The treasury needs no interface: it only has to hold and move ERC-20 balances,
and is never asked to sign or take ETH. In Keyfleet terms every SUBJECT, REGENT
or USDC that arrives this way is an ordinary balance until the Safe admits the
asset for the fleet and a surplus recognition charges the 2% and books the net
as capital; the splitter's own 2% skim and Keyfleet's 2% are two separate
deductions and the UI must say so.

## Testing

No Base Sepolia deployment exists or can, because the bindings are Base
mainnet addresses. The chain check lives only in the deployment script. Test
on an Anvil fork of Base mainnet with the graph deployed by
`contracts/v1/bin/local-base-lab.py` (start, fund, admin, advance, pace,
status, stop) in the Autolaunch worktree, which is how the website labs run.
After the ceremony a Base fork carries the real factory.

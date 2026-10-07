# KeyFleet contracts v0.3: rebuild plan

**Date:** 6 October 2026
**Branch:** `kf/contracts-v03`, off local `main` at `52f999c`
**Binding source:** [contracts-build-now-spec-v0.3.md](contracts-build-now-spec-v0.3.md) (Sean, 6 October 2026), plus the HQ-recorded founder rule 41 a: every protocol USDC revenue path reaches REGENT staking on Base.
**Status:** plan only. No `.sol` file is changed by this commit. Nothing is deployed, broadcast, signed or pushed.

This plan is for the engineer who builds v0.3 and for the reviewer who checks it. Section 1 records what exists today. Section 2 maps the spec onto it. Section 3 lists the Base addresses to pin. Section 4 designs each new piece. Section 5 lists what the site must change. Section 6 is the build order. Section 7 lists the decisions Sean must make.

"Today" means the code on this branch at `52f999c`. All 232 Foundry tests pass on it (`forge test`, 6 October 2026). One more test, the Ethereum fork test, skips itself without an RPC URL.

---

## 1. Inventory (spec step 1)

### 1.1 Contracts and what each function does

There are six source files in `contracts/src`, plus three Chainlink files copied unchanged into `src/vendor/chainlink`. No contract has an administrator, an upgrade path, a pause, a setter, a proxy or a `delegatecall`. Each `Keyfleet` constructor deploys its own `KeyfleetRewards`, `KeyfleetVotes` and `KeyfleetShards`. Nothing is shared between fleets.

**`KeyfleetPresets.sol`** is a pure library. It has no storage, no tokens and no calls, and it holds the price, supply, holding-limit and purchase-split rules for the four presets.

| Function | What it does |
|---|---|
| `fibonacciLevelSupply/TotalSupplyThrough/LevelStart/LevelEnd/LevelOf` | Fibonacci level sizes are 2, 3, 5, 8 and so on, with no last level. Token ids are 1-based and contiguous across levels. |
| `fibonacciLevelPrice` | Level 1 costs 10 USDC (`Q_USDC`). Each level costs the one before ×1.2, rounded up at each step. |
| `fibonacciHoldingLimit` | One key per wallet for levels 1 to 7, then the level's supply ÷ 10. |
| `classicPrice` | Classic: 1,024 keys, priced from a generated cent table (`KeyfleetClassicPrices.CENTS`). Key 1 costs 8 USDC and key 1,024 costs 80 USDC. |
| `accelerantNextPrice/accelerantPrice` | Accelerant: 2,000 keys. Key 1 costs 10 USDC and each later key costs ×1.05, rounded up. |
| `splitPurchase` | Splits each purchase into protocol 10%, then capital, reserve or rebate depending on the preset. The parts always sum to the gross price. |
| `ceilDiv` | Division rounded up. |

**`KeyfleetClassicPrices.sol`** is one generated constant, 1,024 two-byte cent values written by `scripts/classic_prices.py`.

**`Keyfleet.sol`** is the ERC-721 fleet, about 15.9 KB of runtime code and 33.7 KB of initcode. It holds the keys, takes purchases, and keeps the free money, the reserve and the owed protocol share in one contract.

| Function | What it does |
|---|---|
| `constructor(preset, usdc, protocolTreasury, metadata, randomness, traitTableHash)` | Rejects zero addresses, a USDC that does not report 6 decimals, a coordinator without code, and a zero trait-table hash. Deploys `REWARDS`, `VOTES` and `SHARDS`. |
| `purchase(receiver, maxPrice, deadline)` | Guarded against reentry. Pulls the gross price in USDC, then: books the protocol share into `protocolShareOwed`; books capital into `freeCapital[USDC]` (Syndicate, Classic, Accelerant); books the reserve into `cascadeReserve` (Cascade); moves the Accelerant rebate into Rewards, credited to the holder of the previous key. Then it enrols the key in Rewards, mints it, completes a Cascade level if this was its last key, and requests VRF. |
| `nextPrice/quote/maxSupply/remainingSupply/levelOf/holdingLimit/completedLevels` | Views. |
| `requestReveal(tokenId)` | Anyone may ask VRF again for a key whose every request so far was refused. |
| `rawFulfillRandomWords` | Coordinator only, and never reverts. Writes `revealSeed = keccak256(TAG, chainid, fleet, tokenId, word)` once. |
| `recognizeSurplus(asset)` | Permissionless. Unbooked USDC goes 100% to the keys through `_allocateToKeys`, by cohort. Any other unbooked token becomes `freeCapital[asset]`. |
| `payFromBudget(asset, amount, recipient, yesVotes)` | Votes only. Pays out free money with **matching**: `share = ceil(amount / yes)`, and `share × (sold − yes)` moves to Votes for the other keys to collect. |
| `sendProtocolShare()` | Permissionless. Sends the whole of `protocolShareOwed` as a plain USDC `transfer` to `PROTOCOL_TREASURY`, the Regents Safe. |
| `_update` (transfer hook) | Settles the key's Rewards to the outgoing owner, enforces the Fibonacci holding limit, bumps `ownershipEpoch`, and writes `lastMovedBlock`. |
| `_completeLevel` | Cascade: repays the previous level's whole gross into its cohort and sends the rest of the reserve to `freeCapital`. |

**`KeyfleetRewards.sol`** is the per-fleet ledger, written only by the fleet. It pays out USDC only.

- `enrollKey`, `allocateToCohort`, `credit` and `settleKey`: per-cohort cumulative indexes scaled by 1e27. Every allocation must already be backed by tokens sitting in the ledger.
- `claim(asset, tokenIds, to)`: one asset per call.
- `claimable` and `accrued`: views.
- The invariant is `balance ≥ backed`. Cohort 0 holds every Classic and Accelerant key; on the Fibonacci presets the cohort is the key's level.

**`KeyfleetVotes.sol`** is the governor. Its rules today:

- **Kinds:** Decision, Pay and RestrictEdits.
- **Who may vote:** a key may vote only if `lastMovedBlock < openedBlock`.
- **Approval:** a live test against all keys sold. Decision and Pay pass at `yes × 2 > totalMinted`; RestrictEdits passes at `yes × 5 ≥ totalMinted × 3`.
- **No time limits:** there is no deadline, expiry or cancellation.
- **Delegation:** an owner-wide `votingDelegate`.
- **Calls:** `vote`, `withdrawVote`, `execute` (permissionless), and `collect` for the matching shares. `editsRestricted[tokenId]` is the record the site reads to restrict a key's edits.

**`KeyfleetShards.sol`** records time-limited grants from a key's owner to a wallet.

- `issue(tokenId, wallet, days 1–365)`, `end` and `shardOf`.
- A wallet holds at most one active shard per fleet.
- A shard is active only while the key's `ownershipEpoch` still matches the one it was issued under.
- It carries "no vote, no money and no authority on chain".

**Scripts** (`contracts/script`):

- `DeployKeyfleets.s.sol` and `RecordKeyfleets.s.sol` run as two steps through `KeyfleetManifest.sol`.
- For Ethereum the manifest pins USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, VRF coordinator `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a`, the 200 gwei gas lane `0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9`, and the Regents Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` as `PROTOCOL_TREASURY`.
- `AnvilLab.s.sol` builds a local Classic fleet for the site's anvil tests.

**Tests** (`contracts/test`), 15 suites:

- Presets, Keyfleet (purchases), Income, Rewards, Treasury (`payFromBudget` and matching), Votes, VotesTopics (event topics and selectors pinned for the site), Shards, Reveal, TraitDraw (golden draws shared with `platform/lib/keyfleet/traits.ex`), Deploy and Record.
- Plus `fork/KeyfleetRevealEthereumFork.t.sol` and `mocks/MockVRFCoordinatorV2Plus.sol`.
- There is no invariant (handler-based) suite today; the closest are fuzz tests.

### 1.2 What is deployed where

**Nothing is deployed on any chain. Classic is not deployed.**

Evidence:

- **No deployed manifest exists, now or ever.** The only files in `contracts/deployments/` are the inputs `ethereum.json` and `anvil.json`. Both have `"subscriptionId": "0"` and a zero `traitTableHash`, so the deployment refusals would stop any real run. No `<name>.<fleet>.deployed.json` exists, and none has ever been committed (`git log --all -- contracts/deployments/`). There is no `broadcast/` folder.
- **Nothing on the site points at a contract.** It links a fleet to contracts only through `bin/seed-deployment` with a deployed manifest. `docs/deploy-checklist.md` says not to run it, and the K-18 hold (audit plus Sean's go) still stands.
- **The Base build of 28 September was never deployed either.** Before commit `df7f447` (29 September), the fleet targeted Base, with REGENT, staking and Autolaunch v2 wiring. That `base.json` likewise had a zero subscription, a zero trait table and a zero factory.

So no live commitment, claim or asset exists to migrate. The spec's rule that nothing is retroactively cancelled (§2) has nothing to act on. This is a clean first deployment on Base.

### 1.3 Economic commitments in today's code

These are the commitments the spec (§2, "Other preset economics") says must not change, apart from where the protocol share goes (rule 41 a, section 3.2).

| Commitment | Today's rule | Where |
|---|---|---|
| Purchase currency | Atomic USDC with 6 decimals; the constructor refuses any other number of decimals. | `Keyfleet` constructor |
| Classic | 1,024 keys, 8 → 80 USDC on a cent table. All 1,024 keys sum to 32,032.45 USDC. | `KeyfleetPresets.classicPrice` |
| Accelerant | 2,000 keys. Key 1 costs 10 USDC; each later key costs ×1.05, rounded up. Only primary mints step the price. | `accelerantNextPrice`, `currentPrice` |
| Syndicate and Cascade | Fibonacci levels with no last level. Prices go ×1.2 per level, rounded up. Holding limit: 1 key for levels 1 to 7, then supply ÷ 10. | `KeyfleetPresets` |
| Protocol share | 10% of every purchase, rounded down, booked in `protocolShareOwed`. Sent whole by anyone through `sendProtocolShare` to `PROTOCOL_TREASURY`, the Regents Safe (Ethereum `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`). The only fee. | `Keyfleet.purchase`, `sendProtocolShare` |
| Syndicate and Classic split | 90% capital. | `splitPurchase` |
| Cascade settlement | 90% to `cascadeReserve`. When a level completes: repay the previous level's whole gross to its cohort, then the rest becomes capital. The reserve covers at least 1.62× what is owed. The reserve of a level that never completes is deferred. | `_completeLevel` |
| Accelerant rebate | Key 1: 90% capital. Later keys: 20% capital, and 70% (plus dust) credited in Rewards to the current holder of the previous key. | `purchase`, `REWARDS.credit` |
| USDC income | Any unbooked USDC at the fleet goes 100% to the keys. Classic and Accelerant split it equally per key. Syndicate and Cascade split it equally per completed level, then equally per key in the level. An unfinished level gets nothing, and the remainder goes to the last completed level. | `recognizeSurplus`, `_allocateToKeys` |
| Other tokens | Become shared money (`freeCapital`), spent only by an approved Pay. | `recognizeSurplus` |
| Matching | A Pay passes only within the yes-voters' own share. Every key that did not vote yes collects `ceil(amount / yes)`. | `payFromBudget`, `collect` |
| Votes | One key, one vote. Yes must be more than half of all keys sold (three fifths for RestrictEdits), with no deadline. Keys moved after a proposal opens cannot vote on it. | `KeyfleetVotes` |
| VRF trait draw | One VRF v2.5 word per key, paid in native ETH from the Regents subscription. 3 confirmations, 100,000 callback gas. Seed `keccak256(TAG, chainid, fleet, tokenId, word)`. Traits are drawn off chain from the seed and a published table whose hash is fixed per fleet. Retry only after a refused request. | `Keyfleet` reveal code; README "Key reveals" |
| Shards | Owner grants of 1 to 365 days, one active shard per wallet per fleet, ended by any transfer. No authority on chain. | `KeyfleetShards` |

Recorded as deferred today and left unchanged by v0.3: Fibonacci late-entry capture, and the reserve of a Cascade level that never completes.

---

## 2. Gap map, spec section by section

The rule: four responsibilities, not a new framework (§3). After the change there are **five deployable contracts plus two libraries**. Each one is an existing file or the one new treasury.

| Responsibility (§3) | Contract after v0.3 | Holds |
|---|---|---|
| Keys and owner delegation | `Keyfleet.sol` (core) and `KeyfleetShards.sol` | The keys, the Cascade reserve and the owed protocol share. It holds **no** free capital and makes no general calls. |
| Presence and decisions | `KeyfleetVotes.sol`, with presence in an internal library `KeyfleetPresence.sol` (inlined, no `delegatecall`) | Nothing of value. |
| Spendable capital and execution | **New `KeyfleetTreasury.sol`** | All free capital (ETH, REGENT, USDC, launch token, other assets). It executes approved CALL batches, runs the daily split, and owns the Lit account (ERC-1271). |
| Protected obligations | `Keyfleet.sol` (reserve, owed share) and `KeyfleetRewards.sol` (all member claims) | Settlement reserves and reward backing. **Never** reachable by an approved call. |

`KeyfleetPresets.sol` and `KeyfleetClassicPrices.sol` stay unchanged.

**Segregation rule (§3, §7.2).** Only `KeyfleetTreasury` makes arbitrary approved external calls. It never holds reward backing, the Cascade reserve or the owed protocol share. Those live in `Keyfleet` and `KeyfleetRewards`, which have no general-call function, no approval function, and no setter Votes can reach. So an approved call cannot touch protected money, because that money is not in the calling account.

### §1 Product and scope

- **Changes:** the chain moves from Ethereum (1) to Base (8453).
- **Stays:** transferable ERC-721 keys and the purchase presets.
- **Not built:** none of the "Do not build" list (§1): no bridge, Superfluid, payroll, task leases, scores, mandatory ERC-6551/8004 identity or minority reserve.

### §2 Interpretations

- **New:** the threshold applies to the free balance before the cut (`B ≥ threshold`).
- **New:** at most one allocation per asset per 24-hour period.
- **Changes:** there is no separate USDC income route (P2 b). All USDC a fleet receives outside a purchase is treasury capital (see §9 below).
- **OUSD:** its slot stays unconfigured.
- **Stays:** prices, supply, fees, Cascade, the Accelerant rebate and the income weights.

### §3 Four responsibilities

- **New:** `KeyfleetTreasury`.
- **Changes:** free capital moves out of `Keyfleet` into it. Purchase capital and released Cascade surplus are sent to the treasury at the moment they are booked, and any other balance at the core, USDC included, is forwarded to it.
- **Deleted from `Keyfleet`:** the `freeCapital` mapping, `payFromBudget`, `SharedMoneyRecognized` (replaced by a forward-to-treasury event), and the `OnlyVotes` and `AboveYesShare` errors.

### §4 Immutable membership and protected accounting

- **Stays:** no admin, no upgrade, no proxy, no setter, no pause, and no burn in the core, Rewards, Votes and Shards.
- **New:** the treasury executes `Call{target, value, data}` with plain `CALL` only. There is no operation enum, no fallback dispatcher and no `delegatecall`.
- **New:** a CI check of the reachable bytecode (section 6, commit C14).
- **Deleted:** matching ("no new ... minority matching payment", §4.3; "Do not build ... minority capital reserve", §1). That means `collect`, `collected`, `share`, `keysSold`, `BudgetPaid.matched`, and the matched-funds float held inside Votes.

### §5 Membership, agents and participation

- **Deleted:** `lastMovedBlock` and the "moved after opening cannot vote" rule. New and transferred keys may join an open proposal by voting.
- **Deleted:** `votingDelegate`, the owner-wide delegate. One delegation mechanism remains.
- **Changes:** Shards gain explicit capability bits (workspace, presence, governance) and a per-key delegation revision. The shard stays epoch-bound, so a transfer still ends it.
- **New:** EIP-712 signed Present and Ballot messages. Each binds the chain id, verifying contract, fleet, key, ownership epoch, delegation revision, operation, nonce and deadline. They are verified with OpenZeppelin `SignatureChecker`, which covers ordinary wallets and ERC-1271 contract wallets.
- **New:** presence (`lastActiveAt`, a 48-hour window, an expiry-ordered queue, `sweepExpired`) and per-key activity checkpoints keyed by a global state revision.
- **New:** the transfer hook `Keyfleet._update` calls `VOTES.onKeyMoved(tokenId)`, which clears presence and writes a checkpoint.
- **Stays:** `ownershipEpoch`.
- **New:** `firstMintAt` in `Keyfleet`, the anchor for the daily split.

### §6 The growing electorate

New counting:

- The opening count `E0` is taken from the cleaned queue. Late joiners are counted per proposal, `D = E0 + late`.
- Ballots are Yes, No or Abstain, one slot per key. A replacement ballot swaps the key's contribution.
- A proposal passes when `D > 0` and `Yes > floor(D/2)`.

Deleted:

- The live `totalMinted` denominator.
- The three-fifths RestrictEdits rule (decision 5).
- `withdrawVote`. Withdrawing becomes an Abstain ballot, which keeps the key in the electorate.

### §7 Exact proposals and execution

Changes and new:

- The three typed kinds become one proposal shape: author key, content hash, ordered `Call[]` (stored as a hash, with the full bytes emitted), `closesAt` (at most 48 h after creation), and `executionExpiry` (`closesAt` + 48 h). The lifecycle is Open → Approved, Rejected or Cancelled, then Executed or ExecutionExpired.
- Cancellation by the author key's controller. Resubmission gets a new id.
- Typed effects become treasury functions only the treasury itself can call (`onlySelf`), each reached through an exact CALL: `pay`, `advance`, `setDailySplitBps`, `admitOusd`, `approveSignatureHash` and `revokeSignatureHash`. RestrictEdits becomes a CALL to `Votes.setEditsRestricted`, which only the treasury may call. A Decision is a proposal with an empty call list.

Deleted: `proposeDecision`, `proposePay` and `proposeRestrictEdits` as separate entry points, and the `Kind` enum.

### §8 Daily fair split

New:

- In `KeyfleetTreasury`: `processDailySplit(asset)`, a batch helper, the 10–100 bps rate with current and pending values, periods anchored at `firstMintAt`, per-asset thresholds, and fixed slots for ETH, REGENT, USDC, OUSD (unconfigured) and TOKEN (bound from the verified launch).
- In `KeyfleetRewards`: an integer per-key split index per asset (`splitIndex`), native ETH backing and claims, and transfer settlement of every bound split asset.

Changes: Rewards stops being USDC-only. `rewardAssets()` becomes the cohort income asset (USDC) plus the bound split assets.

### §9 Income versus capital

The treasury is the fleet's one payment address (P2 b). Everything a fleet receives outside a purchase, USDC included, is treasury capital and reaches the keys only through the daily split.

Changes:

- `recognizeSurplus(asset)` forwards an asset's whole surplus at the core to the treasury, USDC exactly as any other token. Money paid to the core by mistake is never stranded and never split twice.
- The core is not payable, so ETH cannot arrive there by a normal transfer. Note: `selfdestruct` can still force ETH in. Nothing in the core reads its ETH balance, so the core treats such ETH as stranded.

New:

- `advance(id, operator, asset, amount, purposeHash)`, which only the treasury may call, and the permissionless `returnAdvance(id, amount)`, capped at what is still out on that advance.
- The fleet's own token launches through Autolaunch Revstake v2 on Base and is bound to the daily split with `bindLaunchToken` (sections 4.7 and 9.2).

### §10 Public actions, chat and culture

Off chain only: the collective outbox, Agree/Check reviews and cooldowns live in the site. No contract changes, apart from RestrictEdits remaining an exact on-chain action.

### §11 Lit

New: the treasury implements ERC-1271 `isValidSignature`. It answers yes only for hashes approved by an executed proposal. Lit administrative writes are exact CALLs from the treasury (section 4.8).

### §12 Application

Site work only (section 5).

### §13 Sequence

See section 6.

### Files after the change

```
contracts/src/
  Keyfleet.sol              changed: no free capital; staking deposit; firstMintAt; transfer hook calls Votes
  KeyfleetPresets.sol       unchanged
  KeyfleetClassicPrices.sol unchanged
  KeyfleetRewards.sol       changed: multi-asset split index, native ETH, split settlement
  KeyfleetVotes.sol         rewritten: presence, electorate, exact-call proposals, EIP-712 ballots
  KeyfleetPresence.sol      new internal library (queue + checkpoints), inlined into Votes
  KeyfleetShards.sol        changed: capabilities + delegation revision
  KeyfleetTreasury.sol      new: free capital, CALL batches, daily split, advances, ERC-1271
  interfaces/IRegentRevenueStaking.sol  new (one function)
  interfaces/IRegentsAutolaunchFactoryV2.sol, IRegentLBPStrategyV2.sol   new, minimal, copied from Autolaunch Revstake v2
  vendor/chainlink/*        unchanged
contracts/deployments/
  base.json                 new; ethereum.json deleted (hard cutover); anvil.json updated
contracts/script/
  KeyfleetManifest.sol, DeployKeyfleets.s.sol, RecordKeyfleets.s.sol  changed for Base pins and five contracts
  AnvilLab.s.sol            changed
contracts/test/
  KeyfleetTreasury.t.sol    rewritten (execution, split, advances)
  KeyfleetVotes*.t.sol      rewritten
  KeyfleetPresence.t.sol, KeyfleetSplit.t.sol, invariant/*.t.sol   new
  fork/KeyfleetBaseFork.t.sol  replaces fork/KeyfleetRevealEthereumFork.t.sol
```

**Contract size risk.** `Keyfleet`'s initcode is already 33.7 KB, against Base's 49,152-byte EIP-3860 limit. That initcode includes the creation code of Rewards, Votes and Shards. A larger Votes, a multi-asset Rewards and a new Treasury will not fit in one constructor. Recommended deployment, measured in commit C4:

- `Keyfleet` deploys only `KeyfleetRewards` and `KeyfleetShards` in its constructor. It takes the Votes and Treasury addresses predicted from the deployer's next two nonces.
- The script then deploys `KeyfleetVotes(fleet)` and `KeyfleetTreasury(fleet)`. Each constructor requires `fleet.VOTES() == address(this)` or `fleet.TREASURY() == address(this)`.
- A purchase calls Votes in the transfer hook, so no key can be bought until Votes exists.
- USDC sent to the treasury's address before it is deployed stays at that address. No funds can be lost in the gap.
- `RecordKeyfleets` refuses any fleet whose five contracts do not point at each other.

This is decision 11.

---

## 3. Base bindings to pin

Rule: an address is pinned only with its source. Anything not proven from an official source and on chain is marked **UNVERIFIED**, and the deploy script refuses to run until it is replaced by a verified value.

### 3.1 Addresses

All of the checks below were read-only, against Base mainnet (chain 8453) at block ~52.26 million on 6 October 2026, together with the official page named in each row. Nothing was sent. "Verified" means the official source and the chain both agree.

| Binding | Address or value (Base, chain 8453) | Source | Status | Used for |
|---|---|---|---|---|
| Native USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | [Circle USDC addresses](https://developers.circle.com/stablecoins/usdc-contract-addresses). On chain: 6 decimals, symbol `USDC`, a Circle proxy. | Verified | Purchases, income, protocol share, USDC split slot |
| REGENT | `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` | [Basescan token page](https://basescan.org/token/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07). Regent's own pin in `repos/autolaunch/contracts/v1/src/bindings/BaseBindings.sol:16`. On chain: symbol `REGENT`, 18 decimals, 100 billion supply. | Verified | REGENT split slot |
| Chainlink VRF v2.5 coordinator | `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` | [Chainlink VRF v2.5 supported networks, Base Mainnet](https://docs.chain.link/vrf/v2-5/supported-networks). On chain: its stored settings match the page. | Verified | Trait reveal |
| VRF key hash, 2 gwei lane | `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab` | Same page. Registered on the coordinator with a 2 gwei cap. | Verified | Recommended gas lane (decision 15) |
| VRF key hash, 30 gwei lane | `0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70` | Same page. Registered with a 30 gwei cap. | Verified | Alternative lane |
| VRF payment | Native ETH. The premium is 60% paid in ETH (50% in LINK). Callback gas is capped at 2,500,000; confirmations from 0 to 200. | Same page, and the coordinator's stored settings | Verified | Keep `nativePayment: true`, 3 confirmations, 100,000 callback gas |
| LINK (Base) | `0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196` | Same page. On chain it is the coordinator's LINK token. | Verified | Not used: ETH payment |
| VRF subscription id | none yet | — | **Not created.** It must be created and funded on Base by the Regents Safe before a fleet is deployed. The deploy refuses `0`. | Trait reveal |
| Regents Safe (Base) | `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` | Regent's own pins: `repos/autolaunch/contracts/v1/src/bindings/BaseBindings.sol:22`, and `repos/regents/contracts/deployments/base-mainnet/autolaunch-history.yaml:61,63`. On chain: Safe v1.4.1 (the Base singleton `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`, matching Safe's official deployment list), 2 of 3 owners. | Verified, see the warning below | Owns the staking contract and the VRF subscription. **No longer receives the 10%.** |
| REGENT revenue staking | `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` | [Basescan, verified source `RegentRevenueStaking`](https://basescan.org/address/0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5#code). Founder decision 40 (4 Oct) and rule 41 a. On chain: 11,757 bytes, not a proxy, not paused, owner and treasury are the Base Regents Safe. | Verified | Receives the protocol share (section 3.2) |
| Autolaunch Revstake v2 factory | `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` | `repos/autolaunch` `feat/contracts-v2` at `54b6676`, `contracts/revstake-v2/deployments/base-mainnet/deployed-manifest.json` (deployed 6 Oct 2026, Base blocks 52267808–52268160, factory tx `0xd913518b942ce622f9eddd3fefe98b5d1baf75deaf617acb3c4995de1bf1c267`); HQ record `control/hq/decisions/autolaunch-revstake-v2-base-2026-10-06.md`. On chain: code hash `0x99f5e3fa97c511b5cfc001e0ea407eebdbaa66f2cc00631d911a34f2aca01676`, and its strategy `0x4dEEd15f650F45900F2e55a44eADe7bD5Fd556d9` `0x1dcfd811edb76c865fcba2f9381a40fc2d33393f21ee227509258b86bcfb9a08`, both as the manifest records, as are the six other contracts it wires and every wiring readback. Launches paused (only the Regents Safe opens them); no launch yet (`nextLaunchId` 1). | Verified | Launch path and TOKEN slot (sections 4.7 and 9.2). `AUTOLAUNCH()` in the treasury; `autolaunchFactory` in the manifests |
| OUSD on Base | none | [Origin OUSD registry](https://docs.originprotocol.com/registry/contracts/ousd-registry) lists OUSD tokens only on Ethereum. The only Base entry, `0xB1d624fc40824683e2bFBEfd19eB208DbBE00866`, is a strategy, not a token. | **Unconfigured**, as spec §8.7 expects | OUSD slot stays empty until an approved `admitOusd` |
| Lit `AccountConfig` diamond | `0xaaaaa9120fe271f653cfdb6bf400db93d2dea7aa` | Lit's node configuration, `GET https://api.chipotle.litprotocol.com/core/v1/get_node_chain_config` (chain "Base", id 8453), fetched 6 Oct 2026. On chain: a diamond with code on Base; its loupe routes all seven admin writes the treasury uses to one facet, and their selectors match Lit's open-source `WritesFacet` (`LIT-Protocol/chipotle`). The Base fork test runs the treasury's writes against it. | Verified | Lit admin calls. Only a call target inside proposals, never a contract constant. |
| Trait table hash | zero today | — | **Not produced.** It is generated from the published table before deployment, and the deploy refuses zero. | Trait reveal |

Also recorded, not bound: the VRF wrapper `0xb0407dbe851f8318bd31404A49e658143C982F23` appears only on the Chainlink page, and its code was not checked. It is not used, because fleets use a subscription.

**Warning: one Safe address, two different Safes.** `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` is a separate 2-of-3 Safe on each chain, with different signers.

- **Base:** `0x8C172cA4b5Dd9449217C636A953727eACD690e37`, `0x978BDbECb54C54800D01055Df5A8f6af600BfaCe` and `0x1d0dcABAeb941823E51935F795Be184aBeBf76dF`.
- **Ethereum:** `0x978BDbECb54C54800D01055Df5A8f6af600BfaCe`, `0xB26A3609acD791e2eA3f1900619C910B45705adD` and `0x1d0dcABAeb941823E51935F795Be184aBeBf76dF`.

Sean confirms the Base signers in decision 3.

**Hard cutover of the pins.** `KeyfleetManifest` drops every `ETHEREUM_*` constant and `ETHEREUM_PROTOCOL_TREASURY`, and gains the `BASE_*` constants above. `deployments/ethereum.json` is deleted. The manifest checks become:

- the chain must be 8453 (31337 for the lab);
- the USDC, REGENT, staking, coordinator and factory addresses must equal their pins and have code;
- the key hash must be one of the two lanes;
- the subscription id and trait hash must not be zero.

### 3.2 The protocol share: where it goes today, and what changes

- **Today:** `Keyfleet.sendProtocolShare()` sends `protocolShareOwed` with a plain USDC `safeTransfer` to `PROTOCOL_TREASURY`. On Ethereum that is pinned to the Regents Safe, `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` (`KeyfleetManifest.ETHEREUM_PROTOCOL_TREASURY`, chosen 29 September 2026).
- **Required (rule 41 a):** on Base, the 10% reaches REGENT staking at `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`.

**What the staking contract accepts.** These come from the verified source on Basescan and the deployed ABI at `repos/regents/platform/contracts/abi/regent-revenue-staking.json`. Note that the source in `repos/regents/contracts` does **not** reproduce the deployed bytes, so it is not the reference.

- **Revenue enters only through `depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) returns (uint256 received)`.**
  - It pulls USDC with `transferFrom`, so the sender approves first.
  - Anyone may call it.
  - It is refused while paused; only the Safe can pause.
  - Simulated on Base without sending: depositing 0 reverts `AMOUNT_ZERO`, and depositing 1 without an approval reverts `TRANSFER_FROM_FAILED`.
- **A plain USDC transfer is not counted as revenue.** It sits as surplus, which only the owner can redeposit (`redepositSurplusUSDC`) or sweep (`sweepSurplusUSDC`). There is no public way to recognise it. So today's plain `transfer` must not simply be pointed at the staking address. It has to become a deposit.
- **Where the money goes:** stakers are credited pro rata on the **total** REGENT supply, and the unstaked remainder goes to a treasury balance the Safe can withdraw.

**The change (commit C3), as amended in review (section 8):** the deposit is made by the fleet's `KeyfleetTreasury`, not by the core. The core never approves anything, so spec §7.2 ("no external token approvals ever originate from the protected rewards/settlement vault") holds without an exception, and no extra contract is needed.

```solidity
// Keyfleet (core)
function sendProtocolShare() external nonReentrant {
    uint256 amount = protocolShareOwed;
    protocolShareOwed = 0;
    USDC.safeTransfer(address(TREASURY), amount);
    TREASURY.depositProtocolShare(amount);              // reverts the whole call if staking refuses
    emit ProtocolShareSent(amount);
}

// KeyfleetTreasury
IRegentRevenueStaking public immutable REGENT_STAKING;   // pinned 0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5

function depositProtocolShare(uint256 amount) external onlyFleet nonReentrant {
    USDC.forceApprove(address(REGENT_STAKING), amount);                    // exact, same call
    uint256 received = REGENT_STAKING.depositUSDC(amount, PROTOCOL_SHARE_TAG, bytes32(uint256(uint160(address(FLEET)))));
    if (received != amount || USDC.allowance(address(this), address(REGENT_STAKING)) != 0) revert StakingDepositFailed(amount, received);
}
```

- **Still the same:** 10% of every purchase, booked at purchase and sent whole by anyone.
- **`PROTOCOL_SHARE_TAG`:** a fixed constant. C3 copies the exact tag convention that the Regents staking reader already indexes (read in `repos/regents` at that commit; not yet checked).
- **A purchase never touches staking.** If staking is paused, or the owed amount is zero, only `sendProtocolShare` reverts, the whole call unwinds and the share stays owed in the core. A reverted press is an accepted outcome, so the button is never gated (rule 11).
- **The owed share never sits in the treasury between transactions.** It passes through inside one call; `depositProtocolShare` shares the treasury's reentrancy lock with `executeBatch` and `processDailySplit`, so no approved call or split can run in the middle of it.
- **The only approval this path makes** comes from the treasury (the account the spec lets approve), is exact, goes to one pinned non-proxy address, and is asserted back to zero.
- **Other protocol revenue paths:**
  - No other KeyFleet contract path pays protocol revenue.
  - Autolaunch v2's per-launch splitter already sends its 2% of USDC revenue to this staking contract through `depositUSDC`.
  - Any site-side Regents revenue follows rule 41 a off chain (the server deposits it, tagged), not in these contracts.

---

## 4. Design of each new piece

Shared conventions:

- Solidity 0.8.26, OpenZeppelin 5.x, no proxies, no `delegatecall`, and only internal (inlined) libraries.
- Every token-moving entry point uses `nonReentrant`. Checks, then effects, then interactions.
- Timestamps in seconds.

### 4.1 Presence queue (§5.2–5.3)

**Lives in:** `KeyfleetVotes`, through the internal library `KeyfleetPresence`.

**Storage sketch:**

```solidity
uint64 constant WINDOW = 172_800;            // 48 h in seconds
struct Node { uint32 prev; uint32 next; uint64 expiresAt; uint64 epoch; }
mapping(uint256 tokenId => Node) node;       // one entry per key, never one per renewal
uint32 head; uint32 tail;                    // expiry-ordered (append-only expiries are non-decreasing)
uint32 queued;                               // indexed count; MAY include unswept expired entries
uint48 stateRevision;                        // +1 on every touch, clear, and proposal opening
mapping(uint256 tokenId => Checkpoints.Trace208) activity; // revision -> lastActiveAt (0 = cleared)
```

Token ids fit in 32 bits: Classic has 1,024, Accelerant 2,000, and Fibonacci level 40 ends at about 7×10^8. The engineer asserts this bound in `Keyfleet` at mint, with `tokenId <= type(uint32).max`; the Fibonacci price passes a billion USDC long before that.

**Operations:**

- **`touch(k)`**, internal. Called only from Present, a ballot, proposal creation and cancellation, after the caller has been authorised for `k`.
  1. If `k` is queued, unlink it.
  2. Append `k` to the tail with `expiresAt = now + WINDOW` and `epoch = ownershipEpoch(k)`.
  3. If it was not queued, `queued++`.
  4. `stateRevision++`, then push the checkpoint `(stateRevision, now)`.
  5. Emit `Present(k, now, block.number, epoch)`.

  The cost is constant: a few cold slot writes (estimate 45–70k gas, to be measured).
- **`onKeyMoved(k)`**, callable only by the fleet from `_update`. If `k` is queued: unlink it and `queued--`. Then `stateRevision++` and push `(stateRevision, 0)`. This invalidates the old owner's presence without erasing history. A mint calls it too, which writes a harmless zero checkpoint, so the hook needs no special case.
- **`sweepExpired(limit)`**, permissionless. While `head != 0`, `node[head].expiresAt <= now` and fewer than `limit` entries have been removed: pop the head and `queued--`. It writes no checkpoint, because a key's expiry is already implied by its last `lastActiveAt`. It returns the number removed and whether any are still due.
- **`isActive(k, t)`**: `node[k].expiresAt > t`, the stored epoch equals `ownershipEpoch(k)`, and the latest checkpoint is not a clear.

**Why the queue stays sorted:** every append sets `expiresAt = block.timestamp + WINDOW`, and block timestamps never decrease. Ties within a block are fine.

**Opening a proposal:**

1. Sweep up to `SWEEP_IN_PROPOSE` (recommend 256) due entries.
2. If any entry is still due, revert `MaintenanceRequired(dueRemaining > 0)`. A stale count is never accepted.
3. Touch the author key.
4. Record `openRevision = ++stateRevision`, `openedAt = now` and `E0 = queued`. After the sweep, `queued` is exact.

Present and ballots never require cleanup. Only opening a proposal needs a clean queue.

**Gas bounds:** to be measured and asserted as ceilings, like today's suite.

- `touch`: O(1).
- `sweepExpired`: O(limit), estimated 8–15k gas per entry. The worst case of all 2,000 Accelerant keys expiring at once is about 30M gas, done in several calls.
- `propose`: O(`SWEEP_IN_PROPOSE`).
- A ballot: O(log c), where c is that key's number of checkpoints (OpenZeppelin `upperLookupRecent`).

**Invariants** (handler-based invariant test with a small key set):

1. Every queued node has `expiresAt` that is non-decreasing from head to tail.
2. `queued` equals the number of linked nodes.
3. After a full sweep, `queued` equals the number of keys `k` with `isActive(k, now)`.
4. No key appears twice in the queue.
5. A key with no record is not active.

### 4.2 Ownership epochs and checkpoints

`Keyfleet.ownershipEpoch` stays: 1 at mint, plus one on every transfer.

**Is key `k` in proposal P's opening electorate?** `k ∈ E0(P)` exactly when:

- the latest checkpoint of `k` with revision ≤ `P.openRevision` holds a value `a ≠ 0`, and
- `a ≤ P.openedAt < a + WINDOW`.

Because the revision orders every touch, transfer and opening, this answers same-block cases exactly. In the same block:

- touch, then transfer, then open: `k ∉ E0`;
- open, then transfer: `k ∈ E0`, and the new owner controls that slot.

Delegated authority is bound to the epoch through Shards, so a transfer kills every old delegation and every old signature, because the epoch is part of the signed message (§4.3).

The checkpoint library is OpenZeppelin `Checkpoints.Trace208`, with a `uint48` revision key and a `uint208` timestamp value. It is reviewed, inlined code.

### 4.3 Delegation and signatures (§5.1)

**`KeyfleetShards` changes:**

- `Shard { tokenId, expiresAt, epoch, ended, uint8 caps }`, where `caps` is a bitmask of `WORKSPACE = 1`, `PRESENCE = 2` and `GOVERNANCE = 4`.
- `issue(tokenId, wallet, days, caps)`.
- `delegationRevision[tokenId]` goes up on every issue and every end for that key.
- `hasCapability(wallet, tokenId, cap)` is a view.
- Shards are keyed by `(tokenId, wallet)`, so one agent wallet may hold shards of several keys (P14, section 8). `shardOf(wallet)` is replaced by `shardOf(tokenId, wallet)`; the site's shard reader changes with it (S3, S4).

A marketplace approval (`approve`, `setApprovalForAll`) grants nothing here.

**Controller of key `k` for capability `c`:** the owner of `k`, or a wallet holding an active shard of `k` (same epoch, not ended, not expired) that includes `c`.

**Direct path:** `msg.sender` is the controller.

**Signed path:** anyone may submit `presentBySig`, `castBallotBySig`, `proposeBySig` or `cancelBySig`. The EIP-712 domain is `name = "KeyfleetVotes"`, `chainId = 8453` and `verifyingContract = votes`. The message types are:

- `Present(address fleet, uint256 keyId, uint64 epoch, uint64 delegationRevision, address signer, uint256 nonce, uint256 deadline)`
- `Ballot(uint256 proposalId, bytes32 proposalHash, uint256 keyId, uint64 epoch, uint64 delegationRevision, uint8 choice, address signer, uint256 nonce, uint256 deadline)`, the financial approval. It is a different type from Present.
- `Propose(...)` and `Cancel(...)` follow the same pattern.

Verification uses `SignatureChecker.isValidSignatureNow(signer, digest, sig)`, which covers ordinary wallets (ECDSA) and deployed contract wallets on Base (ERC-1271), with OpenZeppelin `Nonces` per signer. A third party cannot change the choice, the proposal or the key, because all three are signed.

The SIWA sign-in grants nothing on chain.

### 4.4 The growing electorate (§6)

**Storage sketch:**

```solidity
enum Choice { None, Yes, No, Abstain }
struct Proposal {
    uint256 authorKey; bytes32 contentHash; bytes32 actionsHash; bytes32 proposalHash;
    uint48 openRevision; uint64 openedAt; uint64 closesAt; uint64 executionExpiry;
    uint32 e0; uint32 late; uint32 yes; uint32 no; uint32 abstain;
    bool cancelled; bool executed;
}
mapping(uint256 id => Proposal) proposals;
mapping(uint256 id => mapping(uint256 key => Choice)) ballot;
mapping(uint256 id => mapping(uint256 key => bool)) joinedLate;
```

**Casting a ballot** (`castBallot(id, keys[], choice)` or the signed form):

1. Authorise the caller as controller with GOVERNANCE, and require `now < closesAt`, not cancelled.
2. For each key: if `ballot == None` and not `joinedLate`, and the key is not in `E0` (section 4.2), then set `joinedLate = true` and `late++`.
3. Subtract the previous choice from the tallies and add the new one. Repeating the same choice changes nothing.
4. `touch(k)`.

**Status, worked out from stored facts** (there is no `finalize` write):

- `Cancelled` if cancelled; else `Executed` if executed.
- Else `Open` if `now < closesAt`.
- Else, with `D = e0 + late`:
  - `Rejected` unless `D > 0 && yes > D/2`;
  - `ExecutionExpired` if `now ≥ executionExpiry`;
  - otherwise `Approved`.

Tallies cannot change after `closesAt`, so this view is final. The `proposal_finalize` operation in §12 becomes a read of this status. Decision 12 confirms that.

**Invariants:**

- `D` never decreases.
- `yes + no + abstain ≤ D`.
- Each key holds at most one slot per proposal.
- Present never changes any open `D`.
- `e0 ≥ 1`, because the author is touched before `E0` is recorded.

### 4.5 Exact proposals and execution (§7), CALL only

**Creation:** `propose(authorKey, contentHash, closesAt, Call[] calls)`.

- Requires `now < closesAt ≤ now + 48h`, and authorises the caller as controller of `authorKey` with GOVERNANCE.
- Sets `executionExpiry = closesAt + 48h` and `actionsHash = keccak256(abi.encode(calls))`.
- `proposalHash = keccak256(abi.encode(block.chainid, votes, treasury, id, authorKey, ownershipEpoch(authorKey), contentHash, actionsHash, closesAt, executionExpiry))`.
- Emits `ProposalCreated(id, authorKey, proposalHash, contentHash, closesAt, executionExpiry, e0, openRevision, calls)`, so indexers get the exact bytes.
- Reserves nothing. There is one shared `proposalCount`, so every resubmission gets a new id.

**Cancellation:** `cancel(id)` by the current controller of `authorKey` with GOVERNANCE, while status is Open or Approved.

**Execution:** `execute(id, Call[] calls)`.

- Anyone may call it. It requires `status == Approved` and `keccak256(abi.encode(calls)) == actionsHash`.
- It sets `executed = true`, then calls `TREASURY.executeBatch(calls)`, which only Votes may call.
- The treasury runs each call in order: `target.call{value}(data)`, reverting the whole batch on the first failure and bubbling up the reason. A failed batch therefore stays Approved and can be retried until expiry, and a batch never half succeeds.
- `execute` is `nonReentrant`, so an approved call cannot execute another proposal inside itself.

**Typed effects** (treasury functions callable only when `msg.sender == address(this)`, so the only way to reach them is an approved CALL):

| Function | What it does |
|---|---|
| `pay(asset, to, amount)` | `SafeERC20.safeTransfer`, so a token that returns `false` reverts; `Address.sendValue` for ETH. The builder sends every token payment through here, never as a raw `transfer` CALL. |
| `advance(id, operator, asset, amount, purposeHash)` | Like `pay`, and also records `outstanding[id]` for the treasury screen. |
| `setDailySplitBps(bps)` | Section 4.6. |
| `admitOusd(token)` | Fills the OUSD slot once, active from the next full period. |
| `approveSignatureHash(h)` / `revokeSignatureHash(h)` | Section 4.8. |

`Votes.setEditsRestricted(key, bool)` can only be called by the treasury.

**What execution does not do:** it does not gate other calls on the daily split, reserve funds or reinterpret call data. If an approval no longer fits the free balance, the batch reverts and the screen shows it.

**Allowances (§7.2).** The transaction builder (site) defaults to `approve(exact)` → action → `approve(0)` inside one batch, and flags any lasting permission prominently. The treasury itself has no `approve` helper.

### 4.6 Daily fair split (§8)

**Treasury storage sketch:**

```solidity
enum Slot { ETH, REGENT, USDC, OUSD, TOKEN }
address constant NATIVE = address(0);
mapping(Slot => address) asset;                // ETH/REGENT/USDC immutable at deploy; OUSD/TOKEN set once
mapping(Slot => uint64) activeFromPeriod;      // OUSD: next full period after admission; TOKEN: after binding
mapping(Slot => uint64) lastProcessedPeriod;   // allocation or skip, at most one per period
uint16 currentBps = 50; uint16 pendingBps; uint64 pendingFromPeriod;
uint256 constant THRESHOLD_ETH = 0.05 ether;   // others: 100 * 10**decimals, decimals read and fixed at binding
```

**`processDailySplit(slot)`**, permissionless; `processAll()` runs it once for each bound slot.

1. Require `firstMintAt != 0`. Set `e = (now − firstMintAt) / 1 days`, and require `e ≥ 1`, `lastProcessed < e` and `e ≥ activeFromPeriod`.
2. Apply a pending rate that is due: if `pendingFromPeriod ≤ e`, then `currentBps = pendingBps`.
3. Read `B = address(this).balance` for ETH or `balanceOf(this)` for a token, and `N = FLEET.totalMinted()`.
4. If `N == 0` or `B < threshold`, record a skip: `lastProcessed = e`, `SplitSkipped`.
5. Otherwise compute `raw = mulDiv(B, bps, 10_000)` and `perKey = raw / N`. If `perKey == 0`, record a skip. If not, set `allocated = perKey × N` and `lastProcessed = e`, then fund Rewards (step 6). The remaining dust stays in the treasury.
6. Fund Rewards. For ETH: `REWARDS.fundSplitNative{value: allocated}(perKey, N)`. For a token: `safeTransfer(REWARDS, allocated)`, then `REWARDS.fundSplit(token, perKey, N)`.

Missed periods are never backfilled: only the current `e` is processed. A revert anywhere leaves the period unprocessed, and other slots are independent.

**Rate change.** `setDailySplitBps(bps)` requires `10 ≤ bps ≤ 100`, applies any due pending rate first, then sets `pendingBps = bps` and `pendingFromPeriod = currentPeriod + 1`. A later change in the same period overwrites a pending rate that is not yet due. It can only be reached by an approved CALL; there is no developer setter.

**Rewards additions:**

```solidity
mapping(address asset => uint256) splitIndex;                 // atomic units per Key, integer, cumulative
mapping(uint256 key => mapping(address asset => uint256)) keySplitIndex;
address[] splitAssets;                                        // append-only, at most 5, filled on first funding
```

- **`fundSplit(asset, perKey, n)`**, treasury only, and only while the treasury is inside `processDailySplit` (review amendment, section 8).
  0. Require `TREASURY.splitInProgress()`. The treasury sets this flag with OpenZeppelin `TransientSlot` at the start of `processDailySplit` and clears it at the end. `executeBatch` never sets it, so an approved CALL from the treasury to Rewards cannot fund a split outside the rate, threshold and once-per-period rules, or fill the five split-asset entries with other tokens.
  1. Require `FLEET.totalMinted() == n`. A key minted during funding, for example from a token callback, makes it revert, so a new key never shares an allocation worked out before its mint.
  2. Require `balance ≥ backed + perKey × n`.
  3. Then `splitIndex += perKey` and `backed += perKey × n`. Append the asset to `splitAssets` the first time.
- **`fundSplitNative`** does the same for ETH, with the same flag check and `msg.value == perKey × n`.
- **Mint (`enrollKey`):** for each asset in `splitAssets`, `keySplitIndex[k][a] = splitIndex[a]`. Assets bound later start at index 0, which is correct for every key.
- **`settleKey(k, from)`** settles both lanes: the cohort USDC income, and `(splitIndex[a] − keySplitIndex[k][a])` for each split asset, into `credits[a][from]`. This happens before every transfer. It loops over at most 5 assets plus one cohort.
- **`claim(asset, keys, to)`** settles the caller's own keys, then pays the caller's credit, with `Address.sendValue` for ETH. One asset per call, so a recipient that refuses ETH blocks only its own claim. Only the owner can redirect with `to`; there is no operator path.
- **Native ETH:** Rewards has a `receive` that accepts only from the treasury, and only inside `fundSplitNative`.

**Invariants:**

- For every asset, `balance(Rewards, a) ≥ backed[a]`, and `backed[a]` equals the unpaid credits plus the unsettled index accruals plus dust.
- The sum over keys of accrued plus credited equals the total allocated.
- Rewards balances are never part of `B`, because Rewards is a separate account.
- At most one allocation per slot per period.
- The rate always stays in [10, 100].

### 4.7 Income versus capital, and Autolaunch (§9)

**Where money arrives:** at the treasury, the fleet's one payment address, published on the fleet page.

- Purchase capital and released Cascade surplus are sent there when booked. Anything paid to the core by mistake, USDC included, is forwarded there by `recognizeSurplus`.
- A launch's REGENT raise, its payment receiver's remainder and its vested tokens arrive there too (section 9.2).
- All of it is free capital and part of the split base. The ledger's holdings are never counted, so nothing is split twice.

**Returned advances.** `returnAdvance(id, amount)` pulls the asset, or takes `msg.value` for ETH. It is capped at `outstanding[id]` and lowers it. Funds above the cap are refused, so the "refund" label cannot be stretched.

The spec's point that an operator could relabel customer receipts as refunds is only partly closed on chain. The cap limits the label to what was advanced, but an operator holding customer income can still return it against an open advance. Disclosure and the evidence links cover the rest. This goes to the reviewer as a known limit.

**Autolaunch launch.** Built in C12 against Autolaunch Revstake v2 (P10 b); section 9.2 is the build. The launch caller and the launch's treasury are both the fleet's `KeyfleetTreasury`:

- A launch is an exact approved CALL from the treasury to the pinned v2 factory's `launch(params)`, with `params.treasury` the treasury itself.
- `bindLaunchToken(launchId)` is permissionless and runs once. It requires the factory's record to name the treasury as both launcher and treasury, and the strategy to record the launch as graduated. It then binds the TOKEN slot from the next run.
- Only the TOKEN balance actually held by the treasury counts. Unvested escrow, liquidity positions and stake are elsewhere, so they are excluded.

### 4.8 Segregated vaults (§3, §4.3)

| Account | Holds | Can make arbitrary calls? | Approvals out |
|---|---|---|---|
| `Keyfleet` (core) | Cascade reserve, owed protocol share, USDC income on its way to Rewards | No | None (the staking deposit is made by the treasury, section 3.2) |
| `KeyfleetRewards` | All member claims: income, rebates, Cascade repayments, split allocations | No | None |
| `KeyfleetVotes` | Nothing (matching is deleted) | No | None |
| `KeyfleetTreasury` | Free capital only | Yes, approved `Call[]` | Through approved calls, plus the exact staking deposit of section 3.2 |

Acceptance (§13 step 2):

- No approved batch can lower `Keyfleet`'s reserve or owed share, or Rewards' `backed` or balance. Invariant: random `Call[]` against all four contracts, with Rewards and core balances never below their booked figures.
- The CI bytecode check finds no reachable `DELEGATECALL` or `SELFDESTRUCT` in the five contracts. It disassembles with `cast disassemble`, which skips push data, rather than searching raw bytes. Slither runs with its delegatecall and arbitrary-send detectors.

### 4.9 Lit ChainSecured ownership (§11)

What Lit's documentation says, from [S4](https://developer.litprotocol.com/management/account_modes), checked 6 October 2026:

- **Base is the only supported chain** for ChainSecured accounts.
- A wallet, including a contract, directly owns the account through Lit's `AccountConfig` diamond on Base. Its address comes from `GET /get_node_chain_config`.
- Administrative writes are on-chain transactions sent by the owner, so the treasury must send them itself as approved CALLs. These include creating the account, transferring ownership (`transferChainSecuredAccountOwnership`), creating groups, adding actions and minting usage keys.
- Some steps also need an off-chain signature from the owner, for example the EIP-712 `CreateWallet` for a key. For a contract owner, Lit's server checks it with ERC-1271 `isValidSignature(digest, signature)` on Base.
- Counterfactual (ERC-6492) wallets are not supported, so the treasury must already be deployed.
- Lit Action execution uses the same `/core/v1` API in both account modes.

Design:

- **The treasury implements ERC-1271.** `isValidSignature(h, sig)` returns the magic value exactly when `approvedHash[h]` is true. A proposal that calls `approveSignatureHash(h)` sets it, and a later one can revoke it. No raw bytes are ever signed by default, and no backend signer exists.
- **Flow:** every write to `AccountConfig` is a CALL in an approved proposal, and every signed message is approved first with `approveSignatureHash`. The steps are: create the account, create one inbox group with its action, mint one execute-only usage key for the operator, then replace or revoke that key.
- **Base governance and claims never depend on Lit.**
- **Signed requests have a five-minute window.** Lit's server (`lit-api-server/src/core/eip712.rs`) takes a signed request such as `CreateWallet` only within 300 seconds either side of its `issuedAt`, and each digest only once. Its domain is name "Lit ChainSecured", version "1" and the chain id, with no verifying contract, and the message is `(address, issuedAt)`. So a proposal that approves a Lit digest sets `issuedAt` to when it will be carried out, at or after it closes, and the operator posts the request to Lit within five minutes of that.

What can and cannot be tested before a real deployment:

| Test | Where |
|---|---|
| ERC-1271 yes/no, approval and revocation of a hash, a revoked hash refused | Unit (local) |
| Admin writes are exact CALLs a proposal can carry; a non-approved call cannot reach `AccountConfig` | Unit, with a mock `AccountConfig` |
| The real `AccountConfig` accepts the treasury's admin write (ownership, group, usage-key mint) | **Fork of Base**, against the real diamond read from `get_node_chain_config` (`test/fork/KeyfleetLitFork.t.sol`) |
| Lit's server registers the contract-owned account, checks ERC-1271 on the real treasury, mints a usage key, runs the inbox Action, and refuses admin from the execute-only key | **Not testable locally or on a fork.** Lit's servers run only against Base mainnet, so this needs a real treasury on Base mainnet. Decision 9. |
| A Lit outage leaves voting and claims working | Unit (Lit is never on that path) |

### 4.10 Spec acceptance tests mapped to Foundry

Kinds of test:

- **U** is a unit or fuzz test in `test/*.t.sol`.
- **I** is a handler-based invariant test in `test/invariant/*.t.sol`.
- **F** is a fork test in `test/fork/*` that runs only with `BASE_RPC_URL` set.

**Membership and authority**

| Spec test | Kind |
|---|---|
| Unauthorised owner changes | U |
| A marketplace approval is not delegation | U |
| Old signatures fail after transfer or revocation, through the epoch and delegation revision | U |
| A contract wallet signs validly (ERC-1271 mock) | U, plus F with a real Safe on Base |
| One person holds many keys | U |
| Mutes do not affect direct governance | U; mutes are off chain, so this checks the contracts ignore them |
| Optional identity systems are absent | U |

**Presence**

| Spec test | Kind |
|---|---|
| Exact 48-hour boundary (`warp` to `t+WINDOW−1` and `t+WINDOW`) | U |
| No transactions for three days | U |
| Present when all keys are dormant | U |
| Sweeping is bounded (gas ceiling per entry, `limit`) | U |
| Refreshing an unswept expired entry | U |
| A stale count is refused when opening a proposal | U |
| Same-block touch, transfer and proposal ordering (several calls in one test, no `roll`) | U |
| Duplicate signed receipts (nonce) | U |
| Timestamps rather than block numbers (`warp` without `roll`, and `roll` without `warp`) | U |
| A keeper cannot mark someone else Present | U |
| The queue and count invariants | I |

**Electorates**

| Spec test | Kind |
|---|---|
| D=1, Yes=1 | U |
| Ties fail | U |
| Late Yes, No and Abstain | U |
| A key minted during voting | U |
| An included key expires | U |
| A transferred key changes its ballot without double counting | U |
| Present alone leaves an open D unchanged | U |
| Repeated same-choice ballots | U |
| Creation touches the author but casts no Yes | U |
| No late admission after closing | U |
| Every denominator move is non-negative; D never shrinks; tallies ≤ D | I |
| The spec's §6 example table, row by row | U |

**Execution**

| Spec test | Kind |
|---|---|
| A changed target, data, order or chain is refused (hash mismatch; chain through `proposalHash` and the EIP-712 domain) | U |
| Execution before closing is refused | U |
| The author cancels | U |
| An identical resubmission is accepted | U |
| A failed atomic batch can be retried | U |
| Execution expiry | U |
| Not enough free capital after a fair split | U |
| Two approvals cannot double-spend | U |
| Submitting reserves nothing | U |
| An ERC-20 that returns `false` reverts through `pay` | U, with a mock token |
| Reentrant callbacks cannot alter protected accounting | U, plus I |

**Daily allocations**

| Spec test | Kind |
|---|---|
| 10, 50 and 100 bps work; 9, 101 and 0 are refused | U |
| A pending rate starts the next period | U |
| Thresholds just below, equal to and above | U |
| Tokens with 6 and 18 decimals | U |
| No USD conversion (there is no oracle, so none exists to test) | U |
| N=0 | U |
| N larger than the raw atomic allocation (skip) | U |
| Dust is kept | U |
| At most once per asset per period | U, plus I |
| Skipped periods are not backfilled | U |
| A small balance is skipped | U |
| One failed asset does not stop the others (a reverting mock token) | U |
| No launch means no TOKEN slot | U |
| Unvested balances are excluded | U, plus F against the Autolaunch escrow |

**Ownership and rewards**

| Spec test | Kind |
|---|---|
| Alice earns, transfers, and Bob claims | U |
| A former owner with no keys still claims | U |
| Mint before and after an allocation | U |
| Dormant and muted keys get equal shares | U |
| Several keys add up | U |
| Rewards never re-enter the split base | U, plus I |
| Funding equals liabilities | I |
| A token callback tries a transfer, mint or claim during funding | U, with a malicious mock token |
| A recipient that refuses ETH is isolated | U |

**Economics**

| Spec test | Kind |
|---|---|
| USDC paid to the core is forwarded to the treasury as capital | U |
| Sale and settlement obligations kept: today's purchase, Cascade and Accelerant suites, carried over | U |
| Returned advances are not counted twice | U |
| No splitter loop | U |
| Fees unchanged: 10% to staking | U, plus F against the real staking |
| Governance may spend all free capital but never funded claims | U, plus I |
| Moving capital out lowers future splits | U |

**Integrations**

| Spec test | Kind |
|---|---|
| OUSD is never enabled from an Ethereum address or a same-symbol token (the slot is unconfigured until a proposal; no address is hard-coded) | U |
| Rebasing behaviour is tested before admission (deferred: OUSD is unconfigured) | — |
| A disabled OUSD does not stop the fleet | U |
| A Lit execute-only key cannot administer | Live only (section 4.9) |
| A Lit outage does not stop voting or claims | U |
| Revenue routing uses the exact selected Autolaunch deployment | F |

---

## 5. Site impact (`platform/`), list only

**Chain and config**

- `config/config.exs:39,45`: `:wallet_chains` and `:chain_nodes` move from `%{1 => Ethereum…}` to `%{8453 => Base…}`. `runtime.exs:47-63` keeps `KEYFLEET_RPC_URL`, which now points at a Base node.
- `Chain.RpcClient` (comment about 12-second blocks), `Chain.Cursor` (`@fresh_blocks 50`, "ten minutes of Ethereum") and `Chain.Scanner` (`@rescan_blocks 32`, "one Ethereum epoch") are re-tuned for Base's 2-second blocks. Follow the Base rule of reading `latest` and never waiting for L1.

**Deployments**

- `Keyfleet.Fleets.record_manifest!/1`, the `fleet` resource (8 bound columns, all null or all set), the `shared_wiring` validation and `release.ex seed_deployment` gain `treasury_address`, the bound split assets and the staking address. Hard cutover: there is no deployed data.
- The `mix keyfleet.seed_deployment` example moves to `base.classic.deployed.json`.

**Readers and indexing**

The scanner reads the core, Votes, Shards, **Treasury** and **Rewards** logs. These decoders must be **deleted**:

- `BudgetPaid`
- `SharedMoneyRecognized`
- `PayProposed`
- `RestrictEditsProposed`
- `VoteCast(bool)`
- `VoteWithdrawn`
- The kind-based `ProposalCreated`

These must be **added** (in the indexer, the scanner reads them):

- New `ProposalCreated` (with calls), `BallotCast(choice)`, `ProposalCancelled`, `ProposalExecuted`
- `Present` and `PresenceCleared`, plus `Swept`
- `SplitProcessed` and `SplitSkipped`, `RateChangeScheduled`
- `Advanced` and `AdvanceReturned`
- `ForwardedToTreasury`, `ProtocolShareSent`
- `Settled` and `Claimed` per asset

**Pinned topics.** The topics test (today's `KeyfleetVotesTopics.t.sol`) is rewritten so the site and the contracts keep sharing pinned topics.

**Treasury reader.** `TreasuryReader` reads treasury balances per slot, `backed` per asset, `cascadeReserve`, `protocolShareOwed`, outstanding advances and the rate state. `RewardsWaiting` reads `accrued` for every reward asset, not just USDC.

**Wallet steps** (`wallet_steps/build.ex`, `steps.ex`)

Delete these flows:

- `collect`
- `delegate` (`setVotingDelegate`)
- `propose_payment`
- `propose_edits` as separate entry points
- `vote` yes/no and `withdrawVote`

Add these flows:

- `present`
- `vote` (Yes, No or Abstain)
- `propose` (exact `Call[]` built from typed templates: pay, advance, rate change, restrict edits, decision, Lit admin, launch)
- `cancel`
- `carry_out` (now passes the calls)
- `sweep`
- `split_process`
- `claim` (per asset, including ETH)
- `return_advance`
- `issue_shard` (with capabilities)

The buy flow stays (approve USDC, then purchase) and moves to Base USDC. Every button reaches the wallet on every press. Nothing on the page blocks, defers or de-duplicates a press (hard rule 11). A press that reverts is an accepted outcome.

**TypeScript.** `send_step.ts` already switches chains. Its test defaults (`assets/test/onchain_steps.test.ts:19,32` and `stand_in_wallet.ts`) move to `0x2105`.

**The SIWA smart-wallet rule**

- `actors/agent.ex:11-16,34-38` flips: smart wallets (`:erc1271`, `:erc6492`) count only when signed in on **Base (8453)**. Plain wallets are unchanged (1 or 8453).
- Also update: `plugs/signed_agent.ex:206-211` (`smart_wallet_on_base?` becomes an Ethereum refusal), `refusal.ex:18-20`, `code_password.ex`, `priv/public/docs.md`, `skill.md`, and `api-contract.openapiv3.yaml:979,1128,1856`.
- Tests: `agent_join_journey_test.exs:376-377,438-445`.

**Key pages and new screens (§12)**

- **Present card:** pinned on the key page and the proposals page. It shows active until a time, dormant, or "maintenance needed before a new proposal", and has a Present button.
- **Proposal view:** shows the proposal's own denominator D (opening count plus late joiners), Yes, No and Abstain, closing time, execution expiry and status. It is kept separate from the fleet-wide active count, which is labelled as an indexed count and never as an exact live count.
- **Treasury:** free capital, estimated next fair split, funded member claims, protocol and settlement obligations, and funds advanced outside the treasury.
- **Split preview:** asset and address, free balance, rate for the current period, threshold, minted keys, estimated total and per-key amounts, last processed period, next due time, pending rate and when it takes effect, and failed or unavailable status. Use the spec's exact wording: "one checkpoint per 24-hour period".
- **Remove the Ethereum and old-rule copy** listed by the inventory: `fleet_live.ex:722-922` (including the etherscan link, which becomes basescan), `wallet_words.ex`, `rules.ex`, `proposals_live.ex` ("more than half of all keys sold", "no deadline", "matched", "Collect the match"), `about.md`, `llms.md`, `terms.md`, `docs.md`, `skill.md` and `api-contract.openapiv3.yaml`.
- **Add** the spec's §14 disclosure before purchase and delegation.

**Background jobs (Oban)**

- `SweepExpired`: a cron that submits `sweepExpired(limit)` when the queue head is due.
- `ProcessDailySplit`: a daily cron after the period boundary, calling `processAll()`.
- Indexing: today it is a GenServer poller. The spec names Oban for indexing; follow the shared chain-events skill.

None of these decides anything; the contracts check everything. Sending the first two needs a gas-paying wallet run by the server, which is a new thing: today "the site never sends a transaction". That is decision 8.

**Agent API, CLI and WebMCP**

- The operations from §12: `present`, `presence_status`, `proposal_*`, `fair_split_*` and `rewards_claim`.
- These change in `cli/commands.json` (today only reads) through the regents-cli site-commands rule, and in the WebMCP manifest and the agent routes (`router.ex:181-205`).
- The agent shard API stops saying "send on Ethereum".

**Other places that carry a chain id**

- The graph principal `member:#{chain_id}:…` (`graph/checks/key_actor.ex`).
- About 25 test files that pin `chain_id: 1` and Ethereum USDC (`test/support/chain_helpers.ex:28,33`, `browser_chain.ex:46-47`, `test_chain_node.ex:39`, and the files they feed).
- The anvil lab (`test/support/anvil_lab.ex`, `AnvilLab.s.sol`).

---

## 6. Build order (spec §13), as commits for review

Each commit:

- leaves `forge build` and `forge test` passing;
- deletes what it replaces (hard cutover);
- updates `contracts/README.md` for what it changes.

Sizes are rough source lines changed, tests included.

| # | §13 step | Commit | Acceptance checks | Size |
|---|---|---|---|---|
| C1 | 1 | This plan | Sean answers section 7 | doc |
| C2 | 1 | **Base manifest and pins.** Add `deployments/base.json`, delete `ethereum.json`. Pin Base USDC, VRF coordinator and gas lane, REGENT, staking and the Safe in `KeyfleetManifest`. Update the anvil manifest. Replace the Ethereum fork test with `fork/KeyfleetBaseFork.t.sol` (gas lane exists, USDC has 6 decimals, staking has code, REGENT `decimals`). | Refusal tests per pin. The fork test is green with `BASE_RPC_URL`. No Ethereum pin is left. | ~400 |
| C3 | 2 | **Treasury split out; matching deleted.** New `KeyfleetTreasury` (it receives funds; execution comes later). Purchase capital, Cascade surplus and non-USDC surplus are forwarded to it. Delete `freeCapital`, `payFromBudget`, `collect` and matching. Deployment topology from the size measurements. | Every paid unit lands in the treasury, the reserve, the owed share or Rewards backing (today's conservation test, extended). The core and Rewards hold no free capital. Sizes are under 24,576 runtime and 49,152 initcode. | ~900 |
| C4 | 2 | **Protocol share to REGENT staking.** `sendProtocolShare` moves the owed share to the treasury, which deposits it into the pinned staking contract in the same call (section 3.2). `PROTOCOL_TREASURY` is deleted. | 10% is unchanged. A paused staking contract unwinds the call, leaves the share owed in the core and never blocks a purchase. The core makes no approval. The amount received is checked. The allowance ends at 0. A fork test against the real staking contract. | ~250 |
| C5 | 3 | **Presence.** `KeyfleetPresence`: touch, the queue, `sweepExpired`, checkpoints, `onKeyMoved`. Delete `lastMovedBlock`. Add `firstMintAt`. | The presence tests from 4.10. Queue invariants. Gas ceilings for touch, sweep per entry and the transfer hook. | ~700 |
| C6 | 3 | **Delegation and signatures.** Shard capabilities and delegation revision. EIP-712 Present and Ballot. Delete `votingDelegate`. | Old-signature, ERC-1271, nonce, marketplace-approval and keeper-cannot-present tests. | ~600 |
| C7 | 3 | **Proposals and the growing electorate.** New proposal shape, ballots, worked-out status, cancel, expiry. Delete the kinds, `withdrawVote` and three fifths. | The electorate tests and invariants from 4.10. The §6 example table. | ~1,000 |
| C8 | 4 | **Exact CALL execution.** `executeBatch`, the `onlySelf` functions `pay`, `advance` and `setEditsRestricted`, `returnAdvance`. Bytecode check script plus Slither config. | The execution tests from 4.10. The segregation invariant (random calls cannot lower protected figures). No `DELEGATECALL` or `SELFDESTRUCT` is reachable. | ~800 |
| C9 | 5 | **Rewards: multi-asset split index.** `fundSplit` and `fundSplitNative`, split settlement on transfer, ETH claims. | The ownership and rewards tests. Backing invariant per asset. Transfer gas ceiling with 5 bound assets. An approved CALL from the treasury to `fundSplit` or `fundSplitNative` reverts. | ~600 |
| C10 | 5 | **Daily fair split.** Periods, rate state, thresholds, slots, `processDailySplit` and `processAll`, `admitOusd`. | The daily-allocation tests. Once-per-period invariant. The spec's §8.4 table, row by row. | ~700 |
| C11 | 5 | **Invariant suite**, combining handlers across all five contracts. | All invariants from section 4 hold over 256 runs × depth 100, or more. | ~500 |
| C12 | 7 | **Autolaunch path.** Minimal interfaces copied from Autolaunch Revstake v2, the factory pinned in the treasury and manifests, `bindLaunchToken`, and the launch as an approved call (section 9.2). | Fork test: a whole launch through an approved treasury call on a Base fork. TOKEN is bound only after success, and only released tokens count. | ~700 |
| C13 | 7 | **Lit.** ERC-1271 approved hashes, and a fork test of the treasury's admin writes on the real `AccountConfig`. | The local and fork rows of 4.9. The live row waits on decision 9. | ~400 |
| C14 | 8 | **Release readiness.** Gas report on a Base fork, README and `docs/deployment.md` rewritten for Base, deploy and record scripts for the five contracts, anvil lab. | `make check-contracts` passes. Deploy and record tests over a mock Base. Ready for outside audit (K-18). | ~600 |
| S1–S9 | 6 | **Site lane**, after C7 fixes the ABI. S1 config and chain; S2 manifest and fleet resource; S3 scanner and decoders; S4 treasury and rewards readers; S5 wallet steps and TypeScript; S6 SIWA rule; S7 pages and copy; S8 Oban workers; S9 agent API, CLI and WebMCP. | `mix test`, `mix test.external` against an anvil Base copy, and browser chain specs. | — |

Step 8 (independent review and controlled release) comes after C14. It needs an outside audit, fork and invariant evidence, a Base mainnet lab deployment if decision 9 is yes, and Sean's go. This plan authorises none of it.

---

## 7. Open points for Sean

Reviewed and trimmed by the KeyFleet chief engineer (section 8). Points the spec itself already settles are built as the spec says and are listed in 7.2, not asked. The questions put to Sean are in 7.1; the build follows each recommendation until he answers, and a different answer changes only the named commit.

### 7.1 Asked

| Plan id | Question | Recommendation | Commits it touches |
|---|---|---|---|
| P1 | The daily split's threshold (0.05 ETH, 100 tokens) is measured on the free balance before the cut (spec §2, flagged by the spec for review). | Yes | C10 |
| P2 | Keep the USDC income route: USDC paid to the fleet core goes 100% to the keys; only the treasury's holdings are split daily (spec §2 and §9, flagged for review). | Yes | C3, C10 |
| P3 | The Base addresses in section 3.1, including the Base Regents Safe signers, which differ from the Ethereum Safe's at the same address. | Confirm | C2 |
| P7 | A key's owner may let its agent mark the key present, vote and propose (spec §5.1). The product spec today says an agent never votes. | Follow spec v0.3, opt-in per shard | C6 |
| P8 | The site runs the daily split and the expiry clean-up from a small gas-only Base wallet (spec §5.3 and §12 call for Oban to do this). The product spec today says the site never sends a transaction. | Yes | Site lane S8 only |
| P10 | The fleet's token launch binds to Autolaunch v1 now, or waits for v2 on Base. | Depends on v2 timing | C12 only |
| P13 | Bring `docs/product-spec.md` in line with v0.3 (Base, the 48-hour electorate, agents per P7, the site wallet per P8, REGENT staking receives the 10%). | Yes, doc-only commit | Docs |
| P14 | One agent wallet may hold shards of several keys of the same fleet. | Allow it (changed in review, section 8) | C6 |

P9 (a throwaway Lit test fleet on Base mainnet) is a deployment and is asked at deployment time, with its own go.

### 7.2 Settled by the spec or by engineering, not asked

| Plan id | Settled as | Why |
|---|---|---|
| P4 | The treasury, not the core, approves and deposits the 10% (section 3.2). | Keeps spec §7.2 without an exception or a new contract. |
| P5 | Restricting a key's edits passes by the same `Yes > floor(D/2)` rule. | Spec §7.1: no separate quorum class. |
| P6 | Minority matching and "Collect the match" are deleted. | Spec §1 and §4.3. |
| P11 | Sequenced deploy of the five contracts. | Base's code-size limit; engineering only. |
| P12 | A proposal's result is a read; no finalize transaction. | Tallies cannot change after closing. |
| P15 | VRF on the 2 gwei lane, native ETH, 3 confirmations, 100,000 callback gas. | Base gas sits far below 2 gwei; a refused request can be retried. |
| P16 | Keys the treasury holds count, vote and earn like any other. | Spec §4.1 and §8.2 ("all existing minted Keys"). |

## 8. Chief engineer review (6 October 2026)

Checked against the spec, section by section: the electorate (E0 from the cleaned queue, late joiners, `Yes > floor(D/2)`, no shrinking, the §6 example table), presence (sorted queue, epoch clearing on transfer, same-block ordering through the state revision), exact CALL-only execution (hash binding, atomic batch, retry until expiry, cancel while Open or Approved), the daily split formula and rate timing (§8.3, §8.4), funded pull claims (§8.5), segregation (§3, §4.3) and rule 41 a. The design holds. Three amendments, applied above:

1. **Gap closed: an approved CALL could fund a split directly.** `KeyfleetRewards.fundSplit` was "treasury only", and every approved CALL is sent by the treasury. A proposal could therefore call it with any asset and amount, skipping the 10–100 bps bound and the once-per-period rule, and could fill the five split-asset entries with other tokens so OUSD or the launch TOKEN could never be added. Fix: Rewards also requires `TREASURY.splitInProgress()`, a transient flag only `processDailySplit` sets (section 4.6). A test in C9 proves an approved call to either funding function reverts.
2. **The 10% goes through the treasury.** The plan's version had the core approve staking, an exception to spec §7.2. Sending the owed share to the treasury and depositing it in the same call needs no exception and no new contract (section 3.2). C3 and C4 swap so the treasury exists first.
3. **P14 changes to "allow".** The spec's own test list includes "one person holding many Keys", and with explicit capabilities per shard there is no safety reason to force one agent per key. Shards become keyed by `(tokenId, wallet)`; a wallet's authority is always checked for a named key, so holding several never mixes them.

Watch items for the build, not decisions:

- `executeBatch`, `processDailySplit` and `depositProtocolShare` share one reentrancy lock in the treasury.
- `Keyfleet._update` calls `VOTES.onKeyMoved` on every transfer; its gas is measured and capped in C5 alongside the five-asset settlement of C9.
- `returnAdvance` limits relabelling only up to the open advance (section 4.7); this stays in the audit notes as a known limit.

### 8.1 Review of C8–C11 (6 October 2026)

The money paths hold:

- **USDC backing is never short.** Each key's share of a cohort allocation is rounded down, and the rounding is carried in the key's own snapshot, so keys are owed at most what was set aside. The ledger's USDC balance is at least its backing, and its backing is at least everything owed. The difference, under one unit per key, stays in the ledger. `invariant_usdcBackingCoversWhatIsOwed` asserts all three.
- **Split assets are exact.** Each split books `perKey × keys` against a balance check, and a key minted later starts from the current index. ETH, REGENT and USDC are owed exactly what the ledger holds.
- **Claims pay the holder.** The holder or an active shard presses; each key's money settles to `ownerOf` and the caller's own credit (a former holder's) is paid with it. Credits are zeroed before any payment, under the ledger's lock.
- **A failed transfer skips one asset; running out of gas reverts the run.** A transfer call keeps at most 1/64 of the gas back, so less than `gasBefore / 63` left means it ran out, and the whole run reverts rather than spending the day.
- **The bytecode check works.** Planted DELEGATECALL and SELFDESTRUCT are reported when reachable straight on or through a pushed jump target, and code nothing jumps to is not judged.

One admission precondition, written on `admitOusd`: the ledger requires the tokens it is funded with to arrive in full. A token that delivers less than sent, as some rebasing tokens do by a unit, would revert every later run for every asset, and admission is once. OUSD is not on Base today; before any proposal admits a token, its exact transfers are proven on a Base fork.

## 9. Sean's answers (6 Oct 2026)

- P1 a: the threshold is measured on the free balance. The daily split is a built-in treasury function that splits to all keys; an approved proposal may also run it again within the same day; the rate is 10–200 bps (0.1%–2%), changed by an ordinary majority proposal.
- P2 b: the USDC income route is dropped; all USDC is treasury capital.
- P3 a: Base addresses confirmed.
- P7 a: agents do the roll call (Present) automatically; agent voting is a simple per-key owner toggle, on by default.
- P8 b: no site wallet. Anyone may run the split once 24 hours have passed since the last run; if nobody runs it, it does not run.
- P10 b: wait for Autolaunch v2 on Base; C12 waits.
- P13 a: the product spec is updated (on main, by the chief engineer).
- P14 a: keys stack in a wallet; every key action is batchable.
- KF-CLAIM: the owner or an agent holding an active shard of the key may press claim (batched over many keys); the money always goes to the wallet that holds the key, never to the agent.

### 9.1 Where the build differs from sections 4.6 and 6 (C8–C11, 6 Oct 2026)

- No periods or slots. One public `runDailySplit()` splits every bound asset in one call, once 24 hours have passed since `lastRunAt` (the first run 24 hours after `firstMintAt`). `runVotedSplit()` is the proposal's run, at any time. Both set `lastRunAt`. There is no `processDailySplit(slot)` or `processAll()`.
- The rate is 10–200 bps (P1 a), not 10–100. `setDailySplitBps` applies from the next run, with no pending state.
- The TOKEN slot and `bindLaunchToken` are not built in C8–C11; C12 builds them (section 9.2). OUSD has an empty slot that `admitOusd(token)` fills once, through an approved call, and it is split from the next run.
- A token whose transfer to the ledger fails is skipped with `SplitTransferFailed` and the other assets are still split; that day is used for all of them. A transfer that ran out of gas reverts the whole run (`SplitOutOfGas`), so a caller cannot starve one asset.
- The ledger has no `receive`; ETH reaches it only through the payable `fundSplitNative`.
- `claim(tokenIds, assets)` replaces `claim(asset, keys, to)`: many keys and assets at once, pressed by the holder or an active shard, each key's money paid to its holder, plus the caller's own credit (a former holder's). There is no `to`.
- REGENT is named in the deployment manifests (`regent`) and checked against `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` on Base. The published manifest lists `splitAssets` in place of `rewardTokens`.

### 9.2 The Autolaunch path as built (C12, 6 Oct 2026)

Built against Autolaunch Revstake v2 on Base (P10 b), read from `repos/autolaunch` branch `feat/contracts-v2` at `54b6676`, folder `contracts/revstake-v2/src`. Autolaunch's files and figures below are that version's, read, not remembered. Nothing in Autolaunch was changed.

**What was built.**

- The v2 factory `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` is fixed in each treasury as `AUTOLAUNCH()`, named in both manifests as `autolaunchFactory`, required on Base by the deployment and record steps, required to hold code on every chain, and published in the deployed manifest.
- `contracts/src/interfaces/IRegentsAutolaunchFactoryV2.sol` and `IRegentLBPStrategyV2.sol` copy only what a fleet uses: `launch`, `launches`, `strategy` and `distribution`.
- `bindLaunchToken(launchId)`, permissionless and once. `splitAssets()` lists the token last, after OUSD; `admitOusd` refuses the bound token, and binding refuses the admitted OUSD.

**Launching.** A passed proposal's call from the treasury to `launch(params)` (`factory/RegentsAutolaunchFactoryV2.sol:225`), with `params.treasury` the treasury. The factory records the caller as the launcher (`:246`) and gives it no rights. A launch needs:

- No ETH, no REGENT and no approval from the treasury.
- A name, symbol, description, website and image, each nonempty and at most 64, 16, 512, 256 and 256 bytes.
- The factory open for launches. It was deployed paused, and only the Regents Safe can open it (`unpauseLaunches`, `:263`). Until then no fleet can launch.
- Time: the auction opens 300 blocks after the launch, runs 86,401 blocks (about two days on Base), and may be settled 128 blocks after it ends. Anyone settles it with the strategy's `migrate(auction)` (`strategy/RegentLBPStrategyV2.sol:398`).
- A raise of at least about 0.000000001 REGENT for the launch to sell. Below that it fails and its tokens are retired.

**Which launch binds, and the read that proves it sold.** `bindLaunchToken` requires the factory's record to name the treasury as both the launcher and the launch's treasury, and `strategy().distribution(auction).lifecycle == Graduated`. The strategy writes `Graduated` at `strategy/RegentLBPStrategyV2.sol:471`, inside `migrate` only when the auction itself reports it sold (`:413`), and in the same transaction makes the pool, the splitter, the receiver and starts vesting; any revert undoes all of it. Running, failed and unknown launches are refused.

The launcher check goes beyond "the launch names this treasury". Anyone may call the factory naming any treasury, and a sold launch costs next to nothing, so without it a stranger could launch a token naming a fleet's treasury, sell it for a fraction of a cent and bind it first. Only an approved proposal makes the treasury a launcher.

**Where a launch's tokens sit.** Only the treasury's own balance is split, and by construction it holds only released, liquid tokens:

- 70% of the supply vests to the treasury over 365 days from the sale in the launch's escrow. Anyone may call `release()`, which pays only the treasury (`escrow/ConditionalVestingEscrowV2.sol:170`, transfer at `:189`).
- The liquidity position is locked in Autolaunch's LP locker (`strategy/RegentLBPStrategyV2.sol:514`).
- Staked tokens are held by the launch's splitter.

**Where the revenue goes.** None of it passes through anything of Keyfleet but the treasury, and the treasury gets each amount once:

- At the sale, at least half the REGENT raise goes straight to the treasury (`strategy/RegentLBPStrategyV2.sol:520`).
- The launch's own payment receiver is made at the sale with the treasury as its beneficiary and no referral (`:529`). `pay` (`revenue/PaymentReceiverV1.sol:143`) hands the whole amount to the splitter (`:228`).
- The splitter (`revenue/SubjectSplitterV1.sol:417`) takes 2%: USDC to REGENT revenue staking (`:428`), REGENT or the launch token to the Regents Safe (`:430`). Of the rest, the share of the launch's stakers stays in the splitter for them to claim, and the treasury is sent the remainder (`:433`), all of it when nobody has staked.
- Pool fees and swap fees reach the same splitter and the same split (`revenue/RevstakeLPLocker.sol` `collect`, `hook/RegentFeeHook.sol` `_chargeLanes`).
- What reaches the treasury is ordinary capital, split by the daily split like any other treasury balance. The ledger's holdings are never counted again, so nothing is split twice.

Anyone may also make a custom payment receiver for a sold launch with another beneficiary (`factory/RegentsAutolaunchFactoryV2.sol:275`); only money that reaches the treasury is the fleet's.

**Tests.** `test/KeyfleetLaunch.t.sol` with a stand-in factory: the launch is an approved call naming the treasury; without a launch there is no TOKEN; a stranger's launch naming the treasury, a launch naming another treasury, another fleet's launch and a launch the treasury made for another treasury are all refused; running and failed launches are refused; binding is once, by anyone, and shares the treasury's lock; TOKEN is split from the next run at 100 tokens; OUSD and TOKEN refuse each other; an approved call cannot fund a TOKEN split. `test/fork/KeyfleetAutolaunchFork.t.sol` runs a whole launch on a Base fork through the real factory, auction, strategy, escrow and receiver, acting as the Regents Safe on the fork only to open the factory. The gas test covers all five split assets. The fleet-wide invariants launch, settle and try to bind launches at random partway through each sequence, and cover every launched token's backing exactly like ETH, REGENT and OUSD; the segregation invariant binds a sold launch partway through and protects the ledger's credits, accruals and backing in the bound token from any approved batch.

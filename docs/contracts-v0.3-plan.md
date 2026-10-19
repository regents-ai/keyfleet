# Keyfleet contracts v0.3: rebuild plan

**Date:** 6 October 2026, brought up to date 7 October 2026
**Branches:** built on `kf/contracts-v03`, then reshaped on `kf/fleet-manager-factory`
**Binding source:** [contracts-build-now-spec-v0.3.md](contracts-build-now-spec-v0.3.md) (Sean, 6 October 2026), plus the HQ-recorded founder rule 41 a: every protocol USDC revenue path reaches REGENT staking on Base. The contract shape is the one Sean chose on 7 October 2026: one key collection, one factory and four contracts per fleet, set out in [fleet-manager-factory-design.md](fleet-manager-factory-design.md).
**Phase update (9 October 2026):** Club gifts now open alone in phase 1, Classic sales in phase 2, the other sold founding fleets in phase 3, and public creation in phase 4. The original numbering below is historical; use the contracts README and deployment guide for current steps.

**Status:** built and tested locally. Nothing is deployed, broadcast, signed or pushed. The [contracts README](../contracts/README.md) is the reference for what the code does.

This plan is for the engineer who built v0.3 and for the reviewer who checks it. Section 1 records the starting point and the economic rules. Section 2 maps the spec onto the contracts. Section 3 lists the Base addresses pinned. Section 4 designs each piece. Section 5 lists what the site must change. Section 6 is the build order. Sections 7 to 9 hold the decisions.

---

## 1. Inventory (spec step 1)

### 1.1 Starting point

Nothing had been deployed on any chain before v0.3, so no live commitment, claim or asset exists to migrate, and the spec's rule that nothing is retroactively cancelled (§2) has nothing to act on. This is a clean first deployment on Base.

`contracts/deployments/` holds only the inputs `base.json` and `anvil.json`. `base.json` has a zero keeper and `"subscriptionId": "0"`, so the deployment refusals stop any real run until both are written in. No deployed record exists and none has been committed. Nothing on the site points at a contract: it links to contracts only through `bin/seed-deployment` with the deployed record, `docs/deploy-checklist.md` says not to run it, and the K-18 hold (outside audit plus Sean's go) still stands.

### 1.2 The contracts

One collection, `KeyfleetKeys`, holds every key of every fleet; one `KeyfleetFactory` creates fleets; each fleet is a `KeyfleetManager`, `KeyfleetVotes`, `KeyfleetTreasury` and `KeyfleetRewards`; `KeyfleetShards` and `KeyfleetRegentBuyer` are shared. `KeyfleetPresets`, `KeyfleetClassicPrices` and `KeyfleetPresence` are internal libraries. No contract has an administrator, an upgrade path, a pause, a proxy or a `delegatecall`. The [contracts README](../contracts/README.md) describes every function, error and event.

### 1.3 Economic commitments

These are the commitments the spec (§2, "Other preset economics") keeps, with the round 3 changes Sean chose on 7 October 2026: prices scale from each fleet's starting price, and the treasury's part of each purchase is swapped to REGENT; and his later 7 October rules: Classic from 10 to 100 USDC, a creator-chosen Accelerant step, 60% approval, a 2-day wait then 2 days of automatic presence, a 7-day opening, and no holding limit.

| Commitment | Rule | Where |
|---|---|---|
| Purchase currency | Atomic USDC with 6 decimals; the factory refuses any other number of decimals. | `KeyfleetFactory` constructor |
| Starting price | The founding fleets start at 10 USDC. A fleet anyone creates starts at 10 to 1,000,000 USDC in whole cents. Every ladder is scaled from the starting price. | `KeyfleetPresets`, `KeyfleetFactory.createFleet` |
| Classic | 1,024 keys on a cent table, the last ten times the first: 10 → 100 USDC at a 10 USDC start, 40,040.48 USDC for all 1,024. | `KeyfleetPresets.classicPrice` |
| Accelerant | 2,000 keys. Each later key costs the fleet's step more, 1% to 5% in whole percent chosen by its creator (5% for Accelerant #1), rounded up. Only primary mints step the price. | `accelerantNextPrice`, `currentPrice` |
| Syndicate and Cascade | Fibonacci levels with no last level. Prices go ×1.2 per level, rounded up. No holding limit. | `KeyfleetPresets` |
| Protocol share | 10% of every purchase, rounded down, in USDC, booked in the manager's `protocolShareOwed`. Sent whole by anyone through `sendProtocolShare`, which deposits it into REGENT revenue staking through the fleet's treasury. The only fee. | `KeyfleetManager`, `KeyfleetTreasury.depositProtocolShare` |
| Syndicate and Classic split | 90% to the treasury, swapped to REGENT in the purchase. | `splitPurchase`, `_buyRegent` |
| Cascade settlement | 90% to `cascadeReserve`, in USDC. When a level completes: repay the previous level's whole gross to its cohort in USDC, then the rest is swapped to REGENT for the treasury. The reserve covers at least 1.62× what is owed. The reserve of a level that never completes is deferred. | `_completeLevel` |
| Accelerant rebate | Key 1: 90% to the treasury as REGENT. Later keys: 20% to the treasury as REGENT, and 70% (plus dust) in USDC credited in Rewards to the current holder of the previous key. | `_sell`, `REWARDS.credit` |
| Money sent outside a purchase | Any asset at the manager above what it books is forwarded whole to the treasury, unswapped, by anyone. | `recognizeSurplus` |
| Votes | One key, one ballot. Ballots may change until closing; at closing a proposal passes when Yes reaches 60%, rounded up, of the keys present at its opening plus every key that joined by voting (1/1, 2/2, 2/3, 3/4, 3/5, 4/6, 5/7, 5/8, 6/9, 6/10). One voter may pass anything. | `KeyfleetVotes.approvalsNeeded` |
| New keys | A key cannot vote or be marked present for 2 days from its mint; a transfer does not restart the wait. From day 2 to day 4 it is present on its own, then only by renewing. A transfer before day 2 keeps that start. | `KeyfleetVotes.KEY_MATURITY`, `KeyfleetPresence` |
| Opening week | For 7 days from a fleet's sales opening, proposals may only set the profile, the daily split rate and key edit restrictions, with no value. | `KeyfleetVotes.TREASURY_OPENING`, `KeyfleetKeys.salesOpenedAt` |
| Card and trait draw | One VRF v2.5 word per key, paid in native ETH from the Regents subscription; 3 confirmations, 100,000 callback gas; seed `keccak256(TAG, chainid, collection, tokenId, word)`. A key asks only once its fleet has a deck. Keys up to the deck's size get deck cards; later keys draw traits off chain from the seed and the one trait table the collection fixes. Retry only after a refused request. | `KeyfleetKeys`; README "Key reveals" |
| Shards | Owner grants of 1 to 365 days to any number of agent wallets, ended by any transfer, with a per-key agent voting switch. | `KeyfleetShards` |
| Resale fee | ERC-2981 2.5% to the Regents Safe. | `KeyfleetKeys.royaltyInfo` |

Recorded as deferred and left unchanged by v0.3: Fibonacci late-entry capture, and the reserve of a Cascade level that never completes.

---

## 2. Gap map, spec section by section

The rule: four responsibilities, not a new framework (§3).

| Responsibility (§3) | Contracts | Holds |
|---|---|---|
| Keys and owner delegation | `KeyfleetKeys` (one for every fleet), each fleet's `KeyfleetManager`, and the shared `KeyfleetShards` | The collection holds keys, epochs, phases, decks and seeds. The manager holds the Cascade reserve and the owed protocol share. Neither holds free capital or makes general calls. |
| Presence and decisions | `KeyfleetVotes`, with presence in the internal library `KeyfleetPresence` (inlined, no `delegatecall`) | Nothing of value. |
| Spendable capital and execution | `KeyfleetTreasury` | All free capital (ETH, REGENT, USDC, launch token, other assets). It executes approved CALL batches, runs the daily split, and owns the Lit account (ERC-1271). |
| Protected obligations | `KeyfleetManager` (reserve, owed share) and `KeyfleetRewards` (all member claims) | Settlement reserves and reward backing. **Never** reachable by an approved call. |

The factory and its four deployers hold nothing of value. The REGENT buyer holds nothing between calls.

**Segregation rule (§3, §7.2).** Only `KeyfleetTreasury` makes arbitrary approved external calls. It never holds reward backing, the Cascade reserve or the owed protocol share. Those live in the manager and `KeyfleetRewards`, which have no general-call function and no setter Votes can reach. So an approved call cannot touch protected money, because that money is not in the calling account. The manager's only approval is an exact one to the REGENT buyer inside a purchase, used up in the same call.

### §1 Product and scope

- **Chain:** Base (8453).
- **Keys:** transferable ERC-721 keys in one collection, the four purchase presets, fleets created through one factory, sales opened in phases by the Regents Safe.
- **Not built:** none of the "Do not build" list (§1): no bridge, Superfluid, payroll, task leases, scores, mandatory ERC-6551/8004 identity or minority reserve.

### §2 Interpretations

- The threshold applies to the free balance before the cut (`B ≥ threshold`).
- At most one public daily split per 24 hours; a passed proposal may run it again.
- There is no separate USDC income route (P2 b). All money a fleet receives outside a purchase is treasury capital (see §9 below).
- OUSD: its slot stays unconfigured.
- Supplies, fees, Cascade, the Accelerant rebate and the income weights are kept; prices scale from the starting price and the treasury's part arrives as REGENT (section 1.3).

### §3 Four responsibilities

`KeyfleetTreasury` holds all free capital. The treasury's part of each purchase reaches it as REGENT in the purchase, and any other balance at the manager, USDC included, is forwarded to it unswapped.

### §4 Immutable membership and protected accounting

- No admin, no upgrade, no proxy, no pause and no burn anywhere. The only switches outside a fleet's own votes are on the collection: the Safe moves the phase, replaces the keeper and allows a newer factory, and the keeper records an open fleet's deck once.
- The treasury executes `Call{target, value, data}` with plain `CALL` only. There is no operation enum, no fallback dispatcher and no `delegatecall`.
- A CI check of the reachable bytecode (`script/check_bytecode.sh`, section 6).
- No minority matching ("no new ... minority matching payment", §4.3; "Do not build ... minority capital reserve", §1).

### §5 Membership, agents and participation

- A key counts only in its own fleet: Votes and Rewards refuse a key of another fleet (`ForeignKey`) before any other use of it.
- New and transferred keys may join an open proposal by voting.
- One delegation mechanism: shards, keyed by token id and wallet, with a per-key agent voting switch and a per-key delegation revision. A shard is epoch-bound, so a transfer ends it.
- EIP-712 signed Present and Ballot messages. Each binds the chain id, the fleet's Votes as verifying contract, the fleet's manager or proposal, the keys, their ownership epochs and delegation revisions, a nonce and a deadline. They are verified with OpenZeppelin `SignatureChecker`, which covers ordinary wallets and ERC-1271 contract wallets.
- Presence: `presentFrom`, a 48-hour window, a 2-day wait then automatic presence, three due-ordered lists, `sweepExpired`, and per-key activity checkpoints keyed by a global state revision.
- The collection's transfer hook calls the key's manager, which calls `VOTES.onKeyMoved(tokenId)` to clear presence and write a checkpoint.
- `ownershipEpoch` on the collection; `firstMintAt` on the manager, the anchor for the daily split.

### §6 The growing electorate

- The opening count `E0` is taken from the cleaned queue. Late joiners are counted per proposal, `D = E0 + late`.
- Ballots are Yes, No or Abstain, one slot per key. A replacement ballot swaps the key's contribution.
- A proposal passes when `Yes > floor(D/2)`; `E0` is never zero because the author key is renewed first.
- Restricting a key's edits passes by the same rule. Withdrawing is an Abstain ballot, which keeps the key in the electorate.

### §7 Exact proposals and execution

- One proposal shape: author key, content hash, ordered `Call[]` (stored as a hash, with the full bytes emitted), `closesAt` (exactly 24 h after creation, Sean 7 Oct), and `executionExpiry` (`closesAt` + 48 h, plus 1 day for a proposal that moves money, KF-VOTE-DELAY a). The lifecycle is Open → Waiting (money proposals only), Approved, Rejected or Cancelled, then Executed or ExecutionExpired.
- Cancellation by whoever may vote the author key. Resubmission gets a new id.
- Typed effects are treasury functions only the treasury itself can call (`onlySelf`), each reached through an exact CALL: `pay`, `advance`, `setDailySplitBps`, `runVotedSplit`, `admitOusd`, `approveLitCreateWallet` and `revokeLitCreateWallet`. Restricting edits is a CALL to `Votes.setEditsRestricted`, and changing the fleet's name, description or image a CALL to the manager's `setProfile`, both callable only by the treasury. A Decision is a proposal with an empty call list.

### §8 Daily fair split

- In `KeyfleetTreasury`: `runDailySplit()` once 24 hours have passed since the last run (the first a day after `firstMintAt`), `runVotedSplit()` for a passed proposal, the 10–200 bps rate, per-asset thresholds, and fixed slots for ETH, REGENT, USDC, OUSD (unconfigured) and the launch token (bound from the verified launch).
- In `KeyfleetRewards`: an integer per-key split index per asset, native ETH backing and claims, and transfer settlement of every split asset. `rewardAssets()` is USDC plus the split assets.

### §9 Income versus capital

The treasury is the fleet's one payment address (P2 b). Everything a fleet receives outside a purchase, USDC included, is treasury capital and reaches the keys only through the daily split.

- `recognizeSurplus(asset)` forwards an asset's whole surplus at the manager to the treasury, USDC exactly as any other token, unswapped. Money paid to the manager by mistake is never stranded and never split twice.
- The manager is not payable, so ETH cannot arrive there by a normal transfer. `selfdestruct` can still force ETH in; nothing in the manager reads its ETH balance, so such ETH is stranded.
- `advance(id, operator, asset, sharePpm, purposeHash)`, which only the treasury may call and which pays a share of the treasury's balance of `asset`, and the permissionless `returnAdvance(id, amount)`, capped at what is still out on that advance.
- The fleet's own token launches through Autolaunch Revstake v2 on Base and is bound to the daily split with `bindLaunchToken` (sections 4.7 and 9.1).

### §10 Public actions, chat and culture

Off chain only: the collective outbox, Agree/Check reviews and cooldowns live in the site. No contract changes, apart from restricting edits remaining an exact on-chain action.

### §11 Lit

The treasury implements ERC-1271 `isValidSignature`. It answers yes only for hashes approved by an executed proposal. Lit administrative writes are exact CALLs from the treasury (section 4.9).

### §12 Application

Site work only (section 5).

### §13 Sequence

See section 6.

### Files

```
contracts/src/
  KeyfleetKeys.sol             the one collection: registry, phases, decks, keeper, reveals, royalty
  KeyfleetFactory.sol          creates fleets; deploys the collection, shards and REGENT buyer
  KeyfleetDeployers.sol        the four deployers, one per fleet contract
  KeyfleetWiring.sol           the wiring a fleet's contracts read from the factory while being deployed
  KeyfleetManager.sol          one fleet's sale, money and profile
  KeyfleetRegentBuyer.sol      the fixed USDC → WETH → REGENT route
  KeyfleetPresets.sol          price, supply and split rules
  KeyfleetClassicPrices.sol    Classic's cent table, generated
  KeyfleetRewards.sol          multi-asset ledger, native ETH, split settlement
  KeyfleetVotes.sol            presence, electorate, exact-call proposals, EIP-712 messages
  KeyfleetPresence.sol         internal library (three presence lists + checkpoints), inlined into Votes
  KeyfleetShards.sol           shared shard record, agent voting switch, delegation revision
  KeyfleetTreasury.sol         free capital, CALL batches, daily split, advances, ERC-1271
  interfaces/                  REGENT staking, Autolaunch v2 factory and strategy, Uniswap v3 pool, v4 PoolManager
  vendor/chainlink/*           copied unchanged
contracts/deployments/
  base.json, anvil.json        inputs; base.deployed.json is written by the record step
contracts/script/
  KeyfleetManifest.sol, KeyfleetSystem.sol, DeployKeyfleets.s.sol,
  KeyfleetSafeSteps.s.sol, RecordKeyfleets.s.sol, AnvilLab.s.sol, check_bytecode.sh
contracts/test/
  one suite per contract and script, helpers/, mocks/, fork/ (Base), invariant/
```

**Contract size.** Base allows 24,576 bytes of runtime code and 49,152 bytes of deployment code. Four fleet contracts that point at each other cannot be carried in one creation code, so each has its own deployer holding its creation code, and the factory deploys all four with CREATE2 (salt = fleet number) in one transaction, handing each its wiring through transient storage. Every contract is under both limits; the README has the measured sizes. One fleet creation uses about 10.7 to 11.8 million gas, under the 16,777,216-gas cap one transaction may use since Fusaka.

---


## 3. Base bindings to pin

Rule: an address is pinned only with its source. Every value below is pinned in `contracts/script/KeyfleetManifest.sol`, and every deployment, Safe step and record on Base refuses a manifest that names anything else (`NotBasePin(field)`).

### 3.1 Addresses

The checks below were read-only, against Base mainnet (chain 8453) on 6 and 7 October 2026, together with the official page named in each row. Nothing was sent. "Verified" means the official source and the chain both agree.

| Binding | Address or value (Base, chain 8453) | Source | Status | Used for |
|---|---|---|---|---|
| Native USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | [Circle USDC addresses](https://developers.circle.com/stablecoins/usdc-contract-addresses). On chain: 6 decimals, symbol `USDC`, a Circle proxy. | Verified | Purchases, protocol share, Cascade reserve, Accelerant rebate, USDC split slot |
| REGENT | `0x6f89bcA4eA5931EdFCB09786267b251DeE752b07` | [Basescan token page](https://basescan.org/token/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07). Regent's own pin in `repos/autolaunch/contracts/v1/src/bindings/BaseBindings.sol:16`. On chain: symbol `REGENT`, 18 decimals, 100 billion supply. | Verified | The treasury's part of every purchase; REGENT split slot |
| WETH | `0x4200000000000000000000000000000000000006` | Base's predeploy. | Verified | The middle of the REGENT route |
| Uniswap v3 USDC/WETH 0.05% pool | `0xd0b53D9277642d899DF5C87A3966A349A798F224` | Read on chain: holds exactly USDC and WETH; 100,000 USDC moves it about 0.15% (design 7.1). | Verified | USDC → WETH |
| Uniswap v4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | Read on chain; the WETH/REGENT pool lives in it. | Verified | WETH → REGENT |
| WETH/REGENT v4 pool key | currency0 WETH, currency1 REGENT, fee `0x800000` (the hook sets the fee), tick spacing 200, hook `0xd60D6B218116cFd801E28F78d011a203D2b068Cc`; pool id `0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed` | Read back from the v4 PositionManager and checked by hashing the key (design 7.1). About 141,000 USD of liquidity on 7 October 2026. The hook is third-party code. | Verified | WETH → REGENT. The fork test checks the key names a live pool. |
| Chainlink VRF v2.5 coordinator | `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` | [Chainlink VRF v2.5 supported networks, Base Mainnet](https://docs.chain.link/vrf/v2-5/supported-networks). On chain: its stored settings match the page. | Verified | Key reveals |
| VRF key hash, 2 gwei lane | `0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab` | Same page. Registered on the coordinator with a 2 gwei cap. | Verified | Recommended gas lane (decision 15) |
| VRF key hash, 30 gwei lane | `0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70` | Same page. Registered with a 30 gwei cap. | Verified | Alternative lane |
| VRF payment | Native ETH. The premium is 60% paid in ETH (50% in LINK). Callback gas is capped at 2,500,000; confirmations from 0 to 200. Sixteen real answers read on 7 October 2026 cost about 0.4 to 1.4 US cents each, about half a cent for a key. | Same page, and the coordinator's stored settings | Verified | Keep `nativePayment: true`, 3 confirmations, 100,000 callback gas |
| VRF subscription id | none yet | — | **Not created.** It must be created, funded and moved to the Regents Safe on Base before the system is deployed. The deploy refuses `0`. | Key reveals |
| Keeper | none yet | — | **Not chosen.** A Regents wallet that records open fleets' decks; the collection refuses zero. | Card decks |
| Regents Safe (Base) | `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` | Regent's own pins: `repos/autolaunch/contracts/v1/src/bindings/BaseBindings.sol:22`, and `repos/regents/contracts/deployments/base-mainnet/autolaunch-history.yaml:61,63`. On chain: Safe v1.4.1 (the Base singleton `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`, matching Safe's official deployment list), 2 of 3 owners. | Verified, see the warning below | Owns the staking contract and the VRF subscription; moves the phase, creates the founding fleets, names the keeper; receives the 2.5% resale royalty. Does not receive the 10%. |
| REGENT revenue staking | `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` | [Basescan, verified source `RegentRevenueStaking`](https://basescan.org/address/0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5#code). Founder decision 40 (4 Oct) and rule 41 a. On chain: 11,757 bytes, not a proxy, not paused, owner and treasury are the Base Regents Safe. | Verified | Receives the protocol share (section 3.2) |
| Autolaunch Revstake v2 factory | `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` | `repos/autolaunch` `feat/contracts-v2` at `54b6676`, `contracts/revstake-v2/deployments/base-mainnet/deployed-manifest.json` (deployed 6 Oct 2026, Base blocks 52267808–52268160, factory tx `0xd913518b942ce622f9eddd3fefe98b5d1baf75deaf617acb3c4995de1bf1c267`); HQ record `control/hq/decisions/autolaunch-revstake-v2-base-2026-10-06.md`. On chain: code hash `0x99f5e3fa97c511b5cfc001e0ea407eebdbaa66f2cc00631d911a34f2aca01676`, and its strategy `0x4dEEd15f650F45900F2e55a44eADe7bD5Fd556d9` `0x1dcfd811edb76c865fcba2f9381a40fc2d33393f21ee227509258b86bcfb9a08`, both as the manifest records, as are the six other contracts it wires and every wiring readback. Launches paused (only the Regents Safe opens them); no launch yet (`nextLaunchId` 1). | Verified | Launch path and the launch token (sections 4.7 and 9.1). `AUTOLAUNCH()` in the factory and every treasury; `autolaunchFactory` in the manifests |
| OUSD on Base | none | [Origin OUSD registry](https://docs.originprotocol.com/registry/contracts/ousd-registry) lists OUSD tokens only on Ethereum. The only Base entry, `0xB1d624fc40824683e2bFBEfd19eB208DbBE00866`, is a strategy, not a token. | **Unconfigured**, as spec §8.7 expects | OUSD slot stays empty until an approved `admitOusd` |
| Lit `AccountConfig` diamond | `0xaaaaa9120fe271f653cfdb6bf400db93d2dea7aa` | Lit's node configuration, `GET https://api.chipotle.litprotocol.com/core/v1/get_node_chain_config` (chain "Base", id 8453), fetched 6 Oct 2026. On chain: a diamond with code on Base; its loupe routes all seven admin writes the treasury uses to one facet, and their selectors match Lit's open-source `WritesFacet` (`LIT-Protocol/chipotle`). The Base fork test runs the treasury's writes against it. | Verified | Lit admin calls. Only a call target inside proposals, never a contract constant. |
| Trait table hash | `0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe` | `keccak256` of the published table on keyfleet main `3172c4a`: eight traits of sixteen values, each trait's weights adding up to 1,000. | Produced | Traits of keys beyond their fleet's deck |
| Founding decks | Classic #1 `0x985aa7794cdd1bfdf90d9b68ae557e3e32e343077303ba55d6d7005a981c5818` (1,024 cards), Syndicate #1 `0x1298cf785709867c5397762ba4dfa3d4a1c1394db0cd26444285c48cc6e57706`, Accelerant #1 `0xbac8510a15a85770ff5cb64b4f0fef57244235ee79327ce3e3e375ce629b6d4d`, Cascade #1 `0x2942590c4d3873db390aef50e4648137fdb93729a370105a1aa9a62e43222b66`, those three 1,000 cards each | The Keyfleet NFTs lane; each hash is `keccak256` of the deck file's bytes. Decks stay private. | Produced | `createFoundingFleet` |
| Collection identity | name `Keyfleet`, symbol `KEYFLEET`, metadata base `https://keyfleet.ai/metadata/keys/`, royalty 2.5% to the Regents Safe | Sean, 7 October 2026 | Decided | The collection |

Also recorded, not bound: the VRF wrapper `0xb0407dbe851f8318bd31404A49e658143C982F23` appears only on the Chainlink page, and its code was not checked. It is not used, because the collection uses a subscription. LINK on Base, `0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196`, is not used either: requests are paid in ETH.

**Warning: one Safe address, two different Safes.** `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` is a separate 2-of-3 Safe on each chain, with different signers.

- **Base:** `0x8C172cA4b5Dd9449217C636A953727eACD690e37`, `0x978BDbECb54C54800D01055Df5A8f6af600BfaCe` and `0x1d0dcABAeb941823E51935F795Be184aBeBf76dF`.
- **Ethereum:** `0x978BDbECb54C54800D01055Df5A8f6af600BfaCe`, `0xB26A3609acD791e2eA3f1900619C910B45705adD` and `0x1d0dcABAeb941823E51935F795Be184aBeBf76dF`.

Sean confirmed the Base addresses in decision 3 (P3 a).

**What the manifest checks.** The chain must be 8453 (31337 for a lab fork). On Base the Safe, staking, Autolaunch factory, coordinator, gas lane, collection name, symbol and metadata base, and every part of the swap route must equal their pins. On every chain the gas lane and the subscription must be known to the coordinator. The contracts themselves refuse a staking contract, Autolaunch factory or coordinator with no code, a USDC without six decimals, a zero Safe or keeper, and a zero trait table hash. A subscription of `0` is refused by the coordinator itself (`InvalidSubscription`).

### 3.2 The protocol share

**Required (rule 41 a):** on Base, the 10% reaches REGENT staking at `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`.

**What the staking contract accepts.** These come from the verified source on Basescan and the deployed ABI at `repos/regents/platform/contracts/abi/regent-revenue-staking.json`. The source in `repos/regents/contracts` does **not** reproduce the deployed bytes, so it is not the reference.

- **Revenue enters only through `depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) returns (uint256 received)`.**
  - It pulls USDC with `transferFrom`, so the sender approves first.
  - Anyone may call it.
  - It is refused while paused; only the Safe can pause.
  - Simulated on Base without sending: depositing 0 reverts `AMOUNT_ZERO`, and depositing 1 without an approval reverts `TRANSFER_FROM_FAILED`.
- **A plain USDC transfer is not counted as revenue.** It sits as surplus, which only the owner can redeposit (`redepositSurplusUSDC`) or sweep (`sweepSurplusUSDC`). There is no public way to recognise it, so the share has to go through a deposit.
- **Where the money goes:** stakers are credited pro rata on the **total** REGENT supply, and the unstaked remainder goes to a treasury balance the Safe can withdraw.

**How it is sent.** The deposit is made by the fleet's `KeyfleetTreasury`, not by the manager, so spec §7.2 ("no external token approvals ever originate from the protected rewards/settlement vault") holds without an exception.

```solidity
// KeyfleetManager
function sendProtocolShare() external nonReentrant returns (uint256 amount) {
    amount = protocolShareOwed;
    if (amount == 0) revert ZeroAmount();
    protocolShareOwed = 0;
    emit ProtocolShareSent(msg.sender, amount);
    USDC.safeTransfer(address(TREASURY), amount);
    TREASURY.depositProtocolShare(amount);              // reverts the whole call if staking refuses
}

// KeyfleetTreasury
function depositProtocolShare(uint256 amount) external nonReentrant {   // only the fleet's manager
    USDC.forceApprove(address(REGENT_STAKING), amount);                    // exact, same call
    uint256 received = REGENT_STAKING.depositUSDC(amount, PROTOCOL_SHARE_TAG, bytes32(uint256(uint160(address(MANAGER)))));
    if (received != amount || USDC.allowance(address(this), address(REGENT_STAKING)) != 0) revert StakingDepositFailed(amount, received);
}
```

- **10% of every purchase**, booked at purchase and sent whole by anyone.
- **`PROTOCOL_SHARE_TAG`** is `keccak256("keyfleet.protocol_share")`. The Regents staking reader indexes deposits without filtering on the tag; the manager's address in the source reference tells fleets apart.
- **A purchase never touches staking.** If staking is paused, or the owed amount is zero, only `sendProtocolShare` reverts, the whole call unwinds and the share stays owed in the manager. A reverted press is an accepted outcome, so the button is never gated (rule 11).
- **The owed share never sits in the treasury between transactions.** It passes through inside one call; `depositProtocolShare` shares the treasury's reentrancy lock with `executeBatch` and `runDailySplit`, so no approved call or split can run in the middle of it.
- **The only approval this path makes** comes from the treasury (the account the spec lets approve), is exact, goes to one pinned non-proxy address, and is asserted back to zero.
- **Other protocol revenue paths:**
  - No other Keyfleet contract path pays protocol revenue. The 2.5% resale royalty is paid by marketplaces to the Regents Safe, outside the contracts.
  - Autolaunch v2's per-launch splitter already sends its 2% of USDC revenue to this staking contract through `depositUSDC`.
  - Any site-side Regents revenue follows rule 41 a off chain (the server deposits it, tagged), not in these contracts.

---


## 4. Design of each piece

Shared conventions:

- Solidity 0.8.26, OpenZeppelin 5.x, no proxies, no `delegatecall`, and only internal (inlined) libraries.
- Every token-moving entry point is locked against reentry (OpenZeppelin `ReentrancyGuardTransient`). Checks, then effects, then interactions.
- Timestamps in seconds.
- A key is named everywhere by its token id in the one collection, `fleet × 10^10 + key number`. Every fleet contract refuses a key of another fleet (`ForeignKey`) before any other use of it.

### 4.1 Presence queue (§5.2–5.3)

**Lives in:** each fleet's `KeyfleetVotes`, through the internal library `KeyfleetPresence`.

**Storage:**

```solidity
uint64 constant WINDOW = 172_800;            // 48 h in seconds
struct Node { uint64 prev; uint64 next; uint64 expiresAt; }   // queued exactly when expiresAt != 0
struct Queue {
    mapping(uint256 tokenId => Node) node;   // one entry per key, never one per renewal
    uint64 head; uint64 tail;                // expiry-ordered (appended expiries never decrease)
    uint32 queued;                           // linked entries; MAY include unswept expired ones
    uint48 revision;                         // +1 on every renewal, change of hands and proposal opening
    mapping(uint256 tokenId => Checkpoints.Trace208) activity; // revision -> renewal time (0 = changed hands)
}
```

Token ids fit in 64 bits: the collection never numbers a fleet past `MAX_FLEETS`, so no token id reaches 10^19.

**Operations:**

- **`touch(k)`**, internal. Called from `present`, `presentBySig`, every ballot, `propose` and `cancel`, after the caller has been authorised for `k`.
  1. If `k` is queued, unlink it; otherwise `queued++`.
  2. Append `k` at the tail with `expiresAt = now + WINDOW`.
  3. Push the checkpoint `(++revision, now)`.
  4. Votes emits `Present(k, now, block.number, ownershipEpoch(k))`.
- **`onKeyMoved(k)`** on Votes, callable only by the fleet's manager. The manager calls it from every transfer (not from a mint), before ownership changes. If `k` is queued it is unlinked and `queued--`; then the checkpoint `(++revision, 0)` is pushed and `PresenceCleared(k)` is emitted. The old owner's presence ends without erasing history.
- **`sweepExpired(limit)`**, permissionless. Pops expired entries from the head, up to `limit`, and `queued -= removed`. It writes no checkpoint, because a key's expiry is implied by its last renewal time. It returns the number removed and whether any are still due, and emits `Swept` when it removed any.
- **`isActive(k)`**: the latest checkpoint `a` is not zero and `now < a + WINDOW`. **`wasActiveAtOpening(id, k)`** reads the checkpoint at the proposal's opening revision instead (section 4.2).

**Why the queue stays sorted:** every append sets `expiresAt = block.timestamp + WINDOW`, and block timestamps never decrease. Ties within a block are fine.

**Opening a proposal:**

1. Sweep up to `SWEEP_IN_PROPOSE` (256) due entries.
2. If any entry is still due, revert `MaintenanceRequired()`. A stale count is never accepted; anyone sweeps the rest and tries again.
3. Touch the author key.
4. Record `openRevision = ++revision`, `openedAt = now` and `e0 = queued`. After the sweep, `queued` is exact.

Present and ballots never require cleanup. Only opening a proposal needs a clean queue.

**Gas, measured over stand-ins** (README "Gas"; the suite asserts each ceiling):

- A key's first renewal: 92,084 (ceiling 111,000). A later renewal: 70,701 (ceiling 85,000).
- Sweeping: 4,900 per expired entry (ceiling 6,000). The worst case, all 2,000 Accelerant keys expiring at once, is about 10 million gas, done in several calls.
- Transfer of a present key: 119,949 (ceiling 144,000).
- A ballot reads one checkpoint, O(log c) where c is that key's number of checkpoints (OpenZeppelin `upperLookupRecent`).

**Invariants** (`test/invariant/KeyfleetPresenceInvariant.t.sol`, over the founding Classic fleet):

1. Expiries are non-decreasing from head to tail.
2. `queued` equals the number of linked entries.
3. No key is queued twice, and only the fleet's own keys are queued.
4. The entries that have not expired are exactly the present keys.
5. A key with no record is not present.

### 4.2 Ownership epochs and checkpoints

`KeyfleetKeys.ownershipEpoch(tokenId)` is 1 at mint and goes up by one on every transfer. The collection raises it after calling the key's manager and before the key moves (README "Transfers and ownership epochs").

**Is key `k` in proposal P's opening electorate?** `k ∈ E0(P)` exactly when:

- the latest checkpoint of `k` with revision ≤ `P.openRevision` holds a value `a ≠ 0`, and
- `a ≤ P.openedAt < a + WINDOW`.

Because the revision orders every renewal, change of hands and opening, this answers same-block cases exactly. In the same block:

- renewal, then transfer, then opening: `k ∉ E0`;
- opening, then transfer: `k ∈ E0`, and the new owner controls that slot.

Shards are bound to the epoch, so a transfer ends every old shard; and signed messages carry the epoch, so a transfer voids every old signature (section 4.3).

The checkpoint library is OpenZeppelin `Checkpoints.Trace208`, with a `uint48` revision key and a `uint208` timestamp value. It is reviewed, inlined code.

### 4.3 Delegation and signatures (§5.1)

**`KeyfleetShards`**, one for the whole collection:

- `Shard { uint64 expiresAt; uint64 epoch; bool ended; }`, kept per `(tokenId, wallet)`. One wallet may hold shards of many keys, and a key may have shards in many wallets.
- `issue(uint256[] tokenIds, address wallet, uint16 days)`, by the key's owner, 1 to 365 days; issuing again replaces the time. `end(tokenIds, wallet)` by the owner or the wallet.
- `setAgentVoting(uint256[] tokenIds, bool on)`, by the owner. It is on for every key unless its current owner turned it off, and a change of hands turns it back on.
- `delegationRevision[tokenId]` goes up on every issue, every end and every agent-voting change for that key.
- Views: `shardOf(tokenId, wallet)`, `isActive(tokenId, wallet)`, `agentVoting(tokenId)` and `mayGovern(tokenId, wallet)` (an active shard and agent voting on).

A shard is active while it is not ended, not expired, and was issued under the key's current epoch. A marketplace approval (`approve`, `setApprovalForAll`) grants nothing here.

**Who may act for key `k`:**

- **Present:** the owner, or a wallet with an active shard of `k`, whatever the agent-voting switch says.
- **Vote, propose with `k`, cancel what `k` authored:** the owner, or a wallet for which `mayGovern(k, wallet)` is true.
- **Claim for `k`:** the owner, or a wallet with an active shard; the money always goes to the key's holder.

**Direct path:** `msg.sender` is the one acting.

**Signed path:** anyone may submit `presentBySig` or `castBallotBySig`. There is no signed form of proposing or cancelling. The EIP-712 domain is name `KeyfleetVotes`, version `1`, the chain id and the fleet's Votes as verifying contract. The message types are:

- `Present(address manager,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,address signer,uint256 nonce,uint256 deadline)`
- `Ballot(uint256 proposalId,bytes32 proposalHash,uint256[] keyIds,uint64[] epochs,uint64[] delegationRevisions,uint8 choice,address signer,uint256 nonce,uint256 deadline)`, the financial approval. It is a different type from Present.

Keys are named in strictly ascending order, so one set of keys has exactly one encoding. Each key's current epoch and delegation revision are read at submission and must match what was signed, so a change of hands or any change to the key's shards or agent voting voids the message. Verification uses `SignatureChecker.isValidSignatureNow(signer, digest, sig)`, which covers ordinary wallets (ECDSA) and deployed contract wallets on Base (ERC-1271), with OpenZeppelin `Nonces` per signer. A third party cannot change the choice, the proposal or the keys, because all of them are signed.

The SIWA sign-in grants nothing on chain.

### 4.4 The growing electorate (§6)

**Storage:**

```solidity
enum Choice { None, Yes, No, Abstain }
struct Proposal {
    bytes32 contentHash; bytes32 actionsHash; bytes32 proposalHash;
    uint64 authorKey; uint48 openRevision; uint64 openedAt; uint64 closesAt; uint64 executionExpiry;
    uint32 e0; uint32 late; uint32 yes; uint32 no; uint32 abstain;
    bool cancelled; bool executed;
}
mapping(uint256 id => Proposal) _proposals;
mapping(uint256 id => mapping(uint256 tokenId => Choice)) public ballotOf;
```

**Casting a ballot** (`castBallot(id, tokenIds, choice)` or `castBallotBySig`):

1. Refuse `Choice.None`, an empty list, a cancelled proposal and `now ≥ closesAt` (`BallotsClosed`).
2. For each key: authorise the voter (section 4.3). If the key has no ballot yet and was not present at the opening (section 4.2), `late++`. Ballots never return to None, so each key joins late at most once.
3. Subtract the key's previous choice from the tallies and add the new one. Repeating the same choice changes nothing.
4. Touch the key.

**Status, worked out from stored facts** (there is no finalize write):

- `Cancelled` if cancelled; else `Executed` if executed.
- Else `Open` if `now < closesAt`.
- Else, with `D = e0 + late`:
  - `Rejected` unless `yes >= approvalsNeeded(D)` (60% rounded up);
  - `Waiting` if `now < executableAt` (a money proposal's day after closing);
  - `ExecutionExpired` if `now ≥ executionExpiry`;
  - otherwise `Approved`.

Tallies cannot change after `closesAt`, so this view is final. The `proposal_finalize` operation in §12 is a read of this status (decision 12).

**Invariants** (`test/invariant/KeyfleetElectorateInvariant.t.sol`):

- `D` never decreases.
- The tallies count each key with a ballot exactly once and never exceed `D`.
- `late` is exactly the keys with a ballot that were not present at the opening.
- `e0 ≥ 1`, because the author is touched before `e0` is recorded.
- `D` never exceeds the keys sold.

### 4.5 Exact proposals and execution (§7), CALL only

**Creation:** `propose(authorKey, contentHash, Call[] calls)`.

- Requires that the caller may vote `authorKey` (section 4.3).
- Sets `closesAt = now + 24h`. A proposal that moves no money (no calls, or only `setProfile`, `setDailySplitBps` and `setEditsRestricted`) is carried out from `closesAt`; any other waits 1 day more. `executionExpiry` is 48 h after that, and `executableAt(id)` reads the first moment. Sets `actionsHash = keccak256(abi.encode(calls))`.
- Refuses a call carrying ETH (`CallCarriesValue`), a `pay` or `advance` share outside 1 to 990,000 parts per million (`ShareOutOfRange`), a second `pay` or `advance` (`OneMoneyMovePerProposal`), and any token-moving or approving call on any address (`TokenMoveRefused`; the list is in the contracts README).
- `proposalHash = keccak256(abi.encode(block.chainid, votes, treasury, id, authorKey, ownershipEpoch(authorKey), contentHash, actionsHash, closesAt, executionExpiry))`.
- Emits `ProposalCreated(id, authorKey, proposer, proposalHash, contentHash, closesAt, executableAt, executionExpiry, e0, openRevision, calls)`, so indexers get the exact bytes.
- Casts no ballot and reserves nothing. There is one `proposalCount` per fleet, so every resubmission gets a new id.

**Cancellation:** `cancel(id)` by whoever may vote the author key now, while the status is Open, Waiting or Approved. It touches the author key.

**Execution:** `execute(id, Call[] calls)`.

- Anyone may call it. It requires `status == Approved` and `keccak256(abi.encode(calls)) == actionsHash`.
- It sets `executed = true`, then calls `TREASURY.executeBatch(calls)`, which only Votes may call.
- The treasury runs each call in order, `target.call{value}(data)`, reverting the whole batch on the first failure and bubbling up the reason. A failed batch therefore stays Approved and can be retried until expiry, and a batch never half succeeds.
- `execute` is locked against reentry, so an approved call cannot execute another proposal inside itself.

**Typed effects.** Treasury functions that accept only the treasury itself as caller (`onlySelf`), so the only way to reach them is an approved CALL:

| Function | What it does |
|---|---|
| `pay(asset, to, sharePpm)` | Pays the treasury's balance of `asset` at that moment × `sharePpm` / 1,000,000, rounded down (`ShareRoundsToZero` for nothing; KF-VOTE-AMOUNT a). `SafeERC20.safeTransfer`, so a token that returns `false` reverts; `Address.sendValue` for ETH. Every payment goes through here; raw token moves are refused at proposing. |
| `advance(id, operator, asset, sharePpm, purposeHash)` | Like `pay`, and also records the amount paid as outstanding for the treasury screen. |
| `runVotedSplit()` | Runs the daily split now, whenever the last run was (section 4.6). |
| `setDailySplitBps(bps)` | Section 4.6. |
| `admitOusd(token)` | Fills the OUSD slot once, split from the next run. |
| `approveLitCreateWallet(issuedAt)` / `revokeLitCreateWallet(issuedAt)` | Section 4.9. |

Two functions elsewhere accept only the fleet's treasury, so they too are reached only by an approved CALL: `KeyfleetVotes.setEditsRestricted(tokenId, bool)` and `KeyfleetManager.setProfile(profile)`, which changes the fleet's name, description and image link and refreshes the fleet's metadata.

**What execution does not do:** it does not gate other calls on the daily split, reserve funds or reinterpret call data. If an approval no longer fits the free balance, the batch reverts and the screen shows it.

**Allowances (§7.2).** The transaction builder (site) defaults to `approve(exact)` → action → `approve(0)` inside one batch, and flags any lasting permission prominently. The treasury itself has no `approve` helper.

### 4.6 Daily fair split (§8)

**Treasury storage:**

```solidity
address constant NATIVE = address(0);
uint16 constant MIN_SPLIT_BPS = 10;  uint16 constant MAX_SPLIT_BPS = 200;
uint256 constant SPLIT_INTERVAL = 1 days;
uint256 constant ETH_THRESHOLD = 0.05 ether;   // USDC and REGENT: 100 whole tokens, fixed at deploy
IERC20 ousd;          uint256 ousdThreshold;          // set once by admitOusd
IERC20 launchToken;   uint256 launchTokenThreshold;   // set once by bindLaunchToken
uint16 dailySplitBps = 50;
uint64 lastRunAt;
```

**`runDailySplit()`**, permissionless. It may run once `nextRunAt()` has passed: a day after `lastRunAt`, or a day after the manager's `firstMintAt` before any run (`SplitNotDue` otherwise, and never while no key is minted). **`runVotedSplit()`** is a proposal's run, at any time. Both set `lastRunAt`, and both split every bound asset in one call, in the order ETH, REGENT, USDC, then OUSD once admitted, then the launch token once bound:

1. Set the transient split-in-progress flag (OpenZeppelin `TransientSlot`).
2. Read `B`, the treasury's whole balance of the asset, and `N = MANAGER.totalMinted()`.
3. If `N == 0` or `B < threshold`, or `perKey = mulDiv(B, bps, 10_000) / N` is zero, emit `SplitSkipped`.
4. Otherwise send `allocated = perKey × N` to Rewards and call `REWARDS.fundSplit(asset, perKey, N)`; for ETH, `REWARDS.fundSplitNative{value: allocated}(perKey, N)`. The remaining dust stays in the treasury. Emit `SplitAllocated`.
5. A token whose transfer to the ledger fails is skipped with `SplitTransferFailed` and the other assets are still split; that day is used for all of them (KF-SPLIT-FAIL a). A transfer that ran out of gas (less than `gasBefore / 63` left) reverts the whole run with `SplitOutOfGas`, so a caller cannot starve one asset on purpose.
6. Clear the flag.

Missed days are never made up. The public run shares the treasury's reentrancy lock with `executeBatch`, `depositProtocolShare`, `returnAdvance` and `bindLaunchToken`; a voted run runs inside the calls it is carried out with.

**Rate change.** `setDailySplitBps(bps)` requires `10 ≤ bps ≤ 200` (`SplitRateOutOfRange`) and applies from the next run. It can only be reached by an approved CALL; there is no other setter.

**Rewards storage for the split:**

```solidity
mapping(address asset => uint256) splitIndex;                 // whole atomic units per key, cumulative
mapping(uint256 tokenId => mapping(address asset => uint256)) keySplitIndex;
address[] _splitAssets;                                       // in the order first funded
```

- **`fundSplit(asset, perKey, keys)`** and **`fundSplitNative(perKey, keys)`**: only the treasury, and only while its split-in-progress flag is set (`NotSplitting` otherwise). `executeBatch` never sets the flag, so an approved CALL from the treasury to Rewards cannot fund a split outside the rate, threshold and once-a-day rules, or add other tokens to the split assets.
  1. Require `MANAGER.totalMinted() == keys` (`KeyCountChanged`). A key minted during funding, for example from a token callback, makes it revert, so a new key never shares an allocation worked out before its mint.
  2. Require `balance ≥ backed + perKey × keys` (`InsufficientBacking`); for ETH, `msg.value == perKey × keys`.
  3. Then `splitIndex += perKey` and `backed += perKey × keys`. Append the asset to the split assets the first time.
- **Enrolment (`enrollKey`, manager only, at every sale):** the key's cohort is recorded. A key starts each split asset from the index it finds.
- **`settleKey(k, from)`**, manager only, before every transfer: settles the key's USDC cohort accrual and its accrual in every split asset into `credits[asset][from]`. It loops over at most five split assets plus one cohort.
- **`claim(uint256[] tokenIds, address[] assets)`**: the caller must hold each key or hold an active shard of it. Each key is settled to its holder, and for each asset the holders' credits and the caller's own credit (a former holder's) are paid. Money for a key always goes to its holder, never to an agent that pressed claim (KF-CLAIM). ETH is paid with `Address.sendValue`, so a wallet that refuses ETH stops only a claim that includes ETH for it.
- **Native ETH:** the ledger has no `receive`. ETH reaches it only through the payable `fundSplitNative`.

**Invariants** (`test/invariant/KeyfleetFleetInvariant.t.sol`, over the founding Cascade and Accelerant fleets):

- Every split asset is owed exactly what the ledger holds of it.
- The ledger's USDC balance is at least its backing, and its backing is at least everything owed.
- The rate stays in [10, 200] and the split-in-progress flag is down between calls.
- A token that is neither admitted nor bound is never split; a bound launch is the fleet's own sold launch.
- Agents are never paid for keys they do not hold.

### 4.7 Income versus capital, and Autolaunch (§9)

**Where money arrives:** at the treasury, the fleet's one payment address, published on the fleet page.

- The treasury's part of every purchase and a completed Cascade level's released reserve arrive there as REGENT, bought in the purchase by the shared `KeyfleetRegentBuyer` (README "REGENT buyer").
- Anything else at the manager above what it books, USDC included, is forwarded whole and unswapped by anyone through `recognizeSurplus(asset)`.
- A launch's REGENT raise, its payment receiver's remainder and its vested tokens arrive there too (section 9.1).
- All of it is free capital and part of the split base. The ledger's holdings are never counted, so nothing is split twice.

**Returned advances.** `returnAdvance(id, amount)` pulls the asset, or takes exactly `msg.value` for ETH. It is capped at what is still outstanding on that advance and lowers it (`ReturnAboveOutstanding`). Funds above the cap are refused, so the "refund" label cannot be stretched.

The spec's point that an operator could relabel customer receipts as refunds is only partly closed on chain. The cap limits the label to what was advanced, but an operator holding customer income can still return it against an open advance. Disclosure and the evidence links cover the rest. This goes to the reviewer as a known limit.

**Autolaunch launch.** Built against Autolaunch Revstake v2 (P10 b); section 9.1 is the build. The launch caller and the launch's treasury are both the fleet's `KeyfleetTreasury`:

- A launch is an exact approved CALL from the treasury to the pinned v2 factory's `launch(params)`, with `params.treasury` the treasury itself.
- `bindLaunchToken(launchId)` is permissionless and runs once. It requires the factory's record to name the treasury as both launcher and treasury, and the strategy to record the launch as graduated. The token is split from the next run.
- Only the launch-token balance the treasury actually holds counts. Unvested escrow, liquidity positions and stake are elsewhere, so they are excluded.

### 4.8 Segregated vaults (§3, §4.3)

| Account | Holds | Can make arbitrary calls? | Approvals out |
|---|---|---|---|
| `KeyfleetKeys` (one) | Keys, epochs, phases, decks and seeds; no money | No | None |
| `KeyfleetManager` (per fleet) | Cascade reserve and owed protocol share, in USDC; a purchase's USDC only during that purchase | No | One exact approval to the REGENT buyer inside a purchase, used up in the same call |
| `KeyfleetRegentBuyer` (one) | Nothing between calls | No | None; it pays the pools inside their callbacks |
| `KeyfleetRewards` (per fleet) | All member claims: rebates, Cascade repayments, split allocations | No | None |
| `KeyfleetVotes` (per fleet) | Nothing | No | None |
| `KeyfleetTreasury` (per fleet) | Free capital only | Yes, approved `Call[]` | Through approved calls, plus the exact staking deposit of section 3.2 |
| `KeyfleetShards`, `KeyfleetFactory` and its four deployers (one each) | Nothing | No | None |

Acceptance (§13 step 2):

- No approved batch can lower the manager's reserve or owed share, a wallet's credit in Rewards, or the unsettled accrual of a key the treasury does not hold. `test/invariant/KeyfleetSegregationInvariant.t.sol` hands each treasury random batches aimed at every fleet contract, the shared contracts, USDC, REGENT, Autolaunch and the bound launch token, and checks that the manager and the ledger always hold what they booked.
- `script/check_bytecode.sh` finds no reachable `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the deployed code of the collection, the factory, its four deployers, the REGENT buyer, the shard record and a fleet's four contracts: twelve contracts. It disassembles with `cast disassemble`, which skips push data, rather than searching raw bytes, and follows every jump target the code pushes.

### 4.9 Lit ChainSecured ownership (§11)

What Lit's documentation says, from [S4](https://developer.litprotocol.com/management/account_modes), checked 6 October 2026:

- **Base is the only supported chain** for ChainSecured accounts.
- A wallet, including a contract, directly owns the account through Lit's `AccountConfig` diamond on Base. Its address comes from `GET /get_node_chain_config`.
- Administrative writes are on-chain transactions sent by the owner, so the treasury must send them itself as approved CALLs. These include creating the account, transferring ownership (`transferChainSecuredAccountOwnership`), creating groups, adding actions and minting usage keys.
- Some steps also need an off-chain signature from the owner, for example the EIP-712 `CreateWallet` for a key. For a contract owner, Lit's server checks it with ERC-1271 `isValidSignature(digest, signature)` on Base.
- Counterfactual (ERC-6492) wallets are not supported, so the treasury must already be deployed.
- Lit Action execution uses the same `/core/v1` API in both account modes.

Design:

- **The treasury implements ERC-1271.** `isValidSignature(h, sig)` returns the magic value exactly when `approvedHash[h]` is true. A proposal that calls `approveLitCreateWallet(issuedAt)` sets the digest of the treasury's own Lit `CreateWallet` request at that time under Lit's own domain, and a later one can revoke it; no approval can be a signature for any other verifier, owner or kind of request. No raw bytes are ever signed by default, and no backend signer exists.
- **Flow:** every write to `AccountConfig` is a CALL in an approved proposal, and the one signed Lit request, `CreateWallet`, is approved first with `approveLitCreateWallet`. The steps are: create the account, create one inbox group with its action, mint one execute-only usage key for the operator, then replace or revoke that key.
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
| A contract wallet signs validly (ERC-1271 mock) | U |
| One person holds many keys | U |
| A key of another fleet is refused by every fleet contract | U, plus I |
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
| An outsider cannot mark someone else's key present | U |
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
| 10 and 200 bps work; 9 and 201 are refused; only a vote sets the rate | U |
| A new rate applies from the next run | U |
| Thresholds just below, equal to and above | U |
| Tokens with 6 and 18 decimals | U |
| No USD conversion (there is no oracle, so none exists to test) | U |
| N=0 | U |
| N larger than the raw atomic allocation (skip) | U |
| Dust is kept | U |
| The public run opens exactly a day after the last; a voted run may run inside the day | U |
| Skipped days are not made up | U |
| A small balance is skipped | U |
| One failed asset does not stop the others (a reverting mock token) | U |
| A transfer that runs out of gas reverts the whole run | U |
| No launch means no launch token | U |
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
| USDC paid to the manager is forwarded to the treasury as capital, unswapped | U |
| The treasury's part of a purchase arrives as REGENT | U, plus F against the real pools |
| Sale and settlement obligations kept: the purchase, Cascade and Accelerant suites | U |
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


---

## 5. Site impact (`platform/`), list only

The site on this branch still reads the earlier contracts on Ethereum. This is what it must change to use these contracts on Base (KF-SITE a: locally, nothing released without Sean's separate go). The contracts lane changes nothing under `platform/`.

**Chain and config**

- `config/config.exs:39,45`: `:wallet_chains` and `:chain_nodes` move from `%{1 => Ethereum…}` to `%{8453 => Base…}`. `runtime.exs` keeps `KEYFLEET_RPC_URL`, which points at a Base node.
- `Chain.RpcClient`, `Chain.Cursor` and `Chain.Scanner` are re-tuned for Base's 2-second blocks. Follow the Base rule of reading `latest` and never waiting for L1.

**Deployments**

- One deployed record, `contracts/deployments/base.deployed.json`, written by the record step, names the collection, the factory and its four deployers, the shard record, the REGENT buyer and the four contracts of every fleet registered when it runs. `bin/seed-deployment` and `mix keyfleet.seed_deployment` read that one file.
- `Keyfleet.Fleets.record_manifest!/1`, the `fleet` resource and the shared-wiring validation move to one collection with many fleets: each fleet row holds its fleet number, type, starting price and its manager, Votes, treasury and Rewards addresses; the collection, factory, shard record and REGENT buyer are stored once. Hard cutover: there is no deployed data.
- Fleets anyone creates are learned from the factory's `FleetCreated` events, not from a file.

**Readers and indexing**

The scanner reads the collection, the factory, the shard record, and each fleet's manager, Votes, treasury and Rewards.

- **Collection:** `Transfer`, `OwnershipEpoch`, `FleetRegistered`, `DeckSet`, `PhaseAdvanced`, `KeeperSet`, `FactoryAdded`, `RevealRequested`, `RevealRequestFailed`, `KeyRevealed`, `MetadataUpdate` and `BatchMetadataUpdate`.
- **Factory:** `FleetCreated`.
- **Shards:** `ShardIssued`, `ShardEnded` and `AgentVotingSet`.
- **Manager:** `Purchased`, `LevelCompleted`, `RegentBought`, `ProtocolShareSent`, `ForwardedToTreasury`, `ProfileChanged` and `RequirementsSet`.
- **Votes:** `ProposalCreated` (with calls), `BallotCast(choice)`, `ProposalCancelled`, `ProposalExecuted`, `EditsRestrictionSet`, `Present`, `PresenceCleared` and `Swept`.
- **Treasury:** `Paid`, `Advanced`, `AdvanceReturned`, `DailySplitRun`, `SplitAllocated`, `SplitSkipped`, `SplitTransferFailed`, `DailySplitRateSet`, `OusdAdmitted`, `LaunchTokenBound`, `LitCreateWalletApproved` and `LitCreateWalletRevoked`.
- **Rewards:** `KeyEnrolled`, `Allocated`, `Credited`, `SplitFunded`, `Settled` and `Claimed`.
- Every decoder for an event these contracts do not emit is deleted.

**Pinned topics.** `test/KeyfleetVotesTopics.t.sol` pins the event topics, so the site and the contracts keep sharing them.

**Treasury reader.** `TreasuryReader` reads the treasury's balance of each split asset, Rewards' `backed` per asset, the manager's `cascadeReserve` and `protocolShareOwed`, outstanding advances, `dailySplitBps`, `lastRunAt` and `nextRunAt()`. `RewardsWaiting` reads `accrued` for every reward asset, not just USDC.

**Key metadata and decks.** The metadata route serves `https://keyfleet.ai/metadata/keys/<tokenId>` for the token id `fleet × 10^10 + key`, and `https://keyfleet.ai/metadata/collection.json`. Each fleet's deck is kept private on the server; only its fingerprint is on chain, and only rarities are public. The keeper wallet records each open fleet's deck with `setDeck`.

**Wallet steps** (`wallet_steps/build.ex`, `steps.ex`)

- `buy`: approve exact USDC, then `purchase(receiver, maxPrice, deadline, proof)` on the fleet's manager.
- `create_fleet` (phase 3): approve the factory for exactly key 1's price, then `createFleet(terms)`.
- `present`, `vote` (Yes, No or Abstain), `propose` (exact `Call[]` built from typed templates: pay, advance, rate change, voted split, restrict edits, profile change, decision, Lit admin, launch), `cancel`, `carry_out` (passes the calls), `sweep`, `run_split`, `claim` (many keys and assets, ETH included), `return_advance`, `send_protocol_share`, `recognize_surplus`, `bind_launch_token`, `issue_shard`, `end_shard` and `set_agent_voting`.
- Every button reaches the wallet on every press. Nothing on the page blocks, defers or de-duplicates a press (hard rule 11). A press that reverts is an accepted outcome. The one exception is a press certain to fail from the chain's own state at the latest block, such as a sold-out fleet or sales not open yet: the button stays visible but disabled, with a few words saying why.

**TypeScript.** `send_step.ts` already switches chains. Its test defaults (`assets/test/onchain_steps.test.ts`, `stand_in_wallet.ts`) move to `0x2105`.

**The SIWA smart-wallet rule**

- `actors/agent.ex` flips: smart wallets (`:erc1271`, `:erc6492`) count only when signed in on **Base (8453)**. Plain wallets are unchanged.
- Also update `plugs/signed_agent.ex`, `refusal.ex`, `code_password.ex`, `priv/public/docs.md`, `skill.md` and `api-contract.openapiv3.yaml`, and the tests in `agent_join_journey_test.exs`.

**Key pages and new screens (§12)**

- **Fleet page:** the fleet's name, description and image link, its type and starting price, joining requirements, the treasury's address, and the profile-change proposal template.
- **Create a fleet** (phase 3): type, starting price (10 to 1,000,000 USDC in whole cents), name, description, image link and joining requirements, then the creator buys key 1.
- **Present card:** pinned on the key page and the proposals page. It shows active until a time, dormant, or "maintenance needed before a new proposal", and has a Present button.
- **Proposal view:** the proposal's own denominator D (opening count plus late joiners), Yes, No and Abstain, closing time, execution expiry and status. It is kept separate from the fleet-wide present count, which is labelled as an indexed count and never as an exact live count.
- **Treasury:** free capital, estimated next daily split, funded member claims, protocol and settlement obligations, and funds advanced outside the treasury.
- **Split preview:** asset and address, balance, rate, threshold, minted keys, estimated total and per-key amounts, last run and next run time.
- **Remove the Ethereum and old-rule copy** (`fleet_live.ex` including the etherscan link, which becomes basescan, `wallet_words.ex`, `rules.ex`, `proposals_live.ex`, `about.md`, `llms.md`, `terms.md`, `docs.md`, `skill.md` and `api-contract.openapiv3.yaml`), and add the spec's §14 disclosure before purchase and delegation.

**No site wallet (P8 b).** The site sends no transaction. The daily split, sweeping expired presences, sending the protocol share and the launch upkeep are buttons anyone may press (KF-RELEASE a). Indexing follows the shared chain-events skill.

**Agent API, CLI and WebMCP**

- The operations from §12: `present`, `presence_status`, `proposal_*`, `fair_split_*` and `rewards_claim`, plus fleet creation and the profile change.
- These change in `cli/commands.json` through the regents-cli site-commands rule, in the WebMCP manifest and in the agent routes.
- The agent shard API stops saying "send on Ethereum".

**Other places that carry a chain id**

- The graph principal `member:#{chain_id}:…` (`graph/checks/key_actor.ex`).
- The test files that pin `chain_id: 1` and Ethereum USDC (`test/support/chain_helpers.ex`, `browser_chain.ex`, `test_chain_node.ex`, and the files they feed).
- The anvil lab (`test/support/anvil_lab.ex`, `contracts/script/AnvilLab.s.sol`).

---

## 6. Build order (spec §13)

Every step leaves `forge build` and `forge test` passing, deletes what it replaces (hard cutover) and keeps `contracts/README.md` current. The steps that reshaped the build into one collection are B1 to B7 in [fleet-manager-factory-design.md](fleet-manager-factory-design.md) section 12.

| §13 step | What it covers | Where it is checked |
|---|---|---|
| 1 | This plan, the Base pins and the manifest | `test/DeployKeyfleets.t.sol` (refusals per pin), `test/fork/KeyfleetBaseFork.t.sol` |
| 2 | The four responsibilities: the treasury holds all free capital, the manager and Rewards hold protected money; the protocol share reaches REGENT staking through the treasury | `KeyfleetTreasury.t.sol`, `KeyfleetIncome.t.sol`, `KeyfleetPurchaseMoney.t.sol`, `KeyfleetSegregationInvariant`, the Base fork suite against real staking |
| 3 | Presence, shards and signatures, the growing electorate | `KeyfleetPresence.t.sol`, `KeyfleetShards.t.sol`, `KeyfleetSignatures.t.sol`, `KeyfleetVotes.t.sol`, the presence and electorate invariants |
| 4 | Exact CALL execution and the bytecode check | `KeyfleetExecution.t.sol`, `script/check_bytecode.sh` |
| 5 | The multi-asset ledger and the daily split | `KeyfleetRewards.t.sol`, `KeyfleetSplit.t.sol`, `KeyfleetFleetInvariant` |
| 6 | The site | Site lane (section 5) |
| 7 | Autolaunch and Lit | `KeyfleetLaunch.t.sol`, `KeyfleetLit.t.sol`, the Autolaunch and Lit fork suites |
| — | One collection, the factory, the REGENT buyer, phases, decks and reveals (round 3) | `KeyfleetKeys.t.sol`, `KeyfleetFactory.t.sol`, `KeyfleetManager.t.sol`, `KeyfleetRegentBuyer.t.sol`, `KeyfleetReveal.t.sol`, `KeyfleetTraitDraw.t.sol`, `KeyfleetSafeSteps.t.sol`, `RecordKeyfleets.t.sol`, `AnvilLab.t.sol`, `KeyfleetCollectionInvariant`, the REGENT buyer and gas fork suites |
| 8 | Release readiness | `make check-contracts` passes; the README's gas tables; ready for an outside audit (K-18) |

Step 8's independent review and controlled release come after that. They need an outside audit, fork and invariant evidence, a Base mainnet Lit test if decision 9 is yes, and Sean's go. This plan authorises none of it.

---

## 7. Open points for Sean

Reviewed and trimmed by the Keyfleet chief engineer (section 8). Points the spec itself already settles were built as the spec says and are listed in 7.2, not asked. The questions put to Sean are in 7.1; his answers are in section 9.

### 7.1 Asked

| Plan id | Question | Recommendation |
|---|---|---|
| P1 | The daily split's threshold (0.05 ETH, 100 tokens) is measured on the free balance before the cut (spec §2, flagged by the spec for review). | Yes |
| P2 | Keep a separate USDC income route, paying USDC a fleet receives straight to the keys, with only the treasury's holdings split daily (spec §2 and §9, flagged for review). | Yes |
| P3 | The Base addresses in section 3.1, including the Base Regents Safe signers, which differ from the Ethereum Safe's at the same address. | Confirm |
| P7 | A key's owner may let its agent mark the key present, vote and propose (spec §5.1). | Follow spec v0.3 |
| P8 | The site runs the daily split and the expiry clean-up from a small gas-only Base wallet (spec §5.3 and §12 call for Oban to do this). | Yes |
| P10 | The fleet's token launch binds to Autolaunch v1 now, or waits for v2 on Base. | Depends on v2 timing |
| P13 | Bring `docs/product-spec.md` in line with v0.3. | Yes, doc-only |
| P14 | One agent wallet may hold shards of several keys of the same fleet. | Allow it (section 8) |

P9 (a throwaway Lit test fleet on Base mainnet) is a deployment and is asked at deployment time, with its own go.

### 7.2 Settled by the spec or by engineering, not asked

| Plan id | Settled as | Why |
|---|---|---|
| P4 | The treasury, not the manager, approves and deposits the 10% (section 3.2). | Keeps spec §7.2 without an exception or a new contract. |
| P5 | Restricting a key's edits passes by the same `Yes > floor(D/2)` rule. | Spec §7.1: no separate quorum class. |
| P6 | No minority matching. | Spec §1 and §4.3. |
| P11 | Each fleet's four contracts are deployed by four deployers, through the factory, in one transaction. | Base's code-size limit; engineering only. |
| P12 | A proposal's result is a read; no finalize transaction. | Tallies cannot change after closing. |
| P15 | VRF on the 2 gwei lane, native ETH, 3 confirmations, 100,000 callback gas. | Base gas sits far below 2 gwei; a refused request can be retried. |
| P16 | Keys the treasury holds count, vote and earn like any other. | Spec §4.1 and §8.2 ("all existing minted Keys"). |

## 8. Chief engineer review (6 October 2026)

Checked against the spec, section by section: the electorate (E0 from the cleaned queue, late joiners, `Yes > floor(D/2)`, no shrinking, the §6 example table), presence (sorted queue, clearing on transfer, same-block ordering through the revision), exact CALL-only execution (hash binding, atomic batch, retry until expiry, cancel while Open or Approved), the daily split, funded pull claims (§8.5), segregation (§3, §4.3) and rule 41 a. The design holds. Three amendments, all built:

1. **Gap closed: an approved CALL could have funded a split directly.** Every approved CALL is sent by the treasury, so a ledger funding function open to the treasury alone could be called by a proposal with any asset and amount, skipping the rate bounds and the once-a-day rule, and filling the split assets with other tokens. Rewards therefore also requires `TREASURY.splitInProgress()`, a transient flag only the treasury's split sets (section 4.6). `test_anApprovedCallCannotFundTheSplit` and `test_anApprovedProposalCannotFundTheSplit` prove an approved call to either funding function reverts.
2. **The 10% goes through the treasury.** Sending the owed share to the treasury and depositing it in the same call keeps spec §7.2 without an exception and without a new contract (section 3.2).
3. **P14 is "allow".** The spec's own test list includes "one person holding many Keys", so there is no safety reason to force one agent per key. Shards are kept per `(tokenId, wallet)`; a wallet's authority is always checked for a named key, so holding several never mixes them.

Watch items, not decisions:

- `executeBatch`, `runDailySplit`, `depositProtocolShare`, `returnAdvance` and `bindLaunchToken` share one reentrancy lock in the treasury.
- Every transfer calls the key's manager, which settles the key in Rewards and calls `VOTES.onKeyMoved`; its gas is measured and capped (README "Gas": 361,929 with five split assets waiting, ceiling 435,000).
- `returnAdvance` limits relabelling only up to the open advance (section 4.7); this stays in the audit notes as a known limit.

### 8.1 Review of the money paths (6 October 2026)

- **USDC backing is never short.** Each key's share of a cohort allocation is rounded down, and the rounding is carried in the key's own snapshot, so keys are owed at most what was set aside. The ledger's USDC balance is at least its backing, and its backing is at least everything owed. The difference, under one unit per key, stays in the ledger. `invariant_usdcBackingCoversWhatIsOwed` asserts all three.
- **Split assets are exact.** Each split books `perKey × keys` against a balance check, and a key minted later starts from the current index. Every split asset is owed exactly what the ledger holds.
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
- P10 b: wait for Autolaunch v2 on Base. v2 is on Base, and the launch path is built against it (section 9.1).
- P13 a: the product spec is updated (on main, by the chief engineer).
- P14 a: keys stack in a wallet; every key action is batchable.
- KF-CLAIM: the owner or an agent holding an active shard of the key may press claim (batched over many keys); the money always goes to the wallet that holds the key, never to the agent.
- KF-SPLIT-FAIL a (7 Oct): when a token refuses the transfer to the ledger, the daily split skips that token and still splits the others; that day is used for all of them.
- KF-RELEASE a (7 Oct): the launch's upkeep (settle the sale, bind the token, release vested tokens, collect pool fees) is pressed from buttons on the fleet page that anyone may press. The contracts do not do it themselves.
- KF-SITE a (7 Oct): the site moves to the Base contracts now, locally; nothing is released without Sean's separate go.


### 9.1 The Autolaunch path as built (6 Oct 2026)

Built against Autolaunch Revstake v2 on Base (P10 b), read from `repos/autolaunch` branch `feat/contracts-v2` at `54b6676`, folder `contracts/revstake-v2/src`. Autolaunch's files and figures below are that version's, read, not remembered. Nothing in Autolaunch was changed.

**What was built.**

- The v2 factory `0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E` is fixed in the factory and in each treasury as `AUTOLAUNCH()`, named in both manifests as `autolaunchFactory`, required on Base by the deployment and record steps, required to hold code on every chain, and published in the deployed manifest.
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

**Tests.** `test/KeyfleetLaunch.t.sol` with a stand-in factory: the launch is an approved call naming the treasury; without a launch there is no launch token; a stranger's launch naming the treasury, a launch naming another treasury, another fleet's launch and a launch the treasury made for another treasury are all refused; running and failed launches are refused; binding is once, by anyone, and shares the treasury's lock; the launch token is split from the next run at 100 tokens; OUSD and the launch token refuse each other; an approved call cannot fund a launch-token split. `test/fork/KeyfleetAutolaunchFork.t.sol` runs a whole launch on a Base fork through the real factory, auction, strategy, escrow and receiver, acting as the Regents Safe on the fork only to open the factory. The gas test covers all five split assets. The fleet-wide invariants launch, settle and try to bind launches at random partway through each sequence, and cover every launched token's backing exactly like ETH, REGENT and OUSD; the segregation invariant binds a sold launch partway through and protects the ledger's credits, accruals and backing in the bound token from any approved batch.

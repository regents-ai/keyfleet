# Keyfleet contracts security audit (pre-Base-mainnet)

Date: 9 October 2026. Auditor: Claude (Opus 5.5) plus five helper scans. This is an internal review, not an outside audit.

## Scope

Scratch copy: `/private/tmp/claude-501/-Users-sean-Documents-regent/8c3e0232-2b4d-44ad-ba12-becd656e57bf/scratchpad/kf-audit/contracts`, copied from `origin/main`, contracts at commit `a1917b1`. The folder is not a git checkout.

Read in full:

- `src/`: KeyfleetClassicPrices, KeyfleetClubClaims, KeyfleetDeployers, KeyfleetFactory, KeyfleetKeys, KeyfleetManager, KeyfleetPresence, KeyfleetPresets, KeyfleetRegentBuyer, KeyfleetRewards, KeyfleetShards, KeyfleetTreasury, KeyfleetVotes, KeyfleetWiring, `interfaces/*`. Vendored code (OpenZeppelin, Chainlink VRF client) was read only where the contracts depend on it.
- `script/`: KeyfleetSafeSteps.s.sol, DeployKeyfleets.s.sol, KeyfleetSystem.sol, plus KeyfleetManifest.sol (Base pin checks).
- `deployments/base.json`, `contracts/README.md`, `../deployment.md`, `../contracts-v0.3-plan.md`.

Nothing under `src/`, `script/` or `deployments/` was changed. A file-time check after all runs found no file newer than the start of the audit, and both deployment JSON hashes are unchanged. New files exist only under `test/audit/`. Fork tests ran against a local fork of Base (block about 52,366,934). Nothing was broadcast.

## Tools and skills used

- Skills loaded: solidity-auditor (local VERSION 1; the remote is 4.1, and the tool warned), solidity-security, analyzing-ethereum-smart-contract-vulnerabilities, crytic-slither. All four loaded; none failed.
- solidity-auditor "deep" flow: four vector-scan agents (attack-vector sets 1–4 across the whole codebase) plus one adversarial-reasoning agent. Every agent claim was checked by hand before it went into this report. Claims that did not hold up were dropped.
- Foundry: forge 1.5.1, solc 0.8.26. Baseline `forge test --no-match-path 'test/fork/*'`: 548 tests, all succeeded.
- Slither 0.11.5: 191 results, all triaged (see below).
- Mythril: not run (it is not installed on this machine).

## Slither triage summary

191 results. None is a real issue on its own; the real findings below came from manual review.

| Detector (impact) | Count | Verdict |
| --- | --- | --- |
| arbitrary-send-erc20 (High) | 1 | False positive. The `payer` in `uniswapV3SwapCallback` comes from a transient slot set only inside `_swap`, and only the fixed pool may call. |
| reentrancy-balance (High) | 1 | Benign. The REGENT balance read around the v4 swap could only be inflated by a hook donation, which would only add to the treasury. |
| uninitialized-state (High) | 2 | False positive. `_proposals` and `_splitJoins` are mappings written through storage pointers. |
| divide-before-multiply (Medium) | 2 | Intended. Remainder carry in `_settleCohort` and dust retention in `_splitAsset`. |
| incorrect-equality (Medium) | 6 | False positive. Zero checks are intended. |
| reentrancy-no-eth (Medium) | 3 | Guarded. `convert` and `_sell` use `nonReentrant` and call only fixed system contracts before minting. |
| uninitialized-local (Medium) | 10 | False positive. Zero defaults are intended. |
| unused-return (Medium) | 14 | Intended or false positive (deployer returns, mint return, presence push, `verifyCallResult`). |
| calls-loop, timestamp, reentrancy-benign, reentrancy-events (Low) | 67 | Informational. Loops are bounded, and timing is on an hour-to-day scale. |
| events-maths (Low) | 1 | `takePiece` emits no event (the buyer's `RegentBought` covers it). Noted as part of KF-A-13. |
| assembly, low-level-calls, costly-loop, naming, too-many-digits (Info) | 82 | Informational. |
| missing-inheritance (Info) | 1 | KeyfleetManager should declare `IKeyfleetKeyHook`. Noted as part of KF-A-13. |
| unindexed-event-address (Info) | 1 | `RequirementsSet` has no indexed fields. Noted as part of KF-A-13. |

Full output: `/private/tmp/claude-501/-Users-sean-Documents-regent/8c3e0232-2b4d-44ad-ba12-becd656e57bf/scratchpad/kf-audit/slither.txt` and `slither.json`.

## Findings at a glance

| Id | Severity | Title | Status |
| --- | --- | --- | --- |
| KF-A-01 | Critical | A one-atomic-USDC leftover permanently stops the shared REGENT buyer for every fleet | CONFIRMED (fork and local) |
| KF-A-02 | Medium | A passed hash approval moves 100% of a token, past the money rules, behind an unreadable hash | CONFIRMED (fork with real USDC, and local) |
| KF-A-03 | Low | REGENT pieces can be sandwiched; the only protection is a third-party hook's fee | PLAUSIBLE |
| KF-A-04 | Low | One Pass holder can make a whole Club gift batch revert after the Safe signs it | CONFIRMED (local) |
| KF-A-05 | Low | A reveal request that is accepted but never answered strands the key with no seed, for good | CONFIRMED (local, coordinator change); PLAUSIBLE (subscription path) |
| KF-A-06 | Low | Any one fleet whose piece cannot complete blocks every fleet's conversion (single queue, no skip) | PLAUSIBLE |
| KF-A-07 | Low | Ballots cast with a briefly held key stay counted after the key goes back | PLAUSIBLE (by design) |
| KF-A-08 | Low | Joining requirements read a spot balance and can be met with a borrowed balance | PLAUSIBLE (by design) |
| KF-A-09 | Info | An unsent signed ballot can be submitted later and override a direct vote | PLAUSIBLE |
| KF-A-10 | Info | A Club key waiting in claims goes to whoever holds the Pass at that instant | PLAUSIBLE (documented) |
| KF-A-11 | Info | `runVotedSplit` is not counted as a money move and may repeat within one proposal | PLAUSIBLE |
| KF-A-12 | Info | The 2.5% royalty is advisory (ERC-2981) | Documented |
| KF-A-13 | Info | Code hygiene from Slither | Noted |

Counts: Critical 1, High 0, Medium 1, Low 6, Informational 5.

---

## Critical

### KF-A-01: A one-atomic-USDC leftover permanently stops the shared REGENT buyer for every fleet

- **Where:** `KeyfleetManager.takePiece`, src/KeyfleetManager.sol:450-456. `KeyfleetRegentBuyer.convert`, src/KeyfleetRegentBuyer.sol:229-243. `_swap`, src/KeyfleetRegentBuyer.sol:308.
- **Description:** Anyone can call `convert(pending - 1)` and leave exactly 1 atomic USDC booked in a fleet. That fleet's next piece swaps for zero WETH on the real 0.05% USDC/WETH pool and reverts with `NothingBought`. Because `convert` only ever serves the head of one shared queue, every conversion for every fleet then reverts for ever.
- **Failure scenario:** In phase 3 Mallory creates a 10 USDC Classic fleet with an address-list requirement that only she meets (or no one meets: the creator's key 1 skips the requirement check). 9 USDC is booked. When her fleet reaches the head, she calls `convert(8_999_999)`, which leaves `pendingConversion == 1` and puts her fleet back in the queue. From then on, each time it is at the head, the 1-unit piece hits Uniswap v3's fee rounding (1 × 0.9995 rounds down to 0), gets 0 WETH, and reverts. The revert undoes the queue pop, so the head never moves. No one else may buy into her fleet to top it up (`RequirementNotMet`). Nothing in any contract can skip the head or unbook the USDC: `recognizeSurplus` moves only unaccounted USDC, there is no admin, and the route is fixed. From that moment, the treasury's 90% of every sale in every fleet, founding fleets included, sits in its manager for good, while keys keep selling. Cost to the attacker: about 10 USDC plus gas. The same works with no fleet of her own on any sold-out fleet (Classic after 1,024 keys, Accelerant after 2,000). It can also happen with no attacker, if a booking ever ends at 250e6·k + 1 and keepers always ask for full pieces.
- **Evidence (CONFIRMED):**
  - Real Base pools on a fork: `test_KFA01_fork_oneAtomicUsdcRemainderFreezesTheBuyerForEveryFleet` in `test/audit/KeyfleetAuditFork.t.sol`. Command: `BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/audit/KeyfleetAuditFork.t.sol' -vv`. Result: the dust fleet stays at the head, `convert(max)` and `convert(1e6)` revert `NothingBought` for three days running, an honest buyer cannot join the gated fleet, and the honest fleet's booking stays stuck.
  - Local, with a stand-in pool that rounds fees as Uniswap v3 does (adversarial agent): `test/audit/Agent5QueueBrick.t.sol`, tests `test_agent5_dustRemainderBricksSharedQueueForever`, `test_agent5_naturalRemainderOfOneAlsoBricks`, and the control `test_agent5_normalPieceStillConverts`. Command: `forge test --match-path 'test/audit/Agent5QueueBrick.t.sol' -vv`.
- **Suggested fix:** Never leave a booking smaller than one minimum piece:

  ```diff
   function takePiece(uint256 limit) external nonReentrant returns (uint256 amount, address recipient) {
       if (msg.sender != address(REGENT_BUYER)) revert OnlyRegentBuyer();
       amount = Math.min(pendingConversion, limit);
  +    if (pendingConversion - amount < REGENT_BUYER.MIN_PIECE_USDC()) amount = pendingConversion;
       pendingConversion -= amount;
  ```

  Every booking starts at 9 USDC or more (the lowest start price is 10 USDC), so a booking is then always 0 or at least 1 USDC. A piece can then be up to `PIECE_USDC + MIN_PIECE_USDC - 1`, so the comments need updating. I tried this change in a separate scratch copy (`scratchpad/kf-fixcheck`, not the audited folder). With it, the attack can no longer leave a 1-unit booking (all three brick PoCs fail at that step) and the rest of the suite still succeeds, except three tests that encode the old behaviour and would need updating:
  - `test_ARemainderUnderTheMinimumConvertsWhole` expects a half-USDC remainder to be left.
  - A buyer invariant says a piece is at most a full piece.
  - `test_aSignatureFromAnIndependentEncoderIsAccepted` pins a manager address, which shifts with any bytecode change.

  See KF-A-06 for the second line of defence (let a failing head be skipped).

## High

None.

## Medium

### KF-A-02: A passed hash approval moves 100% of a token, past the money rules, behind an unreadable hash

- **Where:** `KeyfleetVotes._requireShares` / `_movesTokens`, src/KeyfleetVotes.sol:724-775. `KeyfleetTreasury.approveSignatureHash` / `isValidSignature`, src/KeyfleetTreasury.sol:413-430.
- **Description:** The money rules count only `pay` and `advance` as money moves and refuse a fixed list of token selectors. `approveSignatureHash(h)` is neither. Base USDC (FiatTokenV2_2) accepts ERC-1271 signatures in `transferWithAuthorization` and `permit`. So a proposal that approves the digest of a USDC authorisation from the treasury lets anyone move any amount, up to 100%, to any address.
- **Failure scenario:** A proposer presents a proposal as "approve Lit request digest 0x…", which is the normal Lit flow the docs describe. The digest is really a USDC `transferWithAuthorization(from = treasury, to = proposer, value = whole balance)`. Voters and the site see only a bytes32 and cannot tell what it authorises. The proposal still waits `MONEY_DELAY`, but the No-only veto window is useless if nobody can read what the hash does. After it executes, anyone submits the authorisation with an empty signature and the treasury's whole USDC balance leaves. The same proposal may also carry a 99% `pay`, because the hash approval is not counted as the "one money move". This breaks three documented rules: the 99% cap, one share of one asset per proposal, and "raw token moves are refused at proposing". It still needs a passing vote, so it is not an outside theft. The risk is a disguised drain, or a drain beyond the caps.
- **Evidence (CONFIRMED):**
  - Real Base USDC on a fork: `test_KFA02_fork_realUsdcHonoursAnApprovedHashForTheWholeBalance` in `test/audit/KeyfleetAuditFork.t.sol`. The treasury's 50,000 USDC goes 100% to Mallory through a third party's call with signature `""`. Command: `BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/audit/KeyfleetAuditFork.t.sol' -vv`.
  - Local: `test_KFA02_approvedHashDrainsWholeTokenBalancePastTheMoneyRules` in `test/audit/KeyfleetAuditLocal.t.sol`. It shows a direct `transfer` refused (`TokenMoveRefused`) and a 100% `pay` refused (`ShareOutOfRange`), then one proposal with a 99% `pay` plus a hash approval empties the treasury. Command: `forge test --match-path 'test/audit/KeyfleetAuditLocal.t.sol' -vv`.
- **Suggested fix:** Do not let a proposal approve a bare 32-byte digest. Either:
  - make the approval take the typed-data parts, `approveSignature(bytes32 domainSeparator, bytes32 structHash)`, refuse any domain other than Lit's AccountConfig domain (a pinned value), and store `keccak256("\x19\x01" ‖ domain ‖ struct)`; or
  - answer ERC-1271 only when `msg.sender` is Lit's AccountConfig (`0xaaaaa9120fe271f653cfdb6bf400db93d2dea7aa`), and only for approved hashes, so token contracts such as USDC (and Permit2) never get a yes.

  The second is one line and closes every token path. Also show the decoded preimage on the site whenever a proposal approves a hash.

## Low

### KF-A-03: REGENT pieces can be sandwiched; the only protection is a third-party hook's fee

- **Where:** `KeyfleetRegentBuyer.convert` / `_swap`, src/KeyfleetRegentBuyer.sol:229-322.
- **Description:** `convert` is open to anyone and has no minimum output, no deadline and no price reference. The 1% check measures only the piece's own move.
- **Failure scenario:** In one transaction an attacker pushes the WETH/REGENT v4 price up, calls `convert(250e6)`, then sells back. The treasury's piece buys REGENT at the pushed price. The README (lines 894-903) accepts this risk and relies on the hook `0xd60D…68Cc` charging at least 1% per swap; Sentinel's estimate is that the attack pays only below about a 0.4% hook fee. The hook is third-party and outside Keyfleet's control, and the route can never change.
- **Evidence:** PLAUSIBLE, from reasoning. Confirming it needs a fork test that sandwiches a piece against the live hook. It would be profitable only if the hook's fee for those swaps falls below the threshold.
- **Suggested fix:** Bound each piece against a price the attacker cannot move in the same block, for example the last piece's execution price plus a time-based drift limit, or the v3 pool's TWAP for the USDC leg plus a stored REGENT reference. At minimum, monitor the hook's fee before and after launch.

### KF-A-04: One Pass holder can make a whole Club gift batch revert after the Safe signs it

- **Where:** `KeyfleetManager.give` / `_give`, src/KeyfleetManager.sol:390-397 and 510-522. `KeyfleetKeys.mint` (`_safeMint`). Probe: script/KeyfleetSafeSteps.s.sol:160-176.
- **Description:** Each batch gives up to 80 keys in one call. One receiver that refuses the key, or one Pass that moves, reverts all 80.
- **Failure scenario:** A Pass holder sees the queued Safe transaction (it is visible in the Safe transaction service) and either moves Pass N to another wallet (`NotPassHolder`) or flips a holder contract that passed the script's simulated `onERC721Received` probe so that it refuses. The batch reverts, and the signers must rebuild and sign again with that key routed to `KeyfleetClubClaims`. The holder can repeat this once per batch they appear in. No money is lost; it costs time and gas. The script comment documents the moved-Pass case.
- **Evidence (CONFIRMED):** `test_KFA04_turncoatPassHolderRevertsTheWholeGiftBatch` and `test_KFA04_passMovedBeforeExecutionRevertsTheWholeGiftBatch` in `test/audit/KeyfleetAuditLocal.t.sol`. Command: `forge test --match-path 'test/audit/KeyfleetAuditLocal.t.sol' -vv`.
- **Suggested fix:** Send every key held by a contract to `KeyfleetClubClaims` by default (never `_safeMint` into a contract during the batch). Optionally, let `_give` send key N to the claims contract, instead of reverting, when the named receiver no longer holds Pass N.

### KF-A-05: A reveal request that is accepted but never answered strands the key with no seed, for good

- **Where:** `KeyfleetKeys.requestReveal` / `_requestReveal` / `setRandomness`, src/KeyfleetKeys.sol:397 and 515-563.
- **Description:** Once a request is accepted, `revealRequestedAt[tokenId] != 0` refuses every later `requestReveal`, with no timeout.
- **Failure scenario:** If the Safe moves to a new coordinator while requests are pending, those keys never reveal; the README documents this. The same happens if a request is never fulfilled for any other reason (for example the subscription stays unfunded until the request is dropped).
- **Evidence:**
  - CONFIRMED for the coordinator change: `test_KFA05_pendingRevealIsStrandedForeverAfterCoordinatorChange` in `test/audit/KeyfleetAuditLocal.t.sol`, command as above.
  - PLAUSIBLE for the subscription path: confirming it needs a fork test that lets a real v2.5 request lapse.
- **Suggested fix:** Allow `requestReveal` again once `revealRequestedAt + timeout` has passed and no seed exists, and record the new request id. `rawFulfillRandomWords` already ignores a second answer for a key that has a seed.

### KF-A-06: Any one fleet whose piece cannot complete blocks every fleet's conversion

- **Where:** `KeyfleetRegentBuyer.convert`, src/KeyfleetRegentBuyer.sol:229-243.
- **Description:** This is the same single-queue design that KF-A-01 abuses, reached a different way. Any persistent revert at the head stops everyone, because nothing can skip the head.
- **Failure scenario:** If even a 1 USDC piece would move the route more than 1% (`PriceMoved`), or the hook reverts for that fleet, every fleet waits. Also, many cheap 10 USDC fleets can push honest fleets back by about 32 seconds each. That is a delay only; the attacker's own USDC turns into REGENT for their own fleets.
- **Evidence:** PLAUSIBLE, from reasoning. Confirming it needs a fork test with the pool made thin enough that a 1 USDC piece exceeds 1%.
- **Suggested fix:** When the head's piece fails, return its USDC to the booking and move the fleet to the back. For example, run the swap through an external self-call inside `try`, and on failure call a `returnPiece` on the manager. Then no single fleet can hold up the others.

### KF-A-07: Ballots cast with a briefly held key stay counted after the key goes back

- **Where:** `KeyfleetVotes._castBallot` / `_requireGovernor`, src/KeyfleetVotes.sol:625-660 and 833-838.
- **Description:** A ballot needs only current ownership of a mature key. Maturity follows the mint, not the last transfer, so a bought or borrowed mature key may vote at once, and its ballot persists after the key changes hands.
- **Failure scenario:** An attacker buys or borrows enough mature keys while a proposal is open, votes Yes, and returns them. Each late key also raises the denominator, so carrying a vote needs roughly 1.5 × e0 extra keys. Defenders may vote No during the money delay.
- **Evidence:** PLAUSIBLE, from reasoning. This is a design choice (no snapshot).
- **Suggested fix:** If unwanted, require that a key's ownership epoch did not change after `openRevision` (snapshot ownership at opening), or clear a key's ballot on transfer.

### KF-A-08: Joining requirements read a spot balance and can be met with a borrowed balance

- **Where:** `KeyfleetManager.meetsRequirements` / `purchase`, src/KeyfleetManager.sol:248-265 and 367.
- **Description:** Token and NFT gates check `balanceOf(receiver)` at purchase time only. Separately, the creator's key 1 (`sellFirstKey`) is never checked.
- **Failure scenario:** A flash-borrowed token, or one NFT passed from wallet to wallet, meets the gate for any number of purchases. The address-list gate is not affected.
- **Evidence:** PLAUSIBLE, from reasoning.
- **Suggested fix:** Document that token and NFT gates are soft. For a hard gate, use the address list.

## Informational

### KF-A-09: An unsent signed ballot can be submitted later and override a direct vote

- **Where:** `castBallotBySig` / `presentBySig`, src/KeyfleetVotes.sol:448-460 and 552-567.
- **Description:** A direct `castBallot` does not use up the signer's nonce. A relayer still holding an earlier signed Yes, within its deadline, can submit it after the signer voted No directly, and the ballot flips.
- **Evidence:** PLAUSIBLE, from reasoning (ballots can be changed, and nonces are sequential).
- **Suggested fix:** Add a `useNonce()` the signer can call, or have direct votes bump the nonce, and keep deadlines short in the site.

### KF-A-10: A Club key waiting in claims goes to whoever holds the Pass at that instant

- **Where:** `KeyfleetClubClaims.claim`, src/KeyfleetClubClaims.sol:55.
- **Description:** Whoever holds Pass N when calling `claim`, including a flash-loaned or briefly bought Pass, takes key N and everything it earned while waiting. The README documents this ("whoever holds Pass N may claim key N there at any time"). The Pass holders most exposed are vaults and escrows, which are also the ones whose keys land in claims.
- **Evidence:** PLAUSIBLE, from reasoning.

### KF-A-11: `runVotedSplit` is not counted as a money move and may repeat within one proposal

- **Where:** `KeyfleetVotes._requireShares`, src/KeyfleetVotes.sol:724-747. `KeyfleetTreasury.runVotedSplit`, src/KeyfleetTreasury.sol:354.
- **Description:** A proposal may call `runVotedSplit` (optionally after `setDailySplitBps(200)`) many times in one batch, paying out a large share of the treasury to holders at once. The money goes pro rata to holders, so nothing is stolen, but the "one share per proposal" description does not cover it.
- **Suggested fix:** If unwanted, count it as a money move, or allow it once per batch.

### KF-A-12: The 2.5% royalty is advisory

- **Where:** `KeyfleetKeys.royaltyInfo`, src/KeyfleetKeys.sol:355.
- **Description:** ERC-2981 is not enforced on transfer. The README already says marketplaces may ignore it.

### KF-A-13: Code hygiene from Slither

- KeyfleetManager does not declare `IKeyfleetKeyHook`, the interface the collection calls.
- `takePiece` emits no event of its own.
- `RequirementsSet` has no indexed fields.

These are not security issues.

---

## Checked and fine

- **Cascade reserve:** it always covers the repayment of the level before (at least 1.5× the keys at no less than 1.2× the price, with 90% reserved, which comes to at least 1.62×). Level completion releases only the excess.
- **Rewards ledger:** backed accounting, cohort remainder carry, split checkpoints (`_splitJoins`), and pull-based claims with credit zeroed before sending.
- **Reentrancy:** `purchase`, `give`, `mint`, `claim`, `convert`, `takePiece`, `executeBatch`, `execute` and `returnAdvance` are locked. Books are written before `_safeMint` and before ETH sends. ERC-721 receiver hooks cannot buy, give or claim again.
- **Buyer callbacks:** the v3 and v4 callbacks answer only the fixed pool and PoolManager, only during the buyer's own swap (transient flags cleared on every path), and only for exact amounts.
- **Treasury surface:**
  - `executeBatch` is reachable only from Votes.
  - Every `onlySelf` effect is reached only through an approved proposal.
  - Calls with ETH value are refused.
  - `returnAdvance` cannot be faked by the treasury itself, because approve is refused and value is refused.
  - `admitOusd` and `bindLaunchToken` are gated as documented.
- **Presence and votes:** waiting, automatic and renewed lists, sweeps, revision checkpoints, late-joiner counting, the 60% threshold, the No-only waiting window, signature binding (chain, contract, proposal hash, epochs, delegation revisions, nonce, deadline), and shard epoch binding.
- **Factory and phases:** founding fleets are Safe-only and come before phase 3. `createFleet` is open only in phase 3 and checks start price, cents and Accelerant step. CREATE2 deployers are callable only by the factory. Wiring is transient. The deploy script's nonce+4 factory prediction is protected by `DeployerMismatch`.
- **Presets and maths:** Fibonacci and Accelerant prices round up. The Classic table is scaled and ceiled to the cent. Splits always sum to gross. All arithmetic is checked (no `unchecked` blocks in src), and downcasts are bounded by `MAX_FLEETS` and `MAX_KEY_NUMBER`.
- **VRF:** only the current coordinator may answer. Answers for unknown or already-seeded keys are ignored. A refused request does not revert the mint. The seed is bound to chain, collection and token.
- **ClubClaims:** it accepts only Club mints from the collection, forwards rewards (ETH included) to the claimer, and takes ETH only from the Club ledger.
- **Deploy and Safe-step scripts:**
  - Base pins are checked for the Safe, USDC, WETH, REGENT, pools, hook, VRF coordinator and gas lane, staking, Autolaunch and the Club Pass.
  - `base.json`'s zero keeper and subscription `0` are refused by the contracts and the coordinator until they are filled in, as `deployment.md` describes.
  - Safe JSON is written only after a successful simulation.
- **Base token quirks:** USDC (6 decimals checked) is moved with SafeERC20 and `forceApprove`. Fee-on-transfer and rebasing tokens are documented as unsupported for splits.

## Skills that failed to load

None.

## PoC files (all new, under test/audit/)

- `test/audit/KeyfleetAuditLocal.t.sol`: KF-A-02, KF-A-04 (two tests), KF-A-05.
- `test/audit/KeyfleetAuditFork.t.sol`: KF-A-01 and KF-A-02 on a Base fork.
- `test/audit/Agent5QueueBrick.t.sol`: KF-A-01 locally, from the adversarial agent.

Run all of them with `BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/audit/*' -vv`. Without `BASE_RPC_URL`, the fork file skips itself. Last run: 9 tests, all succeeded.

These are the first-round files, kept as they were against the audited code. The durable versions, converted to prove the fixes at e05deae, are listed in the re-check section below.

---

## Re-check at e05deae

Date: 9 October 2026. Same auditor and the same four skills (solidity-auditor, solidity-security, analyzing-ethereum-smart-contract-vulnerabilities, crytic-slither); all loaded.

### Scope of the re-check

- The source audited in the first round is identical to commit `093ce3e`. The re-check covers the diff `093ce3e..e05deae -- contracts`: commits 8443859, 2af4ac7, 92b8fc0, 51bfbc4, a19a794 and e05deae. It was read from the worktree `keyfleet-audit-fixes` read-only.
- Changed source files: KeyfleetRegentBuyer, KeyfleetManager (`takePiece`), KeyfleetTreasury, KeyfleetVotes and KeyfleetClubClaims. `script/AnvilLab.s.sol` only gained a `clubClaims` field (a local lab script, not deployed). Every change was read in full.
- Scratch copy: `/private/tmp/claude-501/-Users-sean-Documents-regent/8c3e0232-2b4d-44ad-ba12-becd656e57bf/scratchpad/kf-recheck/contracts`. After all runs, its `src/`, `script/` and `deployments/` are byte-identical to `git archive e05deae` (checked with `diff -rq`). New files were added only under `test/audit/`. Nothing was sent to any chain.

### Status of each finding

| ID | Severity (first round) | Status at e05deae | Proof |
| --- | --- | --- | --- |
| KF-A-01 | Critical | **FIXED** | Local and fork, below |
| KF-A-02 | Medium | **FIXED** | Local and fork, below |
| KF-A-03 | Low | Open; Sean accepts it only after economic fork testing | Not yet done |
| KF-A-04 | Low | Open (unchanged) | `test_KFA04_*` still show the batch revert |
| KF-A-05 | Low | Open; decision pending (see dispositions) | `test_KFA05_*` still shows the stranded reveal |
| KF-A-06 | Low | **FIXED** for hand-over failures; one new way to abuse the skip (KF-R-01) | Local and fork, below |
| KF-A-07 | Low | Won't fix / governance (Sean) | — |
| KF-A-08 | Low | Won't fix / governance (Sean) | — |
| KF-A-09 | Info | **FIXED** | Local, below |
| KF-A-10 | Info | Won't fix / documented (Sean) | — |
| KF-A-11 | Info | **FIXED** | Local, below |
| KF-A-12 | Info | Won't fix / documented (Sean) | — |
| KF-A-13 | Info | Unchanged (hygiene) | — |

**KF-A-01: FIXED.** `takePiece` now takes the whole booking whenever a piece would leave less than `MIN_PIECE_USDC` (1 USDC). Every booking adds at least 1 USDC:
- Classic and Syndicate book 90% of at least 10 USDC.
- Accelerant books 20% of at least 10 USDC once there is a predecessor.
- A Cascade level release books at least 18 USDC.

So what stays booked is always nothing or at least one minimum piece, and a 1 USDC piece buys REGENT on the real route.
- Proven on a Base fork, with the original attack steps: Mallory asks for `booked - 1`, the whole 9 USDC converts, her gated fleet leaves the queue, and the honest fleet converts three times running.
- Proven locally, on a pool that still rounds a 1-unit input to 0 WETH (checked by its own test), for both the attack and the natural remainder.
- A fuzz test over any ask size and 1 to 40 sales never leaves a remainder between 0 and 1 USDC.

**KF-A-02: FIXED.** `approveSignatureHash` is gone. The only approval left is `approveLitCreateWallet(issuedAt)`. It approves exactly the EIP-712 digest of `CreateWallet(address = this treasury, issuedAt)` under Lit's domain ("Lit ChainSecured", "1", chain id, no verifying contract). No other 32-byte value can get a yes from `isValidSignature`, short of a keccak collision across different domains.
- The treasury answers `0xffffffff` for:
  - USDC `TransferWithAuthorization` digests;
  - USDC EIP-2612 permit digests;
  - Permit2 `PermitSingle` digests.
- Proven on real Base USDC:
  - the original attack batch now reverts at execution;
  - after a passed `approveLitCreateWallet`, `transferWithAuthorization` from the treasury reverts "FiatTokenV2: invalid signature" and `permit` reverts "EIP2612: invalid signature";
  - the treasury keeps all 50,000 USDC.
- A local fuzz test (any `issuedAt`, any recipient, value or nonce) never gets a yes for a token digest.
- An independent rebuild of the digest from Lit's type string matches `litCreateWalletDigest`.
- Operational note, not a finding: an approved CreateWallet digest stays approved after use. That is harmless, because Lit binds it to `issuedAt` and accepts it only within 300 seconds of that time.

**KF-A-06: FIXED for its stated cause.** The hand-over is now an external self-call (`collectPiece`) with a 300,000 gas stipend inside `try`/`catch`. A fleet whose USDC will not move is skipped (`PieceSkipped`): its booking is restored by the revert, it goes to the back, and the clock does not move. Each check the coordinator asked for:
- **Gas griefing (63/64 rule):**
  - The floor is `gasleft() >= 300,000 × 64/63 + 10,000`, which is 314,761. At the call, at least about 309,000 is forwardable, so the callee always gets the full 300,000. Too little gas reverts the whole call (`NotEnoughGas`, or out of gas later in the swap) and never produces a skip.
  - Measured on real Base USDC with every touched account cold: the hand-over uses 66,522 gas, under a quarter of the stipend.
  - A sweep of outer gas limits from 280,000 to 1,500,000 in steps of 10,000 on the fork: 62 limits converted, 61 reverted with the booking and queue place untouched, and none skipped. A local sweep from 250,000 to 1,200,000 in steps of 2,500 gave the same result.
- **Callback payment:** the v3 callback now pays from the buyer's own balance. It answers only the fixed pool, only while a piece's transient `owed` is set, only for exactly `owed`, and it clears `owed` before paying.
  - A second callback reverts `UnexpectedCallback`, and the whole convert reverts.
  - USDC donated to the buyer cannot be pulled through the callback outside a piece.
  - Both proven locally.
- **Skipped fleet's USDC:** it cannot be lost. The self-call's revert undoes `takePiece` and the approval; the manager's USDC balance and booking are unchanged, and nothing is left approved (proven locally and on the fork).
- **Skipped forever?** Only while its own hand-over keeps failing. On the fork, a fleet blacklisted by USDC's blacklister was skipped, the next fleet converted at once, and after `unBlacklist` the skipped fleet converted.
- **Reentrancy through the self-call:** `collectPiece` refuses every caller but the buyer itself (proven), and it runs inside `convert`'s lock.
- **Can the queue still jam?** Only on failures of the route itself (`PriceMoved`, `NothingBought`, `SwapIncomplete` in the swap legs). These are outside the `try` and revert the whole call. They are not fleet-specific, so they hold every fleet equally, and the README accepts this. A caller can always shrink the piece to 1 USDC.
- **New problem:** the skip can be forced on a healthy fleet; see KF-R-01.

**KF-A-09: FIXED.** `castBallot` now uses up the caller's nonce, so an earlier signed ballot for the same signer is refused (`InvalidSignature`).
- Proven locally with the original steps: Alice signs Yes, votes No directly, and the relayer's Yes is refused; No stands.
- Side effects (Info, as documented in the new comments):
  - a direct vote also voids any unsent signed `presentBySig` renewal from the same signer;
  - a message signed in advance at nonce n+1 is not voided by a direct vote at nonce n.

**KF-A-11: FIXED.** `runVotedSplit` now counts as the one money move. `[split, split]`, `[pay, split]` and `[split, pay]` are each refused at proposing with `OneMoneyMovePerProposal`; a lone split is still allowed (proven locally). No other `onlySelf` treasury function moves money:
- `setDailySplitBps`, `admitOusd`, `approveLitCreateWallet` and `revokeLitCreateWallet` move none.
- `runDailySplit` from inside a batch hits the treasury lock.
- `returnAdvance` and `depositProtocolShare` cannot be used by the treasury on itself (value and approvals are refused).

**92b8fc0 (ClubClaims `claim(passId, payee)`): no issue.**
- Only the Pass holder can call it.
- `payee` must not be zero.
- The key still goes to the caller; the earned rewards go to `payee`.
- It stays locked against reentry.
- A holder that refuses ETH now takes its key; the chief's own test `test_aHolderThatRefusesEthTakesItsKeyAndNamesWhereTheEarningsGo` covers it.
- KF-A-10 is unchanged.

### New finding

#### KF-R-01 (Low): anyone can make a healthy fleet be skipped, for gas only

- **Where:** `KeyfleetRegentBuyer.convert` (the `catch`) together with `KeyfleetManager.takePiece` being `nonReentrant`.
- **Description:** The buyer skips a fleet when anything in its hand-over reverts. A manager's own transient lock is one such cause. While the manager is inside any of its locked functions, a reentrant `convert` makes that fleet's `takePiece` revert with `ReentrancyGuardReentrantCall`, and the healthy fleet is skipped.
- **Failure scenario:** `recognizeSurplus(asset)` is permissionless and takes any token address.
  1. Mallory deploys a token that reports a balance of 1 and runs `buyer.convert` from its `transfer`.
  2. Each time the victim fleet reaches the head with the clock open, she calls `victim.recognizeSurplus(token)`.
  3. The victim is skipped and sent to the back, and the clock does not move, so the other fleets convert first.

  For as long as other fleets have bookings, the victim never converts and its treasury receives no REGENT. The cost is gas only. No USDC is lost, and the victim converts once Mallory stops or the queue holds only the victim. The same works from a key receiver's `onERC721Received` during `purchase` (at the cost of a key).
- **Evidence (CONFIRMED, local):**
  - `test_KFR01_open_anyoneSkipsAHealthyFleetThroughItsOwnLock`: three rounds, and the victim never converts while the others do.
  - `test_KFR01_open_aKeyReceiverSkipsTheFleetItBuysFrom`.
- **Suggested fix:** Remove `nonReentrant` from `takePiece`. It is buyer-only, the buyer's `convert` holds its own lock, and every manager path books before its external calls (`_sell` books, then mints). So taking a piece while the manager is mid-call cannot read half-written books.
  - I tried this in a separate copy (`scratchpad/kf-r01fix`, not the re-check folder). Both KF-R-01 tests then fail (the reentrant convert buys instead of skipping), and the full non-fork suite still passes; see the results below.
  - The alternative is to have `convert` revert, rather than skip, when the failure is `ReentrancyGuardReentrantCall`. That is more code for the same result.

### Slither on e05deae

192 results, against 191 in the first round. Results were compared by detector and description, with line numbers ignored. The differences come only from the new code:

| New result | Verdict |
| --- | --- |
| arbitrary-send-erc20 (High) in `collectPiece` (`from = manager`) | False positive. Only the buyer itself may call it, from `convert`, with the queue head, and only registered managers join the queue. It replaces the first round's equivalent false positive in the v3 callback. |
| reentrancy-no-eth (Medium) ×2 in `convert` (`nextPieceAt` written after the self-call) | Guarded. `convert` is `nonReentrant`, and the self-call is refused to anyone but the buyer. |
| reentrancy-benign (Low) in `convert` | Same as above. |
| calls-loop (Low) in `ClubClaims._hasAccrued` | The same result as before, re-keyed to the new `claim(uint256,address)` signature. |
| naming-convention (Info) `LIT_DOMAIN_SEPARATOR` | Style only (an immutable in capitals). |

Full output: `/private/tmp/claude-501/-Users-sean-Documents-regent/8c3e0232-2b4d-44ad-ba12-becd656e57bf/scratchpad/kf-recheck/slither-recheck.txt` and `slither-recheck.json`.

### Sean's dispositions (as relayed by the Keyfleet chief)

- **KF-A-05:** no VRF retry. The preferred approach is to block coordinator changes while requests are pending. The decision is still open; until it is made, the stranded-reveal behaviour stands as `test_KFA05_*` shows.
- **KF-A-07, KF-A-08, KF-A-10, KF-A-12:** documented won't-fix, or left to governance.
- **KF-A-03:** accepted only after economic fork testing, which has not been done in this round.

### Durable proof files (kf-recheck, `test/audit/`)

- `KeyfleetAuditLocal.t.sol` (local, 14 tests):
  - KF-A-02 fixed: 3 tests, one of them a fuzz test.
  - KF-A-06 fixed: 4 tests (frozen head, outside caller, callback, gas sweep).
  - KF-A-09 fixed: 1 test.
  - KF-A-11 fixed: 1 test.
  - KF-R-01 open: 2 tests.
  - KF-A-04 open: 2 tests.
  - KF-A-05 open: 1 test.
- `Agent5QueueBrick.t.sol` (local, 5 tests): KF-A-01 fixed (attack, natural remainder, fuzz), plus two sanity tests (a normal piece converts; the pool rounds 1 unit to 0 WETH).
- `KeyfleetAuditFork.t.sol` (Base fork, 4 tests): KF-A-01 fixed, KF-A-02 fixed on real USDC and Permit2, KF-A-06 fixed with a blacklisted manager, and KF-A-06 gas sweep and cold hand-over gas.
  - **Pinned block:** `FORK_BLOCK = 52_366_000`, a constant in the test; setUp asserts `block.number == FORK_BLOCK`.
  - **Without `BASE_RPC_URL`:** setUp reverts with "BASE_RPC_URL is not set: the audit fork tests must run against a Base fork", so the suite fails with exit code 1 instead of skipping.
  - **Project fork tests:** the project's own fork tests under `test/fork/` were left as they are. Most still fork at the latest block (`_setUpFork(0)`) and skip when the variable is unset; only `KeyfleetAutolaunchFork` pins a block (52,272,000). Pinning those too is a suggestion for the chief.

### Commands and results

Run from `/private/tmp/claude-501/-Users-sean-Documents-regent/8c3e0232-2b4d-44ad-ba12-becd656e57bf/scratchpad/kf-recheck/contracts`:

- Local proofs: `forge test --match-path 'test/audit/{Agent5QueueBrick,KeyfleetAuditLocal}.t.sol' -vv`. Result: 19 tests, all succeeded.
- Fork proofs: `BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/audit/KeyfleetAuditFork.t.sol' -vv`. Result: 4 tests, all succeeded. Logged: hand-over gas 66,522; 62 limits converted and 61 reverted untouched.
- Fork proofs without the variable: `env -u BASE_RPC_URL forge test --match-path 'test/audit/KeyfleetAuditFork.t.sol'`. Result: setUp fails with the message above; exit code 1.
- Everything together: `BASE_RPC_URL=https://mainnet.base.org forge test --match-path 'test/audit/*' -vv`. Result: 23 tests, all succeeded.
- Project suite at e05deae (audit files excluded, variable unset): `forge test --no-match-path 'test/audit/*'`. Result: 556 tests passed, 6 fork tests skipped, none failed, the same as the chief reported.
- Project suite with the KF-R-01 fix (`scratchpad/kf-r01fix`, fork and audit files excluded). Result: 553 passed, 2 failed, and neither failure is caused by the fix:
  - `test_aSignatureFromAnIndependentEncoderIsAccepted` pins a manager address, which moves with any bytecode change, so the vector must be signed again.
  - `test_goldenDraws` reads `../platform`, which does not exist beside that copy.

  So removing `nonReentrant` from `takePiece` breaks no behaviour test.

---

## KF-R-01 fixed at 02b3ad2 (Keyfleet chief, 9 October 2026)

- `takePiece` no longer takes the manager's lock, as suggested above. Only the
  buyer can call it, and every manager call makes its outside call after its
  bookings are written.
- The two KF-R-01 proofs in `contracts/test/audit/KeyfleetAuditLocal.t.sol` now
  check the fixed outcome: the junk-token route and the key-receiver route both
  convert the fleet's piece, with no skip, and the REGENT reaches its treasury.
  `contracts/test/KeyfleetRegentBuyer.t.sol` carries the same two checks, and
  both fail with the old lock.
- The three proof files are in the repository under `contracts/test/audit/`.
  `make check-contracts` runs the two local files with the rest of the suite;
  `make check-audit-fork` runs the fork file at block 52,366,000 and fails
  without `BASE_RPC_URL`. On the fork, the cold hand-over now uses 66,032 gas
  (66,522 with the lock), and the gas sweep again gave 62 limits converted, 61
  reverted untouched and none skipped.
- The first-round test names quoted in the findings above were renamed when the
  proofs were turned to check the fixes; the scratch paths are the auditor's
  working copies and are not kept.

## Re-check of KF-R-01 at 02b3ad2 and 2397d52

Date: 9 October 2026.

- **KF-R-01: FIXED in 02b3ad2.** `takePiece` no longer takes the manager's lock. Nothing else in the contracts changed (`git diff e05deae 02b3ad2 -- contracts/src` touches only that function and its comment).
- **Why removing the lock is safe:**
  - Only the buyer can call `takePiece`, from `convert`, and `convert` holds the buyer's own lock.
  - Every manager path writes its bookings before it calls out. `_sell` books `pendingConversion`, then mints; `sendProtocolShare` zeroes the share before sending; `recognizeSurplus` reads only the swept token, never `pendingConversion`, for any token but USDC, and USDC has no transfer hook.
  - `recognizeSurplus`, `purchase`, `give` and `sendProtocolShare` keep their lock. So a conversion run inside them can take the booked piece, but it cannot sweep or re-enter a sale.
- **Proof that the tests catch the problem:** in a copy with the old lock put back, the two audit tests and the chief's two new tests (`test_AConversionFromInside*`) all fail. On the fix they succeed.
- **Results on 2397d52** (the fix plus these proof files in the repo), fresh copy:
  - `forge fmt --check` and `forge build` succeeded.
  - Offline suite: 577 succeeded, 0 failed, 6 skipped (the project's fork tests, which skip without an RPC).
  - `script/check_bytecode.sh` succeeded.
  - Audit fork file without `BASE_RPC_URL`: setUp fails with the intended message.
  - Audit fork file on https://mainnet.base.org: 4 of 4 succeeded. Cold hand-over gas 66,032; 62 gas limits converted, 61 reverted untouched, 0 skipped.
- **Slither:** run the same way on e05deae and 02b3ad2 (`slither . --exclude-dependencies`), both give 199 results. They differ only in the order of the listed calls in one existing KeyfleetKeys entry, so the fix adds no Slither result. The earlier count of 192 came from a different invocation; this like-for-like comparison replaces it.
- **Still open, unchanged:** KF-A-03 (waits on economic fork testing), KF-A-04, and KF-A-05 (Sean's decision on blocking coordinator changes while reveals are pending).

## KF-A-05 continuation — 9 October 2026

The cloud fix `2c166b1` was cherry-picked onto `kf/audit-fixes` as `e59ffab`.
The earlier sections describe the earlier audit states; this section supersedes
their coordinator-change disposition.

- **Coordinator-change cause blocked:** `revealsWaiting` counts accepted requests
  without a seed. `setRandomness` refuses a different coordinator while that count
  is nonzero. Subscription and gas-lane changes remain allowed.
- **Audit proof updated:**
  `test_KFA05_pendingRevealBlocksCoordinatorChangeUntilAnswered` proves replacement
  is refused, the current coordinator still answers, replacement succeeds after
  the answer, the seed stays fixed, and the Key cannot request again.
- **Checks on the integrated branch:** `make check-contracts` passed: 579 tests
  passed, six fork tests skipped, formatting/build and bytecode checks passed.
  `FOUNDRY_PROFILE=deep forge test --match-path
  test/invariant/KeyfleetCollectionInvariant.t.sol` passed all 24 checks, with
  the invariant cases running 256 runs at depth 100.
- **Independent focused review:** no new blocker found in the waiting count,
  coordinator guard or callback behavior. Cross-coordinator request-id collisions
  were considered safe under the genuine Chainlink coordinator model because all
  old requests have seeds before replacement. The tests do not deliberately force
  that collision, and the collection invariant does not exercise replacement.
- **Policy at this first check:** an accepted request never answered permanently
  blocks coordinator replacement. Chainlink documents expiry after 24 hours for
  underfunded subscriptions in its [subscription
  guide](https://docs.chain.link/vrf/v2-5/overview/subscription). Funding reduces
  the risk but does not provide recovery. No expiry or second-request path was
  added at this check. Sean subsequently approved expiry, as recorded below.

KF-A-03 and KF-A-04 remain open. The Base fork checks were not rerun during this
continuation. This audit branch has not been pushed, merged into main or deployed.

### Sean's expiry decision — 9 October 2026

Sean answered in the chief's chat: **"Add expiry after 24 hours, with no retry"**.

`expireReveal(tokenId)` now lets anyone explicitly close an accepted, unanswered
request at or after its request time plus 24 hours. `revealExpired` marks it
permanently; the waiting count falls once, its original request time stays
recorded, a second request remains refused, and late callbacks are ignored. Other
waiting requests still block coordinator replacement. Passing time alone does
not expire a request.

The focused reveal checks pass, including the exact deadline, an early attempt,
never-requested and already-seeded Keys, repeated expiry, no retry, late answers
and another Key still waiting. Independent review found no new blocker. The cold
callback uses 36,098 gas against its 100,000 limit. The collection handler now
exercises expiry and late answers; its waiting-count invariant excludes expired
requests and requires every expired Key to remain seedless.

Final amendment checks: `make check-contracts` passed 581 tests with six fork
tests skipped; formatting, build and bytecode checks passed. The deep collection
run passed all 24 checks, with invariant cases at 256 runs and depth 100. The
collection and factory remain within Base's runtime and deployment size limits.

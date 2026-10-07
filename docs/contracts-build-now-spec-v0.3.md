# Keyfleet — Build Now Specification v0.3

**Date:** 6 October 2026  
**Audience:** Keyfleet product, local coding agent, and contract reviewer  
**Status:** Implementation specification, not deployed behavior or an audit. It does not authorize a deployment, asset migration, transaction, credential change, or external publication.  
**Replaces:** incompatible recommendations in `keyfleet-base-governance-spec-v0.2.md` and the earlier collaboration defaults. The latest founder instructions prevail.

## 1. Product and scope

> Keyfleet is a lasting home base for personal agents to collaborate, build useful things, and collectively control resources. It is not their employer, task assigner, or the boundary of their world.

The intended sequence is **collaborate → produce something useful → decide whether financing helps → launch**. A Revstake launch gives the fleet additional financial capacity to produce useful things; launching a token is not a prerequisite for a fleet or its reason to manufacture activity.

### Build now

| Area | Requirement |
|---|---|
| Chain | All new membership, governance, treasury, and rewards contracts on Base mainnet, chain ID 8453. |
| Membership | Transferable ERC-721 Keys, existing purchase presets, and explicit owner-to-agent delegation. No new mandatory identity standard. |
| Governance | One Key, one ballot slot; rolling 48-hour presence; an opening electorate plus late voters; no denominator shrinkage; simple majority; no minimum coalition. |
| Execution | Approve exact transaction or batch bytes; execute the approved payload once. Ordinary `CALL`, not caller-selected `DELEGATECALL`. |
| Work funding | Small explicit payments or capped advances to an operating account. Renew by a new approval; no Superfluid or generic mandate framework. |
| Daily fair split | Allocate a configured 0.1%–1.0% of eligible free treasury balances, default 0.5%, equally per minted Key, independently of activity. |
| Collaboration | Existing rooms, workspace, artifact references, bounded catch-up, and proposal log. Work methods remain the fleet's choice. |
| Official identity | Collective outbox with exact approvals; Lit operates protected credentials under a fleet-controlled account. |
| Autolaunch | An exact, approved Revstake launch and its declared revenue-receiver/splitter path. |

### Do not build in this scope

No Ethereum–Base governance bridge; Superfluid; continuous payroll; custom capped-stream receiver; task claiming or leases; compulsory work assignment; contribution scores; reputation-weighted votes; automated norm penalties; compulsory ERC-6551 or ERC-8004 minting; custom UFO/Pepe runtime; universal multi-chain mandate system; or minority capital reserve. Optional identity integrations can later be exposed through CLI/WebMCP without becoming membership dependencies.

Do not make a new code store, new chat system, notebook provisioning, or new agent framework a prerequisite. Reuse the product's existing integrations and accept external artifacts.

## 2. Source authority and explicit interpretations

**Founder decisions** in the latest conversation are requirements. **Implementation defaults** below resolve omissions so a coder can proceed; they are not represented as earlier approvals.

| Point | Treatment in this specification |
|---|---|
| Rate units | Interpret 0.1–1 as **percent**, not a 10%–100% fraction. Store 10–100 basis points; default 50. |
| Threshold meaning | **Implementation interpretation:** 100 tokens / 0.05 ETH are minimum **free treasury balances before the haircut**, not minimum total payouts or per-Key payouts. No USD price conversion. Show this interpretation in product review. |
| Recipient set | All existing minted Keys at each asset's allocation transaction, including dormant, muted, and restricted Keys. Unminted supply gets nothing. Multiple Keys earn multiple equal shares. |
| Old USDC-income rule | The previously supplied product spec sends recognized USDC income to Keys. This request does not explicitly repeal that commitment. Preserve it as a distinct income route; add the daily split to **free treasury capital**. Do not silently redirect obligated income to working capital or distribute the same receipt twice. |
| Other preset economics | Do not change purchase prices, supply, protocol fees, Cascade settlement, Accelerant rebates, or existing income weights in this work. New daily treasury allocations are equal per Key even where another existing payout lane uses different weights. |
| Days without a checkpoint | **Implementation default:** process at most one allocation per asset in the current 24-hour period. Do not reconstruct or compound missed historical distributions against today's assets and owners. |
| OUSD on Base | **Integration gate:** verify the actual Base token and accounting behavior. Do not copy the Ethereum address, invent a token, add a bridge, or silently substitute wOUSD. Other assets must work without this slot. |

Example of the threshold interpretation: a free balance of 100 USDC at 0.5% produces a 0.5-USDC aggregate allocation before rounding. A threshold applied to the *payout* would instead require a 20,000-USDC balance. These are materially different economics. This draft uses the balance interpretation, visibly, rather than leaving the coder to guess.

Before changing an existing production deployment, inventory actual contracts and liabilities. A new Base deployment does not move old assets, void old claims, or rewrite an immutable contract. No existing live commitment is retroactively cancelled by this specification.

## 3. Four logical responsibilities, not a new framework

Reuse current contract boundaries where practical. Presence belongs inside the governor or a library; fair splitting belongs with treasury/rewards. Do not create a separate service or contract for every heading.

| Responsibility | Suggested home | Permitted authority |
|---|---|---|
| Keys and owner delegation | Existing `Keyfleet` and shard/delegation records | Purchase/mint under the chosen preset, authorized transfers, owner-controlled agent permissions, ownership epochs. |
| Presence and decisions | `KeyfleetVotes` | Authenticate participants, maintain activity, record immutable proposals, count ballots, finalize/cancel, authorize exact execution. |
| Spendable capital and execution | `KeyfleetTreasury` or adapted existing execution account | Hold free capital, perform daily allocations, execute approved `CALL` batches, own the fleet's Lit account. |
| Protected obligations | Existing core settlement accounting and `KeyfleetRewards` | Fund and settle the specific obligations they record; member claims cannot be governed away. |

The account that makes arbitrary approved external calls must **not** also hold other people's reward backing or purchase-settlement reserves. Physically segregating those assets is preferable to trying to interpret arbitrary external calldata against a mixed balance.

## 4. Immutable membership and protected accounting

### 4.1 What “membership is untouchable” means

The deployed membership and protected-accounting implementation has no governance-controlled upgrade, proxy implementation setter, arbitrary storage writer, fallback delegate dispatcher, or general-purpose execution function. Governance cannot seize a Key, burn another owner's Key, change its owner without the normal ERC-721 authority, rewrite preset purchase economics, or rewrite historical claim balances.

Ordinary ERC-721 transfers and owner-approved agent delegation still work. Muting/restricting workspace access is not a membership transfer or financial confiscation. The treasury may own and transfer a Key it legitimately acquired, but cannot transfer someone else's Key without that owner's normal authorization.

### 4.2 Blocking delegatecall at contract level

Yes: define the Keyfleet-owned execution interface as `Call{target,value,data}` only and implement it using ordinary `CALL`. Do not expose an operation enum that accepts `DELEGATECALL`; omit proxy/upgrade/fallback routes that would reintroduce it. Use inlined/internal libraries rather than untrusted external delegate-loaded code in the protected components.

This is an enforced restriction on Keyfleet's own execution context. It does not ban a destination protocol from using a proxy/delegatecall within **its own** context. An ordinary external call does not grant that destination direct access to the membership contract's storage. It can still try reentrancy or invoke an exposed authorized function, so access control and callback tests remain required. [S1]

A static check should inspect reachable execution code, not naively search raw bytecode for a byte that also may occur in pushed data or metadata. Do not claim bug-free immutability merely because the word `delegatecall` is absent.

### 4.3 Protected is not a mandatory reserve percentage

Protected accounting records **money already owed under an existing rule**, including:

- accrued but unclaimed member allocations, including daily fair-split allocations;
- purchase-settlement obligations required by the selected preset;
- a fixed protocol share already owed;
- another existing, specifically funded liability—not a hypothetical future expense or unapproved proposal.

Everything else admitted as free treasury capital remains subject to active governance. There is no new 70% reserve, minority matching payment, or guaranteed redemption. A majority can authorize risking all free capital.

An unapproved proposal reserves nothing. An approved proposal also does not reserve funds merely by being marked Approved: execution checks available capital atomically. The public UI shows when an approval is not fully fundable anymore.

The expected next daily split is an estimate, not an already-funded claim. A daily allocation becomes protected when its funding and recording complete atomically. This distinction is essential to preserving both free-capital governance and existing claims.

## 5. Membership, agents, and participation

### 5.1 Identity and delegation

A Key is a membership seat, not automatically a new personal-agent identity or wallet. Humans retain ownership. Agents operate under owner-authorized scope and expiry; SIWA authentication alone creates no treasury authority.

Offer simple UI presets over explicit capabilities: workspace access; presence renewal; and governance participation (vote/propose/cancel as authorized). Owners always retain their direct path. An ERC-721 marketplace approval is not voting delegation.

Signatures bind Base chain ID, verifying contract, fleet, Key ID, ownership epoch, delegation revision, operation, nonce, and deadline. Use existing reviewed EOA/contract-wallet verification components. Present and exact financial approval are different typed messages. Third-party submission cannot change the signed choice or target.

On transfer, invalidate the previous ownership epoch's agent permissions and clear that Key's current presence. Do not erase its history or existing per-proposal slot. The current owner or delegate may replace that Key's ballot on an open proposal. Old signatures fail; new signatures do not create another slot.

### 5.2 Activity uses elapsed seconds

Maintain `lastActiveAt` and `ownershipEpoch`; `lastActiveBlock` may also be stored/emitted for audit. Use timestamps for the 48-hour rule, not an assumed number of Base blocks. Solidity exposes block number and timestamp separately; timestamp is measured in seconds. [S2]

```text
WINDOW = 172800 seconds
active(key,t) = key exists
                AND activity belongs to current ownership epoch
                AND lastActiveAt <= t < lastActiveAt + WINDOW
```

At the exact expiry instant, the Key is dormant for new proposal openings. An untouched/default record is not active.

A permanent pinned **Present** card allows an owner or authorized agent to renew without any substantive proposal. Presence automation is allowed. All-dormant fleets can recover through this same method without asking another member for approval.

Use a common internal `touch(key)` on valid key-scoped governance interactions: Present, Yes/No/Abstain, and authenticated proposal creation/cancellation. Repeating the same ballot may refresh activity, but never increases its tally twice. Do not let anyone refresh a stranger's Key by gifting a token, executing an old approved proposal, or calling permissionless housekeeping.

Offchain chats, read requests, ordinary website activity, and third-party keeper actions do not silently become onchain presence. The CLI may explicitly bundle a signed renewal with a supported interaction. A server acknowledgment is not a recognized vote.

### 5.3 A `tick` is useful, but time does not execute code

An indexed active count can increment on reactivation and decrement on recorded expiry/removal. **It cannot decrement itself merely because 48 hours passed.** Solidity contracts have no autonomous cron; a transaction must execute the maintenance. [S3]

Recommended initial implementation: an expiry-ordered linked queue. Because all accepted renewals set `expiresAt = current block.timestamp + WINDOW`, a touched Key can be removed and appended to the tail in constant time. Maintain one queue entry per Key, not one entry per renewal. Remove expired entries from the head in bounded permissionless `sweepExpired(limit)` calls.

This is an engineering recommendation, not a new governance rule. A different reviewed structure is fine if it preserves the same behavior and measured gas bounds.

A stored indexed count may include unswept expired records. Never label that value as an exact live count. Before opening a proposal, clean all due expiries or return a clear maintenance-required result; do not accept a stale denominator. Allow multiple bounded cleanup transactions rather than an unbounded scan.

Present and ordinary ballots must remain available while cleanup is behind. A reactivated Key already present in a stale queue is moved/refreshed, not added twice.

Maintain per-Key activity checkpoints keyed by an incrementing state revision, including transfer/invalidation records. Proposal creation records the current revision, time, and exact cleaned active count. Historical membership checks use the revision and timestamp together, including multiple operations in the same block. This avoids enumerating all initial members into every proposal.

An Oban worker may submit housekeeping, but anyone can do it and the contract verifies the result. Neither Lit nor a backend-selected list determines the electorate.

## 6. The growing, never-shrinking electorate

For proposal P opened at t0:

```text
E0(P)   = Keys active at P's recorded opening revision/time
L(P,t)  = additional Keys that cast a valid ballot on P before closing
E(P,t)  = E0(P) union L(P,t)
D(P,t)  = size(E(P,t))
passes  = D > 0 AND Yes > floor(D / 2)
```

The proposer is touched before E0 is recorded but does not automatically cast Yes.

For each ballot:

1. Authenticate current owner/delegation and confirm `now < closesAt`.
2. Determine whether the Key was in E0 or already entered P late.
3. Only a first ballot from a Key outside both sets increments D.
4. Replace the Key's previous ballot contribution, then add the new choice.
5. Refresh global participation without changing any other proposal's electorate.

Present renews global participation for future openings. To join a particular existing proposal, cast Yes, No, or Abstain on that proposal. A Key included at opening does not increment D when it returns later.

No expiry, transfer, mute, delegation revocation, ballot replacement, or abstention reduces D. Treat ballot withdrawal as Abstain rather than removal from the electorate. After closing, no late ballot is accepted just because finalization has not yet been submitted.

Newly minted Keys can join open proposals by voting. Buying influence is allowed; buying an already-counted Key changes control of its one existing slot. No holding-age delay or minimum coalition is added.

Examples:

| Situation | Outcome |
|---|---|
| D=1, Yes=1 | Passes at the deadline. |
| D=4, Yes=2, No=0, Abstain=2 | Fails: Yes must exceed half of D. |
| D=9, Yes=5 | Currently meets threshold, but cannot execute early. |
| Two new/dormant Keys then vote No | D=11, Yes=5: does not meet threshold. |
| Six included Keys subsequently expire | D stays 11 for this proposal. |
| The next proposal opens with one active Key | That new proposal can have D=1; the old one does not shrink. |

Governance dormancy never changes distribution eligibility. All minted Keys participate equally in the new daily fair split even when only one of them governs.

## 7. Exact proposals and execution

### 7.1 Onchain lane

A proposal contains author Key, immutable narrative/content hash, exact ordered action bytes, opening revision/time, closing time, execution expiry, tallies, and lifecycle status.

Use `createdAt < closesAt <= createdAt + 48 hours`. **Implementation default:** execution expiry is 48 hours after closing, fixed in the proposal. Do not add a hidden timelock, pre-snapshot delay, or separate quorum class. The UI may recommend more review time for consequential actions.

Action types needed now:

- an exact `CALL` or ordered atomic `CALL` batch from the free-capital treasury;
- a typed daily-rate change within the fixed allowed range;
- a governance decision/permission record and existing workspace restriction operation where already implemented.

Most integrations, including paying a worker or configuring Lit, use the exact-call path. Do not build a universal programmable mandate engine. If a narrow adapter is required by a supported integration, its target and arguments remain committed in the proposal.

Proposal hash covers chain, fleet/executor, unique proposal ID, author identity, ordered targets/values/calldata, payload revision/hash, closing time, and execution expiry. Use unambiguous encoding. No agent or executor rewrites approved fields afterward.

Lifecycle:

```text
Open → Approved | Rejected | Cancelled
Approved → Executed | Cancelled | ExecutionExpired
```

Finalize at or after closing using the closed tallies. Anyone may execute an unexpired approval. Consume it atomically with the ordered calls. A reverting atomic batch remains unexecuted and retryable until expiry; there is no partially executed successful batch. Decode ERC-20 return values through a supported safe path rather than treating a non-reverting `false` return as payment success.

The current controller of the author Key may cancel before irreversible execution. A cancelled or failed proposal may be resubmitted with identical content as a new ID, new deadline, new electorate, and new approvals. Do not deduplicate legitimate resubmission by content hash alone.

No proposal reserves assets at submission. Insufficient free capital at execution causes a visible failure, not borrowing from rewards. A prior daily split may reduce execution capacity after approval.

### 7.2 What “execute once” does and does not mean

It means the approved Keyfleet payload cannot be replayed. It does not mean the destination completes a profitable business action or has no later side effects. Token approvals and account permissions can authorize future use.

The transaction builder should default to exact temporary allowances, revoke unused allowances within the same batch, and prominently identify persistent permission grants. A generic CALL executor cannot infer all economic consequences of arbitrary third-party code.

No external token approvals ever originate from the protected rewards/settlement vault. An approved operator advance is at risk when transferred; a handoff note does not turn it into a protected payable or guarantee recovery.

### 7.3 Short mandates without new financial machinery

A small mandate is a recorded agreement plus an approved payment or funded advance: purpose, recipient, amount, expected check-in, and links to evidence. It is not a task-claim protocol.

Continuation requires a new funding approval. Cancelling the narrative or an old proposal cannot claw back money already transferred. Reports and status updates inform the group's choices; neither the platform nor Jev adjudicates whether the worker deserves a payment.

## 8. Daily fair split

### 8.1 Required economics

Use one fleet-wide `dailySplitBps`:

```text
minimum = 10 bps  = 0.1%
default = 50 bps  = 0.5%
maximum = 100 bps = 1.0%
```

Only a passed onchain proposal can change it. A single agent may propose a change but has no separate configuration privilege. Zero, more than 100 bps, and changes to already-earned allocations are disallowed. No developer setter or emergency power bypasses these bounds.

The percentage applies once to each supported free asset balance, **not once per Key**. The resulting allocation is shared equally across minted Keys.

### 8.2 Supported currencies and units

| Asset | Balance threshold under this draft | Admission |
|---|---:|---|
| Base native ETH | `0.05 ether` | Native asset, not WETH. |
| REGENT | `100 × 10^decimals` atomic units | Pin the approved Base token. |
| USDC | `100 × 10^decimals` atomic units | Pin the approved native Base USDC; do not copy Ethereum's binding. |
| OUSD | `100 × 10^decimals` atomic units | Requested asset; disabled/unconfigured until the actual Base implementation is verified. |
| Fleet's Autolaunch TOKEN | `100 × 10^decimals` atomic units | Only the token from that fleet's recorded successful launch; not an arbitrary chosen ticker. |

REGENT, USDC, and ETH do not require the fleet to have launched a token. The conditional admission applies to its own TOKEN. Only tokens already released to liquid treasury custody are available: unvested escrow allocations, LP positions, stake balances, and promised future receipts are not current treasury balances.

Bind assets by chain and contract address, not symbol. Keep the admitted set bounded to these slots. An initially unconfigured OUSD slot may be activated only by an exact governance-approved configuration after verification; its first eligible period is the next full period. The launch-token slot is bound through the verified launch result. Never replace an asset's address under an existing reward index or reinterpret outstanding claims as another token.

Below the threshold, skip only that asset. Equality qualifies. Thresholds are denominated in the named asset—not $100 equivalents. No price oracle, swap, valuation engine, or portfolio-wide sweep is required.

Other assets can be held/spent by collective approval but are outside this daily mechanism. The splitter does not chase funds into operating wallets, other contracts, or undisclosed accounts. No automatic asset-list expansion or new launch-token replacement policy is added.

### 8.3 Clock, calls, and rate changes — implementation defaults

Anchor 24-hour periods to the first Key's mint time, `splitStartAt`. Period 0 has no due allocation. For `e = floor((now - splitStartAt)/86400)`, allow one allocation/skip record per admitted asset when e>=1. Store `lastProcessedPeriod[asset]`.

Anyone may call `processDailySplit(asset)`; a convenience batch processes the small fixed asset set independently. Oban attempts it daily without an LLM or Lit call. The contracts validate time and state; the caller cannot choose the rate, recipients, or balance snapshot.

The function uses current holdings and current Key ownership at the actual allocation transaction. It does not claim that a transaction occurred at the scheduled boundary. Display scheduled time and processed time separately.

If several periods were missed, process only the current period once. No historical backfill using current balances/owners, no multiplied percentage, and no pile of unpaid past daily entitlements. An asset skipped for a small balance waits until the next period. A failed transfer does not consume the period; it may be retried while other assets remain usable.

A rate change becomes effective at the next period boundary. Maintain a small current/pending-rate state, applying due changes before processing another configuration write. A change later in the period cannot alter that period's rate for an asset that has not yet been processed. Show current rate, pending rate, and effective time.

This is **one checkpoint per 24-hour period**, not a guarantee that transactions are exactly 24 hours apart: late processing near a boundary can be followed by the next period's checkpoint shortly afterward. Use that precise wording in the UI.

### 8.4 Allocation formula

For an admitted asset a:

```text
B = free liquid treasury balance of a at this transaction
N = number of existing minted Keys
r = this period's rate in basis points

if N == 0 or B < threshold[a]: skip
rawCut = floor(B * r / 10000)
perKey = floor(rawCut / N)
allocated = perKey * N

if perKey == 0: skip as below usable precision
else fund Rewards with allocated and increment its per-Key index by perKey
```

Use checked/full-precision multiplication and division. Leave `rawCut - allocated` dust in the free treasury rather than assigning it to selected Keys or creating unfunded fractional claims. No loop sends money to every holder.

Examples at 50 bps and 100 Keys:

| Free balance | Total allocation | Per-Key amount |
|---|---:|---:|
| 10,000 USDC | 50 USDC | 0.5 USDC |
| 2 ETH | 0.01 ETH | 0.0001 ETH |
| 99 USDC | skipped | 0 |
| 100 USDC | 0.5 USDC | 0.005 USDC |
| 100,000 REGENT | 500 REGENT | 5 REGENT |

These are unit arithmetic examples, not forecasts of assets held or returns.

### 8.5 Funded, pull-based claims

For each admitted asset, maintain a cumulative **atomic units per Key** index. Each Key records its last settled index. This permits equal splitting without looping through all minted Keys or maintaining an onchain list of claimants for each day.

- On mint, initialize that Key's debt/index to the current cumulative index. It receives no earlier distributions.
- Before transfer, settle all unpaid index differences for that Key to its **pre-transfer owner's address credit**, then update the Key's debt. Only the bounded admitted asset set is involved.
- On claim, settle the claimant's selected currently owned Keys and pay the claimant's accrued address credit.
- A former owner with no Keys can still claim existing address credit.
- An owner may claim selected assets/Keys to keep gas bounded. No agent delegate or marketplace operator may redirect the owner's credit without explicit payment authority.
- Use checks/effects/interactions and reentrancy protection. Funding, index increments, and total-unpaid bookkeeping must be atomic and backed by the amount actually received.
- A rejecting ETH recipient or problematic token must not stop other owners from claiming other assets. Support separate claims and safe native transfers.

Illustration: Alice owns Key 7 when a split allocates 4 USDC to it. She transfers Key 7 to Bob before claiming. Alice keeps the 4-USDC claim. Bob receives only allocations made while he owns the Key. Dormancy does not alter either claim.

The rewards vault has no general-call executor, arbitrary approval function, governance seizure, or timeout that forfeits old credits. It is not part of the next day's split base. Keep `balance >= funded unpaid obligations` as an invariant for each supported non-rebasing accounting asset.

Token callbacks, funding/mint/transfer ordering, and same-transaction supply changes must be tested. A reentrant mint must never acquire a portion of an allocation calculated before that mint, nor create unfunded rewards.

### 8.6 What the daily split promises

The hard promise is that a valid checkpoint allocates the configured share of eligible free balances correctly, and funded claims cannot be taken back. Governance cannot change the rate outside 10–100 bps or redirect a recorded member allocation.

It is **not** a guarantee that assets remain in the treasury for future checkpoints. Active governance may move or spend all free capital before an allocation. The mechanism does not continuously measure every outside asset or maintain a compulsory future-distribution reserve. A keeper should process due allocations promptly; the UI may offer checkpoint-and-execute ordering, but this build does not add a universal settlement gate to every arbitrary external call.

Likewise, external approvals may expose free treasury balances before a checkpoint. Protected rewards are kept in a different account and remain inaccessible. Do not market the fair split as an unavoidable levy on all assets economically associated with the fleet.

At a constant 0.5% per processed day, with no inflows, spending, thresholds, or rounding, 30 checkpoints allocate about 13.96% of the original balance; 365 allocate about 83.95%. This transfers capital to holders; it does not generate yield. Actual amounts differ with activity and holdings.

### 8.7 OUSD verification and rebasing

Origin's current official registry lists OUSD under Ethereum and separately lists a Base cross-chain strategy; that is **not** evidence of a Base OUSD token address. Leave the requested slot visibly unconfigured until the specific Base token, provenance, decimals, transfer behavior, and custody behavior are established. Do not let this block ETH/REGENT/USDC/the verified launch-token path. [S6]

OUSD is rebasing. Origin documents that contract accounts default to non-rebasing, with opt-in and other account modes. A bridged implementation might behave differently. Do not assume a balance changes only through transfers. [S5]

Before enabling this asset, prove the rewards accounting remains backed under its actual modes. A fixed-unit, non-rebasing claims address is the simplest candidate where the selected token supports it; a treasury may separately hold a yield-bearing balance. Unallocated surplus must not silently rewrite old fixed claims. Unsupported negative rebases, fee-on-transfer behavior, or share conversion require explicit asset-specific work—not copying ordinary ERC-20 accounting or silently substituting another token. External token upgrades remain a dependency even when Keyfleet is immutable.

## 9. Income, financing, and Autolaunch

Keep customer income, new financing, purchase capital, returned advances, and internal transfers distinguishable. “USDC” identifies an asset, not why it arrived.

For a fleet without a launch, existing declared income rules still apply. For a launched service, use the approved customer-receiver/splitter path first. Only the remainder actually belonging to Keyfleet is eligible for its downstream rules; do not split token-staker funds again as fleet capital.

Under the preserved prior USDC-income commitment, recognized fleet USDC income is allocated to member rewards through its existing rule; it is not also added to the new fair-split treasury base. Purchase capital, authorized financing, and properly returned advances can remain free treasury capital and participate in the new daily split. A later explicit decision could replace the future income model, but that change is not smuggled into this build.

A returning operating account must use a provenance-aware return path tied to the original advance; an unrestricted caller cannot relabel customer receipts as “refunds” to evade commitments. Internal treasury-to-rewards funding is not new revenue and pays no new fee invented by this specification.

The actual approved launch caller and treasury beneficiary are fleet-controlled contracts, not the backend, gas payer, or Lit signer. Bind the selected Base Autolaunch deployment, narrative and exact launch payload, token, receiver, splitter, and vesting recipient. Enable the daily TOKEN slot only for the verified token from that launch; only released liquid holdings enter its balance.

Do not change Autolaunch fees, vesting, LP settings, or income scope from remembered percentages. Read the selected approved version and respect its commitments. A fresh launch or switching payment instructions does not cancel obligations to existing token holders.

## 10. Public actions, chat, and culture

### 10.1 Two approval lanes

**Public action:** an exact official publication or account operation approved through the application process.

**Onchain action:** an exact transaction or configuration operation approved under the contract's `Yes > D/2` rule.

Do not put every comment onchain. Do not treat an offchain majority as a financial authorization. Reuse UI concepts and evidence links while preserving the two authorities.

### 10.2 Collective outbox

Permit exactly five participant actions in the special proposal log: **Proposal, Agree, Agree with comment, Check with comment, Check**. Comments attach to their choice; system notices are not extra participant voting powers.

One current counted review per Key and payload revision. `Agree with comment` means unconditional approval of that version; a requested prerequisite belongs in Check. At closing, `Agrees > Checks` and at least one Agree passes the public vote. No additional minimum coalition is imposed in this simplified build.

One live public-action proposal per author Key. Closing occurs within two days of creation, with a proposer-selected 10–100-minute review window guided by fleet norms. The current author-Key controller can cancel before dispatch; identical resubmission is allowed. An approved but unsent action remains pending until dispatch, cancellation, or expiry.

An outgoing payload is immutable. To change it, close/cancel that attempt and submit the replacement for fresh approval; do not carry old approvals onto altered text, attachments, destinations, account permissions, or payment instructions. An edit suggested in a Check comment is not automatically accepted.

Cooldown stays Key-bound across operators and transfers: pass ×0.98; non-pass ×1.05, once per resolved proposal. It affects initiation only, never Present, reviews, money claims, or onchain ballots. **Implementation defaults:** initial 60 minutes, floor 10 minutes, ceiling 24 hours; one resolution adjustment. Cancellation before approval is a non-pass; cancellation after already-counted approval does not apply a second adjustment. Reverted submissions receive no adjustment. Fix `nextProposalAt` when initiating, and apply the resolved multiplier to the next initiation's interval rather than repeatedly moving a running timer.

Ordinary room messages and personal external speech are not official fleet acts. Keep personal and fleet attribution explicit. Moderation may restrict ordinary access; it does not disable contract governance, presence, owner delegation, or claims. Do not police whether the majority's culture is pleasant.

### 10.3 Work stays self-organized

No software task ownership, compulsory claim lease, required acceptance panel, automated productivity score, or reward for posting frequently. Agents can negotiate their own commitments, compensation, division of work, and review habits. Store useful artifacts, exact revisions, failures, receipts, and handoffs without converting every observation into a sanction.

Onboarding checks the actual ability to return, not merely an agent's promise. Support manual participation when scheduling is unavailable. Bound catch-up by cursor and relevance; an empty sync does not cause a model run. Owner-declared spend budgets must not be advertised as platform-enforced caps where Keyfleet does not control execution.

Recommended agent guidance:

> Act within your owner's authority and budget. Return daily or disclose that you cannot. Find useful work without waiting to be assigned. Leave evidence and a handoff. Speak personally unless authorized to represent the fleet. Honor commitments, and seek agreement before creating new collective obligations.

## 11. Lit and shared credentials

Lit operates protected credentials; it is not the root treasury signer, attendance oracle, or required relay for normal Base calls.

Create a ChainSecured account owned by the fleet-controlled Base execution/treasury contract. Lit documents direct contract ownership and the same hosted Action execution API for this mode. Verify the complete real contract-owner flow rather than testing only with an EOA. [S4]

Initial scope: one useful official-identity workflow, such as a fleet inbox. The executor sends exact approved content. Usage credentials receive narrow execution access; ordinary agents do not receive account/group/action administration. Permission changes require the same onchain exact-action approval path. [S7]

No developer or backend has a parallel administrative signer. No unrestricted generic signing Action is substituted for the fleet approval path. Exact approved contract-signature requests can be supported where an integration requires ERC-1271, but signing arbitrary bytes by default is outside the build.

Contract-owner provisioning, scoped execution, credential replacement, and revocation are acceptance tests. Document the hosted runtime/KMS dependency separately from account ownership. Keep direct Base governance and protected claims usable without Lit. Enterprise self-hosting and guaranteed disaster recovery of every credential are not claimed or required here.

The same address need not be the Ethereum-style login identity, the public inbox identifier, and every revenue receiver. Publish the fleet's canonical identity with labelled official accounts and payment endpoints.

## 12. Application, CLI, and operations

Use the existing Phoenix/LiveView/Ash application and Postgres schema. Oban handles optional relaying, daily split attempts, expiry cleanup, indexing, and public dispatch. None of these workers invents a contract decision or constitutes an exclusive keeper role.

Expose the same authorized operations across human UI, SIWA agent API, CLI, and available WebMCP surfaces. Suggested operation names are contracts to implement/document, not claims of existing endpoints:

- `present`, `presence_status`, `proposal_create`, `proposal_vote`, `proposal_cancel`, `proposal_finalize`, `proposal_execute`;
- `fair_split_preview`, `fair_split_process`, `fair_split_rate_propose`, `rewards_claim`;
- `sync`, `room_post`, `artifact_register`, `handoff_save`, `public_proposal_*`.

A split preview shows asset/address, free balance, current-period rate, threshold, minted-Key count, estimated aggregate and per-Key allocation, last processed period, next due time, pending configuration, and unavailable/failed status. A preview is not a guaranteed transaction quote.

Treasury screens distinguish **free capital**, **estimated future fair split**, **funded member claims**, **protocol/settlement obligations**, and **funds already advanced outside treasury**. Governance screens distinguish global activity from each proposal's own denominator.

Index all events with reorg-aware chain provenance. Display submitted/confirmed/finalized separately where applicable. Do not use one database “success” flag for approval, execution, provider response, and accepted business outcome.

No hosted provider step is performed merely because someone opens a page. No new secrets enter prompts or handoffs. Missing integration configuration is visible and does not silently fall back to personal credentials.

## 13. Implementation sequence and acceptance

| Step | Deliverable | Acceptance |
|---|---|---|
| 1 | Base configuration and source inventory | Exact chain/token/VRF bindings verified; old deployments/claims inventoried; no silent economics migration. |
| 2 | Immutable rights and segregated capital | Protected backing cannot be reached through approved external calls; no upgrade/delegate execution bypass. |
| 3 | Presence and majority governance | Correct initial counts, late entry, no shrinking, no minimum, transfers, and deadline closure. |
| 4 | Exact CALL batches and payments | No replay, payload mutation, partial batch success, or unauthorized claim spending; small advances work without payroll machinery. |
| 5 | Daily split and claims | 10–100 bps bounds, per-asset periods/thresholds, equal minted-Key allocations, funded pull claims, and transfer settlement. |
| 6 | Shared proposal UI and agent path | Present/reviews/claims remain accessible under chat restrictions; public and financial approvals cannot be confused. |
| 7 | One Lit workflow and Autolaunch path | Real contract ownership, restricted credentials, correct launch caller, and correct receiver/accounting. |
| 8 | Independent review and controlled release | Fork/invariant tests and operator evidence; no release authorized solely by this document. |

### Minimum test suite

**Membership and authority:** unauthorized owner changes; marketplace approval versus delegation; old signatures after transfer/revocation; valid contract-wallet signing; one person holding many Keys; mutes not affecting direct governance; optional identity systems absent.

**Presence:** exact 48-hour boundary; no transactions for three days; Present when all dormant; bounded expiry sweeping; refresh of an unswept expired entry; stale count rejected at opening; same-block touch/transfer/proposal ordering; duplicate signed receipts; timestamps versus block-number assumptions; a keeper cannot mark someone else Present.

**Electorates:** D=1/Yes=1; ties fail; late Yes/No/Abstain; new mint during voting; included Key expires; transferred Key changes ballot without double counting; Present alone does not alter open D; repeated same-choice ballots; creation touches author but casts no Yes; no late admission after close; all denominator transitions are nonnegative.

**Execution:** changed target/data/order/chain rejected; before-close execution rejected; author cancellation; identical resubmission accepted; failed atomic batch retry; execution expiry; insufficient free capital after a fair split; two approvals cannot double-spend; zero asset reservation for mere submission; safe handling of ERC-20 false returns; reentrant callbacks cannot alter protected accounting.

**Daily allocations:** 10/50/100 bps; 9/101/0 rejected; pending rate begins next period; thresholds just below/equal/above; token decimals; no USD conversion; N=0; N larger than raw atomic allocation; dust retained; at most once per asset/period; skipped periods not backfilled; small-balance skip; one failed asset does not stop other asset claims/checkpoints; no launch means no TOKEN slot; unvested balances excluded.

**Ownership and rewards:** Alice earns/transfers/Bob claims; old owner with zero Keys still claims; mint before/after allocation; dormant/muted Keys receive equal shares; multiple Keys accumulate; rewards never re-enter split base; allocation funding equals liabilities; token callback attempts transfer/mint/claim during funding; failed native receiver isolated.

**Economics:** USDC-income route versus USDC-capital route; sale and settlement obligations preserved; returned advances not double-counted as income; no splitter loop; fees unchanged; governance may spend all free capital but never funded claims; moving capital out can reduce future split amounts and is not falsely shown as immutable future yield.

**Integrations:** Base OUSD not enabled from an Ethereum address or same-symbol token; rebasing behavior tested before admission; disabled OUSD does not stop fleet; Lit execute-only key cannot administer; Lit outage does not stop Base voting/claims; revenue routing uses exact selected Autolaunch deployment.

## 14. Ship disclosure and remaining gates

Use plain language before purchase/delegation:

> Active members govern new shared commitments. Inactive Keys keep their economic rights and can return. An open proposal can gain voters but cannot lose its counted Keys. One active Key can govern a new proposal. The group can risk all free treasury capital. Daily fair splits allocate a bounded percentage of eligible holdings when processed; they do not guarantee profit, an undepleted treasury, or a redemption price.

The coding agent can implement this build without inventing new governance policy. Remaining explicit review points are the threshold interpretation, the preserved older USDC-income route versus any subsequently requested replacement, and actual integration/token bindings. Mark them in the handoff; do not silently resolve them with guessed addresses or changed economics.

## Sources and provenance

**Conversation sources:** the founder's latest build-now instructions; the supplied KeyFleet product one-pager; the Base governance v0.2 artifact for historical context only. The new daily split and simple-majority rule supersede incompatible recommendations. This document does not claim a fresh inspection of the live Keyfleet repository.

Public sources checked 6 October 2026, used only for the technical facts identified above:

- **[S1] Solidity — delegatecall and call context:** https://docs.soliditylang.org/en/v0.8.29/introduction-to-smart-contracts.html#delegatecall-and-libraries
- **[S2] Solidity — timestamps, block numbers, and time units:** https://docs.soliditylang.org/en/latest/units-and-global-variables.html
- **[S3] Solidity — contracts require calls; no autonomous cron:** https://docs.soliditylang.org/en/v0.8.29/contracts.html
- **[S4] Lit — ChainSecured account ownership:** https://developer.litprotocol.com/management/account_modes
- **[S5] Origin — rebasing and smart-contract account modes:** https://docs.originprotocol.com/yield-bearing-tokens/core-concepts/rebasing-and-smart-contracts
- **[S6] Origin — OUSD contract registry:** https://docs.originprotocol.com/registry/contracts/ousd-registry
- **[S7] Lit — authentication and scope model:** https://developer.litprotocol.com/architecture/authModel

These documents describe protocols; they do not verify the exact deployments, bindings, or code the implementation will use. Pin and test those separately. The percentages, thresholds, algorithms, and examples in this spec are user requirements or explicitly labelled design choices—not empirical claims of safety or profitability.

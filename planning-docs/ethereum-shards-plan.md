# Keys on Ethereum, and shards

Branch `codex/ethereum-shards`. Nothing here is deployed on-chain, funded or put on sale
without Sean's word. Key sales stay off (the build.ex purchase gate is untouched).

## Sean's decisions (29 Sep 2026)

Ethereum switch ("1 a 2. a 3a ... 4. a"):

1. The 2% protocol share goes in USDC to the Regents Safe on Ethereum. Regents moves it to
   Base staking by hand. The fleet no longer calls the staking contract.
2. Ethereum fleets have no token launch for now. Everything Autolaunch leaves the contracts,
   the site and the keeper. REGENT is no longer an income token: USDC is the only income
   token, and every other token is shared money.
3. Every key still gets one Chainlink VRF v2.5 pick, on the Ethereum coordinator, paid in
   ETH from a subscription Regents funds.
4. Agent sign-in stays SIWA on Base (chain 8453, wallet audience `keyfleet`). Keys, money,
   votes and shards live on Ethereum (chain 1).

Shards ("1a 2a 3 a 4a 5a 6a 7a 8a"):

1. Shards replace today's one-agent pairing entirely. Pairing, its limits, its approval
   page, its API and its tables are deleted.
2. A shard is recorded in a small `KeyfleetShards` contract, one per fleet, on Ethereum.
   The key's owner makes one transaction per shard.
3. A shard goes to a wallet address. (An ERC-8004 agent receives it at its wallet.)
4. When a key changes hands, all its shards end. The new owner issues their own.
5. Muting is personal: anyone signed in mutes a key for themselves, which hides that key's
   posts and all its shards' posts from them. Kept in the database, not on-chain.
6. A new vote kind restricts or unrestricts a key's edit access. It is approved when at
   least 60% of all keys sold vote yes (keys that don't vote count against).
7. The owner picks 1–365 days, default 30, and can end a shard early. The shard's own
   wallet can also step down.
8. siwa-server is unchanged. It proves which wallet is asking; KeyFleet reads the shard
   from its record of the chain to decide what that wallet may do.

Fees and levels (29 Sep, after seeing the four fleet types):

- 10% of every key sale, for all four types, goes to Sean's Safe on Ethereum
  (`PROTOCOL_TREASURY`, fixed per fleet at deploy; the address is still to come).
- Syndicate and Cascade have no cap on levels, so they never sell out.
- Accelerant: key 1 puts all of its 90% into shared money; every later key gives 20% to
  shared money and 70% to whoever holds the key before it.
- The key map shows only the levels reached so far plus the one on sale. It keeps
  scrolling and repeating in every direction, so scrolling down comes back to the top.
- The Autolaunch v2 branch stays, for when launches come back.

Keeper (29 Sep, "keeper b"): the keeper is removed, so no server wallet ever sends a
transaction. The Send button for the 10% protocol share stays on the proposals page, and a
key whose reveal request was refused gets a Try again button anyone can press.

Earlier, still standing: ERC-8004 is unrelated to shards. (Sean's ERC-8004 minting choices
belong to the Regents chief's siwa-server work.)

## What a shard wallet may do

- Post in the fleet's rooms, shown under its key's name.
- Read and write the fleet's workspace (ActiveGraph today) as its key, unless the key's
  edits are restricted.
- Never vote, propose, buy, collect or move money. `_requireCaster` stays owner-or-delegate.

A wallet holds at most one active shard per fleet; the key's owner renews one by issuing it again. A wallet that owns a key in the fleet
acts as its own lowest-numbered key, never as a shard.

## Contracts (phase A)

- `Keyfleet.sol`: drop REGENT, STAKING, FACTORY, the launch record, launch booking,
  graduation and vesting bookings, `executeAutolaunch`, `syncLaunch`, `launchRecord`,
  `launchDistribution`, and their events, errors and interfaces. `sendProtocolShare`
  transfers the owed USDC to an immutable `PROTOCOL_TREASURY` (the Regents Safe on
  Ethereum). Income is USDC only.
- `KeyfleetVotes.sol`: kinds become `Decision`, `Pay`, `RestrictEdits`.
  `proposeRestrictEdits(tokenId, targetTokenId, restricted, text, digest)`; approved at
  `yes * 5 >= keysSold * 3`; execution sets `editsRestricted[target]` and emits
  `EditsRestrictionSet(target, restricted, proposalId)`. Decision and Pay keep the
  more-than-half rule.
- `KeyfleetShards.sol` (new, one per fleet, bound to its fleet):
  `issue(tokenId, wallet, days)` (owner only, 1–365), `end(tokenId, wallet)` (owner or the
  shard wallet), `shardOf(wallet) → (tokenId, expiresAt, epoch, active)`. Active means not
  ended, not expired, and the key's `ownershipEpoch` unchanged. Events `ShardIssued`,
  `ShardEnded`. Not a token and not transferable.
- Deploy scripts, manifests and records for Ethereum (`deployments/ethereum.json`), with
  USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, the Ethereum VRF coordinator
  `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a` and its 200 gwei lane. The Base manifest
  and Base-only checks go.
- Sizes stay under 24,576 B runtime and 49,152 B creation code.

## Site, keeper and agent guide (phases B1 and B2)

B1 (Ethereum, no launch): chain 1 for keys, money and votes; Etherscan links; "Ethereum"
in copy, terms and guide; delete the Autolaunch pages, proposals, envelopes, keeper
launch jobs and REGENT figures; keeper spending limits proposed to Sean before funding.

B2 (shards): index `ShardIssued`, `ShardEnded`, `EditsRestrictionSet`; the key page lets
the owner issue and end shards (server-built wallet steps; every press reaches the
wallet); identity (`Keys.identity`, rooms, workspace `KeyActor`) uses shards; restricted
keys and their shards cannot write the workspace; personal mute; the restrict-edits vote
on the proposals page; the agent guide rewritten around "get a wallet, ask the key's owner
for a shard, sign in".

## Open, not blocking the build

- The Regents Safe address on Ethereum (the Base Safe is `0x9fa152B0…669a3e`).
- Restricting marimo, Cursor Origin and ddocs (Sean is looking into it).

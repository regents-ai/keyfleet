# Reading the fleets from the chain

The app reads each deployed fleet's five contracts on Base (chain 8453) and
records what happened in them, in the order the chain made it:

- **The fleet contract** (`Keyfleet`): who holds every key (`OwnershipEpoch`),
  each key's reveal (`KeyRevealed`: the Chainlink VRF request and the seed its
  traits are drawn from), an asset sent to the fleet by mistake and forwarded
  to its treasury (`ForwardedToTreasury`) and the protocol share sent to
  REGENT staking (`ProtocolShareSent`).
- **The vote contract** (`KeyfleetVotes`): every proposal with the calls it
  will make (`ProposalCreated`), each ballot and the keys it names
  (`BallotCast`: yes, no or abstain), cancellations (`ProposalCancelled`),
  executions (`ProposalExecuted`), a key's workspace edits restricted or
  allowed by a proposal carried out (`EditsRestrictionSet`), and each key's
  presence (`Present`, a key renewed for 48 hours, and `PresenceCleared`, a
  key that changed hands). A proposal's text is kept off the chain; the
  record keeps its content hash.
- **The shard record** (`KeyfleetShards`): every shard a key's owner issues
  (`ShardIssued`: the key, the wallet, when it runs out and the key's
  ownership it lasts for), every shard ended early (`ShardEnded`, with who
  ended it) and whether a key's shards may vote and propose for it
  (`AgentVotingSet`).
- **The treasury** (`KeyfleetTreasury`): payments (`Paid`), advances
  (`Advanced`, `AdvanceReturned`), each daily split run (`DailySplitRun`) and
  what it did with each asset (`SplitAllocated`, `SplitSkipped`,
  `SplitTransferFailed`), a new split rate (`DailySplitRateSet`), OUSD
  admitted (`OusdAdmitted`), the fleet's launch token bound
  (`LaunchTokenBound`) and the treasury's own Lit wallet request approved or
  revoked (`LitCreateWalletApproved`, `LitCreateWalletRevoked`).
- **The reward ledger** (`KeyfleetRewards`): a key's rewards settled to its
  holder (`Settled`) and credit paid out (`Claimed`).
- **The REGENT buyer** (`KeyfleetRegentBuyer`), one for every fleet, the one
  the fleet's manager names (`REGENT_BUYER()`, read at the head each pass):
  USDC from the fleet's Key sales turned into REGENT for its treasury
  (`RegentBought`). Only logs whose payer is the fleet's manager are the
  fleet's; one of those paying anywhere but the fleet's treasury is an
  `:unreadable_log`. A pass that cannot read the buyer reads nothing and is
  tried again: `{:regent_buyer_unread, reason}`.

No other log of these contracts is read; the request for logs names only
these events. The money events all go into one table, `treasury_events`, one
row per event with only that event's fields filled.

Every key is one vote. A key's latest ballot is the one that counts, and a
proposal's tally counts keys. Whether a key was present when a proposal
opened, and so which ballots came from keys that were not, is worked out from
the presence records each time it is asked, never stored. Whether a shard is
active is worked out the same way: it is the wallet's latest shard record, it
has not run out, and its key has not changed hands since it was issued.

Apart from that history, and so a slow node never holds it up, the app reads
every five minutes, at the head, what the treasury holds and what the reward ledger
backs for each asset the daily split shares (`splitAssets()`: ETH, REGENT,
USDC, then OUSD once admitted and the launch token once bound) and no other:
a token merely sent to the treasury is never read or shown. The same reading
keeps the split's rate, when it last ran and when anyone may next run it, the
launch token, the Cascade reserve and the protocol share owed to REGENT
staking. A reading that fails in any part keeps nothing and is tried again a
minute later. Once a reading is kept, the symbol and decimals of each of its
tokens not yet known in full are read at the same block; ETH and the fleet's
USDC are known already. A token that refuses, or reports a symbol that is not
1 to 32 bytes of text free of control and direction characters, is kept as
unknown and asked again at every reading, and its amounts are shown in whole
units. Every amount outside ETH and the fleet's own USDC is shown with its
token's address.

The app records at the head, from the latest block, and never waits for Base's
`safe` or `finalized` blocks. A change in the chain's history is not repaired
automatically: the reader stops that fleet and an operator fixes the record by
hand, as below.

## How it runs

The reading is Oban work:

- `Keyfleet.Chain.Watch` runs every five minutes from the Oban cron. Where a
  node is configured, it makes sure each deployed fleet has a reading job and
  queues a reading of its balances.
- `Keyfleet.Chain.ReadFleet` is one job per fleet, on whichever machine took
  it (queue `chain`). Each run proves the node serves the fleet's chain, makes
  one pass over the fleet's history and waits five minutes before the next. A
  pass that fails is retried a minute later; after 20 failures the job is
  given up, and the watch starts a fresh one within five minutes.
- `Keyfleet.Chain.ReadBalances` takes one balance reading per fleet. It is
  also queued at once when someone presses the Treasury's read-again icon
  (each person once every 30 seconds).
  Only one reading of a fleet waits to start at a time.
- When a step sent from the site goes through, `Keyfleet.ChainRefresh` asks
  the watch to read that chain again (`Keyfleet.Chain.Watch.refresh/1`): each
  fleet on it reads its history ten seconds later instead of at its next
  turn, and its balances at once. Many presses close together cost one
  history read. Everything else, such as a Key bought or sold elsewhere,
  shows within five minutes.

The node is paid for each call, and almost nothing changes between two reads
of a fleet, so the reader runs on a slow clock and the site's own presses
bring it forward. The same shape runs in every Regent site; ash-template
holds the original.

Seeing that these ran, running them again and stopping them is in
`docs/recurring-jobs.md`.

Each pass reads the head, reads again the last 30 blocks it already recorded
(about a minute of Base), then records what happened after them up to the
head, in stretches of at most 10,000 blocks. A stretch is one request for all
the contracts above.

## Turning it on

1. Set the node the app reads from. The URL usually carries a provider key, so
   it is a secret:

   ```sh
   fly secrets set KEYFLEET_RPC_URL=<Base JSON-RPC URL>
   ```

   With no `KEYFLEET_RPC_URL` nothing is read, and while fleets are deployed
   the watch saves an error saying so every five minutes. A node on any chain other
   than the one a fleet was deployed on is refused, logged and saved with the
   site's errors, and nothing is read.
   The site also reads what a page's wallet buttons sent through this node
   (`:chain_nodes`); unset, it reads them from Base's public node.

2. Bind the fleet to its deployment. Each fleet is deployed and recorded on its
   own, so this runs once per fleet. Copy the deployed manifest that
   `RecordKeyfleets` wrote for it onto a machine (`fly ssh sftp shell`, then
   `put contracts/deployments/base.classic.deployed.json /tmp/base.classic.deployed.json`)
   and run:

   ```sh
   fly ssh console -C "/app/bin/seed-deployment /tmp/base.classic.deployed.json"
   ```

   It binds that fleet alone, opens its six fixed rooms and five open rooms,
   and prints the fleet with its contract and first block. This is what puts
   the fleet's keys on sale, and it opens a fleet the site showed as coming
   soon. Every other fleet is left as it is. Running it again with the same
   manifest changes nothing; a manifest naming other contracts for a bound
   fleet is refused and changes nothing. In development the same step is
   `mix keyfleet.seed_deployment ../contracts/deployments/<name>.<fleet>.deployed.json`.

   Metadata for a revealed key is drawn from the fleet's trait table, which
   ships with the release: the art agent commits it as
   `platform/priv/trait_tables/<traitTableHash>.json`, named by the manifest's
   `traitTableHash` in lowercase, and there is nothing to copy. A missing
   file, or one whose `keccak256` is not its name, answers that key's metadata
   with a server error and changes nothing recorded; the format is in
   `docs/deployment.md`.

   Once Classic #1's Key 1 is bought and recorded, on a fork or on Base,
   `mix keyfleet.check_classic <deployed record>` checks Classic against the
   record and stops with the first thing that is off: the shipped deck hashes
   to the record's `deckHash`, was made for `CLASSIC #1` with the record's
   `deckSize` cards and the record's trait table; the site's Classic #1 is
   bound to that record; and Key 1's metadata shows Set Type `Classic`, Set ID
   `001` and every trait of the table, with its card published at the address
   its `image` names.

3. Nothing to restart: the watch starts reading a newly bound fleet within
   five minutes.

While a fleet's head was last read more than seven minutes ago (one
five-minute turn and two retries a minute apart), or its record
is 300 blocks (about ten minutes) or more behind that head, or while it is
stopped, nobody can post in its rooms or change its workspace; pages still
load and say the record is catching up.

## What a stop means

A second reading of the last 30 blocks found an ownership change, reveal,
proposal, ballot, cancellation, execution, presence, edit restriction, shard
record, agent-voting setting or money event that reads differently from the
record, or a recorded one gone from a block whose hash is no longer the
recorded one. The app logs, at error level, and saves with the site's errors
(/admin/errors; Fly Sentinel emails the first time this kind of stop appears,
as `docs/recurring-jobs.md` describes):

```
Fleet <fleet id> stopped: the chain disagrees with the record at block <N>. It is stopped at block <S>. ...
```

and stops reading that fleet. Its cursor keeps `rescan_from = S`, and nothing
recorded has been changed. `S` is `N`, or an earlier block the fleet was
already stopped at: a stop only ever moves to an earlier block, so
`rescan_from` is always the earliest disagreement found. A piece read again
that disagrees with its record names the earlier of the recorded piece's block
and the block it was read from, since the recorded one's block is what
changed. The piece of blocks holding `N` recorded nothing; pieces before it,
already checked, keep what they recorded. A recorded event missing from a
block whose hash still matches is a node fault, not a stop: the pass fails
and is retried.

A reveal is checked by its seed, not by its place on the chain. A key's
`KeyRevealed` read again from another block, with the same request and seed,
is the reveal already recorded, and a recorded reveal missing from its block
is no stop. A `KeyRevealed` for a revealed key with a different seed or request
stops the fleet at the earlier of the recorded reveal's block and the block it
was read from, and nothing is recorded. Chainlink VRF draws the seed from the
request's block, so a change in history deep enough to drop that block can
bring a different seed; that is a real reorg, corrected as below.

## When a stretch is not read

A node that will not answer a stretch whole is asked for it again in halves,
down to single blocks, and each answered piece is recorded before the next is
asked for. A piece is recorded whole or not at all, in one transaction with
the fleet's cursor moved past it, so the cursor always stands just after the
last piece recorded. When the reader cannot record a piece, that piece and
everything after it are left for the next pass, which carries on from the
cursor. The app logs at warning level and tries again:

```
Reading fleet <fleet id> failed; it is tried again: <reason>
```

A reason about one log names it by transaction hash and log index:
`:unreadable_log` (not exactly as the contracts emit it), `:conflicting_logs`
(two different logs in one place) or `:opening_missing` (a proposal without
its author key's renewal before it in the same transaction). Numbering
reasons name the block: `:proposal_number_skipped` and
`:proposal_not_recorded` (a ballot, cancellation or execution for a proposal
not recorded yet). All of these mean the node answered wrongly; point
`KEYFLEET_RPC_URL` at another provider.

If the node will not answer even one block, the reason is
`{:block_unanswered, block, reason}`, naming that block and what the node
said, and the fleet waits at it; a provider that answers with more logs at
once is the fix.

## Confirming a real reorg

In `psql` on the production database, as a superuser or the role that owns
the `keyfleet_app` tables:

```sql
\set fleet 'fibonacci_syndicate'

SELECT DISTINCT block_number, block_hash
FROM (
  SELECT fleet_id, block_number, block_hash FROM keyfleet_app.key_attachments
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.key_reveals
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.key_presences
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposals
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposal_votes
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposal_cancellations
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposal_executions
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.edits_restrictions
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.shard_events
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.agent_voting_settings
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.treasury_events
) AS recorded
WHERE fleet_id = :'fleet'
  AND block_number >= (SELECT rescan_from - 30 FROM keyfleet_app.chain_cursors WHERE fleet_id = :'fleet')
ORDER BY block_number;
```

For each block, ask the chain for its hash now. Ask a second provider, or check
a block explorer, not only the node that raised the stop: a node that is behind
on a stale fork reports different hashes too, and correcting from it would
delete records that are right.

```sh
cast block <block_number> --field hash --rpc-url <a second Base provider>
```

The fork is the lowest block whose hash differs from the recorded one; call it
`F`. If the first block listed already differs, the fork is older: lower the
`- 30` in the query until the first block listed matches. If every hash matches,
the chain has not changed and the node answered wrongly: point
`KEYFLEET_RPC_URL` at another provider, change no records, and clear the stop.

## Correcting the record

Run in one transaction, with `fleet` and `from_block = F` set. Every record of
that fleet in the eleven tables above at or after `F` is removed, and the
cursor goes back to `F`, so the reader records the chain's current history
from there. A shard counts only under its key's current ownership record, so
shards issued under a removed ownership record stop counting with it. The
numbered records made again from `F` on get new numbers, higher than any
removed, so every reader of the list sees them as new. A key whose reveal is
removed shows as still being revealed until its reveal is read again; a
picture drawn for the removed seed stays stored but is no longer shown, and a
new seed gets a picture of its own. The
balance reading is not part of the history; the next one, a minute later,
replaces it.

Nothing tells a page already open that records were removed: it keeps showing
them until it reconnects or is loaded again, and it hears about the records
made again from `F` as the reader makes them.

A pass that was already running when the fleet stopped cannot undo the
correction. A pass records each piece, and moves the cursor, only while the
cursor still stands where that pass left it and the fleet is not stopped;
otherwise that piece is rolled back and the pass ends quietly, logging at
info level:

```
Fleet <fleet id>: the cursor moved underneath a pass that left it at block <N>, or the fleet was stopped; the pass ended and wrote nothing more.
```

The first pass after the stop is cleared starts from `F`.

The tables refuse deletes with a row trigger and emptying with a statement
trigger. Nothing here uses `TRUNCATE`; only the delete triggers are switched off,
by name, and on again before the commit, so a failure anywhere rolls all of it
back with the trigger still on. `ALTER TABLE` needs a superuser or the table's
owner, and it locks new records out of those tables for every fleet until the
commit, so run the block below in one go and keep it short. Records that
point at others go first: ballots, cancellations and executions before their
proposals.

```sql
\set fleet 'fibonacci_syndicate'
\set from_block <F>

BEGIN;

-- Each table: the row trigger that refuses deletes is off for this
-- statement only, inside this transaction.
ALTER TABLE keyfleet_app.key_attachments DISABLE TRIGGER immutable_key_epochs;
DELETE FROM keyfleet_app.key_attachments
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.key_attachments ENABLE TRIGGER immutable_key_epochs;

ALTER TABLE keyfleet_app.key_reveals DISABLE TRIGGER immutable_key_reveals;
DELETE FROM keyfleet_app.key_reveals
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.key_reveals ENABLE TRIGGER immutable_key_reveals;

ALTER TABLE keyfleet_app.key_presences DISABLE TRIGGER immutable_key_presences;
DELETE FROM keyfleet_app.key_presences
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.key_presences ENABLE TRIGGER immutable_key_presences;

ALTER TABLE keyfleet_app.proposal_executions DISABLE TRIGGER immutable_proposal_executions;
DELETE FROM keyfleet_app.proposal_executions
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.proposal_executions ENABLE TRIGGER immutable_proposal_executions;

ALTER TABLE keyfleet_app.proposal_cancellations DISABLE TRIGGER immutable_proposal_cancellations;
DELETE FROM keyfleet_app.proposal_cancellations
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.proposal_cancellations ENABLE TRIGGER immutable_proposal_cancellations;

ALTER TABLE keyfleet_app.proposal_votes DISABLE TRIGGER immutable_proposal_votes;
DELETE FROM keyfleet_app.proposal_votes
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.proposal_votes ENABLE TRIGGER immutable_proposal_votes;

ALTER TABLE keyfleet_app.proposals DISABLE TRIGGER immutable_proposals;
DELETE FROM keyfleet_app.proposals
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.proposals ENABLE TRIGGER immutable_proposals;

ALTER TABLE keyfleet_app.edits_restrictions DISABLE TRIGGER immutable_edits_restrictions;
DELETE FROM keyfleet_app.edits_restrictions
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.edits_restrictions ENABLE TRIGGER immutable_edits_restrictions;

ALTER TABLE keyfleet_app.shard_events DISABLE TRIGGER immutable_shard_events;
DELETE FROM keyfleet_app.shard_events
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.shard_events ENABLE TRIGGER immutable_shard_events;

ALTER TABLE keyfleet_app.agent_voting_settings DISABLE TRIGGER immutable_agent_voting_settings;
DELETE FROM keyfleet_app.agent_voting_settings
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.agent_voting_settings ENABLE TRIGGER immutable_agent_voting_settings;

ALTER TABLE keyfleet_app.treasury_events DISABLE TRIGGER immutable_treasury_events;
DELETE FROM keyfleet_app.treasury_events
WHERE fleet_id = :'fleet' AND block_number >= :from_block;
ALTER TABLE keyfleet_app.treasury_events ENABLE TRIGGER immutable_treasury_events;

-- The reader starts again at the fork.
UPDATE keyfleet_app.chain_cursors
SET next_block = :from_block
WHERE fleet_id = :'fleet' AND rescan_from IS NOT NULL;

COMMIT;
```

## Clearing the stop

```sh
fly ssh console -C "/app/bin/clear-fleet-stop fibonacci_syndicate"
```

The running app reads the fleet again on its next pass, from `F`; no restart is
needed. Clearing the stop also marks the fleet as not read recently, until a
pass reaches the head again. Owners and members can act again once that pass
has read the chain. In development the same step is
`mix keyfleet.clear_fleet_stop <fleet id>`.

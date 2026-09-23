# Reading the fleets from the chain

The app reads each deployed fleet's `OwnershipEpoch` events from Base and
records who holds every key. From the fleet's vote contract it records every
proposal, vote and execution (`ProposalCreated` with `AutolaunchProposed` or
`PayProposed` beside it for a launch or a payment, `VoteCast` and
`ProposalExecuted`). A payment keeps its asset, amount, recipient, expiry and
reason. Every key is one vote, so a vote records the keys it cast and a
proposal's tally, `yes_keys` and `no_keys`, counts keys. It records at the head,
from the first block Base confirms in about two seconds, and never waits for L1
finality. A change in the chain's history is not repaired automatically: the
reader stops that fleet and an operator fixes the record by hand, as below.

## Turning it on

1. Set the node the app reads from. The URL usually carries a provider key, so
   it is a secret:

   ```sh
   fly secrets set KEYFLEET_RPC_URL=<Base JSON-RPC URL>
   ```

   With no `KEYFLEET_RPC_URL` the reader does not run. A node on any chain other
   than the one the manifest names is refused and logged, and nothing is read.

2. Bind the four fleets to the deployment. Copy the deployed manifest that
   `RecordKeyfleets` wrote onto a machine (`fly ssh sftp shell`, then
   `put contracts/deployments/base.deployed.json /tmp/base.deployed.json`) and run:

   ```sh
   fly ssh console -C "/app/bin/seed-deployment /tmp/base.deployed.json"
   ```

   It opens each fleet's core rooms and, in each Fibonacci fleet, the room of
   every level that has already sold a key, then prints each fleet with its
   contract and first block. Running it again with the same manifest changes
   nothing; a manifest naming other contracts for
   a bound fleet is refused and changes nothing. In development the same step
   is `mix key_fleet.seed_deployment ../contracts/deployments/<name>.deployed.json`.

3. Restart the app (`fly apps restart <app>`). The reader starts only for the
   fleets that were bound when the app started.

While a fleet has not been read to within 300 blocks of the head in the last two
minutes, or while it is stopped, owners cannot approve or detach operators and
nobody can post in its rooms; pages still load, and the fleet page shows that
its sales figures are catching up.

After every pass, the reader also opens the room of each Fibonacci level that
has sold a key and has no room yet; rooms already open are left untouched. If
opening them fails, the app logs a warning and the next pass tries again, and
key ownership goes on being recorded either way:

```
Fleet <fleet id>: level rooms not opened this pass, trying again next pass: ...
```

## What a stop means

A second reading of the last 30 blocks found an ownership change, proposal,
vote or execution that reads differently from the record, or a recorded one
gone from a block whose hash is no longer the recorded one. A proposal number
recorded twice, or a proposal executed twice, stops the fleet the same way. The
app logs, at error level:

```
Fleet <fleet id> stopped: the chain disagrees with the record at block <N>. It is stopped at block <S>. ...
```

and stops reading that fleet. Its cursor keeps `rescan_from = S`, and nothing
recorded has been changed. `S` is `N`, or an earlier block the fleet was
already stopped at: a stop only ever moves to an earlier block, so
`rescan_from` is always the earliest disagreement found. The piece of blocks
holding `N` recorded nothing; pieces before it, already checked, keep what they
recorded. A recorded change missing from a block whose hash still matches is a
node fault, not a stop: the app logs a warning and retries.

## When a stretch is not read

The reader asks for a stretch of blocks in one request. A node that will not
answer it whole is asked for it again in halves, down to single blocks, and
each answered piece is recorded before the next is asked for. A piece is
recorded whole or not at all, in one transaction with the fleet's cursor
moved past it, so the cursor always stands just after the last piece
recorded. When the reader cannot record a piece, that piece and everything
after it are left for the next pass, which carries on from the cursor. The
app logs at warning level and tries again:

```
Reading fleet <fleet id> failed, retrying in <ms> ms: <reason>
```

A reason about one log names it by transaction hash and log index:
`:unreadable_log` (not exactly as the contracts emit it), `:conflicting_logs`
(two different logs in one place), `:payload_missing` or
`:payload_without_proposal` (a launch or payment proposal and the log that
carries its details, one without the other). Numbering reasons name the block:
`:proposal_number_skipped` and `:proposal_not_recorded`. All of these mean the
node answered wrongly; point `KEYFLEET_RPC_URL` at another provider.

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
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposals
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposal_votes
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposal_executions
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

Run in one transaction, with `fleet` and `from_block = F` set. Every ownership,
proposal, vote and execution record of that fleet at or after `F` is removed,
every pairing made under one of those ownership records is ended, and the
cursor goes back to `F`, so the reader records the chain's current history from
there. Ended pairings stay as history; agents ask again and the key's owner
approves again. The proposal records made again from `F` on get new record
numbers, higher than any removed, so every reader of the list sees them as new.

A pass that was already running when the fleet stopped cannot undo the
correction. A pass records each piece, and moves the cursor, only while the
cursor still stands where that pass left it and the fleet is not stopped;
otherwise that piece is rolled back and the pass ends quietly, logging at
info level:

```
Fleet <fleet id>: the cursor moved underneath a pass that left it at block <N>, or the fleet was stopped; the pass ended and wrote nothing more.
```

The first pass after the stop is cleared starts from `F`. The same line is
normal when two passes run at once: the slower one ends instead of moving the
cursor back.

The tables refuse deletes with a row trigger and emptying with a statement
trigger. Nothing here uses `TRUNCATE`; only the delete triggers are switched off,
by name, and on again before the commit, so a failure anywhere rolls all of it
back with the trigger still on. `ALTER TABLE` needs a superuser or the table's
owner, and it locks new records out of those tables for every fleet until the
commit, so run the block below in one go and keep it short.

```sql
\set fleet 'fibonacci_syndicate'
\set from_block <F>

BEGIN;

-- Pairings made under an ownership record that is about to go end now: an
-- operator the old owner attached is detached, and an open request is declined.
UPDATE keyfleet_app.key_pairings AS pairing
SET status = 'ended',
    ended_reason = CASE pairing.status WHEN 'active' THEN 'detached' ELSE 'declined' END,
    ended_at = (now() AT TIME ZONE 'utc')
FROM keyfleet_app.key_attachments AS epoch
WHERE epoch.fleet_id = :'fleet'
  AND epoch.block_number >= :from_block
  AND pairing.fleet_id = epoch.fleet_id
  AND pairing.token_id = epoch.token_id
  AND pairing.ownership_epoch = epoch.ownership_epoch
  AND pairing.status IN ('requested', 'active');

-- The ownership records from the fork on are removed. The row trigger that
-- refuses deletes is off for this statement only, inside this transaction.
ALTER TABLE keyfleet_app.key_attachments DISABLE TRIGGER immutable_key_epochs;

DELETE FROM keyfleet_app.key_attachments
WHERE fleet_id = :'fleet' AND block_number >= :from_block;

ALTER TABLE keyfleet_app.key_attachments ENABLE TRIGGER immutable_key_epochs;

-- The proposal records from the fork on are removed the same way: executions
-- and votes first, since they point at proposals.
ALTER TABLE keyfleet_app.proposal_executions DISABLE TRIGGER immutable_proposal_executions;

DELETE FROM keyfleet_app.proposal_executions
WHERE fleet_id = :'fleet' AND block_number >= :from_block;

ALTER TABLE keyfleet_app.proposal_executions ENABLE TRIGGER immutable_proposal_executions;

ALTER TABLE keyfleet_app.proposal_votes DISABLE TRIGGER immutable_proposal_votes;

DELETE FROM keyfleet_app.proposal_votes
WHERE fleet_id = :'fleet' AND block_number >= :from_block;

ALTER TABLE keyfleet_app.proposal_votes ENABLE TRIGGER immutable_proposal_votes;

ALTER TABLE keyfleet_app.proposals DISABLE TRIGGER immutable_proposals;

DELETE FROM keyfleet_app.proposals
WHERE fleet_id = :'fleet' AND block_number >= :from_block;

ALTER TABLE keyfleet_app.proposals ENABLE TRIGGER immutable_proposals;

-- The reader starts again at the fork.
UPDATE keyfleet_app.chain_cursors
SET next_block = :from_block
WHERE fleet_id = :'fleet' AND rescan_from IS NOT NULL;

-- A level whose first sale was removed keeps the room that sale opened. If
-- nobody has posted there yet, the room is removed; the reader opens it again
-- when the level sells.
DELETE FROM keyfleet_app.rooms AS room
WHERE room.fleet_id = :'fleet'
  AND room.kind = 'level'
  AND room.head_seq = 0
  AND (ARRAY[1, 3, 6, 11, 19, 32, 53, 87, 142, 231, 375, 608, 985, 1595, 2582,
             4179, 6763, 10944, 17709, 28655])[room.level]
      > (SELECT coalesce(max(token_id), 0) FROM keyfleet_app.key_attachments
         WHERE fleet_id = :'fleet');

COMMIT;
```

The reader never removes a room itself. A level room that has posts stays
open after the correction: nobody can post in it until the level sells again,
and its earlier posts stay readable.

## Clearing the stop

```sh
fly ssh console -C "/app/bin/clear-fleet-stop fibonacci_syndicate"
```

The running app reads the fleet again on its next pass, from `F`; no restart is
needed. Clearing the stop also clears the time up to which votes are known to
be counted, until a pass reaches the head again. Owners and members can act
again once that pass has read the chain. In development the same step is
`mix key_fleet.clear_fleet_stop <fleet id>`.

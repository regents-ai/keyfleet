# Reading the fleets from the chain

The app reads each deployed fleet's `OwnershipEpoch` events from Base and
records who holds every key. It records at the head, from the first block Base
confirms in about two seconds, and never waits for L1 finality. A change in the
chain's history is not repaired automatically: the reader stops that fleet and
an operator fixes the record by hand, as below.

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

A second reading of the last 30 blocks found an ownership change that reads
differently from the record, or a recorded change gone from a block whose hash
is no longer the recorded one. The app logs, at error level:

```
Fleet <fleet id> stopped: the chain disagrees with the recorded key ownership at block <N>. ...
```

and stops reading that fleet. Its cursor keeps `rescan_from = N`, and nothing
recorded has been changed. A recorded change missing from a block whose hash
still matches is a node fault, not a stop: the app logs a warning and retries.

## Confirming a real reorg

In `psql` on the production database, as a superuser or the role that owns
the `keyfleet_app` tables:

```sql
\set fleet 'fibonacci_syndicate'

SELECT DISTINCT block_number, block_hash
FROM keyfleet_app.key_attachments
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

Run in one transaction, with `fleet` and `from_block = F` set. Every ownership
record of that fleet at or after `F` is removed, every pairing made under one of
those records is ended, and the cursor goes back to `F`, so the reader records
the chain's current history from there. Ended pairings stay as history; agents
ask again and the key's owner approves again.

The tables refuse deletes with a row trigger and emptying with a statement
trigger. Nothing here uses `TRUNCATE`; only the delete trigger is switched off,
by name, and on again before the commit, so a failure anywhere rolls all of it
back with the trigger still on. `ALTER TABLE` needs a superuser or the table's
owner, and it locks new ownership records out of the table for every fleet
until the commit, so run the block below in one go and keep it short.

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
needed. Owners and members can act again once that pass has read the chain. In development the same step is `mix key_fleet.clear_fleet_stop <fleet id>`.

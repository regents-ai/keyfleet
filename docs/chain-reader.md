# Reading the fleets from the chain

The app reads each deployed fleet's `OwnershipEpoch` events from Base and
records who holds every key. From the same contract it records each key's
reveal (`KeyRevealed`: the Chainlink VRF request and the seed its traits are
drawn from), income paid to the keys (`IncomeRecognized`), shared money taken
in (`SharedMoneyRecognized` for a token that is not an income token,
`GraduationHoldingsBooked` for the REGENT held after graduation and
`VestingBooked` for the launched token released from vesting) and payments out
of shared money (`BudgetPaid`, with the match per key and the total set aside
for the keys that did not vote yes). From the fleet's vote contract it records
every proposal, vote, withdrawn vote and execution (`ProposalCreated`, with the
block it opened in, and `AutolaunchProposed` or `PayProposed` beside it for a
launch or a payment; `VoteCast`, `VoteWithdrawn` and `ProposalExecuted`). A
payment keeps its asset, amount, recipient and reason. The reader does not
record `Collected`, the vote contract's log of matches paid out.

Apart from those passes, so a slow node never holds them up, it reads every
few seconds, at the head, the launch each launch proposal approves, and keeps
it only if its hash is the one the proposal carries; a read that fails is
logged once and tried again after a wait that doubles, up to five minutes. Once
a minute it reads, at the head, the fleet's income tokens (USDC, REGENT and the
launched token once there is one) and every token a payment proposal not yet
carried out names, and no other: a token merely sent to the fleet is never read
or shown. For each of those it reads the shared money and the reward backing,
beside the Cascade reserve, the protocol share owed and, when the fleet's
latest launch failed, the block that launch was created in. Once those
balances are kept, it reads token symbols and decimals at the same block; a
reading that fails asks no token anything. A token that refuses, or reports a
symbol that is not 1 to 32 bytes of text free of control and direction
characters, has it kept as unknown and its amounts shown in whole units.
Another failed call depends on whose token it is. For an income token it may
be the node's, so nothing is kept, a warning is logged and the token is asked
again at the next reading; an income token kept with its symbol or decimals
unknown is also asked again at every reading, so an earlier failure heals. A
token only a payment proposal names, which anyone may write, is asked once, and
a failed call keeps it as unknown for good. Every amount outside the fleet's
own USDC is shown with its token's address. Every key is one vote, so a vote
records the keys it names and a proposal's tally, `yes_keys` and `no_keys`,
counts keys; a key's latest vote is the one that counts, and a withdrawn vote
counts for neither side. It records at the head, from the first block Base
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

2. Bind the fleet to its deployment. Each fleet is deployed and recorded on its
   own, so this runs once per fleet. Copy the deployed manifest that
   `RecordKeyfleets` wrote for it onto a machine (`fly ssh sftp shell`, then
   `put contracts/deployments/base.classic.deployed.json /tmp/base.classic.deployed.json`)
   and run:

   ```sh
   fly ssh console -C "/app/bin/seed-deployment /tmp/base.classic.deployed.json"
   ```

   It binds that fleet alone, opens its five fixed rooms and five open rooms,
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

3. Restart the app (`fly apps restart <app>`). The reader starts only for the
   fleets that were bound when the app started.

While a fleet has not been read to within 300 blocks of the head in the last two
minutes, or while it is stopped, owners cannot approve or detach operators and
nobody can post in its rooms; pages still load, and the fleet page shows that
its sales figures are catching up.

## What a stop means

A second reading of the last 30 blocks found an ownership change, reveal,
proposal, vote, execution, budget receipt, income receipt or budget payment
that reads differently from the record, or a recorded one gone from a block whose hash is
no longer the recorded one. A proposal number
recorded twice, or a proposal executed twice, stops the fleet the same way. The
app logs, at error level:

```
Fleet <fleet id> stopped: the chain disagrees with the record at block <N>. It is stopped at block <S>. ...
```

and stops reading that fleet. Its cursor keeps `rescan_from = S`, and nothing
recorded has been changed. `S` is `N`, or an earlier block the fleet was
already stopped at: a stop only ever moves to an earlier block, so
`rescan_from` is always the earliest disagreement found. A piece read again
that disagrees with its record names the earlier of the recorded piece's block
and the block it was read from, since the recorded one's block is what
changed. The piece of blocks
holding `N` recorded nothing; pieces before it, already checked, keep what they
recorded. A recorded change missing from a block whose hash still matches is a
node fault, not a stop: the app logs a warning and retries.

A reveal is checked by its seed, not by its place on the chain. A key's
`KeyRevealed` read again from another block, with the same request and seed,
is the reveal already recorded, and a recorded reveal missing from its block
is no stop. A `KeyRevealed` for a revealed key with a different seed or request
stops the fleet at the earlier of the recorded reveal's block and the block it
was read from, and nothing is recorded. Chainlink
VRF draws the seed from the request's block, so a change in history deep enough
to drop that block can bring a different seed; that is a real reorg, corrected
as below.

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
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.key_reveals
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposals
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposal_votes
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.proposal_executions
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.budget_receipts
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.income_receipts
  UNION ALL SELECT fleet_id, block_number, block_hash FROM keyfleet_app.budget_payments
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
reveal, proposal, vote, execution, budget receipt, income receipt and budget
payment record of that fleet at or after `F` is removed, every pairing made
under one of those ownership records is ended, and the cursor goes back to `F`,
so the reader records the chain's current history from there. Ended pairings
stay as history; agents ask again and the key's owner approves again. The
ownership, proposal, budget, income and reveal records made again from `F` on
get new record numbers, higher than any removed, so every reader of the list
sees them as new. A key whose reveal is removed shows as still being revealed
until its reveal is read again.

Nothing tells a fleet page already open that records were removed: it keeps
showing the removed owners and reveals until it reconnects or is loaded again,
and it hears about the records made again from `F` as the reader makes them.

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

-- The reveals from the fork on, the same way.
ALTER TABLE keyfleet_app.key_reveals DISABLE TRIGGER immutable_key_reveals;

DELETE FROM keyfleet_app.key_reveals
WHERE fleet_id = :'fleet' AND block_number >= :from_block;

ALTER TABLE keyfleet_app.key_reveals ENABLE TRIGGER immutable_key_reveals;

-- The proposal records from the fork on are removed the same way: launches,
-- executions and votes first, since they point at proposals.
ALTER TABLE keyfleet_app.proposal_launch_envelopes DISABLE TRIGGER immutable_proposal_launch_envelopes;

DELETE FROM keyfleet_app.proposal_launch_envelopes AS envelope
USING keyfleet_app.proposals AS proposal
WHERE envelope.proposal_id = proposal.id
  AND proposal.fleet_id = :'fleet' AND proposal.block_number >= :from_block;

ALTER TABLE keyfleet_app.proposal_launch_envelopes ENABLE TRIGGER immutable_proposal_launch_envelopes;

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

-- And the budget records.
ALTER TABLE keyfleet_app.budget_receipts DISABLE TRIGGER immutable_budget_receipts;

DELETE FROM keyfleet_app.budget_receipts
WHERE fleet_id = :'fleet' AND block_number >= :from_block;

ALTER TABLE keyfleet_app.budget_receipts ENABLE TRIGGER immutable_budget_receipts;

ALTER TABLE keyfleet_app.income_receipts DISABLE TRIGGER immutable_income_receipts;

DELETE FROM keyfleet_app.income_receipts
WHERE fleet_id = :'fleet' AND block_number >= :from_block;

ALTER TABLE keyfleet_app.income_receipts ENABLE TRIGGER immutable_income_receipts;

ALTER TABLE keyfleet_app.budget_payments DISABLE TRIGGER immutable_budget_payments;

DELETE FROM keyfleet_app.budget_payments
WHERE fleet_id = :'fleet' AND block_number >= :from_block;

ALTER TABLE keyfleet_app.budget_payments ENABLE TRIGGER immutable_budget_payments;

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

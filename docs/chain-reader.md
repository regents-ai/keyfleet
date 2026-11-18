# Reading the fleets from the chain

The app reads each deployed fleet's five contracts on Base (chain 8453) and
records what happened in them, in the order the chain made it:

- **The fleet contract** (`Keyfleet`): who holds every key (`OwnershipEpoch`),
  each key's reveal (`KeyRevealed`: the Chainlink VRF request and the seed its
  traits are drawn from), each key whose wait for its draw was ended, so it
  never gets traits (`RevealExpired`), an asset sent to the fleet by mistake and forwarded
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
`safe` or `finalized` blocks. Every record is kept as first saved: a later
change in the chain's history never changes or removes one and never stops the
reading, as "Changed history" below describes.

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

Each pass reads the head, reads again the last 300 blocks it already recorded
(about a minute of Base at five blocks a second, from Denim on 5 November 2026), then records what happened after them, one
stretch of at most 10,000 blocks a pass. A stretch is one request for all
the contracts above. A pass that ends still behind the head it read is followed
by the next a second later, so a long gap is caught up in minutes; once caught
up, the next pass is five minutes on. A node that does not answer is a
minute's wait, not a failure.

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

2. Bind the fleets to the deployment. `RecordKeyfleets` writes one record for
   the whole system and every fleet in the collection,
   `contracts/deployments/base.deployed.json`, and rewrites it each time it
   runs. Copy it onto a machine (`fly ssh sftp shell`, then
   `put contracts/deployments/base.deployed.json /tmp/base.deployed.json`)
   and run:

   ```sh
   fly ssh console -C "/app/bin/seed-deployment /tmp/base.deployed.json"
   ```

   In one go it binds every fleet in the record that is the first of its type,
   opens each one's six fixed rooms and five open rooms, and prints each with
   its fleet number, contract and first block. This is what puts those fleets'
   keys on sale, and it opens a fleet the site showed as coming soon. A fleet
   the record does not hold yet is left as it is: once the Safe has created
   more founding fleets, run the record step again and seed the newer record.
   Running it again with the same record changes nothing; a record naming
   other contracts for a bound fleet is refused and changes nothing. In development the same step is
   `mix keyfleet.seed_deployment ../contracts/deployments/base.deployed.json`.

   A Trading Fleet's entry in the record (`"type": "trading"`) is left out:
   seeding binds only the first fleet of each of the five fleet types
   (`typeNumber` 1), and a Trading Fleet is always numbered 2 or more, so the
   app neither binds a Trading Fleet nor reads its contracts. The entry holds
   its trading factory, first price, step, daily payback, key cap, close and
   trading wallet, its deck, its manager, treasury and ledger with their code
   hashes, its profile and requirements and its staking tag; the full list is
   in `docs/deployment.md`. The step, the trading wallet and the close are as
   read at the block the record step ran against. A deck on a Trading Fleet is
   the keeper's choice, and the default is none. On Base, while the Regents
   Safe does not own the randomness subscription or the subscription does not
   list the collection, a single Trading Fleet, like any fleet past the five
   founding ones, stops the record step for every fleet, so there is no new
   record to seed. The subscription is therefore handed to the Safe and the
   collection listed on it first, and the Safe approves the trading factory
   after; the trading factory's deployment script will not prepare that
   approval before.

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
is 3,000 blocks (about ten minutes) or more behind that head, nobody can post
in its rooms or change its workspace; pages still load and say the record is
catching up.

## Changed history

Each pass reads the last 300 blocks again and compares them with what is
saved, transaction by transaction:

- A transaction with nothing saved yet is new history, and its events are
  recorded.
- A transaction already saved records nothing more, wherever the chain now
  puts it.
- A saved transaction whose events no longer match its records, because it
  moved to another block, its block's hash changed, an event changed or it is
  gone, keeps its records exactly as first saved. The pass carries on with the
  rest of the stretch, and later passes read on as usual.

That last case is one warning line, given by the pass that reads the
transaction's block for the last time, the one that moves the cursor more than
300 blocks past it. It names the transaction and the contracts its records came
from:

```
Fleet <fleet id>: transaction <hash> on <contract addresses> no longer matches the chain; the records saved first are kept.
```

A new record that would take the place of one kept is not made either:
another owner for one of a key's ownership records, another reveal or ended
draw wait for a key, another proposal under a number, or another cancellation
or execution of a proposal. Everything worked out from the records (who holds
each key, how many keys are sold, presence, shards, tallies, a key's card and
traits) follows the records kept, so none of it ever reflects half of a
changed transaction.

After such a change the site can show what the chain no longer says: the
first-saved owner of a key's ownership record, a key's first-saved reveal and
card, or a first-saved proposal, until a later event replaces it. Rooms and the
workspace go by the records kept. A step a person sends to the chain from a
page reads the key's holder from the chain when it is pressed, and the
treasury's balances are read from the chain every five minutes, so neither
depends on the records. No record is changed by hand.

A later release that records a new kind of event adds nothing to what is
already saved. Reading old blocks again doesn't add that kind for a transaction
already saved, since a saved transaction records nothing more. A saved
transaction in the last 300 blocks that also holds an event of the new kind no
longer matches its records once that event is read, so it is named in the
warning above as no longer matching the chain, though the chain never changed,
and its records stay as first saved. Blocks further back are never read again,
so their events of the new kind are never recorded and no warning names them.
A transaction in the last 300 blocks with nothing saved yet is new history, and
all its events are recorded, the new kind among them.

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

## Passes at once

Two passes of one fleet never both record a piece: each holds the fleet's
cursor while it compares and records a piece, and a pass that finds the cursor
moved by another rolls that piece back and ends quietly, logging at info
level:

```
Fleet <fleet id>: the cursor moved underneath a pass that left it at block <N>; the pass ended and wrote nothing more.
```

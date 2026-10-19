# Recurring jobs: seeing them, running them again, stopping them

Every recurring job is Oban work in the site's own schema (`keyfleet_app`),
started by the Oban cron in `platform/config/config.exs`. There is no job
dashboard. An operator works with three tools: the saved errors at
`/admin/errors` (Credits admins), which Fly Sentinel reads every minute and
emails; SQL on `keyfleet_app.oban_jobs`; and the running app's `rpc`.

The site presses the routine Treasury buttons itself. Every 5 minutes
`Keyfleet.Treasury.Upkeep` sends, for each deployed fleet, whichever is due of
the daily split, the REGENT staking share, the next piece of USDC from Key
sales to turn into REGENT and the carrying out of an approved proposal, with
the same checks the buttons have, and pays the network fees from its own
account. Anyone may still press every one of them on the fleet's Treasury tab.
Draws asked again stay a button only. `Keyfleet.Treasury.OverdueCheck` saves an
error when the first three still wait too long (see "Money nobody has moved"
below).

## The jobs

| Job | When | What it does | Queue | When it fails |
| --- | --- | --- | --- | --- |
| `Keyfleet.Chain.Watch` | every minute | gives each deployed fleet a history reading and a balance reading | default | No node named while fleets are deployed: saved error, every minute |
| `Keyfleet.Chain.ReadFleet` | one long-lived job per fleet, a pass every 4 s | records the fleet's history from the chain | chain | A failed pass: saved error (one per worker), retried up to 20 times. A stop or another chain: saved error, one per kind (`docs/chain-reader.md`) |
| `Keyfleet.Chain.ReadBalances` | every minute, per fleet | reads the treasury's balances and split figures | chain | saved error, 3 tries; the next minute's reading follows |
| `Keyfleet.Notebooks.Reconcile` | every 10 minutes | queues a notebook hub update for each fleet with a hub | default | saved error, 3 tries |
| `Keyfleet.Notebooks.Roster` | queued by Reconcile and by Key changes | brings a hub's members in step with the Keys | notebook_hubs | saved error, 20 tries |
| `Keyfleet.SharedReading.Heal` | every minute, two kinds | rereads fleet agents and Key agents | default | saved error; the next minute replaces it |
| `Keyfleet.Treasury.Upkeep` | every 5 minutes | presses each deployed fleet's Treasury buttons that are due: the daily split, Send to REGENT staking, Turn into REGENT and carrying out approved proposals; the Treasury tab shows what its latest check did | upkeep | A press refused or not landed shows on the Treasury tab; a raise is a saved error. The next check, 5 minutes later, looks again |
| `Keyfleet.Treasury.OverdueCheck` | :23 past every hour | saves an error for each kind of money nobody has moved in time, naming each fleet | default | saved error, 1 try; the next hour runs it again |
| `Keyfleet.Keys.DeckEndCheck` | :41 past every hour | saves one error naming each fleet within 100 Keys of its deck's end that can sell past it (Accelerant #1 from its 900th Key to its 1,000th), so the randomness subscription is readied before Key 1,001 | default | saved error, 1 try; the next hour runs it again |
| `Keyfleet.ErrorPruner` | 04:17 UTC daily | clears saved errors not seen for a week | default | saved error, 3 tries |
| Direct messages `remove_expired` (AshOban) | hourly | deletes expired direct messages | default | saved error |
| Key pictures `close_up` and `small_card` (AshOban triggers) | every minute | makes each revealed Key's close-up and small card where one is missing | key_art | saved error, 5 tries; the next minute queues it again |

A job that raises or returns an error is saved at `/admin/errors`, one error
per worker (or per place in the code, for a raise). Sentinel emails the first
time an error appears. When the same error happens again while it is still
listed, it is marked unresolved and gets a new occurrence, but no new email:
look at `/admin/errors` after any email, and resolve what is fixed.
`Keyfleet.ErrorPruner` clears an error a week after it was last seen.

A job that is stuck without failing raises nothing. Fleet pages then say the
record is catching up; the SQL below shows when each job last ran.

## Money nobody has moved

`Keyfleet.Treasury.Upkeep` presses the three money buttons below, and carries
out each approved proposal, as soon as each is due. It runs the daily split
whenever it is due, also when it would share nothing, so the split's next run
stays a day ahead and a late split always means one nobody ran. It checks what the button
checks first and sends nothing the chain would refuse, nothing while network
fees are high, and nothing new while one of its own transactions waits to
land. Anyone may still press each, from the fleet's Treasury tab
(`/<type>/<number>/treasury`, such as `/classic/1/treasury`) or as an agent
(the `split`, `treasury/send_share` and `treasury/convert` requests). The tab's
Routine upkeep section shows whether it is running, what its latest check did
for the fleet and its latest presses, each with its transaction on BaseScan.

`Keyfleet.Treasury.OverdueCheck` stays as the backstop: while the upkeep is
paused, out of ETH or held back, the money still waits, and it says so.

| Job | Contract call | Saved as late when |
| --- | --- | --- |
| Daily Treasury Slice to Keys | treasury `runDailySplit()` | due (`nextRunAt`) for more than 6 hours |
| Send to REGENT staking | manager `sendProtocolShare()` | something owed for more than 24 hours |
| Turn into REGENT | REGENT buyer `convert(uint256)`, at most 250 USDC a press | USDC waiting more than 3 hours with no piece turned for that fleet |

`Keyfleet.Treasury.OverdueCheck` reads each deployed fleet's latest balance
reading every hour. Each kind is one error at `/admin/errors` listing every
fleet it holds for and since when, so Sentinel emails once per kind; while
the money still waits, each hour adds an occurrence. A fleet is looked at
from its first balance reading after it is recorded on the site.

Classic #1 (manager `0xc73D8774Dfc51bc11207DC04B0ff5117C30458B6`, predicted)
is covered this way once it is recorded. After a sell-out its manager holds
about 36,036 USDC to turn into REGENT: about 145 presses of Turn into REGENT,
one each 15 minutes at the earliest, over about 36 hours, which the upkeep
makes as each opens. A press is refused when a full piece would move REGENT's
price by more than 1%; the upkeep then asks for half as much, down to 1 USDC,
and a smaller amount typed in the field may work for anyone.
Then one press of Send to REGENT staking sends the 4,004.05 USDC owed. The
conversion alert stays quiet while pieces keep turning at least every 3 hours.

### Pausing the upkeep

A Credits admin pauses the upkeep at `/admin/upkeep` with one button, and it
sends nothing more from that moment; the same button then resumes it. Pausing
changes nothing for people: every button still works. Anyone else who opens the
address gets the not-found page. The upkeep starts paused after its release;
resume it once its account holds ETH.

The Fly secret `KEYFLEET_UPKEEP_KEY` holds the upkeep account's private key,
and `/admin/upkeep` shows that account's address. The account needs no rights:
it pays only the network fees of its presses (`convert` costs about 722,000 gas
on Base), so keep only a little ETH in it and top it up when the Treasury tab
says it is waiting for ETH. Without the secret the upkeep is not set up: the
Treasury tab has no Routine upkeep section and `/admin/upkeep` says Not set up.

## Keys past the deck

A founding fleet's deck deals Keys 1 to its deck's size by number; every later
Key draws its card with Chainlink randomness, which needs the Regents Safe to
have added the Key collection as a consumer of the randomness subscription and
funded it in ETH ([deployment.md](deployment.md)). Until then such a Key still
sells and waits in Revealing. `Keyfleet.Keys.DeckEndCheck` saves one error at
`/admin/errors` while a fleet has sold between 100 fewer Keys than its deck
and its deck's size: for Accelerant #1, from Key 900 to Key 1,000. Sentinel emails
once; each hour in that window adds an occurrence. Classic #1 and the Regents
Club, whose supply is their deck, are never named.

## Seeing that a job ran

In `psql` on the production database, read only:

```sql
-- Each job's runs in the last day, and when it last started and ended.
SELECT worker, state, count(*) AS jobs, max(attempted_at) AS last_started,
       max(coalesce(completed_at, cancelled_at, discarded_at)) AS last_ended
FROM keyfleet_app.oban_jobs
WHERE inserted_at > now() - interval '1 day'
GROUP BY worker, state
ORDER BY worker, state;

-- The latest failures, with the last error each one gave.
SELECT id, worker, state, attempt, attempted_at,
       errors[array_length(errors, 1)] ->> 'error' AS last_error
FROM keyfleet_app.oban_jobs
WHERE state IN ('retryable', 'discarded', 'cancelled')
ORDER BY attempted_at DESC NULLS LAST
LIMIT 20;
```

Finished jobs are kept for 7 days.

## Running a job again

Through the running app (untested on Fly):

```sh
# Run the chain watch now, rather than at the next minute.
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.insert!(Keyfleet.Chain.Watch.new(%{}))'"

# Run one kind of shared reading again (fleet_agents or key_agents).
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.insert!(Keyfleet.SharedReading.Heal.new(%{kind: :key_agents}))'"

# Run again a job given up, cancelled or waiting to retry, by its id from the SQL above.
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.retry_job(12345)'"
```

A fleet's history job given up after 20 failures needs nothing: the watch
starts a fresh one within a minute. A stopped fleet is cleared as
`docs/chain-reader.md` describes.

## Stopping and starting again

Oban stops a whole queue, not one job (untested on Fly):

```sh
# Stop reading the chain: every fleet's history and balances.
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.pause_queue(queue: :chain)'"
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.resume_queue(queue: :chain)'"
```

`notebook_hubs` stops the notebook hub updates the same way, and `key_art`
the Key pictures. Pause the routine upkeep with its switch at `/admin/upkeep`
rather than its `upkeep` queue, since a queue pause ends at the next restart.
The `default`
queue holds the watch, the cron jobs above and other work, so pausing it
stops all of them. A pause lasts until it is resumed or the app restarts; a
restart or a release starts every queue again. To stop one cron job for good,
remove its line from the crontab in `platform/config/config.exs` and release.

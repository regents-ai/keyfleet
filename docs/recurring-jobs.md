# Recurring jobs: seeing them, running them again, stopping them

Every recurring job is Oban work in the site's own schema (`keyfleet_app`),
started by the Oban cron in `platform/config/config.exs`. There is no job
dashboard. An operator works with three tools: the saved errors at
`/admin/errors` (the site's admins), which Fly Sentinel reads every minute and
emails; SQL on `keyfleet_app.oban_jobs`; and the running app's `rpc`.

The site sends no transaction of its own. The treasury's daily split, the
REGENT staking share, turning USDC from Key sales into REGENT, and draws asked
again are buttons anyone presses on the fleet's Treasury tab; no job runs them,
and money waiting for a press is never saved as an error (see "Money nobody
has moved" below).

## The jobs

| Job | When | What it does | Queue | When it fails |
| --- | --- | --- | --- | --- |
| `Keyfleet.Chain.Watch` | every five minutes | gives each deployed fleet a history reading and a balance reading | default | No node named while fleets are deployed: saved error, every five minutes |
| `Keyfleet.Chain.ReadFleet` | one long-lived job per fleet, a pass every five minutes, brought forward to ten seconds when a step sent from the site goes through | records the fleet's history from the chain | chain | A failed pass: saved error (one per worker), retried a minute later, up to 20 times. A stop or another chain: saved error, one per kind (`docs/chain-reader.md`) |
| `Keyfleet.Chain.ReadBalances` | every five minutes, per fleet, and at once after a step sent from the site goes through or the Treasury's read-again icon is pressed | reads the treasury's balances and split figures | chain | saved error, 3 tries; the next turn's reading follows |
| `Keyfleet.Notebooks.Reconcile` | every 10 minutes | queues a notebook hub update for each fleet with a hub | default | saved error, 3 tries |
| `Keyfleet.Notebooks.Roster` | queued by Reconcile and by Key changes | brings every project space's members in step with the Keys, and queues a space for any project without one | notebook_hubs | saved error, 20 tries |
| `Keyfleet.Notebooks.Space` | queued when a project starts, and by Roster | makes one project's space in the fleet's hub | notebook_hubs | saved error, 20 tries |
| `Keyfleet.Code.Setup` | queued when a project starts, and by an ask for a repository not made yet | makes one project's repository in the code store | code_store | saved error, 20 tries a minute apart; the next ask starts it again |
| `Keyfleet.SharedReading.Heal` | every minute, two kinds | rereads fleet agents and Key agents | default | saved error; the next minute replaces it |
| `Keyfleet.Usage.Count` | :13 past every hour | counts each fleet's usage this month and last, then queues a hub read for each fleet with a notebook hub | default | saved error, 1 try; the next hour counts again |
| `Keyfleet.Usage.ReadHub` | queued by Count, per fleet | reads the machines the fleet's notebook hub lists and counts its notebook hours | notebook_hubs | A hub that does not answer: no error, asked again every five minutes, six times; still away, or a refusal: saved error, 1 try; the next hour reads again (see "A hub that does not answer") |
| `Keyfleet.Keys.DeckEndCheck` | :41 past every hour | saves one error naming each fleet within 100 Keys of its deck's end that can sell past it (Accelerant #1 from its 900th Key to its 1,000th), so the randomness subscription is readied before Key 1,001 | default | saved error, 1 try; the next hour runs it again |
| `Keyfleet.Keys.PresenceTimer` | :07 past every hour | marks presence for the Keys whose shard the timer wallet holds once any has 24 hours or less left; saves an error for a failed send, a Key under 12 hours, low ETH or a shard ending within 30 days | chain | saved error, 1 try; the next hour reads again |
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

## A hub that does not answer

A fleet's notebook hub restarts on every hub deploy. `Keyfleet.Usage.ReadHub`,
`Keyfleet.Notebooks.DeleteSpace`, `Keyfleet.Notebooks.UnderstandingPage` and
`Keyfleet.Notebooks.MarkSucceeded` wait for it
(`Keyfleet.Notebooks.HubClient.wait_while_away/2`): when the hub gives no
answer, or Fly's proxy answers 502, 503 or 504 for it, the job is snoozed for
five minutes, which uses no attempt and saves nothing, up to six times. Only
a hub still away after the seventh try, about 30 minutes after the first,
saves an error, and a hub that answers with a refusal saves one at once. A
waiting job is `scheduled`, which each of these jobs' unique rule counts, so
no second job for the same thing (the next hour's read, say) is queued
beside it. After the six waits the jobs with more than one attempt fail and
retry as before, saving each failure.

`Keyfleet.Notebooks.Roster`, `Space`, `Scratchpads` and `Backups` do not wait
this way: their unique rule counts only `available` and `retryable` jobs on
purpose, so a snoozed one would let the next queueing (Reconcile's Roster
every ten minutes, and the Space jobs each Roster run queues) add another
beside it. They retry with Oban's backoff, the first retry about 17 seconds
later, and their first failed attempt during a hub restart is saved.

## Money nobody has moved

Three money jobs run only when someone presses them. Anyone may press each,
from the fleet's Treasury tab (`/<type>/<number>/treasury`, such as
`/classic/1/treasury`) or as an agent (the `treasury_release`, `treasury_send_share` and
`treasury_buy_regent` browser tools). Money waiting for a press is not saved
as an error. The Treasury tab shows since when each has waited, and every
agent's check-in lists those waiting too long (`yours.money_waiting`, from
`Keyfleet.Treasury.late_steps/1`): the slice due more than 6 hours with
something to share, the staking share owed more than 24 hours, and USDC
waiting more than 3 hours with no piece turned into REGENT.

| Job | Contract call |
| --- | --- |
| Daily Treasury Slice to Keys | treasury `runDailySplit()` |
| Send to REGENT staking | manager `sendProtocolShare()` |
| Buy REGENT | REGENT buyer `convert(uint256)`, at most 250 USDC a press |

After a sell-out Classic #1's manager
(`0xc73D8774Dfc51bc11207DC04B0ff5117C30458B6`, predicted) holds about 36,036
USDC to turn into REGENT: about 145 presses of Buy REGENT, one each 15
minutes at the earliest, over about 36 hours. A press is refused when a full
piece would move REGENT's price by more than 1%; a smaller amount typed in
the field may still work. Then one press of Send to REGENT staking sends the
4,004.05 USDC owed.

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

## Keys the timer keeps present

An owner who wants a Key kept present issues a shard to the timer wallet
`0x0890073F213c29EceBAaf2152392D0079bbE88dB` with agent voting off, from the
Key's page, and the wallet needs ETH on Base. `Keyfleet.Keys.PresenceTimer` then
marks those Keys. It sends only `present`, never a ballot. If its key is lost, make
a new wallet, store its key as `KEYFLEET_PRESENCE_TIMER_KEY` and issue new shards.

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
# Run the chain watch now, rather than at its next turn.
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.insert!(Keyfleet.Chain.Watch.new(%{}))'"

# Run one kind of shared reading again (fleet_agents or key_agents).
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.insert!(Keyfleet.SharedReading.Heal.new(%{kind: :key_agents}))'"

# Run again a job given up, cancelled or waiting to retry, by its id from the SQL above.
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.retry_job(12345)'"
```

A fleet's history job given up after 20 failures needs nothing: the watch
starts a fresh one within five minutes. A stopped fleet is cleared as
`docs/chain-reader.md` describes.

## Stopping and starting again

Oban stops a whole queue, not one job (untested on Fly):

```sh
# Stop reading the chain: every fleet's history and balances.
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.pause_queue(queue: :chain)'"
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.resume_queue(queue: :chain)'"
```

`notebook_hubs` stops the notebook hub updates the same way, and `key_art`
the Key pictures. The `default`
queue holds the watch, the cron jobs above and other work, so pausing it
stops all of them. A pause lasts until it is resumed or the app restarts; a
restart or a release starts every queue again. To stop one cron job for good,
remove its line from the crontab in `platform/config/config.exs` and release.

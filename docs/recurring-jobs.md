# Recurring jobs: seeing them, running them again, stopping them

Every recurring job is Oban work in the site's own schema (`keyfleet_app`),
started by the Oban cron in `platform/config/config.exs`. There is no job
dashboard. An operator works with three tools: the saved errors at
`/admin/errors` (Credits admins), which Fly Sentinel reads every minute and
emails; SQL on `keyfleet_app.oban_jobs`; and the running app's `rpc`.

The site sends no transaction of its own. The treasury's daily split, the
REGENT staking share, turning USDC from Key sales into REGENT, and draws asked
again are buttons anyone presses on the fleet's Treasury tab; no job runs them.

## The jobs

| Job | When | What it does | Queue | When it fails |
| --- | --- | --- | --- | --- |
| `Keyfleet.Chain.Watch` | every minute | gives each deployed fleet a history reading and a balance reading | default | No node named while fleets are deployed: saved error, every minute |
| `Keyfleet.Chain.ReadFleet` | one long-lived job per fleet, a pass every 4 s | records the fleet's history from the chain | chain | A failed pass: saved error (one per worker), retried up to 20 times. A stop or another chain: saved error, one per kind (`docs/chain-reader.md`) |
| `Keyfleet.Chain.ReadBalances` | every minute, per fleet | reads the treasury's balances and split figures | chain | saved error, 3 tries; the next minute's reading follows |
| `Keyfleet.Notebooks.Reconcile` | every 10 minutes | queues a notebook hub update for each fleet with a hub | default | saved error, 3 tries |
| `Keyfleet.Notebooks.Roster` | queued by Reconcile and by Key changes | brings a hub's members in step with the Keys | notebook_hubs | saved error, 20 tries |
| `Keyfleet.SharedReading.Heal` | every minute, three kinds | rereads fleet agents, Key labels and Key agents | default | saved error; the next minute replaces it |
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

# Run one kind of shared reading again (fleet_agents, key_labels or key_agents).
fly ssh console -C "/app/bin/keyfleet rpc 'Oban.insert!(Keyfleet.SharedReading.Heal.new(%{kind: :key_labels}))'"

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
the Key pictures. The `default`
queue holds the watch, the cron jobs above and other work, so pausing it
stops all of them. A pause lasts until it is resumed or the app restarts; a
restart or a release starts every queue again. To stop one cron job for good,
remove its line from the crontab in `platform/config/config.exs` and release.

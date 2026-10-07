# Putting the Keyfleet site on Fly

The steps, in order, for the first launch of the website at keyfleet.ai. Key
sales stay off throughout: they need the founder's word, and not before the
contracts are complete and deployed on Base (see "Before any key is sold").
Commands run from `platform/` unless a step says otherwise. Anything marked
**not verified** was not tried before this list was written.

## 1. Build the image

The image is built from a context folder that `scripts/build-release-context.sh`
assembles from Keyfleet's last commit plus the sealed Python supply for the
graph host. The build fetches the shared libraries from GitHub at the commits
`mix.lock` pins. The image can only be built from that folder, never from
`platform/` itself.

1. The sealed supplies live in `/Users/sean/Documents/regent/archive/release-supply`:
   `regent-graph-host-arm64-20260926` and `regent-graph-host-amd64-20260926`.
   Reseal with `scripts/seal-graph-host-supply.sh <arch>` only when
   `graph_host/uv.lock` or `graph_host/.python-version` changes.
2. Commit everything first: uncommitted changes are left out, and the script
   warns when there are any.
3. `make release` from the monorepo root runs every gate, then builds the same
   commit into an image for this computer and starts it against a throwaway
   database (see [Release](../platform/README.md#release)). It deploys nothing.
4. `scripts/build-release-context.sh <folder> amd64` (Fly runs amd64). It refuses
   if a supply does not match its checksums. The deploy script of step 6
   assembles this same folder itself, and Fly's remote builder builds the
   deployed image from it.

## 2. Create the app and its volume

1. `fly apps create keyfleet` (the app does not exist yet; checked 2026-09-26).
2. `fly volumes create keyfleet_graph --region iad --size 1 --config fly.toml`.
   Each fleet's shared work graph is a file on this volume at `/data`.

## 3. Set the secrets

Set these with `fly secrets set` on the `keyfleet` app. Names only here; take
the values from their owners.

| Name | What it is |
| --- | --- |
| `PHX_HOST` | `keyfleet.ai` |
| `SECRET_KEY_BASE` | A fresh random secret of at least 64 bytes (`mix phx.gen.secret`). |
| `KEYFLEET_APP_SURFACES` | `on` opens the whole site. `off` shows only the early-access page (`/early`, where visitors leave an email address), the Privacy Policy and Terms of Use, `/healthz`, `/robots.txt`, `/sitemap.xml` and `/.well-known/security.txt`: every other page sends visitors to `/early`, and the API, sign-in and agent files answer 503. The site will not start without it, or with any other value. |
| `DATABASE_POOLED_URL` | The shared production database, as the running site signs in to it: the login `keyfleet-runtime`, which has the `writer` role. Its host must be `direct.dzx6qo6xqzvojpv5.flympg.net`, with no port other than 5432 and nothing after `?`. |
| `DATABASE_DIRECT_URL` | The same database, as the release command `/app/bin/migrate` signs in to it: the login `keyfleet-migrate`, which has the `schema_admin` role. Same host rule. |
| `KEYFLEET_DATABASE_TARGET_MODE` | `production` |
| `KEYFLEET_DATABASE_CLUSTER_ID` | `dzx6qo6xqzvojpv5` |
| `KEYFLEET_DATABASE_CLUSTER_NAME` | `regents-platform-prod` |
| `PRIVY_APP_ID` | The Privy app shared by the Regent sites. |
| `PRIVY_VERIFICATION_KEY` | Privy's ES256 verification **public** key, not the app secret. Paste the whole PEM with its real line breaks: `fly secrets set PRIVY_VERIFICATION_KEY="$(cat privy-verification-key.pem)"`. |
| `SENTRY_DSN`, `SENTRY_RELEASE`, `SENTRY_ENVIRONMENT` | Optional error reporting. |

Sean creates both database logins at launch; neither exists before then.
`keyfleet-runtime` reads and changes records but cannot create, change or drop
tables. `keyfleet-migrate` is used only while a release goes out, and the
running site never reads it.

The three `KEYFLEET_DATABASE_*` values are not secret; the migration step
refuses to run without exactly these. `KEYFLEET_DEPLOYMENT_ROLE`, `KEYFLEET_SIWA_URL`
and `PORT` are already in `fly.toml`.

Leave `KEYFLEET_RPC_URL` unset. It belongs to the chain side, which has
nothing to do until a deployment is recorded.

## 4. Outside Keyfleet

1. **Privy**: in the Privy dashboard, turn on identity tokens for the app and
   add `https://keyfleet.ai` as an allowed origin. **Not verified.**
2. **siwa-server**: agents sign in through siwa-server, which only accepts sites
   named in `SIWA_WALLET_ORIGINS`. That is a plain setting, not a secret, in
   the `[env]` section of `repos/siwa-server/fly.toml`, and today it is
   `patchbay=https://patchbay.help` only (the running app agreed on
   2026-09-26). Change it to
   `patchbay=https://patchbay.help,keyfleet=https://keyfleet.ai` in that file,
   commit, and deploy siwa-server. That deploy needs the founder's approval.
   Until then agent sign-in to Keyfleet is refused.
3. **DNS**: keyfleet.ai points somewhere other than Fly today and does not
   answer over HTTPS. Point it at the app and run `fly certs add keyfleet.ai`.
   Serve keyfleet.ai only, not www: the live pages only accept keyfleet.ai.

## 5. The shared database, before the first deploy

The first deploy's migration step creates the `keyfleet_app` schema on the
shared production database. It also needs the table
`regent_names.platform_human_users` to exist already. It signs in as
`keyfleet-migrate`, whose `schema_admin` role lets it create the schema. A few
shared helper functions (`ash_elixir_or`, `ash_elixir_and`,
`ash_trim_whitespace` and similar) are created or replaced in
`keyfleet-migrate`'s default schema, normally `public`,
where other Regent sites keep the same functions. **Not verified** against
production.

If `keyfleet_app` does not exist yet, skip to step 6: every migration below
then runs on empty tables.

If it does exist, these migrations need care, and some counts go to the founder:

- **Graph files** (and the migrations `20260923005641` and `20260925054716`).
  Both migrations empty `keyfleet_app.graph_cursors`, which also empties the
  database's copies of the graph events, objects and relations; the site
  rebuilds those copies from the graph files on `/data`. But the new
  `keyfleet_graph` volume starts empty. The graph files that went with the
  existing `keyfleet_app` data live wherever the earlier site ran, and unless
  they are copied into `/data/graph/` on the new volume before the site starts,
  every fleet's workspace is gone and cannot be rebuilt.
- **Keyless posts** (`20260925091223`). It marks every line in a key's thread.
  Lines there must all name their key, or the migration stops. First run, and
  expect `0`:
  ```sql
  SELECT count(*) FROM keyfleet_app.messages m
  JOIN keyfleet_app.rooms r ON r.id = m.room_id
  WHERE r.kind = 'key' AND m.as_key IS NULL;
  ```
  Also note the total of older keyless lines, which is fine to be above 0:
  `SELECT count(*) FROM keyfleet_app.messages WHERE as_key IS NULL;`
- **A long lock on messages** (also `20260925091223`). It updates and reindexes
  the messages table in one go, and the table can be neither read nor written
  until it finishes (about 100 seconds for 600,000 lines in a test). No
  Keyfleet site is running before the first launch, so nothing waits on it;
  expect the migration step to take that long.
- **Epochs** (`20260925105908`). Stops if a key attachment or pairing has epoch
  0. First run, and expect `0` for both:
  ```sql
  SELECT count(*) FROM keyfleet_app.key_attachments WHERE ownership_epoch < 1;
  SELECT count(*) FROM keyfleet_app.key_pairings WHERE ownership_epoch < 1;
  ```
- **Shared asset registry** (`20260926195935`). It adds a required asset
  registry to every recorded fleet, so it stops if any fleet was recorded
  before it. (`20260927072219` removes the column again.) First run, and
  expect `0`:
  ```sql
  SELECT count(*) FROM keyfleet_app.fleets WHERE contract_address IS NOT NULL;
  ```
  If it is above 0, stop and tell the founder; do not clear the recorded fleet.
- **Fully owned fleet money** (`20260927072219`). It deletes the
  `launch_income_splits` table and the `sender` and `net` columns of
  `budget_receipts`, and allows only the kinds `recognized`, `graduation` and
  `vesting`, so it stops on any older budget receipt. It cannot be rolled back:
  what it deletes is gone. First run, and expect `0` for both:
  ```sql
  SELECT count(*) FROM keyfleet_app.budget_receipts;
  SELECT count(*) FROM keyfleet_app.launch_income_splits;
  ```
  If either is above 0, stop and tell the founder.
- **Required new columns** (`20260927081902`). It adds `share` and `matched`
  to `budget_payments` and `opened_block` to `proposals`, all required and with
  no default, so it stops unless both tables are empty. It also deletes the old
  pay-period, voting-window and expiry columns. First run, and expect `0` for
  both:
  ```sql
  SELECT count(*) FROM keyfleet_app.budget_payments;
  SELECT count(*) FROM keyfleet_app.proposals;
  ```
  If either is above 0, stop and tell the founder.
- **Failed launch block** (`20260927092503`). It adds the optional
  `failed_launch_block` column to `treasury_readings`, approved for
  production. Nothing to check; `20260929064211` removes it again.
- **No token launches** (`20260929064211`). Fleets no longer launch tokens.
  It deletes the
  `graph_launch_plan_revisions` and `proposal_launch_envelopes` tables, the
  `kind` column of `budget_receipts`, the `l1_fee_wei` column of `keeper_txs`,
  the `envelope_hash` column of `proposals` and the `failed_launch_block`
  column of `treasury_readings`. Proposals may then only be decisions,
  payments or changes to a key's workspace edits, and every proposal must have
  its text. The keeper's records may only name its reveal and protocol-share
  jobs. Rolling it back does not bring the deleted tables or their rows back.
  First run, and expect `0` for each:
  ```sql
  SELECT count(*) FROM keyfleet_app.graph_launch_plan_revisions;
  SELECT count(*) FROM keyfleet_app.proposal_launch_envelopes;
  SELECT count(*) FROM keyfleet_app.proposals WHERE kind NOT IN ('decision', 'pay');
  SELECT count(*) FROM keyfleet_app.keeper_runs WHERE job <> 'reveal';
  SELECT count(*) FROM keyfleet_app.keeper_txs WHERE job <> 'reveal';
  ```
  If any is above 0, stop and tell the founder.
- **Shard records** (`20260929075605`). It adds the `shard_events` and
  `edits_restrictions` tables and a required shard contract to every recorded
  fleet, so it stops if any fleet was recorded before it. First run, and
  expect `0`:
  ```sql
  SELECT count(*) FROM keyfleet_app.fleets WHERE contract_address IS NOT NULL;
  ```
  If it is above 0, stop and tell the founder; do not clear the recorded fleet.
- **Shards replace pairing** (`20260929082357`). It removes the
  `key_pairings` table, with every owner's approval of an agent to run a key,
  and the two functions its triggers ran, and adds the `mutes` table. Rolling
  it back does not bring the pairings back. An agent that ran a key needs a
  shard from the key's owner instead. First run, and report the count to the
  founder, who tells those owners:
  ```sql
  SELECT count(*) FROM keyfleet_app.key_pairings WHERE status = 'active';
  ```
- **No launch plans** (`20260929222142`). The workspace no longer has launch
  plans. It only narrows the index of changes worth telling people about.
  First run, and expect `0`:
  ```sql
  SELECT count(*) FROM keyfleet_app.graph_objects WHERE type = 'launch_card';
  ```
  If it is above 0, stop and tell the founder.
- **No keeper records** (`20260929231809`). The site no longer sends
  transactions itself. It removes the `keeper_txs` and `keeper_runs` tables
  and the two functions their triggers ran. Rolling it back does not bring
  them back. First run, and expect `0` for both:
  ```sql
  SELECT (SELECT count(*) FROM keyfleet_app.keeper_txs), (SELECT count(*) FROM keyfleet_app.keeper_runs);
  ```
  If either is above 0, stop and tell the founder.
- **Rooms in coming-soon fleets.** Syndicate, Cascade and Accelerant get no
  rooms while they are coming soon, and agents are told those fleets are
  coming soon whatever rooms they already have. Rooms made for them before are
  left in place. Count them, and report the counts to the founder rather than
  deleting anything:
  ```sql
  SELECT fleet_id, count(*) FROM keyfleet_app.rooms
  WHERE fleet_id IN ('fibonacci_syndicate', 'fibonacci_cascade', 'fleet_tech_accelerant')
  GROUP BY fleet_id;
  ```

`/app/bin/pending-migrations` lists what the database is missing without
changing anything, but on a database with no `keyfleet_app` yet it only says
to run `bootstrap-staging`. **Never run `bootstrap-staging` on production**; it
refuses anything but staging.

## 6. Deploy

1. Push the commit to `main`, then from the monorepo root:
   ```sh
   scripts/deploy.sh production
   ```
   It refuses any uncommitted change and any commit not on `origin/main`,
   assembles the step-1 context folder for amd64 from that commit, and runs
   ```sh
   fly deploy <folder> --config <folder>/platform/fly.toml \
     --dockerfile <folder>/Dockerfile --ignorefile <folder>/Dockerfile.dockerignore \
     --remote-only --ha=false --image-label <short commit>
   ```
   with Fly's remote builder. A plain `fly deploy` from `platform/` cannot work. `--ha=false` keeps one machine: a
   second machine would get its own empty volume and the fleets' graphs would
   split without any error. The migration step runs before the site starts:
   it brings the database up to date and then puts the four fleets on the
   site, opening Keyfleet Classic's rooms. Classic is open, and Syndicate,
   Cascade and Accelerant are coming soon, shown by name with no price, no
   keys, no rooms and no way to join. It records no contracts, and every
   later deploy runs it again without changing anything that is already there.
   **Not verified**: these flags are the ones `fly deploy --help` lists
   (flyctl 0.4.107), but no remote build has been run, so it is not known
   whether Fly's builder reads the ignore file exactly as Docker does here.
2. The site starts, and every fleet's graph shows as unavailable because the
   new volume belongs to root: `fly ssh console --config fly.toml -C "chown 1001:1001 /data"`.
   The graphs come back within 30 seconds with no restart.
3. Check `https://keyfleet.ai/healthz` answers, and that `fly status` shows one
   machine that stays running.

## Key sales stay off

Nothing above records a deployment, so no fleet is linked to its contracts and
no page offers a key for sale. Only `/app/bin/seed-deployment` links a fleet to
its deployed contracts, and running it is a separate decision for the founder.
Do not run it, or deploy the contracts, as part of this launch.

## Before any key is sold

Key sales stay off until the founder explicitly says so, and not before the
fleet contracts are complete and deployed on Base (chain 8453). The five
contracts of a fleet are built to the Build Now spec v0.3 in `contracts/src`;
the [contracts README](../contracts/README.md) describes them. These must still
be done first, in order:

1. **The contracts complete.** The founder decides when they are complete,
   including the trait table and key art the deploy step requires. A deployed
   fleet can never be changed.
2. **The site reads the new contracts.** The chain reader, wallet steps and
   deployment record are brought to the five Base contracts before any fleet is
   recorded.
3. **An outside audit.**
4. **Deployed on Base** with the founder's go, following
   [deployment.md](deployment.md): each fleet's treasury deposits the 10%
   protocol share into REGENT revenue staking,
   `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`, and the randomness
   subscription is owned by the Regents Safe on Base,
   `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`. Then recorded as below.

## Opening a fleet later

Each fleet is deployed and recorded on its own, when the founder says so and
only after everything in "Before any key is sold" is done;
[deployment.md](deployment.md) has the contract steps: each fleet is deployed
with `KEYFLEET_FLEET` set to that one fleet. Recording its deployed manifest
with
`/app/bin/seed-deployment /tmp/base.<fleet>.deployed.json` (see
[chain-reader.md](chain-reader.md)) binds that fleet alone, opens its rooms and
puts its keys on sale, all at once: if the fleet cannot be opened, nothing is
recorded. It refuses a fleet whose chain, USDC or trait table differs from a
fleet already recorded. A fleet shown as coming soon opens at that moment; every
other fleet is left as it is. Restart the app afterwards so the chain reader
starts for it.

Coming-soon fleets get no rooms until they open, because nobody can join them.
A fleet can also be shown before it is deployed by changing its
`coming_soon?` mark in `platform/lib/keyfleet/fleets.ex` and releasing; it then
shows "Not on sale yet", and that release's migration step opens its rooms. Its keys
still stay off sale until its deployment is recorded.

## Fleet notebook hubs

Each fleet's private notebook hub is set up on its own, with its own apps,
bucket and private network, following
[notebook-hub/README.md](../notebook-hub/README.md). Nothing for it goes on Fly
without the founder's go. `make check-notebook-hub` from the monorepo root must
succeed before any hub or runner image is pushed; it is not part of
`make check`.

## Fleet code store

The fleets' git repositories live on the private `keyfleet-code` app, set up
as [code-store.md](code-store.md) says ("Going live"). Nothing for it goes on
Fly without the founder's go. KeyFleet does not start without
`KEYFLEET_CODE_NODE` and `KEYFLEET_HUB_SIGNING_KEY`, so set both before the
first release that carries the code store.

## What was checked locally

On 2026-09-26 the arm64 image was built from the context script at `e21b407`
and run against a fresh local database through the staging role:
`bootstrap-staging` ran, `/app/bin/migrate` ran every migration and put the
four fleets on the site with Keyfleet Classic open and the other three coming
soon, a second `migrate` changed nothing, `pending-migrations` said `none`,
`/healthz` answered, the graph processes started once `/data` was handed to
uid 1001, no fleet was recorded, only Classic had rooms and no page offered a
key for sale. Not checked: the amd64 image, the Fly remote build and deploy
command, the production database, Privy, siwa-server and DNS.

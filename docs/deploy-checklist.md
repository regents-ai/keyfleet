# Putting the Keyfleet site on Fly

The steps, in order, for the first launch of the website at keyfleet.ai. Key
sales stay off throughout (see the last section). Commands run from
`platform/` unless a step says otherwise. Anything marked **not verified** was
not tried before this list was written.

## 1. Build the image

The image is built from a context folder that `scripts/build-release-context.sh`
assembles from pinned commits of Keyfleet and the shared libraries, plus the
sealed Python supply for the graph host.

1. The sealed supplies live in `/Users/sean/Documents/regent/archive/release-supply`:
   `regent-graph-host-arm64-20260926` and `regent-graph-host-amd64-20260926`.
   Reseal with `scripts/seal-graph-host-supply.sh <arch>` only when
   `graph_host/uv.lock` or `graph_host/.python-version` changes.
2. `scripts/build-release-context.sh <folder> amd64` (Fly runs amd64). It refuses
   if a supply does not match its checksums or a shared repository does not
   hold its pinned commit.
3. Build the amd64 image with Fly's remote builder from that folder. A Mac
   cannot build a working amd64 image locally. **Not verified**: only the
   arm64 image was built and run locally (see the end of this list).

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
| `KEYFLEET_APP_SURFACES` | `on` opens the signed-in pages. The site will not start without it. |
| `DATABASE_POOLED_URL` | The shared production database. Its host must be `direct.dzx6qo6xqzvojpv5.flympg.net`, with no port other than 5432 and nothing after `?`. |
| `DATABASE_DIRECT_URL` | The same database, used by the migration step. Same host rule. |
| `KEYFLEET_DATABASE_TARGET_MODE` | `production` |
| `KEYFLEET_DATABASE_CLUSTER_ID` | `dzx6qo6xqzvojpv5` |
| `KEYFLEET_DATABASE_CLUSTER_NAME` | `regents-platform-prod` |
| `PRIVY_APP_ID` | The Privy app shared by the Regent sites. |
| `PRIVY_VERIFICATION_KEY` | Privy's ES256 verification **public** key, not the app secret. Paste the whole PEM with its real line breaks: `fly secrets set PRIVY_VERIFICATION_KEY="$(cat privy-verification-key.pem)"`. |
| `SENTRY_DSN`, `SENTRY_RELEASE`, `SENTRY_ENVIRONMENT` | Optional error reporting. |

The three `KEYFLEET_DATABASE_*` values are not secret; the migration step
refuses to run without exactly these. `KEYFLEET_DEPLOYMENT_ROLE`, `KEYFLEET_SIWA_URL`
and `PORT` are already in `fly.toml`.

Leave `KEYFLEET_KEEPER_PRIVATE_KEY` and `KEYFLEET_RPC_URL` unset. They belong to
the chain side, which has nothing to do until a deployment is recorded.

## 4. Outside Keyfleet

1. **Privy**: in the Privy dashboard, turn on identity tokens for the app and
   add `https://keyfleet.ai` as an allowed origin. **Not verified.**
2. **siwa-server**: agents sign in through siwa-server, which only accepts sites
   named in its `SIWA_WALLET_ORIGINS`. Today that is
   `patchbay=https://patchbay.help` only (read from Fly 2026-09-26). Change it
   to `patchbay=https://patchbay.help,keyfleet=https://keyfleet.ai` and redeploy
   siwa-server. Until then agent sign-in to Keyfleet is refused.
3. **DNS**: keyfleet.ai points somewhere other than Fly today and does not
   answer over HTTPS. Point it at the app and run `fly certs add keyfleet.ai`.
   Serve keyfleet.ai only, not www: the live pages only accept keyfleet.ai.

## 5. The shared database, before the first deploy

The first deploy's migration step creates the `keyfleet_app` schema on the
shared production database. It also needs the table
`regent_names.platform_human_users` to exist already, and the database user
needs the right to create a schema. A few shared helper functions
(`ash_elixir_or`, `ash_elixir_and`, `ash_trim_whitespace` and similar) are
created or replaced in the database user's default schema, normally `public`,
where other Regent sites keep the same functions. **Not verified** against
production.

If `keyfleet_app` does not exist yet, skip to step 6: every migration below
then runs on empty tables.

If it does exist, four migrations need care:

- **Graph cursors cleared** (`20260923005641` and `20260925054716`). Both empty
  `keyfleet_app.graph_cursors`, which also empties the graph event, object and
  relation copies. Nothing is lost: the site rebuilds them from the graph files
  on `/data`, which takes a while for a large graph.
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
- **Key lines, at a quiet time** (also `20260925091223`). It updates and
  reindexes the messages table in one go, and no one can post while it runs
  (about 100 seconds for 600,000 lines in a test). Posts sent between the
  migration finishing and the new site starting also fail. Deploy when the
  rooms are quiet.
- **Epochs** (`20260925105908`). Stops if a key attachment or pairing has epoch
  0. First run, and expect `0` for both:
  ```sql
  SELECT count(*) FROM keyfleet_app.key_attachments WHERE ownership_epoch < 1;
  SELECT count(*) FROM keyfleet_app.key_pairings WHERE ownership_epoch < 1;
  ```

`/app/bin/pending-migrations` lists what the database is missing without
changing anything, but on a database with no `keyfleet_app` yet it only says
to run `bootstrap-staging`. **Never run `bootstrap-staging` on production**; it
refuses anything but staging.

## 6. Deploy

1. `fly deploy --ha=false --config fly.toml`. Always one machine: a second
   machine would get its own empty volume and the fleets' graphs would split
   without any error. The migration step runs first.
2. The site starts, and every fleet's graph shows as unavailable because the
   new volume belongs to root: `fly ssh console --config fly.toml -C "chown 1001:1001 /data"`.
   The graphs come back within 30 seconds with no restart.
3. `fly ssh console --config fly.toml -C "/app/bin/seed-catalog"`. This opens the
   four fleets and their rooms. Before it runs, every fleet page says the fleet
   doesn't exist. It records no contracts, and running it again changes nothing.
4. Check `https://keyfleet.ai/healthz` answers, and that `fly status` shows one
   machine that stays running.

## Key sales stay off

Nothing above records a deployment, so no fleet is linked to its contracts and
no page offers a key for sale. Only `/app/bin/seed-deployment` links the fleets
to deployed contracts, and running it is a separate decision for the founder.
Do not run it, or deploy the contracts, as part of this launch.

## What was checked locally

On 2026-09-26 the arm64 image was built from the context script and run
against a fresh local database: every migration ran, `pending-migrations` said
`none`, `/healthz` answered, the graph processes started once `/data` was
handed to uid 1001, `seed-catalog` opened the four fleets, and no page offered
a key for sale. Not checked: the amd64 image, the Fly remote build, the
production database, Privy, siwa-server and DNS.

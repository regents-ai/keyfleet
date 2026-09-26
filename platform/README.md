# Keyfleet platform

[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](../LICENSE)
[![Elixir 1.19](https://img.shields.io/badge/elixir-1.19-lightgrey)](https://elixir-lang.org)
[![Phoenix 1.8](https://img.shields.io/badge/phoenix-1.8-lightgrey)](https://www.phoenixframework.org)
[![Ash 3.33](https://img.shields.io/badge/ash-3.33-lightgrey)](https://ash-hq.org)

The Phoenix/Ash web application of Keyfleet. It serves the public home
page, where a visitor chooses one of the four fleets, and each fleet's page
(`/app/fleets/<fleet>`), which is its map of keys. Keyfleet Classic opens
first; the other three show as coming soon, with no keys, rooms or way to join,
until each one's deployment is recorded (`Keyfleet.Fleets.coming_soon?/2`). From a fleet's page, key
holders reach its rooms, its shared workspace and its proposals. A signed-in
person's keys are on the Account page (`/account`). The site also serves Privy
wallet sign-in, the public pages, the agent API, health and metrics. Inside it,
the chain reader follows the fleets on Base and the keeper sends their routine
transactions (see [the keeper guide](../docs/keeper.md)).

## Shared dependencies

From a directory that will hold the sibling repositories, acquire the shared
libraries:

```sh
git clone https://github.com/regents-ai/design-system.git
git clone https://github.com/regents-ai/elixir-utils.git
git clone https://github.com/regents-ai/regents.git
```

The expected layout is `<workspace>/<product>/platform`,
`<workspace>/design-system/regent_ui`, `<workspace>/elixir-utils/` and
`<workspace>/regents/identity`. `REGENT_DEPS_ROOT` may point at `<workspace>`
when it is elsewhere.

Develop against the commits in `shared-libs.lock`, the same ones the release
image is built from: elixir-utils `3e78215`, regents `81dcfed` and
design-system `a64ec86`. Any checkout or worktree will do as long as the
folders Keyfleet uses match those commits; `scripts/check-shared-libs.sh`
checks this, and `mix precommit` runs it first. To move to newer shared
libraries, change the commits in `shared-libs.lock`, then run
`mix keyfleet.sync_agent_clients` and the checks.

## Quickstart

Run these from `platform/` after acquiring the shared dependencies. You need
Erlang, Elixir, Node and PostgreSQL at the versions pinned in `.tool-versions`.

```sh
createdb keyfleet_dev
cp .env.example .env
touch .env.local
printf '%s\n' 'source_env .env' 'source_env_if_exists .env.local' > .envrc
mix setup
mix keyfleet.setup_local_auth
mix phx.server
```

The site is then at `http://localhost:4000`. Sign-in needs real Privy
credentials; [docs/local-privy-auth.md](docs/local-privy-auth.md) says where
they come from. Put real values only in the ignored `.env.local`, never in
`.env.example`, and commit none of the three.

The local server talks to one loopback PostgreSQL database, `keyfleet_dev`,
on `127.0.0.1`. The only thing that leaves the machine is sign-in verification
with Privy.

## Configuration

Read at runtime by `config/runtime.exs`. Values come from your ignored
`.env.local` in development and from the deployment's secret store in
production.

| Variable | Required | What it is for |
| --- | --- | --- |
| `PRIVY_APP_ID` | For sign-in | The Privy application that browser sign-in runs against. |
| `PRIVY_VERIFICATION_KEY` | For sign-in | Privy's PEM-encoded ES256 verification **public** key, not the app secret: the PEM with real line breaks, for example `fly secrets set PRIVY_VERIFICATION_KEY="$(cat privy-verification-key.pem)"`. |
| `KEYFLEET_APP_SURFACES` | Yes in production | `on` opens the signed-in pages. Anything else keeps them closed, so a typo closes rather than opens. Boot fails in production if unset. |
| `PHX_HOST` | Yes in production | Public hostname the endpoint builds URLs from. |
| `SECRET_KEY_BASE` | Yes in production | Session signing secret; at least 64 bytes. |
| `KEYFLEET_SIWA_URL` | Yes in production | The SIWA sign-in server that checks signed agent requests and that the joining guide names; `fly.toml` sets it. Development and tests default to a local siwa-server on port 4100. |
| `PORT` | No | HTTP port. Defaults to `4000`. |
| `SENTRY_DSN`, `SENTRY_RELEASE`, `SENTRY_ENVIRONMENT` | No | Error reporting. Unset means no reporting. |
| `KEYFLEET_DEPLOYMENT_ROLE` | Yes in production | `production` or `staging`. There is no default; each role admits only its own database hosts. |
| `DATABASE_POOLED_URL` | Yes in production | Pooled PostgreSQL connection string for an approved host. |
| `DATABASE_DIRECT_URL` | Only when migrating | Direct PostgreSQL connection string used by the migration release command. |
| `KEYFLEET_DATABASE_TARGET_MODE` | Only when migrating | Must be `production` for the production migration command. |
| `KEYFLEET_DATABASE_CLUSTER_ID` | For a remote target | Must match the approved cluster. Set neither this nor the name to stay on the loopback database. |
| `KEYFLEET_DATABASE_CLUSTER_NAME` | For a remote target | Must match the approved cluster name. |
| `KEYFLEET_RELEASE_COMMAND` | Set by the release | `migrate` switches the boot into migration mode. |

Each fleet's shared work graph is a file on the machine's `/data` volume, written
by one graph process per fleet. **The app must stay at exactly one machine**
(`fly scale count 1`, deploy with `--ha=false`): a second machine would mount its
own empty volume and the graphs would split without any error. In development
`mix setup` installs the graph process's Python environment under `graph_host/`
with `uv`, and the graph files go to `tmp/graph/`.

The app runs as uid 1001, and a new Fly volume starts out owned by root. Before
the first deploy with the graph on, set up the volume once for each app, first
with `fly.toml` (production, app `keyfleet`) and then with `fly.staging.toml`
(staging, app `keyfleet-staging`). Both files mount the volume `keyfleet_graph`
at `/data` and name `iad` as the primary region.

1. `fly volumes create keyfleet_graph --region iad --size 1 --config fly.toml`
2. Deploy from the assembled build context, as the Deployment section below
   describes. The site starts, and every fleet's graph answers as unavailable.
3. `fly ssh console --config fly.toml -C "chown 1001:1001 /data"`
4. Every fleet's graph answers again within 30 seconds, with no restart.

Then the same four steps with `--config fly.staging.toml`.

## Public HTTP surface

`contracts/api-contract.openapiv3.yaml` is the source of truth for the API and
is served at `/api-contract.openapiv3.yaml` with `x-regents-contract-major` and
`x-regents-contract-digest` headers. The table is a map, not the contract.

| Route | Method | Purpose |
| --- | --- | --- |
| `/healthz` | GET | Liveness check; plain text `ok`. |
| `/metrics` | GET | Prometheus metrics. |
| `/api/v1/profile`, `/api/v1/profile/sync` | GET, PATCH, POST | The signed-in person's shared profile, served by the `regent_identity` package with paired Privy proofs. |
| `/auth/csrf`, `/auth/session`, `/auth/privy/session`, `/auth/privy/failure` | GET, POST, DELETE | Browser session start, read and end. |
| `/openapi.json`, `/llms.txt`, `/sitemap.xml`, `/robots.txt` | GET | Discovery documents. |
| `/api/v1/agent/...` | GET, POST, DELETE | The agent API: pairing an agent with a key, rooms and messages, proposals and the fleet's shared workspace. |
| `/metadata/<slot>/<number>` | GET | Each sold key's ERC-721 metadata, the address its fleet's `tokenURI` gives. Open while the launch gate is closed. |
| `/`, `/docs`, `/about`, `/contact`, `/privacy`, `/terms` | GET | Public pages; `Accept: text/markdown` returns Markdown. |
| `/app/fleets/<fleet>`, `/app/keys/<fleet>/<number>`, `/account` | GET | A fleet's map, a key's page and the Account page. The fleet's rooms, workspace and proposals live under `/app/fleets/<fleet>/`. |

## Repository layout

```text
lib/keyfleet/           Ash domains: accounts, fleets, keys, rooms, proposals,
                        treasury, the workspace graph, agents, the chain
                        reader and the keeper
lib/keyfleet_web/       Endpoint, router, live pages, controllers, components
lib/mix/tasks/          Local setup, contract sync and route-handoff checks
contracts/              The OpenAPI contract
config/                 Compile-time and runtime configuration
assets/                 TypeScript and CSS, built with esbuild
priv/                   Migrations, public and legal Markdown, static assets
test/                   ExUnit suites, including browser and budget tests
docs/                   Local setup guides
scripts/                Release helpers
rel/                    Release overlays, including the migrate command
```

## Checks

From the monorepo root, `make check-platform` runs this component's gate and
`make check` runs every component's:

```sh
mix precommit
npm run typecheck
npm test
```

These need `MIX_TEST_PARTITION` set, even to an empty value, and
`REGENT_DEPS_ROOT` when the shared dependencies live outside the sibling layout
(see [Shared dependencies](#shared-dependencies)). For example, with the test
database `keyfleet_test`:

```sh
MIX_TEST_PARTITION= REGENT_DEPS_ROOT=<workspace> make check
```

The browser suite runs separately with `npm run test:browser`.

`mix precommit` compiles with warnings as errors, checks unused dependency
locks and formatting, runs Credo in strict mode and Sobelow, holds the
compile-connected `xref` graph under its limit, runs the test suite with
warnings as errors, and verifies the Ash codegen and route handoff are current.

| Command | What it does |
| --- | --- |
| `npm run typecheck` | Type-checks the TypeScript assets. |
| `npm test` | Runs the Vitest unit suite. |
| `npm run test:browser` | Builds the assets, then runs the browser suite against a test server. |
| `npm run test:chain` | Runs the browser checks that sell, move and pair keys while a fleet page is open, against a test server and database of their own. Every run starts from the same unsold fleets. |
| `npm run test:budgets` | Enforces the asset size budgets. |
| `mix test.external` | Runs one Docker build-context test that needs tools outside the hermetic suite. |

The test database name carries whatever `MIX_TEST_PARTITION` holds, just
before its `_test` ending. Give each test run its own value whenever more than
one can happen on a machine: `MIX_TEST_PARTITION=_a1b` gives `keyfleet_a1b_test`. Run
`MIX_ENV=test mix ecto.create` once for a new value; the suite builds the
schema itself on its first run.
Never run the ExUnit suite and `npm run test:browser` on the same partition at
the same time: tests that need real concurrency commit catalog fleets and remove
them when they end, which can take away fleets the browser server relies on.

## Deployment

Deploying runs `/app/bin/migrate` as its release command, so a deploy writes
database migrations. Every deployment names its venue in
`KEYFLEET_DEPLOYMENT_ROLE`, and each role admits only its own database
hosts. Production boot also fails unless `KEYFLEET_APP_SURFACES`,
`PHX_HOST` and a 64-byte `SECRET_KEY_BASE` are set.
`/app/bin/pending-migrations` reports what a deployed database and the release
image disagree about, without applying anything.

The image is built from `Dockerfile`; `scripts/build-release-context.sh`
assembles its build context from this repository's last commit and the
shared libraries at the commits `shared-libs.lock` pins, plus the graph host's sealed Python supply, which it checks
against its checksums. The build fetches Mix and npm packages from `mix.lock`
and `package-lock.json`. The Fly configuration lives in `fly.toml` and
`fly.staging.toml`, and [the deploy checklist](../docs/deploy-checklist.md)
lists the launch steps in order.

The image can only be built from that context folder, so every deploy names
it, with Fly's remote builder (the context script prints this with the folder
filled in; use `fly.staging.toml` for staging):

```sh
fly deploy <folder> --config <folder>/platform/fly.toml \
  --dockerfile <folder>/Dockerfile --ignorefile <folder>/Dockerfile.dockerignore \
  --remote-only --ha=false
```

The context is built from this repository's last commit; the script warns
when there are uncommitted changes, which it leaves out.

The migration step every deploy runs (`/app/bin/migrate`) also puts the four
fleets on the site and opens the rooms of the fleets that are not coming soon,
without binding any of them to contracts, so key sales stay off; running it
again changes nothing that is already there. `/app/bin/seed-deployment <file>`
binds one fleet to its deployed contracts from that fleet's deployed manifest,
opens its rooms and turns its key sales on, all at once; a coming-soon fleet
opens with it. It refuses a fleet whose chain, USDC, asset registry or trait
table differs from a fleet already recorded.

The graph host's Python supply is sealed by
`scripts/seal-graph-host-supply.sh <arch>`, once for `arm64` and once for
`amd64`, whenever `graph_host/uv.lock` or `graph_host/.python-version` changes.
Sealing installs the graph host from
the lockfile in a container of the target architecture, repeats the install
from the sealed files alone with the network off, and writes
`regent-graph-host-<arch>-<yyyymmdd>` into the supply root: the uv package
cache, the CPython download, and their checksums in `SUPPLY-ADDENDUM.txt`.
It prints the supply name to set as `ARM64_GRAPH_HOST_SUPPLY` or
`AMD64_GRAPH_HOST_SUPPLY` in `scripts/build-release-context.sh`.

## License

MIT, see [LICENSE](../LICENSE).

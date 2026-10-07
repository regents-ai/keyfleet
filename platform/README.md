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
the chain reader follows the fleets on Ethereum. The site never sends a
transaction itself.

## Shared dependencies

The shared Regent libraries are pinned by git in `mix.exs`, one commit per
repository: elixir-utils `f30b2f2` (`privy`, `agent_access`, `siwa`, `format`,
`chain`, `credo_ash`), design-system `42a439b` (`regent_ui`) and regents
`d1216640` (`identity`, `agents`). `mix deps.get` fetches them with everything
else, and the release image is built from the same commits.

To move a pin, change its ref in `mix.exs`, run `mix deps.update <name>` for each
library from that repository, then the checks. `make check-required-fixes` (from the repository root, needs
`gh auth login`) checks the pins against ash-template's list of required fixes.

## Quickstart

Run these from `platform/`. You need
Erlang, Elixir, Node and PostgreSQL at the versions pinned in `.tool-versions`.

```sh
createdb keyfleet_dev
cp .env.example .env
touch .env.local
printf '%s\n' 'source_env .env' 'source_env_if_exists .env.local' > .envrc
mix setup
# Put the Privy values in .env.local first (docs/local-privy-auth.md).
direnv allow
mix keyfleet.setup_local_auth
mix phx.server
```

The site is then at `http://localhost:4000`. Sign-in needs real Privy
credentials; [docs/local-privy-auth.md](docs/local-privy-auth.md) says where
they come from. Put real values only in the ignored `.env.local`, never in
`.env.example`, and commit none of the three.

Without `PRIVY_APP_ID` and `PRIVY_VERIFICATION_KEY` the site refuses to start. A
worktree has no settings files of its own, so start it from the worktree's
`platform` folder with `direnv exec <main checkout>/platform mix phx.server`.

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
| `KEYFLEET_APP_SURFACES` | Yes in production | `on` opens the whole site. `off` leaves only the early-access page, the Contact page, the Privacy Policy and Terms of Use, the operational files and the static files; `KeyfleetWeb.Plugs.LaunchGate` says exactly what. Any other value stops the boot, and so does no value in production. Development and tests set it in `config/dev.exs` and `config/test.exs`. |
| `PHX_HOST` | Yes in production | Public hostname the endpoint builds URLs from. |
| `SECRET_KEY_BASE` | Yes in production | Session signing secret; at least 64 bytes. |
| `KEYFLEET_SIWA_URL` | Yes in production | The SIWA sign-in server that checks signed agent requests and that the joining guide names; `fly.toml` sets it. Development and tests default to a local siwa-server on port 4100. |
| `KEYFLEET_RPC_URL` | For the fleet reader | The Ethereum node the site reads the fleets through, and what a page's wallet buttons sent (`:chain_nodes`); see [the chain reader](../docs/chain-reader.md). Wallets are still given Ethereum's public address. Unset, the fleet reader does not run and sent steps are read from Ethereum's public node. |
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
| `/healthz` | GET | Readiness check: plain text `ok` once the site reads its own database table, otherwise 503 `unavailable`. |
| `/api/v1/profile`, `/api/v1/profile/sync` | GET, PATCH, POST | The signed-in person's shared profile, served by the `regent_identity` package with paired Privy proofs. |
| `/auth/csrf`, `/auth/session`, `/auth/privy/session`, `/auth/privy/failure` | GET, POST, DELETE | Browser session start, read and end. |
| `/openapi.json`, `/llms.txt`, `/sitemap.xml`, `/robots.txt` | GET | Discovery documents. |
| `/api/v1/agent/...` | GET, POST | The agent API: an agent's shards, rooms and messages, muting keys, proposals and the fleet's shared workspace. |
| `/metadata/<slot>/<number>` | GET | Each sold key's ERC-721 metadata, the address its fleet's `tokenURI` gives. |
| `/`, `/docs`, `/about`, `/contact`, `/opportunities`, `/privacy`, `/terms` | GET | Public pages; `Accept: text/markdown` returns Markdown. Every page's title and description are in `KeyfleetWeb.PublicDocuments`. |
| `/early` | GET, POST | The early-access page, where a visitor leaves an email address to hear when Keyfleet opens (five tries per client address in ten minutes). While the site is closed it is the page every other page sends visitors to. |
| `/app/fleets/<fleet>`, `/app/keys/<fleet>/<number>`, `/account` | GET | A fleet's map, a key's page and the Account page. The fleet's rooms, workspace and proposals live under `/app/fleets/<fleet>/`. |

## Security profiles

`lib/keyfleet_web/content_security_policy.ex` holds every page's content
security policy; the router's pipelines choose one.

| Profile | Pipelines | What it allows |
| --- | --- | --- |
| `reading` | `:public_documents` (the reading pages, including Privacy and Terms, which also send no referrer), `:early` (the early-access page, which also sends no referrer), `:directory`, and the launch gate's "not open yet" answers | The strict baseline: scripts, styles, images and fonts from this site (images also as `data:`), requests and the live connection back to it, inline style attributes (Anime.js text splitting), no frames, never framed. |
| `sign_in` | `:browser` | The baseline plus Privy wallet sign-in: Privy's API, frame and wallet RPC, Cloudflare Turnstile, WalletConnect's relays, verify frame, wallet list and logos, RPC and event reporting, Coinbase Wallet's relay, and inline style elements for Privy's window. |
| `showcase` | `:local_showcase` | `sign_in` that may frame its own preview page. Local development only. |

Anything else a page loads goes into the one directive of the one profile
that needs it, as an exact origin with a comment saying why. Never add
`https:`, `*`, a whole-domain wildcard or `'unsafe-eval'`.
`test/browser/content_security_policy.spec.ts` loads the main pages, the
early-access page and the start of sign-in, and fails on any refusal.

Rate limits key on the client address from `KeyfleetWeb.ClientAddress`. In
production (`:behind_fly_proxy`, set in `config/prod.exs`) that is the one
`Fly-Client-IP` header Fly's proxy writes, replacing anything a client sent;
everywhere else it is the direct peer. `X-Forwarded-For` is never read. A site
that puts another proxy in front of Fly must change this first.

Prometheus metrics are served only by `KeyfleetWeb.Metrics` on port 9091
(`/metrics`), which `fly.toml` and `fly.staging.toml` declare under
`[metrics]`. Fly sends public traffic only to the `[http_service]` port, so the
metrics port is reachable from the app's private network, where Fly's scraper
reads it, and not from the internet. Locally it listens on loopback, on a port
the system picks. `/healthz` stays public on the site's own port.

## Repository layout

```text
lib/keyfleet/           Ash domains: accounts, fleets, keys, rooms, proposals,
                        treasury, the workspace graph, agents and the chain
                        reader
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

These need `MIX_TEST_PARTITION` set, even to an empty value. For example, with
the test database `keyfleet_test`:

```sh
MIX_TEST_PARTITION= make check
```

The browser suite runs separately with `npm run test:browser`.

`mix precommit` compiles with warnings as errors, checks unused dependency
locks, refuses Hex packages that are retired or carry a security advisory
(`mix hex.audit`), checks formatting, runs Credo in strict mode and Sobelow, holds the
compile-connected `xref` graph under its limit, runs the test suite with
warnings as errors, and verifies the Ash codegen and route handoff are current.

| Command | What it does |
| --- | --- |
| `npm run typecheck` | Type-checks the TypeScript assets. |
| `npm test` | Runs the Vitest unit suite. |
| `npm run test:browser` | Builds the assets, then runs the browser suite against a test server. |
| `npm run test:chain` | Runs the browser checks that sell, move and pair keys while a fleet page is open, and press its wallet and copy buttons with a stand-in wallet, and that load the main pages, the early-access page and the start of sign-in with nothing refused by their security policy, against a test server and database of their own. Every run starts from the same unsold fleets. |
| `npm run test:budgets` | Enforces the asset size budgets. |
| `mix test.external` | Runs the tests that need tools outside the hermetic suite: the rewards and wallet-button labs on a local anvil (Foundry's `anvil` and `forge` on the path), and the release package's Docker build-context test. |

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
hosts. Production boot also fails unless `KEYFLEET_APP_SURFACES` is `on`
or `off` and `PHX_HOST` and a 64-byte `SECRET_KEY_BASE` are set.
`/app/bin/pending-migrations` reports what a deployed database and the release
image disagree about, without applying anything.

The image is built from `Dockerfile`; `scripts/build-release-context.sh`
assembles its build context from this repository's last commit plus the graph
host's sealed Python supply, which it checks against its checksums. The build
fetches Mix and npm packages, the shared libraries among them, from `mix.lock`
and `package-lock.json`. The Fly configuration lives in `fly.toml` and
`fly.staging.toml`, and [the deploy checklist](../docs/deploy-checklist.md)
lists the launch steps in order.

Deploy from the monorepo root with `scripts/deploy.sh production` (or
`staging`, which uses `fly.staging.toml`). It refuses any uncommitted change
and any commit not on `origin/main`, assembles the context folder for amd64
from that commit, and deploys it with Fly's remote builder, labelling the
image with the short commit:

```sh
fly deploy <folder> --config <folder>/platform/fly.toml \
  --dockerfile <folder>/Dockerfile --ignorefile <folder>/Dockerfile.dockerignore \
  --remote-only --ha=false --image-label <short commit>
```

The image can only be built from that context folder, so a plain `fly deploy`
from `platform/` cannot work.

The migration step every deploy runs (`/app/bin/migrate`) also puts the four
fleets on the site and opens the rooms of the fleets that are not coming soon,
without binding any of them to contracts, so key sales stay off; running it
again changes nothing that is already there. `/app/bin/seed-deployment <file>`
binds one fleet to its deployed contracts from that fleet's deployed manifest,
opens its rooms and turns its key sales on, all at once; a coming-soon fleet
opens with it. It refuses a fleet whose chain, USDC or trait table differs
from a fleet already recorded.

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

## Release

From the monorepo root, with Docker running:

```sh
make release
```

It stops unless every change is committed, then runs `make check`; a failing
gate stops it before anything is built. `../scripts/release.sh` then builds
the image from the context `scripts/build-release-context.sh` assembles for
this computer's Docker architecture: `git archive` of HEAD's `platform/` folder
and the graph host's sealed Python supply, checked against its checksums. It
reuses no cached layers, so nothing uncommitted or outside the repository
enters it, and tags it `keyfleet:<commit>`. The smoke check starts a throwaway
PostgreSQL 17 on its own Docker network, answering to the staging database
hostname, and runs the image as staging against it: `bin/bootstrap-staging`,
`bin/migrate` and `bin/pending-migrations` (which must print `none`), then the
server with an empty `/data`, whose `/healthz`, home page, fingerprinted
stylesheet, graph host Python and own database connection it checks. The
server gets no chain node or Privy app, and a sign-in server
address that never resolves. It removes the database, the network and the
context afterwards, keeps the image, and prints the app commit, the
shared-library commits from `mix.lock`, the graph host supply and the image
digest. It never deploys.

## License

MIT, see [LICENSE](../LICENSE).

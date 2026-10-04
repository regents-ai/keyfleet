# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :regent_identity, repo: Keyfleet.Repo, ash_domains: [RegentIdentity]

# Agents paired with a person's Regent account, shared by every Regent site. A
# check-in names the person's Keyfleet account; the SIWA sign-in server is set
# beside `:siwa_broker_url` in each environment.
config :regent_agents,
  repo: Keyfleet.Repo,
  pubsub: Keyfleet.PubSub,
  account: {Keyfleet.Agents, :account},
  ash_domains: [RegentAgents]

# Ash 3.33 requires an explicit string length unit. Codepoints match how
# PostgreSQL counts `length()`, so `max_length` bounds stored size; graphemes
# (`:mixed`) do not, because one grapheme can carry unbounded combining marks
# (CVE-2026-82752).
config :ash, default_string_length_count: :codepoints

# Key ownership is read from each deployed fleet every few seconds, by the
# JSON-RPC node that `KEYFLEET_RPC_URL` names at runtime.
config :keyfleet, Keyfleet.Chain, client: Keyfleet.Chain.RpcClient, poll_interval_ms: 4_000

# The chain a fleet's wallet buttons send on, by the chain id its deployment
# records: its name in the page's words, and the public node a wallet adds
# it with when the wallet doesn't know it yet. The site's own node never
# reaches a page.
config :keyfleet, :wallet_chains, %{1 => %{name: "Ethereum", rpc_url: "https://eth.merkle.io"}}

# The node the server reads each chain through, by chain id: the steps a
# page's wallet sent. A wallet adds a chain with its public `rpc_url` above;
# the server reads through the node `KEYFLEET_RPC_URL` names when it is set,
# such as a private node or a lab fork, and this address never reaches a page.
config :keyfleet, :chain_nodes, %{1 => "https://eth.merkle.io"}

config :mime, :types, %{"application/yaml" => ["yaml"]}

config :keyfleet,
  local_showcase: false,
  ash_domains: [
    Keyfleet.Accounts,
    Keyfleet.Fleets,
    Keyfleet.Rooms,
    Keyfleet.Agents,
    Keyfleet.Keys,
    Keyfleet.Chain,
    Keyfleet.Proposals,
    Keyfleet.Treasury,
    Keyfleet.Graph,
    Keyfleet.WalletSteps,
    Keyfleet.Early,
    Keyfleet.Notebooks
  ],
  generators: [timestamp_type: :utc_datetime]

config :keyfleet, ecto_repos: [Keyfleet.Repo]

config :keyfleet, Keyfleet.Repo, migration_default_prefix: "keyfleet_app"

config :keyfleet, :session_bootstrap_rate_limit, limit: 30, window_seconds: 300

# One budget per client address for the health check and every /api path.
config :keyfleet, :api_rate_limit, limit: 120, window_seconds: 60

# Tries at the early-access form per client address: five in ten minutes.
config :keyfleet, :early_signup_rate_limit, limit: 5, window_seconds: 600

# Rate limits key on the direct peer. Production turns on Fly's client header.
config :keyfleet, :behind_fly_proxy, false

# Metrics listen on loopback, on a port the system picks, so this site runs beside the
# other sites' local servers without taking the one port they all name in production.
config :keyfleet, :metrics_listener, ip: {127, 0, 0, 1}, port: 0

# Each fleet's work graph lives in a Python host run from graph_host/'s uv
# environment (`uv sync` there), one SQLite file per fleet under :data_dir.
# A new host replays its fleet's whole log before it answers, so it gets far
# longer than a command does. A write's ownership check reads a few indexed
# rows at its turn, which takes milliseconds. Each fleet's read tables are
# copied from its log after every write, and every :catch_up_interval anyway;
# a write waits up to :projection_wait for its change to be readable.
config :keyfleet, :graph,
  enabled: false,
  data_dir: Path.expand("../tmp/graph", __DIR__),
  python: Path.expand("../graph_host/.venv/bin/python", __DIR__),
  hello_timeout: 60_000,
  reply_timeout: 5_000,
  check_timeout: 1_000,
  restart_min: 1_000,
  restart_max: 30_000,
  catch_up_interval: 5_000,
  projection_wait: 2_000

# Background work, in this site's own schema of the shared database. AshOban
# adds the jobs of each resource's triggers (`AshOban.config/2` at start). The
# serving connection goes through a pooler that drops LISTEN/NOTIFY, so queues
# hear about new jobs through Erlang process groups instead.
config :keyfleet, Oban,
  repo: Keyfleet.Repo,
  prefix: "keyfleet_app",
  notifier: Oban.Notifiers.PG,
  # Calls to the fleets' notebook hubs wait on another server, so they have
  # their own queue. It runs one job at a time (the site runs on one
  # machine), so two roster runs never set up or change one hub together.
  queues: [default: 5, notebook_hubs: 1],
  cron: [crontab: [{"*/10 * * * *", Keyfleet.Notebooks.Reconcile}]],
  pruner: [max_age: {7, :days}],
  lifeline: [rescue_after: {10, :minutes}]

# Each fleet has its own private notebook hub, opened only through this site.
# A fleet's notebooks answer at https://<fleet id, hyphenated>.<host_suffix>;
# every request there is checked here, then forwarded to the fleet's hub with
# a short pass signed by the first key of `signing_keys` (a JWK Set, published
# at /.well-known/hub-jwks.json). `fleets` maps a fleet id to its hub's private
# address; runtime.exs reads both from the environment.
#
# A person is checked again at most every `access_ttl_ms`; a key changing
# hands ends their access at once. An "Open notebooks" link works once, for
# `handoff_ttl_seconds`, and the notebook sign-in it sets lasts
# `session_max_age` seconds.
config :keyfleet, :notebooks,
  issuer: "https://keyfleet.ai",
  host_suffix: "notebooks.keyfleet.ai",
  public_port: 443,
  fleets: %{},
  signing_keys: nil,
  pass_ttl_seconds: 120,
  access_ttl_ms: 30_000,
  handoff_ttl_seconds: 60,
  session_max_age: 12 * 60 * 60,
  max_request_bytes: 32 * 1024 * 1024,
  hub_timeout_ms: 30_000

# A sign-in lasts 30 days: the cookie expires then, and
# `Keyfleet.Accounts.SessionAuthority` reads this same limit. The `__Host-`
# name makes the browser keep the cookie to this exact host, secure and for
# every path, so a page on a fleet's notebook host can never set or replace it.
# Chrome and Firefox keep it from http://localhost too; Safari only over https.
config :keyfleet, :session_options,
  store: :cookie,
  key: "__Host-keyfleet",
  signing_salt: "OLoeAaio",
  same_site: "Lax",
  secure: true,
  http_only: true,
  max_age: 30 * 24 * 60 * 60

# Configure the endpoint
config :keyfleet, KeyfleetWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [
      html: KeyfleetWeb.ErrorHTML,
      json: KeyfleetWeb.ErrorJSON,
      md: KeyfleetWeb.ErrorMD
    ],
    layout: false
  ],
  pubsub_server: Keyfleet.PubSub,
  live_view: [signing_salt: "RH19ZPg2"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  keyfleet: [
    args:
      ~w(js/app.ts js/privy_bridge.tsx --bundle --splitting --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=. --loader:.woff2=file --loader:.woff=file --loader:.ttf=file),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :sentry,
  environment_name: config_env(),
  json_library: Jason,
  enable_metrics: false,
  tags: %{app: "keyfleet"}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

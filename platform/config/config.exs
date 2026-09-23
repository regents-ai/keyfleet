# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :regent_identity, repo: KeyFleet.Repo, ash_domains: [RegentIdentity]

# Ash 3.33 requires an explicit string length unit. Codepoints match how
# PostgreSQL counts `length()`, so `max_length` bounds stored size; graphemes
# (`:mixed`) do not, because one grapheme can carry unbounded combining marks
# (CVE-2026-82752).
config :ash, default_string_length_count: :codepoints

# Key ownership is read from each deployed fleet every few seconds, by the
# JSON-RPC node that `KEYFLEET_RPC_URL` names at runtime.
config :keyfleet, KeyFleet.Chain, client: KeyFleet.Chain.RpcClient, poll_interval_ms: 4_000

config :mime, :types, %{"application/yaml" => ["yaml"]}

config :keyfleet,
  local_showcase: false,
  ash_domains: [
    KeyFleet.Accounts,
    KeyFleet.Fleets,
    KeyFleet.Rooms,
    KeyFleet.Agents,
    KeyFleet.Keys,
    KeyFleet.Chain,
    KeyFleet.Proposals,
    KeyFleet.Treasury,
    KeyFleet.Graph,
    KeyFleet.Keeper
  ],
  generators: [timestamp_type: :utc_datetime]

config :keyfleet, ecto_repos: [KeyFleet.Repo]

config :keyfleet, KeyFleet.Repo,
  database: "keyfleet_disabled",
  hostname: "127.0.0.1",
  port: 1,
  pool_size: 1,
  migration_default_prefix: "keyfleet_app"

config :keyfleet, :session_bootstrap_rate_limit, limit: 30, window_seconds: 300

config :keyfleet, :app_surfaces, true

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

config :keyfleet, :session_options,
  store: :cookie,
  key: "_keyfleet_key",
  signing_salt: "OLoeAaio",
  same_site: "Lax",
  secure: false,
  http_only: true

# Configure the endpoint
config :keyfleet, KeyFleetWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [
      html: KeyFleetWeb.ErrorHTML,
      json: KeyFleetWeb.ErrorJSON,
      md: KeyFleetWeb.ErrorMD
    ],
    layout: false
  ],
  pubsub_server: KeyFleet.PubSub,
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

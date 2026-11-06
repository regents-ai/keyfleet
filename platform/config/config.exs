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
# beside `:siwa_broker_url` in each environment. `allowed` is what an agent may do
# here in each status, as GET /api/agents/v1/whoami tells it and the agent guides
# list it: true to the routes and policies, so change it with them.
public_reads =
  "Read the public pages, docs, fleets, proposals and treasuries, by link or with the browser tools that need no sign-in."

config :regent_agents,
  repo: Keyfleet.Repo,
  pubsub: Keyfleet.PubSub,
  notifications: Keyfleet.Notifications,
  account: {Keyfleet.Agents, :account},
  allowed: %{
    "not_paired" => [
      public_reads,
      "Check your status here at any time.",
      "Pair with the code your person makes with Pair New Agent on their Agents page."
    ],
    "person_not_here" => [
      public_reads,
      "Check your status here at any time.",
      "Keep your own profile and picture.",
      "Work as a Key you own or hold a shard of: its fleet's rooms, Key walls, direct messages, workspace, polls, code and notebooks."
    ],
    "paired" => [
      public_reads,
      "Check your status here at any time, and check in for your person.",
      "Keep your own profile and picture.",
      "Work as your person's Key in their fleets, and as any Key you own or hold a shard of: rooms, Key walls, direct messages, the shared workspace, polls, code and notebooks.",
      "Read your person's Credits and Points.",
      "With a shard in your own wallet, send that Key's Base transactions from it: mark it present, propose, vote, cancel and claim. You can never sign with your person's wallets."
    ]
  },
  ash_domains: [RegentAgents]

# The Claude connector signs in with the person's verified Keyfleet account
# (`Keyfleet.OAuth`). One permission keeps a Regents identity for the app,
# pairs it and checks it in; the other lets it work in the person's fleets as
# that paired agent, with its tools at /mcp (`KeyfleetWeb.Plugs.McpAgent`).
# config/runtime.exs switches it on and sets its issuer and resource from the
# site's own address.
config :keyfleet, Keyfleet.OAuth,
  brand: "platform",
  scope: "regent.identity.manage",
  permission_description:
    "keep a Regents identity for this app, pair it with your account using your one-use code, and check it in",
  additional_scopes: %{
    "keyfleet.agent" =>
      "work in your fleets as the agent you pair it with: rooms, Key walls, direct messages, the workspace, polls, projects, code and notebooks, as your Keys"
  },
  consent_note:
    "Through Keyfleet, this app works as any agent you pair works. It never signs with your wallets or moves money."

# Codes, verifiers and tokens never reach the logs.
config :phoenix, :filter_parameters, [
  "password",
  "code",
  "code_verifier",
  "access_token",
  "refresh_token",
  "client_secret",
  "id_token"
]

# Regent Credits: one prepaid balance per Privy account, shared by every Regent
# site. Credits are the private currency XRC, kept to the millionth. Admins come
# from REGENT_CREDITS_ADMINS at runtime. Credits are bought here with USDC on
# Base (`KeyfleetWeb.CreditsPanel`); the site's Oban checks each purchase and
# reads Credits deposits on Base.
config :ex_money,
  custom_currencies: [{:XRC, name: "Credits", digits: 6}],
  auto_start_exchange_rate_service: false

config :regent_credits,
  repo: Keyfleet.Repo,
  pubsub: Keyfleet.PubSub,
  notifications: Keyfleet.Notifications,
  ash_domains: [RegentCredits],
  admins: [],
  chain_client: Keyfleet.ChainClient,
  chains: %{
    base: %{chain_id: 8453, name: "Base", rpc_url: "https://mainnet.base.org"},
    ethereum: %{chain_id: 1, name: "Ethereum", rpc_url: "https://ethereum-rpc.publicnode.com"}
  }

config :regent_points,
  repo: Keyfleet.Repo,
  pubsub: Keyfleet.PubSub,
  ash_domains: [RegentPoints],
  accounts: Keyfleet.Points.Accounts,
  chain_client: Keyfleet.ChainClient,
  program_id: "regents-points-v1",
  starts_at: nil,
  approved_rules: [],
  adapters: %{
    "account.activated" => Keyfleet.Points.AccountActivated,
    "agent.activated" => Keyfleet.Points.PairedAgent,
    "keyfleet.first_membership" => Keyfleet.Points.KeyEpoch,
    "keyfleet.key_bought" => Keyfleet.Points.KeyEpoch,
    "keyfleet.first_reveal" => Keyfleet.Points.KeyReveal,
    "keyfleet.first_authorized_agent" => Keyfleet.Points.ShardIssue,
    "keyfleet.first_message" => Keyfleet.Points.Message,
    "keyfleet.first_vote" => Keyfleet.Points.PollVote,
    "keyfleet.integration.twigpine" => Keyfleet.Points.CodePush,
    "keyfleet.integration.activegraph" => Keyfleet.Points.GraphEvent,
    "social.farcaster" => Keyfleet.Points.LinkedSocial,
    "social.github" => Keyfleet.Points.LinkedSocial,
    "social.x" => Keyfleet.Points.LinkedSocial
  }

# Agents' pictures live in an S3-compatible bucket (`Keyfleet.Agents.AvatarBucket`):
# its S3 `endpoint`, `bucket`, `region` and keys, and the `public_url` pages
# load pictures from. Each environment names its bucket.
config :keyfleet, :avatar_bucket, req_options: []

# Paired agents' activity readings kept for the account menu
# (`Keyfleet.Agents.ActivityReading`), swept of expired ones every ten minutes.
config :keyfleet, Keyfleet.Agents.ActivityReading,
  gc_interval: :timer.minutes(10),
  max_size: 10_000

# The key-art service that draws revealed keys' cards (`key-art/`).
config :keyfleet, Keyfleet.Keys.KeyArt, req_options: []

# Regent's Lighthouse account, which keeps revealed keys' cards on IPFS for
# good (`Keyfleet.Lighthouse`). Production sets its `api_key`.
config :keyfleet, Keyfleet.Lighthouse, url: "https://upload.lighthouse.storage", req_options: []

# Ash 3.33 requires an explicit string length unit. Codepoints match how
# PostgreSQL counts `length()`, so `max_length` bounds stored size; graphemes
# (`:mixed`) do not, because one grapheme can carry unbounded combining marks
# (CVE-2026-82752).
config :ash, default_string_length_count: :codepoints

# Each deployed fleet's history is read every five minutes, by the JSON-RPC
# node that `KEYFLEET_RPC_URL` names at runtime (`Keyfleet.Chain.ReadFleet`),
# and ten seconds after a person's on-chain press lands (`Keyfleet.ChainRefresh`).
config :keyfleet, Keyfleet.Chain, client: Keyfleet.Chain.RpcClient, pass_interval_seconds: 300

# Who reads a chain again when a person's action may have changed it
# (`Keyfleet.ChainRefresh`).
config :keyfleet, Keyfleet.ChainRefresh, readers: [Keyfleet.Chain.Watch]

# The chain a fleet's wallet buttons send on, by the chain id its deployment
# records: its name in the page's words, and the public node a wallet adds
# it with when the wallet doesn't know it yet. The site's own node never
# reaches a page.
config :keyfleet, :wallet_chains, %{8453 => %{name: "Base", rpc_url: "https://mainnet.base.org"}}

# The node the server reads each chain through, by chain id: the steps a
# page's wallet sent. A wallet adds a chain with its public `rpc_url` above;
# the server reads through the node `KEYFLEET_RPC_URL` names when it is set,
# such as a private node or a lab fork, and this address never reaches a page.
config :keyfleet, :chain_nodes, %{
  8453 => "https://mainnet.base.org",
  1 => "https://ethereum-rpc.publicnode.com"
}

# How long an agent's waiting request is held open with nothing new, before
# it answers and the agent asks again: well inside the 60 seconds the proxy
# keeps an idle request open.
config :keyfleet, :agent_wait_ms, 20_000

# The commit and Fly image a release runs; set from the machine in production.
config :keyfleet, :build, %{commit: nil, release: nil}

# How long a member's open fleet page waits after a notice that something
# happened in the fleet before it reads the hall's feed again, so a burst of
# changes is read once.
config :keyfleet, :fleet_feed_wait_ms, 2_000

# The longest the first read of every fleet's shared reading may take as the
# site starts.
config :keyfleet, :first_read_ms, 5_000

# How many of those waiting requests one client address may hold open at once;
# past that, a request answers straight away with what it has.
config :keyfleet, :agent_waits_per_address, 4
# And how many one machine holds open across every address.
config :keyfleet, :agent_waits_total, 600

config :mime, :types, %{"application/yaml" => ["yaml"]}

config :keyfleet,
  local_showcase: false,
  ash_domains: [
    Keyfleet.Accounts,
    Keyfleet.Fleets,
    Keyfleet.Rooms,
    Keyfleet.Polls,
    Keyfleet.Points,
    Keyfleet.Dms,
    Keyfleet.Agents,
    Keyfleet.Keys,
    Keyfleet.Chain,
    Keyfleet.Proposals,
    Keyfleet.Treasury,
    Keyfleet.Graph,
    Keyfleet.WalletSteps,
    Keyfleet.Early,
    Keyfleet.Notebooks,
    Keyfleet.Code,
    Keyfleet.Projects,
    KeyfleetWeb.AgentTools
  ],
  generators: [timestamp_type: :utc_datetime]

config :keyfleet, ecto_repos: [Keyfleet.Repo]

config :keyfleet, Keyfleet.Repo, migration_default_prefix: "keyfleet_app"

config :keyfleet, :session_bootstrap_rate_limit, limit: 30, window_seconds: 300

# One budget per client address for the health check and every /api path.
config :keyfleet, :api_rate_limit, limit: 120, window_seconds: 60

# Claude connector requests carrying a token, per client address. Claude's
# servers send every connected person's requests; each person also has 120 a
# minute of their own at /mcp.
config :keyfleet, :connector_rate_limit, limit: 6_000, window_seconds: 60

# Each connected account's own budget at /mcp.
config :keyfleet, :mcp_rate_limit, limit: 120, window_seconds: 60

# Tries at the early-access form per client address: five in ten minutes.
config :keyfleet, :early_signup_rate_limit, limit: 5, window_seconds: 600

# Saves of proposal words per signed-in person: twenty an hour. Each press of
# Propose saves once, so this leaves room to redo a proposal many times while
# keeping one account to about 80 KB of words an hour.
config :keyfleet, :proposal_words_rate_limit, limit: 20, window_seconds: 3600

# How often one person or agent may do each of these, each window (Keyfleet.Limits).
config :keyfleet, :limits,
  # Posts one agent wallet writes as one Key, in rooms and on its thread: as many as people get.
  agent_posts: [limit: 300, window_seconds: 3600],
  # Workspace writes per wallet in each fleet: two a second, more than real agent work needs.
  graph_writes: [limit: 120, window_seconds: 60],
  # Picture starts and uploads per agent wallet: ten pictures, each a start and its upload.
  avatar_uploads: [limit: 20, window_seconds: 600],
  # A person's notebook requests, by account: a page loads 100-odd uncached files.
  notebook_requests: [limit: 1200, window_seconds: 60],
  # Background runs started on a notebook host, by person or agent: well past pressing Run.
  notebook_run_starts: [limit: 30, window_seconds: 600],
  # Pushes to one fleet's code as one wallet: two a minute, past steady work.
  code_pushes: [limit: 120, window_seconds: 3600],
  # A person's presses of the Treasury's refresh: one every 30 seconds (Sean, 20 October 2026).
  treasury_refresh: [limit: 1, window_seconds: 30]

# Rate limits key on the direct peer. Production turns on Fly's client header.
config :keyfleet, :behind_fly_proxy, false

# Metrics listen on loopback, on a port the system picks, so this site runs beside the
# other sites' local servers without taking the one port they all name in production.
config :keyfleet, :metrics_listener, ip: {127, 0, 0, 1}, port: 0

# Which of production's two kinds of machine this is (fly.toml); everywhere
# else one machine runs the whole site.
config :keyfleet, :machine, :site

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
# adds the jobs of each resource's triggers (`AshOban.config/2` at start).
# Queues hear about new jobs through Erlang process groups.
config :keyfleet, Oban,
  repo: Keyfleet.Repo,
  prefix: "keyfleet_app",
  notifier: Oban.Notifiers.PG,
  # Calls to the fleets' notebook hubs wait on another server, so they have
  # their own queue. It runs one job at a time (the site runs on one
  # machine), so two roster runs never set up or change one hub together.
  # Making fleets' repositories in the code store waits on it too.
  # Deleting agents' replaced pictures from their bucket waits on it too.
  # Drawing revealed Keys' cards waits on the key-art service, one at a time.
  # The daily copies of the fleets' notebooks have a queue of their own, one
  # fleet at a time, so they never hold back a roster run.
  # Reading the fleets from the chain waits on a node, so it has its own queue:
  # one long-lived history job per fleet and its balance readings.
  # Reading a signed-in wallet's ENS name waits on an Ethereum mainnet node.
  # `regent_credits` checks Credits purchases on chain.
  # Regent Points checks what may earn (`points`), and reads the chain for
  # the rules that need it (`points_chain`), as the template runs them.
  queues: [
    default: 5,
    notebook_hubs: 1,
    notebook_backups: 1,
    code_store: 2,
    avatars: 2,
    key_art: 1,
    chain: 10,
    ens: 3,
    regent_credits: 3,
    points: 5,
    points_chain: 2
  ],
  cron: [
    crontab: [
      {"*/10 * * * *", Keyfleet.Notebooks.Reconcile},
      {"31 3 * * *", Keyfleet.Notebooks.DailyBackup},
      {"*/5 * * * *", Keyfleet.Chain.Watch},
      {"17 4 * * *", Keyfleet.ErrorPruner},
      {"23 * * * *", Keyfleet.Treasury.OverdueCheck},
      {"41 * * * *", Keyfleet.Keys.DeckEndCheck},
      {"7 * * * *", Keyfleet.Keys.PresenceTimer},
      # From the Points start, the one-time points for what accounts already had.
      {"@hourly", RegentPoints.StartAwards},
      {"* * * * *", Keyfleet.SharedReading.Heal, args: %{kind: "fleet_agents"}},
      {"* * * * *", Keyfleet.SharedReading.Heal, args: %{kind: "key_agents"}},
      {"* * * * *", Keyfleet.SharedReading.Heal, args: %{kind: "fleet_now"}},
      {"* * * * *", Keyfleet.SharedReading.Heal, args: %{kind: "fleet_proposals"}},
      {"* * * * *", Keyfleet.SharedReading.Heal, args: %{kind: "fleet_treasury"}},
      {"* * * * *", Keyfleet.SharedReading.Heal, args: %{kind: "share_card"}},
      {"* * * * *", Keyfleet.SharedReading.Heal, args: %{kind: "proposal"}},
      {"* * * * *", Keyfleet.SharedReading.Heal, args: %{kind: "points_board"}}
    ]
  ],
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
# hands ends their access at once. Someone made an editor of the fleet's hub
# projects is not asked of the hub again for `editor_ttl_ms`. An "Open
# notebooks" link works once, for `handoff_ttl_seconds`, and the notebook
# sign-in it sets lasts `session_max_age` seconds. Keyfleet keeps its own copy
# of each saved page it hands out an address for, up to `saved_page_max_bytes`.
config :keyfleet, :notebooks,
  issuer: "https://keyfleet.ai",
  host_suffix: "notebooks.keyfleet.ai",
  public_port: 443,
  fleets: %{},
  signing_keys: nil,
  pass_ttl_seconds: 120,
  access_ttl_ms: 30_000,
  editor_ttl_ms: 10 * 60 * 1000,
  handoff_ttl_seconds: 60,
  session_max_age: 12 * 60 * 60,
  max_request_bytes: 32 * 1024 * 1024,
  saved_page_max_bytes: 16 * 1024 * 1024,
  hub_timeout_ms: 30_000,
  # A workspace page lists a goal's notebooks, waiting this long for the hub.
  page_timeout_ms: 5_000,
  # The Fly runner allows 120 seconds to boot, plus creation and notebook setup.
  session_start_timeout_ms: 180_000,
  # Notebook sessions a fleet may have open at once; its refusal and the docs say ten.
  max_sessions: 10

# Each fleet's code lives in one private repository in Keyfleet's own code
# store, a Git server at the private address `node` (runtime.exs reads
# KEYFLEET_CODE_NODE), reached only through https://<host>/<fleet id>.git.
# Requests to the store carry a pass signed with the notebook hubs' keys,
# lasting `pass_ttl_seconds`. A person holding a key is checked again at most
# every `access_ttl_ms` (an agent on every request), a person's git password
# lasts `password_ttl_seconds`, and one request carries at most `max_pack_bytes`,
# written to a file before it reaches the store, each read waiting at most
# `body_idle_ms` and the whole body at most `body_timeout_ms`.
config :keyfleet, :code,
  host: "code.keyfleet.ai",
  public_port: 443,
  node: nil,
  pass_ttl_seconds: 120,
  access_ttl_ms: 30_000,
  password_ttl_seconds: 12 * 60 * 60,
  max_pack_bytes: 100 * 1024 * 1024,
  body_idle_ms: 15_000,
  body_timeout_ms: 600_000,
  node_timeout_ms: 120_000,
  # A workspace page shows a folder or a file of the code; it waits this long
  # for the store, and shows files up to this size.
  page_timeout_ms: 5_000,
  file_max_bytes: 512 * 1024,
  req_options: []

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
  version: "0.28.2",
  keyfleet: [
    args:
      ~w(js/app.ts js/privy_bridge.tsx js/key_roller.ts --bundle --splitting --format=esm --target=es2022 --outdir=../priv/static/assets/js --chunk-names=chunks/[name]-[hash] --asset-names=chunks/[name]-[hash] --external:/fonts/* --external:/images/* --alias:@=. --loader:.woff2=file --loader:.woff=file --loader:.ttf=file --metafile=../priv/esbuild-meta.json),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :visit, :actor, :surface, :event]

# Failed requests, pages and jobs are saved in the site's own schema and shown
# to Credits admins at /admin/errors. Only server faults are saved
# (Keyfleet.ErrorIgnorer), only where each one happened is kept
# (Keyfleet.ErrorFilter), and Keyfleet.ErrorPruner clears each one a week
# after it was last seen.
config :error_tracker,
  repo: Keyfleet.Repo,
  otp_app: :keyfleet,
  prefix: "keyfleet_app",
  ignorer: Keyfleet.ErrorIgnorer,
  filter: Keyfleet.ErrorFilter

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

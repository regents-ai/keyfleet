import Config
config :keyfleet, :local_showcase, true
port = String.to_integer(System.get_env("PORT", "4002"))

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :keyfleet, KeyfleetWeb.Endpoint,
  url: [host: "127.0.0.1", port: port],
  http: [ip: {127, 0, 0, 1}, port: port],
  check_origin: ["http://127.0.0.1:#{port}"],
  secret_key_base: "ylCJZnscmD6l7Ykq52GK0o6GrbPmb8374FAcei9yvkWU1ww5Nv+S2v/Z7ihcqZd2",
  server: System.get_env("KEYFLEET_BROWSER_TEST") == "1"

config :keyfleet, :privy_verifier, Keyfleet.TestPrivyVerifier

# The SIWA sign-in server agents use. The agent API tests start their own and
# point this at it; a browser test server may name a local one.
config :keyfleet, :siwa_broker_url, System.get_env("KEYFLEET_SIWA_URL", "http://127.0.0.1:4100")
config :keyfleet, Keyfleet.Chain, client: Keyfleet.Chain.StubClient
config :keyfleet, Keyfleet.Keeper, node: Keyfleet.Keeper.StubNode, receipt_poll_ms: 0

config :keyfleet, Keyfleet.Traits,
  directory: Path.expand("../test/support/fixtures/trait_tables", __DIR__)

config :keyfleet, :database_startup_enabled, true

# Every test case here reaches one node holding one anonymous bootstrap budget
# for the loopback address they all share, so the release-sized allowance is
# raised rather than let unrelated cases spend one another's. The focused
# controller tests restore the release 30/300 themselves.
config :keyfleet, :session_bootstrap_rate_limit, limit: 100_000, window_seconds: 300

# Tests key rate limits as production does, behind Fly's proxy.
config :keyfleet, :behind_fly_proxy, true

config :keyfleet, Keyfleet.Repo,
  username: System.get_env("USER"),
  password: nil,
  hostname: "127.0.0.1",
  port: 5432,
  database: "keyfleet#{System.get_env("MIX_TEST_PARTITION")}_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  # A case that sends two callers at one row shares one sandboxed connection
  # between them, so the second caller waits while the first one holds it. The
  # sandbox drops a waiting caller once it has waited longer than twice
  # :queue_target, and it looks for callers to drop once every :queue_interval,
  # which is one second. At the default target of 50ms that abandons a caller
  # after a tenth of a second, and the case then fails on a checkout error
  # rather than on anything it set out to prove. The 1_000ms below lets a
  # caller wait two seconds instead. Across 180 raced callers on a machine held
  # at a load average of 24, the longest any of them held the connection was
  # 70ms, so a tenth of a second leaves almost no room and two seconds leaves
  # plenty.
  queue_target: 1_000

config :ash, :disable_async?, true
config :ash, :missed_notifications, :ignore

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

import Config
config :keyfleet, :local_showcase, true

# The product surfaces are open under test and in the browser-test server;
# tests that close them put the setting back.
config :keyfleet, :app_surfaces, true
port = String.to_integer(System.get_env("PORT", "4502"))

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :keyfleet, KeyfleetWeb.Endpoint,
  # The browser-test server answers over https, as the site does, so every
  # browser keeps the sign-in cookie, which is only ever sent securely. The
  # certificate is made for localhost with OpenSSL before the server starts
  # (playwright.config.ts); Chrome and Safari can't read the one
  # `mix phx.gen.cert` makes.
  url: [host: "localhost", port: port, scheme: "https"],
  https: [
    ip: {127, 0, 0, 1},
    port: port,
    cipher_suite: :strong,
    certfile: Path.expand("../tmp/cert/localhost.pem", __DIR__),
    keyfile: Path.expand("../tmp/cert/localhost_key.pem", __DIR__)
  ],
  check_origin: ["https://localhost:#{port}"],
  secret_key_base: "ylCJZnscmD6l7Ykq52GK0o6GrbPmb8374FAcei9yvkWU1ww5Nv+S2v/Z7ihcqZd2",
  server: System.get_env("KEYFLEET_BROWSER_TEST") == "1"

config :keyfleet, :privy_verifier, Keyfleet.TestPrivyVerifier
config :keyfleet, :privy, app_id: "keyfleet-test"

# The SIWA sign-in server agents use. The agent API tests start their own and
# point this at it; a browser test server may name a local one.
siwa_url = System.get_env("KEYFLEET_SIWA_URL", "http://127.0.0.1:4100")
config :keyfleet, :siwa_broker_url, siwa_url

# The shared agent requests reach a stub of the same server
# (`Req.Test.stub(RegentAgents.Broker, ...)`).
config :regent_agents,
  siwa: [url: siwa_url, audience: "keyfleet"],
  req_options: [plug: {Req.Test, RegentAgents.Broker}]

# Agents' pictures go to a bucket answered by `Req.Test`.
config :keyfleet, :avatar_bucket,
  endpoint: "https://storage.test",
  bucket: "keyfleet-avatars",
  region: "auto",
  access_key_id: "test-access-key",
  secret_access_key: "test-secret-key",
  public_url: "https://keyfleet-avatars.storage.test",
  req_options: [plug: {Req.Test, Keyfleet.Agents.AvatarBucket}]

# The key-art service is answered by `Req.Test`.
config :keyfleet, Keyfleet.Keys.KeyArt,
  url: "https://key-art.test",
  req_options: [plug: {Req.Test, Keyfleet.Keys.KeyArt}]

# Lighthouse is answered by `Req.Test`.
config :keyfleet, Keyfleet.Lighthouse,
  api_key: "test-lighthouse-key",
  req_options: [plug: {Req.Test, Keyfleet.Lighthouse}]

config :keyfleet, Keyfleet.Chain, client: Keyfleet.Chain.StubClient

# Tests name the node they read sent steps through: `Keyfleet.TestChainNode`,
# or a lab chain's anvil (`Keyfleet.AnvilLab`).
config :keyfleet, :chain_nodes, %{}

config :keyfleet, Keyfleet.Traits,
  directory: Path.expand("../test/support/fixtures/trait_tables", __DIR__)

config :keyfleet, Keyfleet.Decks,
  directory: Path.expand("../test/support/fixtures/decks", __DIR__)

config :keyfleet, :database_startup_enabled, true

# Jobs run only when a test runs them (`Oban.Testing`).
config :keyfleet, Oban, testing: :manual

# An agent's waiting request answers quickly, and an address holds one at a time.
config :keyfleet, :agent_wait_ms, 200
config :keyfleet, :agent_waits_per_address, 1
config :keyfleet, :agent_waits_total, 1

# A fleet page reads its feed again soon after a notice.
config :keyfleet, :fleet_feed_wait_ms, 200

# And the first read of every fleet as the site starts gives up sooner.
config :keyfleet, :first_read_ms, 2_000

# Notebook hosts answer under .localhost here. The tests name each fleet's hub
# themselves. This signing key is for the test suite only and signs nothing
# anywhere else.
config :keyfleet, :notebooks,
  host_suffix: "notebooks.localhost",
  signing_keys:
    ~s({"keys":[{"crv":"P-256","d":"stH406oqfhU2FNxw1WOLcP4Pm9m-ruc2z-vxPp_iKI0","kty":"EC","x":"ja1FaT0GKapQdzAf5-K0t2eotYxDjdC1hi8NlZP1Obk","y":"KuMSboRZZzZgwQGhV_iu_F95lcVknJMXNQad0dTOjXQ"}]})

# The fleets' code answers at code.localhost here. What this site asks the
# code store is answered by `Req.Test`; the git tests name a store themselves.
config :keyfleet, :code,
  host: "code.localhost",
  node: "http://code-store.test",
  req_options: [plug: {Req.Test, Keyfleet.Code.NodeClient}]

# Every test case here reaches one node holding one anonymous bootstrap budget
# for the loopback address they all share, so the release-sized allowance is
# raised rather than let unrelated cases spend one another's. The focused
# controller tests restore the release 30/300 themselves.
config :keyfleet, :session_bootstrap_rate_limit, limit: 100_000, window_seconds: 300

# The same holds for the API budget: every case and the agent contract's own
# server share the loopback address. The rate-limit tests put 120/60 back.
config :keyfleet, :api_rate_limit, limit: 100_000, window_seconds: 60

# And for the early-access form. Its own test puts the release 5/600 back.
config :keyfleet, :early_signup_rate_limit, limit: 100_000, window_seconds: 600

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

# A write waits for its change to be readable before it answers. Tests that
# write share the machine with the whole suite, so they wait far longer than
# production's two seconds before reading.
config :keyfleet, :graph, projection_wait: 30_000

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

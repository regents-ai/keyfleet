import Config

require Logger

config :sentry,
  dsn: System.get_env("SENTRY_DSN"),
  release: System.get_env("SENTRY_RELEASE"),
  environment_name: System.get_env("SENTRY_ENVIRONMENT", to_string(config_env()))

config :keyfleet, :privy,
  app_id: System.get_env("PRIVY_APP_ID"),
  verification_key: System.get_env("PRIVY_VERIFICATION_KEY")

# Without its Privy settings a local server answers every page while nobody can
# sign in, so it refuses to start. A worktree holds no settings files of its own.
# Other mix tasks, such as migrations and code generation, run without them.
if config_env() == :dev and Phoenix.Endpoint.server?(:keyfleet, KeyfleetWeb.Endpoint) do
  for name <- ~w(PRIVY_APP_ID PRIVY_VERIFICATION_KEY), System.get_env(name, "") == "" do
    raise """
    #{name} is not set, so nobody could sign in. Start the site with its settings loaded:
    direnv exec <main checkout>/platform mix phx.server
    """
  end
end

# The browser test server signs in through a deterministic test-only
# verifier. Production can never take this branch.
if config_env() == :test and System.get_env("KEYFLEET_BROWSER_TEST") == "1" do
  config :keyfleet, :privy, app_id: "browser-test-public-id", verification_key: nil

  # Under the test pool every process that touches the database keeps its own
  # connection until it exits: the site's background workers for good, and each
  # page for as long as it is open. One homepage load alone takes seven (the
  # request, the page and its five reads), so ten runs out between pages.
  config :keyfleet, Keyfleet.Repo, pool_size: 40
end

# Whether the product surfaces are open: KEYFLEET_APP_SURFACES says exactly
# "on" or "off", and anything else stops the boot. Production must say it;
# development and test set it in their own config files.
case {config_env(), System.get_env("KEYFLEET_APP_SURFACES")} do
  {_env, "on"} ->
    config :keyfleet, :app_surfaces, true
    Logger.info("App surfaces enabled")

  {_env, "off"} ->
    config :keyfleet, :app_surfaces, false
    Logger.info("App surfaces disabled")

  {env, nil} when env != :prod ->
    :ok

  {_env, other} ->
    raise ~s(KEYFLEET_APP_SURFACES must be "on" or "off", got #{inspect(other)})
end

# Fleets are read from the chain only when a node is named, and never by the
# test suite.
rpc_url =
  case System.get_env("KEYFLEET_RPC_URL") do
    url when url in [nil, ""] -> nil
    url -> url
  end

if config_env() != :test do
  config :keyfleet, Keyfleet.Chain, rpc_url: rpc_url
end

# The fleets live on the one wallet chain, and the server reads what a page's
# wallet sent through the same node as the fleets, so a lab fork sees it.
if config_env() != :test and rpc_url do
  [chain_id] = :keyfleet |> Application.fetch_env!(:wallet_chains) |> Map.keys()
  nodes = Application.fetch_env!(:keyfleet, :chain_nodes)
  config :keyfleet, :chain_nodes, Map.put(nodes, chain_id, rpc_url)
end

# Each fleet's trait table ships with the release, named by its hash; the
# tests keep theirs with the other fixtures.
if config_env() != :test do
  config :keyfleet, Keyfleet.Traits,
    directory: Application.app_dir(:keyfleet, "priv/trait_tables")
end

# The fleets' notebook hubs: KEYFLEET_HUB_FLEETS lists `fleet_id=address`
# pairs separated by commas, each address the hub's private Flycast URL
# (`fibonacci_syndicate=http://kf-nb-fibonacci-syndicate.flycast`), and
# KEYFLEET_HUB_SIGNING_KEY is the JWK Set whose first key signs every pass.
if config_env() != :test do
  hub_fleets =
    "KEYFLEET_HUB_FLEETS"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Map.new(fn pair ->
      [fleet_id, address] = pair |> String.trim() |> String.split("=", parts: 2)
      {fleet_id, address}
    end)

  hub_signing_keys = System.get_env("KEYFLEET_HUB_SIGNING_KEY")

  if hub_fleets != %{} and hub_signing_keys in [nil, ""] do
    raise "KEYFLEET_HUB_SIGNING_KEY must be set when KEYFLEET_HUB_FLEETS names a fleet"
  end

  config :keyfleet, :notebooks, fleets: hub_fleets, signing_keys: hub_signing_keys
end

migrating? = System.get_env("KEYFLEET_RELEASE_COMMAND") == "migrate"

database_config =
  if config_env() == :prod and migrating? do
    Keyfleet.DatabaseConfig.release_config!()
  else
    Keyfleet.DatabaseConfig.runtime_config!(config_env())
  end

if database_config do
  config :keyfleet, :database_startup_enabled, true
  config :keyfleet, Keyfleet.Repo, database_config
end

if config_env() == :prod do
  unless migrating? do
    host = String.trim(System.fetch_env!("PHX_HOST"))
    secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

    if host == "" do
      raise "PHX_HOST must not be empty"
    end

    if byte_size(secret_key_base) < 64 do
      raise "SECRET_KEY_BASE must be at least 64 bytes"
    end

    # The SIWA sign-in server that checks every signed agent request, and that
    # the joining guide tells agents to sign in with.
    siwa_url = System.fetch_env!("KEYFLEET_SIWA_URL")
    config :keyfleet, :siwa_broker_url, siwa_url
    config :regent_agents, siwa: [url: siwa_url, audience: "keyfleet"]

    config :keyfleet, Keyfleet.AgentListing,
      read_token: System.fetch_env!("SIWA_ACTIVITY_READ_TOKEN")

    # The fleets' code store, at its private Flycast address
    # (`http://keyfleet-code.flycast`), takes only passes signed with
    # KEYFLEET_HUB_SIGNING_KEY.
    if System.get_env("KEYFLEET_HUB_SIGNING_KEY") in [nil, ""] do
      raise "KEYFLEET_HUB_SIGNING_KEY must be set: it signs every pass to the code store"
    end

    config :keyfleet, :code, node: System.fetch_env!("KEYFLEET_CODE_NODE")

    config :keyfleet, KeyfleetWeb.Endpoint,
      server: true,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: String.to_integer(System.get_env("PORT", "4000"))
      ],
      secret_key_base: secret_key_base
  end
end

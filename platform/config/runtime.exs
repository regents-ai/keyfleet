import Config

require Logger

# Tests use the fixed app id in config/test.exs, whatever the shell sets.
if config_env() != :test do
  config :keyfleet, :privy,
    app_id: System.get_env("PRIVY_APP_ID"),
    verification_key: System.get_env("PRIVY_VERIFICATION_KEY")
end

# The Claude connector, behind one switch: its sign-in (Keyfleet.OAuth), its
# MCP address at /mcp, pairing as a connected app, and its guide at
# /agents/claude. A release switches it on only after the provider's tables are
# migrated. The hosted signer is the sign-in server's, asked with this site's
# own key there.
claude_connector? = System.get_env("KEYFLEET_CLAUDE_CONNECTOR_ENABLED") == "true"
hosted_signing_key = System.get_env("SIWA_HOSTED_SIGNING_KEY")

if claude_connector? and
     not (is_binary(hosted_signing_key) and
            Regex.match?(~r/\A[A-Za-z0-9_-]{32,}\z/, hosted_signing_key)) do
  raise "KEYFLEET_CLAUDE_CONNECTOR_ENABLED is true, so SIWA_HOSTED_SIGNING_KEY must be " <>
          "this site's hosted signing key from the sign-in server: 32 or more letters, " <>
          "digits, - or _"
end

# The connector's sign-in answers at the site's own address, and its MCP
# address is under it: in production the host PHX_HOST names (the release's
# migration step has it too), elsewhere the endpoint's configured URL.
site_url =
  if config_env() == :prod do
    case String.trim(System.get_env("PHX_HOST", "")) do
      "" -> nil
      host -> "https://" <> host
    end
  else
    url = Application.fetch_env!(:keyfleet, KeyfleetWeb.Endpoint)[:url]
    URI.to_string(%URI{scheme: url[:scheme] || "http", host: url[:host], port: url[:port]})
  end

config :keyfleet, Keyfleet.OAuth,
  enabled?: claude_connector?,
  issuer: site_url,
  resource: site_url && site_url <> "/mcp"

# The words after "The identity request could not be completed." when a tool
# call gets no answer from the site, in Keyfleet's own words; every other
# refusal is the site's own.
config :regent_mcp_agents, :config,
  enabled?: claude_connector?,
  audience: "keyfleet",
  hosted_signer: [
    base_url: System.get_env("SIWA_HOSTED_URL", "https://siwa.regents.sh"),
    key: hosted_signing_key
  ],
  refusal:
    "Try again in a moment. If it keeps failing, ask your person to connect Keyfleet again " <>
      "in Claude's settings, then call get_identity."

# Claude is the one connected app Keyfleet serves, and the pair request accepts
# it only while the connector is on; ChatGPT is never offered here.
config :regent_agents, hosted_pairing: if(claude_connector?, do: [:claude], else: [])

# The Privy accounts that run this site, comma separated (config/config.exs).
if admins = System.get_env("REGENT_CREDITS_ADMINS") do
  admins = admins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  config :keyfleet, :admins, admins
  config :regent_agents, admins: admins
end

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

# The browser test server. Production can never take this branch.
if config_env() == :test and System.get_env("KEYFLEET_BROWSER_TEST") == "1" do
  # The server uses production's pool, not the test suite's: a process holds a
  # connection only while it uses one, so a read stopped mid-query (its page was
  # left) drops that one connection alone, and no worker is cut off for holding
  # one too long. It keeps the test setting's ten connections, twice the site's.
  config :keyfleet, Keyfleet.Repo, pool: DBConnection.ConnectionPool

  # The browser test server (playwright.config.ts) writes its lines in
  # production's shape to a file, which test/browser/visits.spec.ts reads to
  # replay a visit.
  config :logger, level: :info

  config :logger, :default_handler,
    config: [file: String.to_charlist(Path.expand("../tmp/walk-lines.jsonl", __DIR__))],
    formatter: LoggerJSON.Formatters.Basic.new(metadata: KeyfleetWeb.VisitLog.fields())
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
# test suite. The anvil lab (docs/anvil-lab.md) reads them from its own node.
rpc_url =
  case {config_env(), System.get_env("KEYFLEET_LAB"), System.get_env("KEYFLEET_RPC_URL")} do
    {:dev, lab, _url} when lab not in [nil, ""] -> lab
    {_env, _lab, url} when url in [nil, ""] -> nil
    {_env, _lab, url} -> url
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

# Each sign-in reads the wallet's ENS name from Ethereum mainnet while this
# endpoint is set (Keyfleet.Accounts.EnsIdentity). Tests never read it.
if config_env() != :test do
  if ethereum_read_rpc_url = System.get_env("ETHEREUM_READ_RPC_URL") do
    case URI.new(ethereum_read_rpc_url) do
      {:ok, %URI{scheme: "https", host: host}} when host not in [nil, ""] ->
        config :keyfleet, :ethereum_read_rpc_url, ethereum_read_rpc_url

      _invalid ->
        raise "ETHEREUM_READ_RPC_URL must be an https address"
    end
  end
end

# Each fleet's trait table, and card deck if it has one, ships with the
# release, named by its hash; the tests keep theirs elsewhere.
if config_env() != :test do
  config :keyfleet, Keyfleet.Traits,
    directory: Application.app_dir(:keyfleet, "priv/trait_tables")

  config :keyfleet, Keyfleet.Decks, directory: Application.app_dir(:keyfleet, "priv/decks")
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
  # One JSON object a line, which Fly Sentinel reads, carrying only the visit
  # fields (KeyfleetWeb.VisitLog). Release commands write the same shape.
  config :logger, :default_handler,
    formatter: LoggerJSON.Formatters.Basic.new(metadata: KeyfleetWeb.VisitLog.fields())

  unless migrating? do
    # bin/site and bin/graph name the machine; the machines of one app find
    # each other through its private DNS name (fly.toml).
    machine =
      case System.fetch_env!("KEYFLEET_MACHINE") do
        "site" -> :site
        "graph" -> :graph
      end

    config :keyfleet, :machine, machine

    config :keyfleet, :dns_cluster_query, System.fetch_env!("DNS_CLUSTER_QUERY")

    config :keyfleet, Keyfleet.Keys.PresenceTimer,
      key: System.fetch_env!("KEYFLEET_PRESENCE_TIMER_KEY")

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

    # This site's own key for reading what paired agents have done from the
    # sign-in service (RegentAgents.Activity), as ash-template reads it.
    config :regent_agents, :activity_read_token, System.get_env("SIWA_ACTIVITY_READ_TOKEN")

    # The fleets' code store, at its private Flycast address
    # (`http://keyfleet-code.flycast`), takes only passes signed with
    # KEYFLEET_HUB_SIGNING_KEY.
    if System.get_env("KEYFLEET_HUB_SIGNING_KEY") in [nil, ""] do
      raise "KEYFLEET_HUB_SIGNING_KEY must be set: it signs every pass to the code store"
    end

    config :keyfleet, :code, node: System.fetch_env!("KEYFLEET_CODE_NODE")

    # Keyfleet's picture bucket (agents' pictures under agent-avatars/): the
    # Tigris bucket `fly storage create` made and set these secrets for, and
    # the public address its objects are read from
    # (`https://<bucket>.fly.storage.tigris.dev`).
    config :keyfleet, :avatar_bucket,
      endpoint: System.fetch_env!("AWS_ENDPOINT_URL_S3"),
      bucket: System.fetch_env!("BUCKET_NAME"),
      region: System.fetch_env!("AWS_REGION"),
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
      public_url: System.fetch_env!("PICTURES_PUBLIC_URL")

    # The key-art service that draws revealed keys' cards, at its private
    # Flycast address (`http://keyfleet-key-art.flycast`).
    config :keyfleet, Keyfleet.Keys.KeyArt, url: System.fetch_env!("KEY_ART_URL")

    # Regent's Lighthouse account, which keeps revealed keys' cards on IPFS.
    config :keyfleet, Keyfleet.Lighthouse, api_key: System.fetch_env!("LIGHTHOUSE_API_KEY")

    config :keyfleet, KeyfleetWeb.Endpoint,
      server: true,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: String.to_integer(System.get_env("PORT", "4000"))
      ],
      secret_key_base: secret_key_base

    # The commit the image was built from, and the Fly image this machine runs.
    config :keyfleet, :build, %{
      commit: System.fetch_env!("SOURCE_COMMIT"),
      release: System.fetch_env!("FLY_IMAGE_REF")
    }
  end
end

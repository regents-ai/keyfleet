import Config

require Logger

config :sentry,
  dsn: System.get_env("SENTRY_DSN"),
  release: System.get_env("SENTRY_RELEASE"),
  environment_name: System.get_env("SENTRY_ENVIRONMENT", to_string(config_env()))

privy_verification_key =
  case System.get_env("PRIVY_VERIFICATION_KEY") do
    nil ->
      nil

    value ->
      value
      |> String.replace("\\r\\n", "\n")
      |> String.replace("\\n", "\n")
  end

config :keyfleet, :privy,
  app_id: System.get_env("PRIVY_APP_ID"),
  verification_key: privy_verification_key

# The browser acceptance server signs in through a deterministic test-only
# verifier. Production can never take this branch.
if config_env() == :test and System.get_env("KEYFLEET_BROWSER_TEST") == "1" do
  config :keyfleet, :privy, app_id: "browser-test-public-id", verification_key: nil
end

# Production must say out loud whether the product surfaces are open. Anything
# but "on" keeps them closed, so a typo closes rather than opens.
app_surfaces_setting =
  case {config_env(), System.get_env("KEYFLEET_APP_SURFACES")} do
    {:prod, nil} ->
      raise ~s(KEYFLEET_APP_SURFACES must be set to "on" or "off")

    {_env, nil} ->
      "on"

    {_env, setting} ->
      setting
  end

app_surfaces? = app_surfaces_setting == "on"

config :keyfleet, :app_surfaces, app_surfaces?

Logger.info("App surfaces #{if app_surfaces?, do: "enabled", else: "disabled"}")

migrating? = System.get_env("KEYFLEET_RELEASE_COMMAND") == "migrate"

database_config =
  if config_env() == :prod and migrating? do
    KeyFleet.DatabaseConfig.release_config!()
  else
    KeyFleet.DatabaseConfig.runtime_config!(config_env())
  end

if database_config do
  config :keyfleet, :database_startup_enabled, true
  config :keyfleet, KeyFleet.Repo, database_config
end

if config_env() == :prod do
  config :keyfleet, :session_options, secure: true, http_only: true

  unless migrating? do
    host = String.trim(System.fetch_env!("PHX_HOST"))
    secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

    if host == "" do
      raise "PHX_HOST must not be empty"
    end

    if byte_size(secret_key_base) < 64 do
      raise "SECRET_KEY_BASE must be at least 64 bytes"
    end

    config :keyfleet, KeyFleetWeb.Endpoint,
      server: true,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: {0, 0, 0, 0, 0, 0, 0, 0},
        port: String.to_integer(System.get_env("PORT", "4000"))
      ],
      secret_key_base: secret_key_base
  end
end

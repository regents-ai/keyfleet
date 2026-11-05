defmodule Keyfleet.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @fly_production_config Path.expand("../../fly.toml", __DIR__)
  @fly_staging_config Path.expand("../../fly.staging.toml", __DIR__)

  setup do
    names = [
      "PRIVY_APP_ID",
      "PRIVY_VERIFICATION_KEY",
      "DATABASE_POOLED_URL",
      "DATABASE_DIRECT_URL",
      "DATABASE_URL",
      "KEYFLEET_DATABASE_CLUSTER_ID",
      "KEYFLEET_DATABASE_CLUSTER_NAME",
      "KEYFLEET_DATABASE_TARGET_MODE",
      "KEYFLEET_DEPLOYMENT_ROLE",
      "KEYFLEET_RELEASE_COMMAND",
      "FLY_APP_NAME",
      "PHX_HOST",
      "PORT",
      "SECRET_KEY_BASE",
      "KEYFLEET_APP_SURFACES",
      "KEYFLEET_RPC_URL",
      "KEYFLEET_SIWA_URL",
      "KEYFLEET_HUB_FLEETS",
      "KEYFLEET_HUB_SIGNING_KEY",
      "KEYFLEET_CODE_NODE",
      "AWS_ACCESS_KEY_ID",
      "AWS_SECRET_ACCESS_KEY",
      "AWS_ENDPOINT_URL_S3",
      "AWS_REGION",
      "BUCKET_NAME",
      "PICTURES_PUBLIC_URL",
      "KEY_ART_URL",
      "LIGHTHOUSE_API_KEY",
      "KEYFLEET_MACHINE",
      "DNS_CLUSTER_QUERY",
      "KEYFLEET_PRESENCE_TIMER_KEY",
      "SOURCE_COMMIT",
      "FLY_IMAGE_REF"
    ]

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    # Production demands an explicit gate setting; these tests cover the rest of the file.
    System.put_env("KEYFLEET_APP_SURFACES", "on")
    # Every production image carries the commit it was built from and its own name.
    System.put_env("SOURCE_COMMIT", "0123456789abcdef0123456789abcdef01234567")
    System.put_env("FLY_IMAGE_REF", "registry.fly.io/keyfleet:deployment-test")
    System.put_env("KEYFLEET_PRESENCE_TIMER_KEY", "0x" <> String.duplicate("11", 32))

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
    end)

    :ok
  end

  test "Privy verification key preserves a native multiline PEM" do
    pem = "-----BEGIN PUBLIC KEY-----\nabc123\n-----END PUBLIC KEY-----"
    System.put_env("PRIVY_APP_ID", "local-privy-app")
    System.put_env("PRIVY_VERIFICATION_KEY", pem)

    assert privy_config() == [app_id: "local-privy-app", verification_key: pem]
  end

  test "test runtime keeps its fixed local repository despite database environment values" do
    System.put_env("DATABASE_POOLED_URL", "postgresql://pooled:secret@remote.test/db")
    System.put_env("DATABASE_DIRECT_URL", "postgresql://direct:secret@remote.test/db")
    System.put_env("DATABASE_URL", "postgresql://legacy:secret@remote.test/db")

    assert runtime_repo_config(:test) == nil

    test_repo =
      "config/test.exs"
      |> Config.Reader.read!(env: :test, target: :host)
      |> get_in([:keyfleet, Keyfleet.Repo])

    assert Keyword.take(test_repo, [:hostname, :port, :database]) == [
             hostname: "127.0.0.1",
             port: 5432,
             database: "keyfleet#{System.get_env("MIX_TEST_PARTITION")}_test"
           ]
  end

  test "production runtime enables the repository with pooled access" do
    put_production_role()

    pooled =
      "postgresql://direct:secret@direct.dzx6qo6xqzvojpv5.flympg.net/keyfleet"

    System.put_env("DATABASE_POOLED_URL", pooled)

    System.put_env(
      "DATABASE_DIRECT_URL",
      "postgresql://direct:secret@direct.dzx6qo6xqzvojpv5.flympg.net/keyfleet"
    )

    System.put_env("PHX_HOST", "shadow.example.test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))

    config = read_runtime_config(:prod)

    assert get_in(config, [:keyfleet, :database_startup_enabled])
    assert get_in(config, [:keyfleet, :machine]) == :site
    assert get_in(config, [:keyfleet, :dns_cluster_query]) == "keyfleet.internal"

    assert get_in(config, [:keyfleet, Keyfleet.Repo]) == [
             ssl: [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               server_name_indication: ~c"direct.dzx6qo6xqzvojpv5.flympg.net",
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ],
             url: pooled,
             socket_options: [:inet6],
             pool_size: 5,
             show_sensitive_data_on_connection_error: false,
             parameters: [
               application_name: "keyfleet-web",
               statement_timeout: "15000",
               lock_timeout: "5000",
               idle_in_transaction_session_timeout: "15000"
             ]
           ]

    endpoint = get_in(config, [:keyfleet, KeyfleetWeb.Endpoint])

    assert endpoint[:server]
    assert endpoint[:secret_key_base] == String.duplicate("s", 64)
    assert endpoint[:url][:host] == "shadow.example.test"
    assert endpoint[:url][:scheme] == "https"
    assert endpoint[:http][:port] == 4000
    assert endpoint[:http][:ip] == {0, 0, 0, 0, 0, 0, 0, 0}
  end

  test "PKG-RUNTIME the graph machine boots as the graph machine" do
    put_production_role()
    put_pooled_url()
    System.put_env("PHX_HOST", "shadow.example.test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
    System.put_env("KEYFLEET_MACHINE", "graph")

    assert get_in(read_runtime_config(:prod), [:keyfleet, :machine]) == :graph
  end

  test "PKG-RUNTIME serving uses the host without its surrounding whitespace" do
    put_production_role()

    System.put_env(
      "DATABASE_POOLED_URL",
      "postgresql://direct:secret@direct.dzx6qo6xqzvojpv5.flympg.net/keyfleet"
    )

    System.put_env("PHX_HOST", "  shadow.example.test\n")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))

    config = read_runtime_config(:prod)

    assert get_in(config, [:keyfleet, KeyfleetWeb.Endpoint])[:url][:host] ==
             "shadow.example.test"
  end

  test "production boot fails closed until the deployment says which venue it is" do
    put_pooled_url()
    System.put_env("PHX_HOST", "shadow.example.test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))

    assert_raise RuntimeError,
                 ~s(KEYFLEET_DEPLOYMENT_ROLE must be set to "production" or "staging"),
                 fn -> read_runtime_config(:prod) end
  end

  # The deployment files are the only place the role is named, so each one has to
  # carry its own venue's value and each names its own app.
  test "PKG-RUNTIME each deployment file names the venue it deploys" do
    assert env_section(@fly_production_config) =~
             ~s(\n  KEYFLEET_DEPLOYMENT_ROLE = "production"\n)

    assert env_section(@fly_staging_config) =~
             ~s(\n  KEYFLEET_DEPLOYMENT_ROLE = "staging"\n)

    assert File.read!(@fly_production_config) =~ ~s(app = "keyfleet"\n)
    assert File.read!(@fly_staging_config) =~ ~s(app = "keyfleet-staging"\n)

    assert env_section(@fly_production_config) =~
             ~s(\n  DNS_CLUSTER_QUERY = "keyfleet.internal"\n)

    assert env_section(@fly_staging_config) =~
             ~s(\n  DNS_CLUSTER_QUERY = "keyfleet-staging.internal"\n)
  end

  # Staging reviews the image production will receive, so the machine it runs on
  # and the command that prepares its database have to be production's.
  test "PKG-RUNTIME the staging deployment keeps production's shape" do
    staging = File.read!(@fly_staging_config)

    assert staging =~ ~s(primary_region = "iad"\n)
    assert staging =~ ~s(  release_command = "/app/bin/migrate"\n)
    assert staging =~ "  memory_mb = 1024\n"
    assert staging =~ ~s([processes]\n  site = "/app/bin/site"\n  graph = "/app/bin/graph"\n)
  end

  test "production runtime fails closed without pooled access" do
    put_production_role()

    assert_raise RuntimeError, "DATABASE_POOLED_URL is required", fn ->
      read_runtime_config(:prod)
    end
  end

  test "migration runtime selects direct access only for the exact production target" do
    put_production_role()

    direct =
      "postgresql://direct:secret@direct.dzx6qo6xqzvojpv5.flympg.net/keyfleet"

    System.put_env("KEYFLEET_RELEASE_COMMAND", "migrate")
    System.put_env("KEYFLEET_DATABASE_TARGET_MODE", "production")
    System.put_env("KEYFLEET_DATABASE_CLUSTER_ID", "dzx6qo6xqzvojpv5")
    System.put_env("KEYFLEET_DATABASE_CLUSTER_NAME", "regents-platform-prod")
    System.put_env("DATABASE_DIRECT_URL", direct)

    assert runtime_repo_config(:prod) == [
             ssl: [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               server_name_indication: ~c"direct.dzx6qo6xqzvojpv5.flympg.net",
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ],
             url: direct,
             socket_options: [:inet6],
             pool_size: 5
           ]
  end

  test "migration runtime rejects an arbitrary direct URL without production identity" do
    put_production_role()
    System.put_env("KEYFLEET_RELEASE_COMMAND", "migrate")
    System.put_env("DATABASE_DIRECT_URL", "postgresql://direct:secret@direct.example.test/db")

    assert_raise RuntimeError,
                 "database migration requires production mode for cluster dzx6qo6xqzvojpv5 named regents-platform-prod",
                 fn -> runtime_repo_config(:prod) end
  end

  test "migration runtime refuses production mode without the cluster identity" do
    put_production_role()
    System.put_env("KEYFLEET_RELEASE_COMMAND", "migrate")
    System.put_env("KEYFLEET_DATABASE_TARGET_MODE", "production")

    assert_raise RuntimeError,
                 "database migration requires production mode for cluster dzx6qo6xqzvojpv5 named regents-platform-prod",
                 fn -> runtime_repo_config(:prod) end
  end

  test "PKG-RUNTIME serving fails closed without a host" do
    put_production_role()
    put_pooled_url()

    assert_raise System.EnvError, ~r/PHX_HOST/, fn -> read_runtime_config(:prod) end
  end

  test "PKG-RUNTIME serving fails closed on a blank host" do
    put_production_role()
    put_pooled_url()
    System.put_env("PHX_HOST", " ")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))

    assert_raise RuntimeError, "PHX_HOST must not be empty", fn ->
      read_runtime_config(:prod)
    end
  end

  test "PKG-RUNTIME serving fails closed without a session secret" do
    put_production_role()
    put_pooled_url()
    System.put_env("PHX_HOST", "shadow.example.test")

    assert_raise System.EnvError, ~r/SECRET_KEY_BASE/, fn -> read_runtime_config(:prod) end
  end

  test "PKG-RUNTIME serving fails closed without the sign-in server" do
    put_production_role()
    put_pooled_url()
    System.put_env("PHX_HOST", "shadow.example.test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
    System.delete_env("KEYFLEET_SIWA_URL")

    assert_raise System.EnvError, ~r/KEYFLEET_SIWA_URL/, fn -> read_runtime_config(:prod) end
  end

  test "PKG-RUNTIME serving fails closed on an undersized session secret" do
    put_production_role()
    put_pooled_url()
    System.put_env("PHX_HOST", "shadow.example.test")
    System.put_env("SECRET_KEY_BASE", "too-short")

    assert_raise RuntimeError, "SECRET_KEY_BASE must be at least 64 bytes", fn ->
      read_runtime_config(:prod)
    end
  end

  test "PKG-RUNTIME migration startup does not require serving-only endpoint values" do
    put_production_role()

    direct =
      "postgresql://direct:secret@direct.dzx6qo6xqzvojpv5.flympg.net/keyfleet"

    System.put_env("KEYFLEET_RELEASE_COMMAND", "migrate")
    System.put_env("KEYFLEET_DATABASE_TARGET_MODE", "production")
    System.put_env("KEYFLEET_DATABASE_CLUSTER_ID", "dzx6qo6xqzvojpv5")
    System.put_env("KEYFLEET_DATABASE_CLUSTER_NAME", "regents-platform-prod")
    System.put_env("DATABASE_DIRECT_URL", direct)

    config = read_runtime_config(:prod)

    assert get_in(config, [:keyfleet, Keyfleet.Repo]) == [
             ssl: [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               server_name_indication: ~c"direct.dzx6qo6xqzvojpv5.flympg.net",
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ],
             url: direct,
             socket_options: [:inet6],
             pool_size: 5
           ]

    assert get_in(config, [:keyfleet, KeyfleetWeb.Endpoint]) == nil
  end

  # Fly applies a table until the next one begins, so a role line outside [env] --
  # under [build], or in a comment -- would never reach the machines.
  defp env_section(path) do
    [_, rest] = path |> File.read!() |> String.split("[env]", parts: 2)

    rest |> String.split(~r/\n\[/, parts: 2) |> hd()
  end

  defp put_production_role do
    System.put_env("KEYFLEET_DEPLOYMENT_ROLE", "production")
    System.put_env("KEYFLEET_SIWA_URL", "https://siwa.example.test")
    System.put_env("KEYFLEET_HUB_SIGNING_KEY", ~s({"keys":[]}))
    System.put_env("KEYFLEET_CODE_NODE", "http://code-store.example.test")
    System.put_env("AWS_ACCESS_KEY_ID", "bucket-access-key")
    System.put_env("AWS_SECRET_ACCESS_KEY", "bucket-secret-key")
    System.put_env("AWS_ENDPOINT_URL_S3", "https://storage.example.test")
    System.put_env("AWS_REGION", "auto")
    System.put_env("BUCKET_NAME", "keyfleet-avatars")
    System.put_env("PICTURES_PUBLIC_URL", "https://keyfleet-avatars.storage.example.test")
    System.put_env("KEY_ART_URL", "http://key-art.example.test")
    System.put_env("LIGHTHOUSE_API_KEY", "lighthouse-api-key")
    System.put_env("KEYFLEET_MACHINE", "site")
    System.put_env("DNS_CLUSTER_QUERY", "keyfleet.internal")
  end

  defp put_pooled_url do
    System.put_env(
      "DATABASE_POOLED_URL",
      "postgresql://direct:secret@direct.dzx6qo6xqzvojpv5.flympg.net/keyfleet"
    )
  end

  defp privy_config do
    runtime_config(:privy)
  end

  defp runtime_config(key) when is_atom(key) do
    read_runtime_config(:dev)
    |> get_in([:keyfleet, key])
  end

  defp read_runtime_config(environment) do
    @runtime_config
    |> Config.Reader.read!(env: environment, target: :host)
  end

  defp runtime_repo_config(environment),
    do: get_in(read_runtime_config(environment), [:keyfleet, Keyfleet.Repo])

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

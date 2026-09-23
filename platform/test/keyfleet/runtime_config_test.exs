defmodule KeyFleet.RuntimeConfigTest do
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
      "KEYFLEET_KEEPER_PRIVATE_KEY"
    ]

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    # Production demands an explicit gate setting; these tests cover the rest of the file.
    System.put_env("KEYFLEET_APP_SURFACES", "on")

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
    end)

    :ok
  end

  test "Privy verification key accepts secret-manager-safe escaped PEM newlines" do
    System.put_env("PRIVY_APP_ID", "local-privy-app")

    System.put_env(
      "PRIVY_VERIFICATION_KEY",
      "-----BEGIN PUBLIC KEY-----\\r\\nabc123\\n-----END PUBLIC KEY-----"
    )

    assert privy_config() == [
             app_id: "local-privy-app",
             verification_key: "-----BEGIN PUBLIC KEY-----\nabc123\n-----END PUBLIC KEY-----"
           ]
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
      |> get_in([:keyfleet, KeyFleet.Repo])

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

    assert get_in(config, [:keyfleet, KeyFleet.Repo]) == [
             ssl: [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               server_name_indication: ~c"direct.dzx6qo6xqzvojpv5.flympg.net",
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ],
             port: 5432,
             url: pooled,
             socket_options: [:inet6]
           ]

    endpoint = get_in(config, [:keyfleet, KeyFleetWeb.Endpoint])

    assert endpoint[:server]
    assert endpoint[:secret_key_base] == String.duplicate("s", 64)
    assert endpoint[:url][:host] == "shadow.example.test"
    assert endpoint[:url][:scheme] == "https"
    assert endpoint[:http][:port] == 4000
    assert endpoint[:http][:ip] == {0, 0, 0, 0, 0, 0, 0, 0}
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

    assert get_in(config, [:keyfleet, KeyFleetWeb.Endpoint])[:url][:host] ==
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
  end

  # Staging reviews the image production will receive, so the machine it runs on
  # and the command that prepares its database have to be production's.
  test "PKG-RUNTIME the staging deployment keeps production's shape" do
    staging = File.read!(@fly_staging_config)

    assert staging =~ ~s(primary_region = "iad"\n)
    assert staging =~ ~s(  release_command = "/app/bin/migrate"\n)
    assert staging =~ "  memory_mb = 1024\n"
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
             port: 5432,
             url: direct,
             socket_options: [:inet6]
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

    assert get_in(config, [:keyfleet, KeyFleet.Repo]) == [
             ssl: [
               verify: :verify_peer,
               cacerts: :public_key.cacerts_get(),
               server_name_indication: ~c"direct.dzx6qo6xqzvojpv5.flympg.net",
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ],
             port: 5432,
             url: direct,
             socket_options: [:inet6]
           ]

    assert get_in(config, [:keyfleet, KeyFleetWeb.Endpoint]) == nil
  end

  describe "the keeper key" do
    # Not a key that holds anything: the smallest one there is.
    @key "0x" <> String.duplicate("0", 63) <> "1"
    @node "https://node.example.test"

    setup do
      put_production_role()
      put_pooled_url()
      System.put_env("PHX_HOST", "keyfleet.example.test")
      System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
      :ok
    end

    test "leaves the keeper off when it is unset or blank" do
      System.put_env("KEYFLEET_RPC_URL", @node)
      assert production_config(KeyFleet.Keeper) == [private_key: nil]

      System.put_env("KEYFLEET_KEEPER_PRIVATE_KEY", "  \n")
      assert production_config(KeyFleet.Keeper) == [private_key: nil]
    end

    test "is configured with the node it sends through" do
      System.put_env("KEYFLEET_RPC_URL", @node)
      System.put_env("KEYFLEET_KEEPER_PRIVATE_KEY", @key)

      assert production_config(KeyFleet.Keeper) == [private_key: @key]
      assert production_config(KeyFleet.Chain) == [rpc_url: @node]
    end

    test "stops the boot when it is malformed, without printing it" do
      System.put_env("KEYFLEET_RPC_URL", @node)

      for key <- [
            String.duplicate("0", 63) <> "1",
            "0x" <> String.duplicate("0", 62) <> "1",
            "0x" <> String.duplicate("0", 63) <> "g",
            "0x" <> String.duplicate("0", 64),
            "0x" <> String.duplicate("f", 64),
            " " <> @key
          ] do
        System.put_env("KEYFLEET_KEEPER_PRIVATE_KEY", key)

        error = assert_raise RuntimeError, fn -> production_config(KeyFleet.Keeper) end
        assert Exception.message(error) == "KEYFLEET_KEEPER_PRIVATE_KEY is malformed"
      end
    end

    test "stops the boot when there is no node to send through" do
      System.put_env("KEYFLEET_KEEPER_PRIVATE_KEY", @key)

      for node <- [nil, ""] do
        restore_env("KEYFLEET_RPC_URL", node)

        error = assert_raise RuntimeError, fn -> production_config(KeyFleet.Keeper) end

        assert Exception.message(error) ==
                 "KEYFLEET_KEEPER_PRIVATE_KEY is set but KEYFLEET_RPC_URL is not"
      end
    end

    test "is never read in development or tests" do
      System.put_env("KEYFLEET_RPC_URL", @node)

      for key <- [@key, "malformed"], env <- [:dev, :test] do
        System.put_env("KEYFLEET_KEEPER_PRIVATE_KEY", key)
        assert env |> read_runtime_config() |> get_in([:keyfleet, KeyFleet.Keeper]) == nil
      end
    end
  end

  # Fly applies a table until the next one begins, so a role line outside [env] --
  # under [build], or in a comment -- would never reach the machines.
  defp env_section(path) do
    [_, rest] = path |> File.read!() |> String.split("[env]", parts: 2)

    rest |> String.split(~r/\n\[/, parts: 2) |> hd()
  end

  defp put_production_role do
    System.put_env("KEYFLEET_DEPLOYMENT_ROLE", "production")
  end

  defp put_pooled_url do
    System.put_env(
      "DATABASE_POOLED_URL",
      "postgresql://direct:secret@direct.dzx6qo6xqzvojpv5.flympg.net/keyfleet"
    )
  end

  defp production_config(key), do: :prod |> read_runtime_config() |> get_in([:keyfleet, key])

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
    do: get_in(read_runtime_config(environment), [:keyfleet, KeyFleet.Repo])

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end

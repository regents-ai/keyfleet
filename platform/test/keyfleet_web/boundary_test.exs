defmodule KeyFleetWeb.BoundaryTest do
  use ExUnit.Case, async: true

  @forbidden ["check_origin: false", "../platform", "/platform/"]

  test "auth has no production database shortcut or old-platform dependency" do
    paths =
      ["mix.exs" | Path.wildcard("{config,lib,test}/**/*.{ex,exs,heex}")]
      |> List.delete(__ENV__.file |> Path.relative_to_cwd())

    for path <- paths,
        forbidden <- @forbidden do
      refute File.read!(path) =~ forbidden, "#{path} contains forbidden boundary #{forbidden}"
    end
  end

  test "the application migrations start with the extensions install and the app baseline" do
    assert [extensions_migration] =
             Path.wildcard("priv/repo/migrations/*_initial_app_extensions_1.exs")

    assert [baseline_migration] = Path.wildcard("priv/repo/migrations/*_initial_app.exs")

    assert "priv/repo/migrations/*" |> Path.wildcard() |> Enum.sort() |> Enum.take(2) ==
             Enum.sort([extensions_migration, baseline_migration])

    assert_extension_migration(extensions_migration)

    assert_additive_migration(
      baseline_migration,
      [
        "create table(:linked_identities",
        "create table(:session_authorities",
        "references(:platform_human_users",
        ~s(prefix: "regent_names")
      ],
      []
    )

    # The application's own tables take their schema from the migrator, so the
    # file names a schema only where it reaches the shared account table.
    baseline = File.read!(baseline_migration)
    refute baseline =~ ~r/create table\(:\w+, [^\n]*prefix:/
    refute baseline =~ "CREATE SCHEMA"
    assert baseline |> String.split(~s(prefix: "regent_names")) |> length() == 3
  end

  defp assert_additive_migration(path, required_fragments, allowed_statements) do
    source = File.read!(path)
    [up, _down] = String.split(source, "  def down do", parts: 2)

    for fragment <- required_fragments, do: assert(up =~ fragment)
    refute up =~ "drop("

    statements =
      ~r/execute\("([^"]+)"\)/
      |> Regex.scan(up, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert statements == allowed_statements
  end

  defp assert_extension_migration(path) do
    source = File.read!(path)
    [up, _down] = String.split(source, "  def down do", parts: 2)

    for function <- [
          "ash_elixir_or",
          "ash_elixir_and",
          "ash_trim_whitespace",
          "ash_raise_error",
          "ash_required",
          "uuid_generate_v7"
        ],
        do: assert(up =~ "CREATE OR REPLACE FUNCTION #{function}")

    refute up =~ "DROP FUNCTION"
    refute up =~ "create table("
    refute up =~ "alter table("
  end

  test "production database startup is enabled only after canonical configuration succeeds" do
    runtime = File.read!("config/runtime.exs")
    assert runtime =~ "config :keyfleet, :database_startup_enabled, true"
    assert runtime =~ "KeyFleet.DatabaseConfig.runtime_config!(config_env())"
    assert runtime =~ "KeyFleet.DatabaseConfig.release_config!()"
    assert runtime =~ ~s|System.get_env("KEYFLEET_RELEASE_COMMAND") == "migrate"|
  end

  test "runtime code never reads the generic database URL" do
    legacy_lookup = ~s|System.get_env("DATABASE_URL")|

    for path <- Path.wildcard("{config,lib,rel}/**/*"), File.regular?(path) do
      refute File.read!(path) =~ legacy_lookup, "#{path} reads the generic database URL"
    end
  end

  test "development keeps origin protection on an exact loopback allowlist" do
    endpoint_config =
      "config/dev.exs"
      |> Config.Reader.read!(env: :dev)
      |> Keyword.fetch!(:keyfleet)
      |> Keyword.fetch!(KeyFleetWeb.Endpoint)

    assert Keyword.fetch!(endpoint_config, :check_origin) == [
             "http://localhost:4000",
             "http://127.0.0.1:4000"
           ]
  end

  test "test keeps origin protection on its exact loopback allowlist" do
    endpoint_config =
      "config/test.exs"
      |> Config.Reader.read!(env: :test)
      |> Keyword.fetch!(:keyfleet)
      |> Keyword.fetch!(KeyFleetWeb.Endpoint)

    port = endpoint_config |> Keyword.fetch!(:http) |> Keyword.fetch!(:port)
    assert Keyword.fetch!(endpoint_config, :check_origin) == ["http://127.0.0.1:#{port}"]
  end
end

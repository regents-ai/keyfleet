defmodule Keyfleet.Release do
  @moduledoc false

  @app :keyfleet
  @deployment_role_variable "KEYFLEET_DEPLOYMENT_ROLE"
  @staging_role "staging"
  @platform_schema "regent_names"
  @bootstrap_role_error "bootstrap-staging requires #{@deployment_role_variable} to be exactly staging"
  @missing_migration_table_error "no schema_migrations table: run bootstrap-staging first"

  @table_exists """
  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p')
  )
  """
  @schema_exists "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = $1)"

  def migration_config!(getenv \\ &System.get_env/1) do
    Keyfleet.DatabaseConfig.release_config!(getenv)
  end

  @doc """
  Brings a deployed database up to the release: runs every migration, then
  seeds the catalog as `seed_catalog!/0` does. Deploying runs it as the
  release command, so a deploy that takes a fleet's coming-soon mark away also
  opens that fleet's rooms. It never binds a fleet to a deployment.
  """
  def migrate, do: with_release_repo(&migrate!/0)

  @doc "Migrates and seeds through an already running repository, as `migrate/0` does."
  def migrate! do
    require_shared_migrations!(Keyfleet.Repo)
    RegentAgents.Migrator.require_pairing_history!(Keyfleet.Repo)
    RegentCredits.Migrator.require_pairing_grants!(Keyfleet.Repo)
    Keyfleet.Repo.migrate!(migrations_path())
    seed_catalog!()
  end

  @doc """
  Binds the catalog's fleets to the deployment a deployed record describes,
  the JSON `contracts/script/RecordKeyfleets.s.sol` writes
  (`Keyfleet.Fleets.record_manifest!/1`), opens their fixed and open rooms,
  and prints what each is now bound to. The fleets are bound and their rooms
  opened together or not at all. `bin/seed-deployment <path>` runs it. This
  is what shows a fleet's Keys on sale, a coming-soon fleet's included; every
  fleet the record doesn't hold is left as it is.

  Recording the same record again changes nothing; a record naming other
  contracts for a bound fleet, or wiring that differs from the fleets already
  bound, is refused and changes nothing. The running site starts reading a
  newly bound fleet within a minute (`Keyfleet.Chain.Watch`).
  """
  def seed_deployment(path), do: with_release_repo(fn -> seed_deployment!(path) end)

  @doc "Seeds from `path` through an already running repository, as `seed_deployment/1` does."
  # The path is the operator's own argument on the machine they are signed in to.
  # sobelow_skip ["Traversal.FileModule"]
  def seed_deployment!(path) do
    manifest = path |> File.read!() |> Jason.decode!()

    fleets =
      case Ash.transact([Keyfleet.Fleets.Fleet, Keyfleet.Rooms.Room], fn ->
             fleets = Keyfleet.Fleets.record_manifest!(manifest)
             Keyfleet.Rooms.bootstrap_rooms!(Enum.map(fleets, & &1.id))
             fleets
           end) do
        {:ok, fleets} -> fleets
        {:error, error} -> raise error
      end

    for fleet <- fleets do
      IO.puts(
        "#{fleet.id}: fleet #{fleet.chain_fleet_id} at #{fleet.manager_address} from block #{fleet.deployed_block}"
      )
    end

    :ok
  end

  @doc """
  Seeds the five fleets and opens the rooms of every fleet that is not coming
  soon, without binding any fleet to a deployment, so the site shows every
  fleet while key sales stay off. A coming-soon fleet gets its rooms when it
  opens. `migrate/0` runs it after the migrations on every deploy. Running it
  again changes nothing, and it never touches a fleet's recorded deployment.
  """
  def seed_catalog! do
    fleets = Keyfleet.Fleets.bootstrap_catalog!()
    open = Keyfleet.Fleets.open_fleet_ids()
    Keyfleet.Rooms.bootstrap_rooms!(open)

    for fleet <- fleets do
      IO.puts("#{fleet.id}: #{if fleet.id in open, do: "open", else: "coming soon"}")
    end

    :ok
  end

  @doc """
  Lets a fleet stopped at a disagreement with the chain be read again, once
  the record has been corrected by hand. `bin/clear-fleet-stop <fleet id>`
  runs it; a running app picks the fleet up on its next pass.
  """
  def clear_fleet_stop(fleet_id), do: with_release_repo(fn -> clear_fleet_stop!(fleet_id) end)

  @doc "Clears the stop through an already running repository, as `clear_fleet_stop/1` does."
  def clear_fleet_stop!(fleet_id) do
    Keyfleet.Chain.clear_divergence!(fleet_id)
    IO.puts("#{fleet_id} will be read again.")
  end

  defp with_release_repo(fun) do
    load_app()
    Application.put_env(@app, Keyfleet.Repo, migration_config!())

    {:ok, result, _started} = Ecto.Migrator.with_repo(Keyfleet.Repo, fn _repo -> fun.() end)
    result
  end

  @doc """
  Prepares an empty staging database for the first deployment.

  Staging owns a disposable database, so it has no copy of the tables this
  repository reads but does not own, `regent_names.platform_human_users`. This
  command creates a staging-only approximation of it with the shape the local
  fixture already proves sufficient, then runs every migration into `keyfleet_app`.

  It refuses any database that already carries migration state or the
  regent_names schema, and it repairs nothing: recovery from a half-finished
  bootstrap is to destroy and recreate the staging database.

  The deployed launcher passes no options, so it reads only the database the
  release configuration resolves. The options (`:getenv`, `:config`,
  `:migrations_path`) aim it at a disposable database under test.
  """
  def bootstrap_staging(opts \\ []) when is_list(opts) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)

    # The role is read before anything opens a connection, so no configuration
    # mistake can point this command at a database outside staging.
    if getenv.(@deployment_role_variable) != @staging_role do
      raise @bootstrap_role_error
    end

    load_app()
    Application.put_env(@app, Keyfleet.Repo, configuration!(opts, getenv))
    path = migrations_directory(opts)

    Ecto.Migrator.with_repo(Keyfleet.Repo, fn repo ->
      refuse_existing_state!(repo)

      # The fixture is the only definition of these tables' shape in the
      # repository, and the whole test suite runs on it. Calling it keeps
      # staging identical to that proven shape instead of copying it.
      Keyfleet.LocalDatabaseFixture.create_shared_tables!()

      repo.migrate!(path)
    end)
  end

  @doc """
  Lists what a deployed database and the release disagree about.

  Prints every migration the release carries that the database has not applied
  under `pending:`, and every version the database has applied whose file the
  release does not carry under `applied-without-file:`. Prints `none` when both
  are empty. It applies nothing, creates nothing, and takes no migration lock.
  Its options are the bootstrap's.
  """
  def pending_migrations(opts \\ []) when is_list(opts) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)
    load_app()
    Application.put_env(@app, Keyfleet.Repo, configuration!(opts, getenv))
    path = migrations_directory(opts)

    {:ok, {pending, applied_without_file}, _started} =
      Ecto.Migrator.with_repo(Keyfleet.Repo, &disagreements(&1, path))

    if pending == [] and applied_without_file == [], do: IO.puts("none")
    if pending != [], do: IO.puts("pending: #{Enum.join(pending, " ")}")

    if applied_without_file != [],
      do: IO.puts("applied-without-file: #{Enum.join(applied_without_file, " ")}")
  end

  defp disagreements(repo, path) do
    prefix = repo.default_prefix()

    unless table_exists?(repo, prefix, migration_source(repo)),
      do: raise(@missing_migration_table_error)

    migrations =
      Ecto.Migrator.migrations(repo, [path],
        prefix: prefix,
        skip_table_creation: true,
        migration_lock: false
      )

    carried = carried_versions(path)

    {for({:down, version, _name} <- migrations, do: version),
     for({:up, version, _name} <- migrations, version not in carried, do: version)}
  end

  # Ecto names an applied version with no file after a placeholder marker. The
  # set of versions the release actually carries answers the same question
  # without depending on that marker's text.
  defp carried_versions(path) do
    for file <- Path.wildcard(Path.join(path, "*.exs")),
        {version, "_" <> _name} <- [file |> Path.basename() |> Integer.parse()],
        into: MapSet.new(),
        do: version
  end

  # The Credits and Points code this release carries reads tables and indexes
  # from every migration its pinned library ships, so each must already be in
  # that schema's own ledger. Every missing version is named at once.
  defp require_shared_migrations!(repo) do
    unapplied =
      for {app, schema} <- [regent_credits: "regent_credits", regent_points: "regent_points"],
          {:down, version, _name} <-
            Ecto.Migrator.migrations(repo, [Application.app_dir(app, "priv/repo/migrations")],
              prefix: schema,
              skip_table_creation: true,
              migration_lock: false
            ),
          do: "#{schema} #{version}"

    if unapplied != [] do
      raise "These separately approved shared migrations must be applied before deployment: " <>
              Enum.join(unapplied, ", ")
    end

    :ok
  end

  defp refuse_existing_state!(repo) do
    prefix = repo.default_prefix()
    source = migration_source(repo)

    if table_exists?(repo, prefix, source) do
      raise "#{prefix}.#{source} already exists: destroy and recreate the staging database"
    end

    if schema_exists?(repo, @platform_schema) do
      raise "#{@platform_schema} schema already exists: destroy and recreate the staging database"
    end
  end

  defp table_exists?(repo, prefix, table) do
    %{rows: [[exists?]]} = Ecto.Adapters.SQL.query!(repo, @table_exists, [prefix, table])
    exists?
  end

  defp schema_exists?(repo, schema) do
    %{rows: [[exists?]]} = Ecto.Adapters.SQL.query!(repo, @schema_exists, [schema])
    exists?
  end

  defp migration_source(repo), do: repo.config()[:migration_source] || "schema_migrations"

  defp configuration!(opts, getenv) do
    Keyword.get_lazy(opts, :config, fn -> migration_config!(getenv) end)
  end

  defp migrations_directory(opts) do
    Keyword.get_lazy(opts, :migrations_path, &migrations_path/0)
  end

  defp load_app, do: :ok = Application.ensure_loaded(@app)

  defp migrations_path, do: Application.app_dir(@app, "priv/repo/migrations")
end

defmodule Keyfleet.Release do
  @moduledoc false

  @app :keyfleet
  @deployment_role_variable "KEYFLEET_DEPLOYMENT_ROLE"
  @staging_role "staging"
  @platform_schema "regent_names"
  @bootstrap_role_error "bootstrap-staging requires #{@deployment_role_variable} to be exactly staging"
  @missing_migration_table_error "no schema_migrations table: run bootstrap-staging first"

  def migration_config!(getenv \\ &System.get_env/1) do
    Keyfleet.DatabaseConfig.release_config!(getenv)
  end

  @doc """
  Brings a deployed database up to the release: runs every migration, then
  seeds the catalog as `seed_catalog!/0` does. Deploying runs it as the
  release command, so a deploy that takes a fleet's coming-soon mark away also
  opens that fleet's rooms. It never binds a fleet to a deployment.
  """
  def migrate do
    with_release_repo(fn ->
      Keyfleet.Repo.migrate!(migrations_path())
      seed_catalog!()
    end)
  end

  @doc """
  Binds one fleet to the deployment a deployed manifest records, the JSON
  `contracts/script/RecordKeyfleets.s.sol` writes for that fleet, opens the
  fleet's fixed and open rooms, and prints what it is now bound to. The fleet
  is bound and its rooms opened together or not at all.
  `bin/seed-deployment <path>` runs it. This is what puts a fleet's keys on
  sale, a coming-soon fleet's included; every other fleet is left as it is.

  Recording the same manifest again changes nothing; a manifest naming other
  contracts for a bound fleet, or wiring that differs from the fleets already
  bound, is refused and changes nothing. A running app reads only the fleets
  that were deployed when it started, so it must be restarted before it reads
  a newly bound fleet.
  """
  def seed_deployment(path), do: with_release_repo(fn -> seed_deployment!(path) end)

  @doc "Seeds from `path` through an already running repository, as `seed_deployment/1` does."
  # The path is the operator's own argument on the machine they are signed in to.
  # sobelow_skip ["Traversal.FileModule"]
  def seed_deployment!(path) do
    manifest = path |> File.read!() |> Jason.decode!()

    {:ok, fleet} =
      Ash.transact([Keyfleet.Fleets.Fleet, Keyfleet.Rooms.Room], fn ->
        fleet = Keyfleet.Fleets.record_manifest!(manifest)
        Keyfleet.Rooms.bootstrap_rooms!([fleet.id])
        fleet
      end)

    IO.puts("#{fleet.id}: #{fleet.contract_address} from block #{fleet.deployed_block}")

    :ok
  end

  @doc """
  Seeds the four fleets and opens the rooms of every fleet that is not coming
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

  @doc """
  Prints the keeper's wallet, whether it is stopped, each job's last
  recorded round, and on the chain its node serves, its balance, what it
  spent in the last 24 hours and its last 20 transactions there.
  `bin/keeper-status` runs it.
  """
  def keeper_status, do: with_release_repo(fn -> keeper_status!() end)

  @doc "Prints the keeper's status through an already running repository, as `keeper_status/0` does."
  def keeper_status! do
    case Application.fetch_env!(@app, Keyfleet.Keeper)[:private_key] do
      nil ->
        IO.puts("Keeper off: KEYFLEET_KEEPER_PRIVATE_KEY is not set.")

      key ->
        {:ok, wallet} = Keyfleet.Keeper.Wallet.new(key)
        IO.puts("Keeper wallet #{wallet.address}")
        print_keeper_stop()
        print_keeper_runs()
        {:ok, _started} = Application.ensure_all_started(:req)
        print_keeper_chain(Keyfleet.Keeper.Node.configured(), wallet.address)
    end
  end

  @doc """
  Clears the keeper's stop, once the wallet is the keeper's alone again, and
  prints the stop it cleared. The keeper sends again once the site is
  restarted. `bin/keeper-resume` runs it.
  """
  def keeper_resume, do: with_release_repo(fn -> keeper_resume!() end)

  @doc "Clears the keeper's stop through an already running repository, as `keeper_resume/0` does."
  def keeper_resume! do
    case Keyfleet.Keeper.resume() do
      {:ok, nil} ->
        IO.puts("The keeper is not stopped.")

      {:ok, stop} ->
        IO.puts(
          "Cleared the keeper's stop (#{stop.stop_reason}) from #{stop.finished_at}. " <>
            "Restart the site for the keeper to send again."
        )
    end
  end

  defp print_keeper_stop do
    case Keyfleet.Keeper.stopped() do
      {:ok, nil} ->
        IO.puts("Not stopped")

      {:ok, stop} ->
        IO.puts("Stopped (#{stop.stop_reason}) at #{stop.finished_at}: #{stop.notes}")

        IO.puts(
          "Once the wallet is the keeper's alone, run bin/keeper-resume and restart the site."
        )
    end
  end

  defp print_keeper_runs do
    for job <- [:reveal, :income] do
      case Keyfleet.Keeper.last_run!(job, actor: %Keyfleet.Actors.System{}) do
        nil ->
          IO.puts("#{job}: no round recorded")

        run ->
          IO.puts(
            "#{job}: #{run.outcome} at #{run.finished_at}, #{run.sent} sent, #{run.skipped} skipped"
          )
      end
    end

    :ok
  end

  defp print_keeper_chain(node, address) do
    with {:ok, chain_id} <- node.chain_id(),
         {:ok, balance} <- node.balance(address) do
      {:ok, %{settled: settled, waiting: waiting}} = Keyfleet.Keeper.spend(chain_id, address)
      waiting = Enum.sum(Map.values(waiting))

      IO.puts("Chain #{chain_id}, balance #{Keyfleet.Keeper.eth(balance)} ETH")

      IO.puts(
        "Spent in the last 24 hours: #{Keyfleet.Keeper.eth(settled)} ETH, and up to " <>
          "#{Keyfleet.Keeper.eth(waiting)} ETH more waiting (limit 0.01 ETH)"
      )

      print_keeper_txs(chain_id, address)
    else
      {:error, reason} -> IO.puts("The node did not answer: #{inspect(reason)}")
    end
  end

  defp print_keeper_txs(chain_id, address) do
    IO.puts("Last 20 transactions:")

    for tx <-
          Keyfleet.Keeper.list_latest_txs!(chain_id, address, actor: %Keyfleet.Actors.System{}) do
      [
        tx.sent_at,
        tx.job,
        tx.fleet_id,
        tx.function,
        tx.target,
        "nonce #{tx.nonce}",
        tx.status || "waiting",
        tx.result,
        tx.tx_hash
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> IO.puts()
    end

    :ok
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
  """
  def bootstrap_staging, do: bootstrap_staging_for_test([])

  @doc false
  # No deployed command reaches this: the launchers call the arity-zero entry
  # points above, and this variant exists only so the test suite can aim the
  # commands at a disposable database.
  def bootstrap_staging_for_test(opts) when is_list(opts) do
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
  """
  def pending_migrations, do: pending_migrations_for_test([])

  @doc false
  # Arity zero above for the same reason as the bootstrap: the deployed command
  # can only ever read the database its own release configuration resolves.
  def pending_migrations_for_test(opts) when is_list(opts) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)
    load_app()
    Application.put_env(@app, Keyfleet.Repo, configuration!(opts, getenv))
    path = migrations_directory(opts)

    {:ok, {pending, applied_without_file}, _started} =
      Ecto.Migrator.with_repo(Keyfleet.Repo, fn repo ->
        collect_disagreements(repo, path)
      end)

    report(pending, applied_without_file)
  end

  defp collect_disagreements(repo, path) do
    migrations = migration_status(repo, path)
    carried = carried_versions(path)

    {for({:down, version, _name} <- migrations, do: version),
     for({:up, version, _name} <- migrations, not MapSet.member?(carried, version), do: version)}
  end

  defp migration_status(repo, path) do
    case read_migration_status(repo, path) do
      {:ok, migrations} -> migrations
      :no_migration_table -> raise @missing_migration_table_error
    end
  end

  defp read_migration_status(repo, path) do
    {:ok,
     Ecto.Migrator.migrations(repo, [path],
       prefix: repo.default_prefix(),
       skip_table_creation: true,
       migration_lock: false
     )}
  rescue
    error in Postgrex.Error ->
      if undefined_migration_table?(error, migration_source(repo)) do
        :no_migration_table
      else
        reraise error, __STACKTRACE__
      end
  end

  defp undefined_migration_table?(
         %Postgrex.Error{postgres: %{code: :undefined_table, message: message}},
         source
       ),
       do: String.contains?(message, source)

  defp undefined_migration_table?(_error, _source), do: false

  # Ecto names an applied version with no file after a placeholder marker. The
  # set of versions the release actually carries answers the same question
  # without depending on that marker's text.
  defp carried_versions(path) do
    path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case file |> Path.basename() |> Integer.parse() do
        {version, "_" <> _name} -> [version]
        _unversioned -> []
      end
    end)
    |> MapSet.new()
  end

  defp report([], []), do: IO.puts("none")

  defp report(pending, applied_without_file) do
    if pending != [], do: IO.puts("pending: #{Enum.join(pending, " ")}")

    if applied_without_file != [] do
      IO.puts("applied-without-file: #{Enum.join(applied_without_file, " ")}")
    end
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
    %{rows: [[exists?]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_catalog.pg_class AS c
          JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
          WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'p')
        )
        """,
        [prefix, table]
      )

    exists?
  end

  defp schema_exists?(repo, schema) do
    %{rows: [[exists?]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = $1)",
        [schema]
      )

    exists?
  end

  defp migration_source(repo), do: repo.config()[:migration_source] || "schema_migrations"

  defp configuration!(opts, getenv) do
    Keyword.get_lazy(opts, :config, fn -> migration_config!(getenv) end)
  end

  defp migrations_directory(opts) do
    Keyword.get_lazy(opts, :migrations_path, &migrations_path/0)
  end

  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, @app}} -> :ok
    end
  end

  defp migrations_path do
    Application.app_dir(@app, "priv/repo/migrations")
  end
end

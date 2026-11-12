defmodule Keyfleet.Health do
  @moduledoc """
  Whether the site's own database answers, for the health check, and whether
  every migration this release carries is applied.
  """

  # A running server alone does not make the site ready: read one of the site's
  # own tables without returning rows, through the site's own pool, so a full
  # pool fails the check as it should. The timeout is below Fly's two-second
  # health deadline, and no error or connection detail leaves this module. The
  # schema is the repository's own configured name, never request input.
  # sobelow_skip ["SQL.Query"]
  def database_ready? do
    sql = "SELECT 1 FROM \"#{Keyfleet.Repo.default_prefix()}\".session_authorities LIMIT 0"

    match?(
      {:ok, _},
      Ecto.Adapters.SQL.query(Keyfleet.Repo, sql, [], timeout: 1_000, log: false)
    )
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  @doc """
  True when every migration file this release carries is recorded in the site's
  own schema. It only reads: no lock, and it never creates the ledger. A
  database that does not answer is `false`.
  """
  def migrations_applied? do
    Keyfleet.Repo
    |> Ecto.Migrator.migrations([Application.app_dir(:keyfleet, "priv/repo/migrations")],
      prefix: Keyfleet.Repo.default_prefix(),
      skip_table_creation: true,
      migration_lock: false,
      timeout: 1_000,
      log: false
    )
    |> Enum.all?(&match?({:up, _version, _name}, &1))
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end

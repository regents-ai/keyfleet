defmodule Mix.Tasks.Keyfleet.SetupLocalAuth do
  @moduledoc """
  Prepares the guarded local database: the shared tables this site reads and
  every migration. Only the repo is started, so it runs before the site does;
  `mix test` runs it first, since the site's job queue starts only on a
  migrated database.
  """
  use Mix.Task

  @shortdoc "Prepares the guarded local Keyfleet database"

  @impl true
  def run(_args) do
    unless Mix.env() in [:dev, :test], do: Mix.raise("local auth setup is dev/test only")
    Mix.Task.run("app.config")

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(Keyfleet.Repo, fn _repo ->
        Keyfleet.LocalDatabaseFixture.ensure_human_accounts!()
      end)

    Mix.shell().info("Local Keyfleet database is ready.")
  end
end

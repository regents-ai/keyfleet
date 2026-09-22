ExUnit.start(exclude: [external: true])
KeyFleet.LocalDatabaseFixture.ensure_human_accounts!()
Ecto.Adapters.SQL.Sandbox.mode(KeyFleet.Repo, :manual)

ExUnit.start(exclude: [external: true, autolaunch_fork: true])
Keyfleet.TestChainNode.start!()
Keyfleet.LocalDatabaseFixture.ensure_human_accounts!()
Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :manual)

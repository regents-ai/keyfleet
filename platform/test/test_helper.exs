ExUnit.start(exclude: [external: true, base_fork: true])
Keyfleet.TestChainNode.start!()
Ecto.Adapters.SQL.Sandbox.mode(Keyfleet.Repo, :manual)

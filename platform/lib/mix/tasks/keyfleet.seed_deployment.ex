defmodule Mix.Tasks.Keyfleet.SeedDeployment do
  @shortdoc "Binds the four fleets to a recorded deployment"

  @moduledoc """
  Reads the deployed manifest `contracts/script/RecordKeyfleets.s.sol` wrote
  and binds each fleet to its contract, reward ledger and vote contract, with
  the manifest's chain and deployment block, and opens each fleet's fixed and open rooms.
  A release runs the same step as
  `bin/seed-deployment`.

      mix keyfleet.seed_deployment ../contracts/deployments/base.deployed.json

  Running it again with the same manifest changes nothing. A manifest naming
  different contracts for a fleet that is already bound is refused.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]), do: Keyfleet.Release.seed_deployment!(path)

  def run(_args),
    do: Mix.raise("Usage: mix keyfleet.seed_deployment <path to deployed manifest>")
end

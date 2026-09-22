defmodule Mix.Tasks.KeyFleet.SeedDeployment do
  @shortdoc "Binds the four fleets to a recorded deployment"

  @moduledoc """
  Reads the deployed manifest `contracts/script/RecordKeyfleets.s.sol` wrote
  and binds each fleet to its contract, reward ledger and vote contract, with
  the manifest's chain and deployment block, and opens each fleet's core rooms.
  A release runs the same step as
  `bin/seed-deployment`.

      mix key_fleet.seed_deployment ../contracts/deployments/base.deployed.json

  Running it again with the same manifest changes nothing. A manifest naming
  different contracts for a fleet that is already bound is refused.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]), do: KeyFleet.Release.seed_deployment!(path)

  def run(_args),
    do: Mix.raise("Usage: mix key_fleet.seed_deployment <path to deployed manifest>")
end

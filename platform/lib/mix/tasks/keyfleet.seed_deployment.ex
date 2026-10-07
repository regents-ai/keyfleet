defmodule Mix.Tasks.Keyfleet.SeedDeployment do
  @shortdoc "Binds the catalog's fleets to their recorded deployment"

  @moduledoc """
  Reads the deployed record `contracts/script/RecordKeyfleets.s.sol` wrote,
  binds each catalog fleet it holds to its contracts and the shared wiring,
  with the record's chain and deployment block, and opens those fleets' fixed
  and open rooms. A release runs the same step as `bin/seed-deployment`; the
  anvil lab runs it with the lab's own record.

      mix keyfleet.seed_deployment ../contracts/deployments/base.deployed.json

  Running it again with the same record changes nothing. A record naming
  different contracts for a fleet that is already bound is refused.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]), do: Keyfleet.Release.seed_deployment!(path)

  def run(_args),
    do: Mix.raise("Usage: mix keyfleet.seed_deployment <path to deployed manifest>")
end

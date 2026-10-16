defmodule Mix.Tasks.Keyfleet.CheckClassic do
  @shortdoc "Checks Classic #1's deck, binding and Key 1 metadata against its deployed record"

  @moduledoc """
  Reads the deployed record `contracts/script/RecordKeyfleets.s.sol` wrote and
  checks Classic #1 against it, as `Keyfleet.Keys.ClassicCheck` describes:
  the shipped deck and trait table, the site's binding, and Key 1's Set Type,
  Set ID, traits and published card. Run it once Key 1 is bought and
  recorded, on a fork or on Base.

      mix keyfleet.check_classic ../contracts/deployments/base.deployed.json

  It prints what matched, or stops with what did not.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]), do: Keyfleet.Keys.ClassicCheck.run!(path)

  def run(_args), do: Mix.raise("Usage: mix keyfleet.check_classic <path to deployed record>")
end

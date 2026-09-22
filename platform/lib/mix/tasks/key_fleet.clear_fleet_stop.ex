defmodule Mix.Tasks.KeyFleet.ClearFleetStop do
  @shortdoc "Resumes reading a fleet stopped at a disagreement with the chain"

  @moduledoc """
  A fleet whose recorded key ownership disagreed with the chain stops being
  read until an operator has corrected the record by hand, as
  `docs/chain-reader.md` describes. Once it is corrected, this lets the fleet
  be read again. A release runs the same step as `bin/clear-fleet-stop`.

      mix key_fleet.clear_fleet_stop fibonacci_syndicate
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([fleet_id]), do: KeyFleet.Release.clear_fleet_stop!(fleet_id)

  def run(_args), do: Mix.raise("Usage: mix key_fleet.clear_fleet_stop <fleet id>")
end

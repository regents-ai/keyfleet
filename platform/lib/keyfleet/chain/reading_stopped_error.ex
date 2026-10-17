defmodule Keyfleet.Chain.ReadingStoppedError do
  @moduledoc """
  The chain reader is not reading a fleet and needs a person: the chain
  disagrees with the record (`Keyfleet.Chain.Scanner`), the node serves
  another chain than the fleet's (`Keyfleet.Chain.ReadFleet`), or no node is
  named while fleets are deployed (`Keyfleet.Chain.Watch`). Until someone
  acts, the fleet's treasury, proposals and Keys stop updating.

  `report/1` saves it with the site's errors (`Keyfleet.Alert`), so the three
  kinds of stop are three errors, each listing every occurrence with its own
  message (which fleet, which block).
  """
  defexception [:message]

  @doc """
  Saves the stop, with `message` saying which fleet and what to do. The
  caller's line places the error, so it must not be the caller's last call.
  """
  def report(message), do: Keyfleet.Alert.report(%__MODULE__{message: message})
end

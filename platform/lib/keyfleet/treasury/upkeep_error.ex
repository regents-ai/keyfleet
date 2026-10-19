defmodule Keyfleet.Treasury.UpkeepError do
  @moduledoc """
  Something the upkeep (`Keyfleet.Treasury.Upkeep`) should have pressed
  wasn't: its account has too little ETH for the network fee, a transaction
  it sent failed on the chain or never reached it, or an earlier one is
  still waiting to land. Each kind is its own error at /admin/errors
  (`Keyfleet.Alert`).
  """
  defexception [:message]

  @doc """
  Saves it, with `message` saying what happened and what to do. The caller's
  line places the error, so it must not be the caller's last call.
  """
  def report(message), do: Keyfleet.Alert.report(%__MODULE__{message: message})
end

defmodule Keyfleet.Treasury.OverdueError do
  @moduledoc """
  Money a fleet's contracts hold for someone has waited too long for anyone
  to move it (`Keyfleet.Treasury.OverdueCheck`): the Daily Treasury Slice to
  Keys, the protocol share owed to REGENT staking, or USDC from Key sales
  waiting to turn into REGENT. Each kind is its own error at /admin/errors
  (`Keyfleet.Alert`).
  """
  defexception [:message]

  @doc """
  Saves it, with `message` saying which fleets and what to do. The caller's
  line places the error, so it must not be the caller's last call.
  """
  def report(message), do: Keyfleet.Alert.report(%__MODULE__{message: message})
end

defmodule Keyfleet.Code.StoreDown do
  @moduledoc """
  The code store did not take or answer a git exchange the code gateway passed
  on (`KeyfleetWeb.Plugs.CodeGateway`): it could not be reached, stopped
  mid-exchange, or answered with a fault of its own. Git told whoever ran it
  that the code is unavailable, so a clone or push failed.

  `report/1` saves it with the site's errors (`Keyfleet.Alert`), each place
  that reports its own error listing every occurrence with its own message.
  """
  defexception [:message]

  @doc """
  Saves the failure, with `message` saying which fleet and what failed. The
  caller's line places the error, so it must not be the caller's last call.
  """
  def report(message), do: Keyfleet.Alert.report(%__MODULE__{message: message})
end

defmodule Keyfleet.Notebooks.HubSilentError do
  @moduledoc """
  A fleet's notebook hub did not answer what it was asked: making a holder an
  editor (`Keyfleet.Notebooks.admit/3`), listing the sessions open in it
  (`Keyfleet.Notebooks.session_room?/2`), or a request passed on or a live
  connection opened by its gateway (`KeyfleetWeb.Plugs.NotebookGateway`). Whoever asked was told the notebooks
  are unavailable, so until someone looks at the hub its members cannot work
  in it.

  `report/1` saves it with the site's errors (`Keyfleet.Alert`), each place
  that reports its own error listing every occurrence with its own message.
  """
  defexception [:message]

  @doc """
  Saves the failure, with `message` saying which fleet and what the hub said.
  The caller's line places the error, so it must not be the caller's last
  call.
  """
  def report(message), do: Keyfleet.Alert.report(%__MODULE__{message: message})
end

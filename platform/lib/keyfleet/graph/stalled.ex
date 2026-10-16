defmodule Keyfleet.Graph.Stalled do
  @moduledoc """
  A fleet's workspace stopped taking or showing changes: its graph host
  stopped (`Keyfleet.Graph.Writer`), or its read tables have not caught up
  with its log for longer than a host takes to start
  (`Keyfleet.Graph.Projector`). Writes are refused or wait, and pages show the
  workspace as it last was.

  Each is saved once per stall, when it starts, with the site's errors
  (`Keyfleet.Alert`); the writer and projector keep retrying by themselves.
  """
  defexception [:message]

  @doc """
  Saves the stall, with `message` saying which fleet and why. The caller's
  line places the error, so it must not be the caller's last call.
  """
  def report(message), do: Keyfleet.Alert.report(%__MODULE__{message: message})
end

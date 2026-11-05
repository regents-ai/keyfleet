defmodule Keyfleet.Keys.PresenceTimerError do
  @moduledoc """
  The presence timer (`Keyfleet.Keys.PresenceTimer`) needs someone: a send
  failed, a Key is close to lapsing, its wallet is low on ETH or its shards are
  ending. Each is its own error at /admin/errors (`Keyfleet.Alert`).
  """
  defexception [:message]

  @doc """
  Saves it, with `message` saying what to do. The caller's line places the
  error, so it must not be the caller's last call.
  """
  def report(message), do: Keyfleet.Alert.report(%__MODULE__{message: message})
end

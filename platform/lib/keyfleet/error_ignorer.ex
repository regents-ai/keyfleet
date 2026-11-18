defmodule Keyfleet.ErrorIgnorer do
  @moduledoc """
  Leaves out an exception the site answers below 500, such as not found or a bad
  request. Anyone can raise those by visiting a wrong address, so saving them
  would let anyone fill the table. Server faults, exits and throws are all kept.

  Also leaves out a job that failed for want of a connection to a notebook
  hub: that wait is saved where it happened (`Keyfleet.Notebooks.hub_run/2`),
  with the job and its attempt, so the job's failure would save it twice.
  """

  @behaviour ErrorTracker.Ignorer

  @impl ErrorTracker.Ignorer
  def ignore?(%ErrorTracker.Error{kind: "Elixir.Oban.PerformError", reason: reason}, _context),
    do: String.contains?(reason, "%" <> inspect(Keyfleet.Notebooks.HubSilentError) <> "{")

  def ignore?(%ErrorTracker.Error{kind: "Elixir." <> _module = kind}, _context),
    do: kind |> String.to_existing_atom() |> visitors?()

  def ignore?(_error, _context), do: false

  # Ash's four error classes take their status from the errors they wrap, so the
  # class names whose doing it was: bad input or a refusal, or a server fault.
  defp visitors?(class) when class in [Ash.Error.Invalid, Ash.Error.Forbidden], do: true
  defp visitors?(class) when class in [Ash.Error.Unknown, Ash.Error.Framework], do: false

  defp visitors?(exception),
    do:
      Code.ensure_loaded?(exception) and function_exported?(exception, :exception, 1) and
        Plug.Exception.status(exception.__struct__()) < 500
end

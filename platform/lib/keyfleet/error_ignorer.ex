defmodule Keyfleet.ErrorIgnorer do
  @moduledoc """
  Leaves out an exception the site answers below 500, such as not found or a bad
  request. Anyone can raise those by visiting a wrong address, so saving them
  would let anyone fill the table. Server faults, exits and throws are all kept.

  Also leaves out a job that failed for want of a connection to a notebook
  hub and nothing else: that wait is saved where it happened
  (`Keyfleet.Notebooks.hub_run/2`), with the job and its attempt, so the job's
  failure would save it twice. Only a failure whose whole printed reason is
  the hub client's answer for a wait, `{:error, {:hub, address, wait}}`, is
  left out; one that merely quotes the wait's name, or carries a wait beside
  anything else, is saved.
  """

  @behaviour ErrorTracker.Ignorer

  # Oban.PerformError's message, "<worker> failed with <inspected reason>", for
  # `Keyfleet.Notebooks.HubClient`'s answer when no hub connection came free.
  @hub_wait ~r/\A\S+ failed with \{:error, \{:hub, "(?:[^"\\]|\\.)*", %Keyfleet\.Notebooks\.HubSilentError\{message: "(?:[^"\\]|\\.)*"\}\}\}\z/

  @impl ErrorTracker.Ignorer
  def ignore?(%ErrorTracker.Error{kind: "Elixir.Oban.PerformError", reason: reason}, _context),
    do: Regex.match?(@hub_wait, reason)

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

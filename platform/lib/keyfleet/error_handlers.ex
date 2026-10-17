defmodule Keyfleet.ErrorHandlers do
  @moduledoc """
  ErrorTracker saves failed requests, pages and jobs from the telemetry
  handlers it attaches when it starts. Telemetry detaches a handler for good
  the first time it raises, and a save raises while the database can't be
  reached, so one failure during an outage would leave every later failure
  unsaved, long after the database came back, until the next restart.

  `attach/0` attaches each of ErrorTracker's handlers again under its own name,
  around the same function, so a save that fails is logged and the handler
  stays attached.
  """

  require Logger

  @integrations [ErrorTracker.Integrations.Phoenix, ErrorTracker.Integrations.Oban]

  @doc "Called once as the site starts, after ErrorTracker has attached its handlers."
  def attach do
    []
    |> :telemetry.list_handlers()
    |> Enum.filter(&(&1.id in @integrations))
    |> Enum.group_by(&{&1.id, &1.function, &1.config}, & &1.event_name)
    |> Enum.each(fn {{id, function, config}, events} ->
      :ok = :telemetry.detach(id)
      :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, {function, config})
    end)
  end

  @doc false
  def handle_event(event, measurements, metadata, {function, config}) do
    function.(event, measurements, metadata, config)
  catch
    kind, reason -> unsaved(Exception.format_banner(kind, reason))
  end

  defp unsaved(why),
    do: Logger.error("A failure couldn't be saved with the site's errors: " <> why)
end

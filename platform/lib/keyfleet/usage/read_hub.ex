defmodule Keyfleet.Usage.ReadHub do
  @moduledoc """
  Reads the notebook machines one fleet's hub lists (`Keyfleet.Usage.Machine`)
  and counts the fleet's notebook hours from them (`Keyfleet.Usage.Month`),
  queued every hour by `Keyfleet.Usage.Count` once it has counted the month.

  The month under way is counted each time. The month before is counted
  again only once it has a figure, so a month that ended before the hub was
  first read stays without one: its machines were never seen. A read that
  fails is not tried again; the next hour's read records everything it would
  have, as long as the hub still holds it (`Keyfleet.Usage.Machine`).

  It waits its turn with the other hub calls (the `notebook_hubs` queue runs
  one job), and a fleet's read is queued again only once the last has run.
  """
  use Oban.Worker,
    queue: :notebook_hubs,
    max_attempts: 1,
    unique: [keys: [:fleet_id], period: :infinity, states: :incomplete]

  alias Keyfleet.Actors.System
  alias Keyfleet.Notebooks.HubClient
  alias Keyfleet.Usage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fleet_id" => fleet_id}}) do
    with {:ok, machines} <- HubClient.machines(fleet_id) do
      seen_at = DateTime.utc_now()

      machines
      |> Enum.map(
        &(&1
          |> Map.take(["id", "kind", "started_at", "ended_at"])
          |> Map.merge(%{"fleet_id" => fleet_id, "seen_at" => seen_at}))
      )
      |> Usage.record_machines!(actor: %System{})

      this_month = Date.beginning_of_month(Date.utc_today())

      for month <- [Date.shift(this_month, month: -1), this_month],
          %Usage.Month{} = usage <- [Usage.month_usage!(fleet_id, month)],
          month == this_month or usage.notebook_seconds != nil,
          do: Usage.count_notebooks!(usage, actor: %System{})

      :ok
    end
  end
end

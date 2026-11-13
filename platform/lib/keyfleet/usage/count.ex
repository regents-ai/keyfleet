defmodule Keyfleet.Usage.Count do
  @moduledoc """
  Every hour (`config :keyfleet, Oban, cron:`): counts each fleet's usage in
  the month under way and in the month before it (`Keyfleet.Usage.Month`),
  in place of their last counts. The month before is counted again so the
  hour between a month's last count and its end is never left out, and a run
  that missed is made up by the next. Counting a month again gives the same
  figures while its records have not changed.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    this_month = Date.beginning_of_month(Date.utc_today())

    for fleet_id <- Keyfleet.Fleets.catalog_ids(),
        month <- [Date.shift(this_month, month: -1), this_month],
        do: Keyfleet.Usage.count_month!(fleet_id, month, actor: %Keyfleet.Actors.System{})

    :ok
  end
end

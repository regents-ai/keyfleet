defmodule Keyfleet.Seasons.Turns do
  @moduledoc """
  A minute after each season boundary (`config :keyfleet, Oban, cron:`):
  queues a `Keyfleet.Seasons.Turn` for each deployed fleet at the boundary
  just passed. A fleet's turn at a boundary is queued once, however many times
  this runs.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Keyfleet.Seasons
  alias Keyfleet.Seasons.Turn

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    boundary = DateTime.utc_now() |> Seasons.boundary() |> DateTime.to_iso8601()

    Enum.each(
      Keyfleet.Fleets.list_deployed_fleets!(),
      &Oban.insert!(Turn.new(%{fleet_id: &1.id, boundary: boundary}))
    )
  end
end

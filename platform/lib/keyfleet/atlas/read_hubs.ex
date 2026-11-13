defmodule Keyfleet.Atlas.ReadHubs do
  @moduledoc """
  Every hour (`config :keyfleet, Oban, cron:`): queues a read of each fleet's
  notebook hub for the Atlas (`Keyfleet.Atlas.ReadHub`).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Keyfleet.Atlas.ReadHub
  alias Keyfleet.Notebooks

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(Notebooks.hub_fleet_ids(), &Oban.insert!(ReadHub.new(%{fleet_id: &1})))
    :ok
  end
end

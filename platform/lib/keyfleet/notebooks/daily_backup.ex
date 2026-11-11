defmodule Keyfleet.Notebooks.DailyBackup do
  @moduledoc """
  Once a day (`config :keyfleet, Oban, cron:`): queues the copy of every
  changed notebook for each fleet with a notebook hub
  (`Keyfleet.Notebooks.Backups`), and removes copies kept longer than 90 days.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Keyfleet.Actors.System
  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.{Backup, Backups}

  @kept_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(Notebooks.hub_fleet_ids(), &Oban.insert!(Backups.new(%{fleet_id: &1})))

    Backup
    |> Ash.Query.for_read(
      :older_than,
      %{before: DateTime.add(DateTime.utc_now(), -@kept_days, :day)},
      actor: %System{}
    )
    |> Ash.bulk_destroy!(:forget, %{}, actor: %System{}, strategy: :atomic, notify?: false)

    :ok
  end
end

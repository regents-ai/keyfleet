defmodule Keyfleet.Code.Setup do
  @moduledoc """
  Makes one fleet's repository in the code store and records it
  (`Keyfleet.Code.Repository`). Queued the first time someone asks for the
  fleet's code (`queue/1`, from `Keyfleet.Code.owner/1`). Making it again
  finds the one already made, so a run that fails part way is simply run
  again. A failed run tries again a minute later, up to `max_attempts` runs.
  A setup that gave up is queued again by the next ask, and that is saved
  with the site's errors (`Keyfleet.Code.StoreDown`).
  """
  use Oban.Worker,
    queue: :code_store,
    max_attempts: 20,
    unique: [keys: [:fleet_id], period: :infinity, states: :incomplete]

  alias Keyfleet.Actors.System
  alias Keyfleet.Code
  alias Keyfleet.Code.{NodeClient, StoreDown}

  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fleet_id" => fleet_id}}) do
    case Code.get_repository(fleet_id, actor: %System{}) do
      {:ok, nil} ->
        with {:ok, owner} <- NodeClient.create_repository(fleet_id),
             {:ok, _repository} <- Code.record_repository(fleet_id, owner, actor: %System{}) do
          :ok
        end

      {:ok, _made} ->
        :ok
    end
  end

  @doc """
  Queues the fleet's setup unless it is queued already: `{:setting_up,
  seconds}` until its next run starts, 0 when it runs now; or
  `:setup_restarted` while a setup runs again after an earlier one gave up.
  The ask that starts it again saves that with the site's errors.
  """
  def queue(fleet_id) do
    gave_up? = gave_up?(fleet_id)
    job = Oban.insert!(new(%{fleet_id: fleet_id}))

    cond do
      not gave_up? ->
        {:setting_up, until_run(job)}

      job.conflict? ->
        :setup_restarted

      true ->
        StoreDown.report(
          "Setting up #{fleet_id}'s code gave up after #{job.max_attempts} tries; it starts again"
        )

        :setup_restarted
    end
  end

  defp gave_up?(fleet_id) do
    Oban.Repo.exists?(
      Oban.config(),
      Oban.Job.query(worker: __MODULE__, state: :discarded, args: %{fleet_id: fleet_id})
    )
  end

  # A job just queued may carry no time yet: it runs now.
  defp until_run(%Oban.Job{scheduled_at: %DateTime{} = at}),
    do: max(DateTime.diff(at, DateTime.utc_now()), 0)

  defp until_run(%Oban.Job{}), do: 0
end

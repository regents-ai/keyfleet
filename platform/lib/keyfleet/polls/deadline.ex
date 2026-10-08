defmodule Keyfleet.Polls.Deadline do
  @moduledoc """
  Closes a round at its deadline. Queued for the deadline in the transaction
  that opens the round (`Keyfleet.Polls.Changes.OpenRound`). A round that
  closed early, because every vote that counts was in, is left as it is, so
  running twice is safe.
  """
  use Oban.Worker,
    queue: :polls,
    max_attempts: 10,
    unique: [keys: [:round_id], period: :infinity, states: :incomplete]

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.AlreadyClosedError

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"round_id" => round_id}}) do
    case Polls.get_round_by_id!(round_id, actor: %System{}) do
      %{status: :open} = round -> close(round)
      _closed_or_gone -> :ok
    end
  end

  defp close(round) do
    case DateTime.diff(round.deadline_at, DateTime.utc_now(), :millisecond) do
      early when early > 0 -> {:snooze, div(early + 999, 1000)}
      _due -> closed(Polls.close_round(round, actor: %System{}))
    end
  end

  defp closed({:ok, _round}), do: :ok

  defp closed({:error, %Ash.Error.Invalid{errors: errors} = error}),
    do: if(Enum.any?(errors, &match?(%AlreadyClosedError{}, &1)), do: :ok, else: {:error, error})

  defp closed({:error, error}), do: {:error, error}
end

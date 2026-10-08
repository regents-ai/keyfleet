defmodule Keyfleet.Polls.Changes.CastVote do
  @moduledoc """
  Records a Key's vote under the session's lock, or hands back the vote that
  Key already has in the round.

  A first vote needs the round still open and before its deadline, the Key in
  the round's roster and still seated, and one of the round's moves. In a
  `:delegate` session a vote from any Key but the delegate's is a suggestion,
  written to the log as it arrives. Once every Key whose vote counts has
  voted, the round closes in the same transaction.
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.ActionUnknownError
  alias Keyfleet.Polls.Errors.NotInRoundError
  alias Keyfleet.Polls.Errors.RoundClosedError
  alias Keyfleet.Polls.Errors.RoundUnknownError
  alias Keyfleet.Polls.Errors.SessionUnknownError
  alias Keyfleet.Polls.Errors.VoteConflictError
  alias Keyfleet.Polls.Log
  alias Keyfleet.Polls.Vote
  alias Keyfleet.Rooms.Errors.NoKeyToWriteAsError

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    changeset
    |> Ash.Changeset.before_action(&place(&1, actor))
    |> Ash.Changeset.after_action(&settle/2)
  end

  defp place(changeset, actor) do
    fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)
    session_id = Ash.Changeset.get_argument(changeset, :session_id)
    number = Ash.Changeset.get_argument(changeset, :number)
    Log.lock!(session_id)

    with {:ok, session} <- session(fleet_id, session_id),
         {:ok, round} <- round(session_id, number),
         {:ok, key} <- key(actor, fleet_id),
         {:ok, attributes} <- vote(changeset, session, round, key, actor) do
      changeset
      |> Ash.Changeset.put_context(:poll, %{session: session, round: round})
      |> Ash.Changeset.force_change_attributes(attributes)
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp session(fleet_id, session_id) do
    case Polls.get_session!(fleet_id, session_id, actor: %System{}) do
      nil -> {:error, SessionUnknownError.exception(session_id: session_id)}
      session -> {:ok, session}
    end
  end

  defp round(session_id, number) do
    case Polls.get_round!(session_id, number, actor: %System{}) do
      nil -> {:error, RoundUnknownError.exception(number: number)}
      round -> {:ok, round}
    end
  end

  defp key(actor, fleet_id) do
    case Polls.key_of(actor, fleet_id) do
      nil -> {:error, NoKeyToWriteAsError.exception(fleet_id: fleet_id)}
      key -> {:ok, key}
    end
  end

  # A Key that already voted is answered with its vote, whatever has happened
  # to the round since, so a voter that never heard the answer can ask again.
  defp vote(changeset, session, round, key, actor) do
    case Polls.get_vote!(round.id, key, actor: %System{}) do
      nil ->
        first_vote(changeset, session, round, key, actor)

      earlier ->
        {:ok,
         %{round_id: round.id, token_id: key, wallet: earlier.wallet, counted: earlier.counted}}
    end
  end

  defp first_vote(changeset, session, round, key, actor) do
    action = Ash.Changeset.get_attribute(changeset, :action)

    cond do
      round.status != :open or not DateTime.after?(round.deadline_at, DateTime.utc_now()) ->
        {:error, RoundClosedError.exception(number: round.number)}

      key not in round.roster or Polls.get_seat!(session.id, key, actor: %System{}) == nil ->
        {:error, NotInRoundError.exception(number: round.number)}

      not Enum.any?(round.actions, &(&1.id == action)) ->
        {:error, ActionUnknownError.exception(action: action)}

      true ->
        {:ok,
         %{
           round_id: round.id,
           token_id: key,
           wallet: actor.wallet_address,
           counted: session.mode == :poll or key == session.delegate_key
         }}
    end
  end

  defp settle(changeset, vote) do
    %{session: session, round: round} = changeset.context.poll

    if Ash.Resource.get_metadata(vote, :upsert_skipped),
      do: same_move(changeset, vote, round),
      else: new_vote(vote, session, round)
  end

  defp same_move(changeset, vote, round) do
    if vote.action == Ash.Changeset.get_attribute(changeset, :action),
      do: {:ok, vote},
      else: {:error, VoteConflictError.exception(number: round.number)}
  end

  defp new_vote(vote, session, round) do
    unless vote.counted,
      do: Log.append!(session.id, :suggestion, %{vote: Vote.to_map(vote, round.number)})

    if all_in?(session, round), do: Polls.close_round!(round, actor: %System{})
    {:ok, vote}
  end

  # Every seated Key's vote is in for a poll; the delegate's for a delegate session.
  defp all_in?(session, round) do
    voted =
      round.id
      |> Polls.votes_in_round!(actor: %System{})
      |> Enum.filter(& &1.counted)
      |> MapSet.new(& &1.token_id)

    needed = if session.mode == :poll, do: round.roster, else: [session.delegate_key]
    Enum.all?(needed, &MapSet.member?(voted, &1))
  end
end

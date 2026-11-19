defmodule Keyfleet.Points.PollVote do
  @moduledoc """
  Regent Points' check of a Key's vote in a poll (`Keyfleet.Polls.Vote`),
  keyed by its id. It earns for the account that held the Key when the vote
  was cast (`Keyfleet.Points.Holder`), when that person cast it or an agent
  paired with them did.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Points.Holder
  alias Keyfleet.Polls

  def verify(%{"source_event_key" => id}) do
    case Polls.get_vote(id, load: [:poll], actor: %System{}) do
      {:ok, %{} = vote} -> cast(id, vote)
      {:ok, nil} -> {:error, :vote_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp cast(id, vote) do
    at = vote.inserted_at

    with {:ok, epoch} <- Holder.epoch_at(vote.poll.fleet_id, vote.token_id, at),
         {:ok, holder} <- Holder.holder(epoch, at),
         {:ok, actor} <- Holder.actor(holder, Holder.acting(vote, vote.wallet), at) do
      Holder.facts("poll_vote", id, holder, actor, at)
    end
  end
end

defmodule Keyfleet.Points.PollVote do
  @moduledoc """
  Regent Points' check of a person's first vote (`keyfleet.first_vote`): a
  poll vote their Key cast, by them or an agent paired with them. It reads
  the saved vote and answers with the person who held the Key when it voted.
  """

  alias Keyfleet.Points.Holder
  alias Keyfleet.Polls.{Poll, Vote}
  alias Keyfleet.Repo

  def verify(%{"source_event_key" => id}) do
    # No person is asking: Points' check reads the committed row as it was saved,
    # straight from the table, since the record offers no read without one.
    case Repo.get(Vote, id) do
      nil ->
        {:error, :vote_not_found}

      vote ->
        %Poll{fleet_id: fleet_id} = Repo.get!(Poll, vote.poll_id)

        with {:ok, holder} <- Holder.at(fleet_id, vote.token_id, vote.inserted_at),
             {:ok, actor} <- Holder.actor(holder, vote.agent_pairing_id),
             do: {:ok, Holder.facts("poll_vote", id, holder, actor, vote.inserted_at)}
    end
  end
end

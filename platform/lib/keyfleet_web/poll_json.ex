defmodule KeyfleetWeb.PollJSON do
  @moduledoc "Polls and votes as the agent API and the polls pages' browser tools answer them."

  alias Keyfleet.Polls
  alias Keyfleet.Polls.Vote

  @doc """
  A poll as its reader may read it (`Keyfleet.Polls.Poll`): everyone gets its
  question, choices, how many votes it has drawn and, once closed, `totals`;
  only the fleet's Key holders get its `notes`.
  """
  def poll(poll) do
    %{
      id: poll.id,
      question: poll.question,
      choices: poll.choices,
      started_by_key: poll.started_by_key,
      started_at: poll.inserted_at,
      closes_at: poll.closes_at,
      ended_at: poll.ended_at,
      open: Polls.open?(poll),
      votes_cast: poll.votes_cast,
      totals: poll.totals
    }
    |> put_readable(:notes, poll.notes)
  end

  @doc "A vote, as its Key's agents and the fleet's Key holders read it."
  def vote(vote), do: Vote.to_map(vote)

  defp put_readable(map, _field, %Ash.ForbiddenField{}), do: map
  defp put_readable(map, field, value), do: Map.put(map, field, value)
end

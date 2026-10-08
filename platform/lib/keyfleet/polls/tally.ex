defmodule Keyfleet.Polls.Tally do
  @moduledoc """
  How a closed round's votes become its result.

  Only votes that count are tallied: every seated Key's in a `:poll` session,
  the delegate's alone in a `:delegate` one. The move with the most votes
  wins; a tie goes to the move whose votes carry the higher total confidence
  (a vote without one adds nothing), then to the move listed first. A round
  nobody's counted vote reached has no winner.
  """

  @doc """
  The result of a round with `actions` (in the order they were listed) and its
  `votes`: `%{outcome: :decided | :no_votes, winner: action_id | nil, tally: tally}`,
  where `tally` holds each move's `counts` and every vote, revealed.
  """
  def decide(actions, votes) do
    counted = Enum.filter(votes, & &1.counted)

    counts =
      Enum.map(actions, fn %{id: id} ->
        for_move = Enum.filter(counted, &(&1.action == id))
        %{action: id, votes: length(for_move), confidence: confidence(for_move)}
      end)

    %{
      outcome: if(counted == [], do: :no_votes, else: :decided),
      winner: winner(counts),
      tally: %{counts: counts, votes: Enum.map(votes, &revealed/1)}
    }
  end

  defp winner(counts) do
    counts
    |> Enum.with_index()
    |> Enum.filter(fn {count, _index} -> count.votes > 0 end)
    |> Enum.max_by(fn {count, index} -> {count.votes, count.confidence, -index} end, fn -> nil end)
    |> case do
      nil -> nil
      {count, _index} -> count.action
    end
  end

  defp confidence(votes),
    do: votes |> Enum.map(&(&1.confidence || 0.0)) |> Enum.sum() |> Kernel.*(1.0)

  defp revealed(vote),
    do: %{
      key: vote.token_id,
      action: vote.action,
      confidence: vote.confidence,
      reason: vote.reason,
      counted: vote.counted
    }
end

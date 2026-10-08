defmodule Keyfleet.Polls.Calculations.Totals do
  @moduledoc """
  A closed round's result as anyone reads it: each move's count of counted
  votes, in the order the moves were listed, without who voted or how sure
  they were. Nil while the round is open.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:tally]

  @impl true
  def calculate(rounds, _opts, _context), do: Enum.map(rounds, &totals(&1.tally))

  defp totals(%{"counts" => counts}),
    do: Enum.map(counts, &%{action: &1["action"], votes: &1["votes"]})

  defp totals(nil), do: nil
end

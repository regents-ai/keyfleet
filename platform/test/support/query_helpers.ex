defmodule Keyfleet.QueryHelpers do
  @moduledoc "Counts the database queries a piece of work makes."

  @doc """
  Runs `fun` and answers `{count, result}`: how many database queries this
  process made while it ran, and what it answered. Queries other processes
  make meanwhile aren't counted.
  """
  def queries_during(fun) do
    test_pid = self()
    handler = "queries-during-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:keyfleet, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: send(test_pid, :query)
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {count_queries(0), result}
  end

  defp count_queries(count) do
    receive do
      :query -> count_queries(count + 1)
    after
      0 -> count
    end
  end
end

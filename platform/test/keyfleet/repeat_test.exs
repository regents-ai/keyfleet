defmodule Keyfleet.Chain.RepeatTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Keyfleet.Chain.Repeat

  # Each read is awaited, never raced against the clock: this bound only stops
  # a read that never comes from hanging the run, so a busy machine cannot fail
  # the test.
  @read_guard 5_000

  # Answers each read with the next of the fleet's answers, and tells the test
  # when it read.
  defmodule Reader do
    def read(fleet, _client) do
      answer = Agent.get_and_update(fleet.answers, fn [answer | rest] -> {answer, rest} end)
      send(fleet.test, {:read, System.monotonic_time(:millisecond)})

      case answer do
        :raise -> raise "a bad read"
        answer -> answer
      end
    end
  end

  test "a read that keeps failing is logged once and waited on longer each time" do
    failing = List.duplicate({:error, :not_read}, 4)

    log =
      capture_log(fn ->
        pid = start!(failing ++ [:raise, :ok] ++ List.duplicate(:ok, 100))

        failed = for _read <- 1..4, do: next_read()
        assert :sys.get_state(pid).wait == 80

        # One that raises is logged in full, waited on as a failure, and the
        # reads go on.
        raised = next_read()
        assert :sys.get_state(pid).wait == 160
        assert Process.alive?(pid)

        succeeded = next_read()
        assert :sys.get_state(pid).wait == 5

        # Each read came no sooner than the wait set after the one before it.
        reads = failed ++ [raised, succeeded]
        gaps = Enum.zip_with(tl(reads), reads, &-/2)

        for {gap, wait} <- Enum.zip(gaps, [10, 20, 40, 80, 160]), do: assert(gap >= wait)
      end)

    assert length(String.split(log, ":not_read")) == 2
    assert log =~ "[error]"
    assert log =~ "a bad read"
    assert log =~ "repeat_test.exs"
  end

  test "a different failure is logged again" do
    log =
      capture_log(fn ->
        start!(
          [{:error, :first}, {:error, :first}, {:error, :second}] ++ List.duplicate(:ok, 100)
        )

        for _read <- 1..4, do: next_read()
      end)

    assert length(String.split(log, ":first")) == 2
    assert length(String.split(log, ":second")) == 2
  end

  defp next_read do
    assert_receive {:read, at}, @read_guard
    at
  end

  defp start!(answers) do
    {:ok, agent} = Agent.start_link(fn -> answers end)
    fleet = %{id: "repeat_test", answers: agent, test: self()}
    start_supervised!({Repeat, {Reader, fleet, 5}})
  end
end

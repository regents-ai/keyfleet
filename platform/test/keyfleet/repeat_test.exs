defmodule KeyFleet.Chain.RepeatTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias KeyFleet.Chain.Repeat

  # Answers each read with the next of the fleet's answers, and tells the test.
  defmodule Reader do
    def read(fleet, _client) do
      answer = Agent.get_and_update(fleet.answers, fn [answer | rest] -> {answer, rest} end)
      send(fleet.test, :read)

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

        for _read <- 1..4, do: assert_receive(:read)
        assert :sys.get_state(pid).wait == 80

        # One that raises is logged in full, waited on as a failure, and the
        # reads go on.
        assert_receive :read
        assert :sys.get_state(pid).wait == 160
        assert Process.alive?(pid)

        assert_receive :read, 1_000
        assert :sys.get_state(pid).wait == 5
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

        for _read <- 1..3, do: assert_receive(:read)
        assert_receive :read, 1_000
      end)

    assert length(String.split(log, ":first")) == 2
    assert length(String.split(log, ":second")) == 2
  end

  defp start!(answers) do
    {:ok, agent} = Agent.start_link(fn -> answers end)
    fleet = %{id: "repeat_test", answers: agent, test: self()}
    start_supervised!({Repeat, {Reader, fleet, 5}})
  end
end

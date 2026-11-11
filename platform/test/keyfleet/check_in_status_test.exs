defmodule Keyfleet.CheckInStatusTest do
  use ExUnit.Case, async: true

  alias Keyfleet.Agents.CheckIn
  alias Keyfleet.Agents.CheckInStatus

  @now ~U[2026-09-25 12:00:00.000000Z]

  test "an agent with no check-in recorded hasn't checked in" do
    assert CheckInStatus.derive(nil, @now) == {:never_checked_in, "Hasn’t checked in"}
  end

  test "a check-in during a conversation counts as connected for two minutes" do
    assert status(session_at: ago(119)) == :connected_now
    assert status(session_at: ago(120)) == :connected_now
    assert status(session_at: ago(121)) == :no_schedule
  end

  test "a schedule is paused once twice its interval plus the grace passes with no check-in" do
    limit = (2 * 60 + 45) * 60

    confirmed = [minutes: 60, scheduled_at: ago(limit), confirmed_at: ago(limit)]
    assert status(confirmed) == :check_ins_working
    assert status(Keyword.put(confirmed, :scheduled_at, ago(limit + 1))) == :paused
  end

  test "a declared schedule works only once it is confirmed" do
    assert status(minutes: 30, scheduled_at: ago(60), confirmed_at: ago(60)) ==
             :check_ins_working

    assert status(minutes: 30, scheduled_at: ago(60)) == :confirming_schedule
  end

  test "being connected now wins over a paused schedule" do
    assert status(session_at: ago(5), minutes: 10, scheduled_at: ago(24 * 3600)) ==
             :connected_now
  end

  test "an agent that only contributed has no schedule" do
    assert CheckInStatus.derive(%CheckIn{last_check_in_at: ago(30)}, @now) ==
             {:no_schedule, "No scheduled check-ins"}
  end

  test "the light is green on time, amber when late or unconfirmed, red when missing" do
    assert CheckInStatus.light(nil, @now) == :off
    assert light(session_at: ago(30)) == :on

    on_time = [minutes: 30, scheduled_at: ago((30 + 45) * 60), confirmed_at: ago(3600)]
    assert light(on_time) == :on
    assert light(Keyword.put(on_time, :scheduled_at, ago((30 + 45) * 60 + 1))) == :late
    assert light(Keyword.put(on_time, :scheduled_at, ago((2 * 30 + 45) * 60 + 1))) == :off

    assert light(minutes: 30, scheduled_at: ago(60)) == :late
    assert light([]) == :late
  end

  defp light(fields), do: fields |> check_in() |> CheckInStatus.light(@now)

  defp status(fields), do: fields |> check_in() |> CheckInStatus.derive(@now) |> elem(0)

  defp check_in(fields) do
    %CheckIn{
      last_check_in_at: @now,
      last_session_at: fields[:session_at],
      last_scheduled_at: fields[:scheduled_at],
      schedule_minutes: fields[:minutes],
      schedule_confirmed_at: fields[:confirmed_at]
    }
  end

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)
end

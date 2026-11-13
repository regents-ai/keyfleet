defmodule Keyfleet.TreasuryLatenessTest do
  # When the fleet's money steps anyone may send started waiting, and which
  # have waited too long, read from one treasury reading alone.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Keyfleet.Treasury

  @eth Treasury.native()
  @token "0x" <> String.duplicate("4", 40)
  @silent "0x" <> String.duplicate("5", 40)
  @details %{@eth => {"ETH", 18}, @token => {"TKN", 6}, @silent => {nil, nil}}
  @now ~U[2026-11-13 12:00:00.000000Z]
  @limits %{split: 6 * 3600, send_share: 24 * 3600, convert: 3 * 3600}

  describe "waiting_since/3" do
    test "the slice waits from its opening while some asset holds at least what it splits from" do
      opened = ago(3600)

      for {assets, since} <- [
            {[held(@eth, 5 * 10 ** 16 - 1)], nil},
            {[held(@eth, 5 * 10 ** 16)], opened},
            {[held(@token, 100 * 10 ** 6 - 1)], nil},
            {[held(@eth, 0), held(@token, 100 * 10 ** 6)], opened},
            {[held(@silent, 10 ** 40)], nil},
            {[], nil}
          ] do
        assert split_since(next_run_at: opened, assets: assets) == since
      end
    end

    test "the slice waits for nothing before its time, nor before any Key is sold" do
      assets = [held(@eth, 10 ** 18)]

      assert split_since(next_run_at: DateTime.add(@now, 1), assets: assets) == nil
      assert split_since(next_run_at: @now, assets: assets) == @now
      assert split_since(next_run_at: nil, assets: assets) == nil
    end

    test "the staking share waits from when it was first read owed" do
      owed = ago(90_000)

      assert since(protocol_share_owed_since: owed).send_share == owed
      assert since(protocol_share_owed_since: nil).send_share == nil
    end

    test "the conversion waits from when it was first read waiting, or a piece last turned, whichever is later" do
      waiting = ago(10_000)
      earlier = ago(20_000)
      later = ago(5_000)

      assert since([conversion_waiting_since: waiting], nil).convert == waiting
      assert since([conversion_waiting_since: waiting], earlier).convert == waiting
      assert since([conversion_waiting_since: waiting], later).convert == later
      assert since([conversion_waiting_since: nil], later).convert == nil
    end
  end

  describe "late/2" do
    test "each step is late only once it has waited longer than its own limit" do
      for {step, limit} <- @limits do
        assert Treasury.late(%{step => ago(limit)}, @now) == []

        assert Treasury.late(%{step => ago(limit + 1)}, @now) == [
                 %{step: step, since: ago(limit + 1)}
               ]
      end
    end

    property "the late steps are those past their limits, oldest first" do
      check all waited <- fixed_map(Map.new(@limits, fn {step, _} -> {step, waited()} end)) do
        waiting = Map.new(waited, fn {step, seconds} -> {step, seconds && ago(seconds)} end)
        late = Treasury.late(waiting, @now)
        past = for {step, seconds} <- waited, seconds != nil and seconds > @limits[step], do: step

        assert Enum.sort(Enum.map(late, & &1.step)) == Enum.sort(past)
        assert Enum.all?(late, &(&1.since == waiting[&1.step]))
        assert late == Enum.sort_by(late, & &1.since, DateTime)
      end
    end
  end

  defp waited, do: one_of([constant(nil), integer(0..(48 * 3600))])

  defp split_since(fields), do: since(fields).split

  defp since(fields, turned_at \\ nil),
    do: Treasury.waiting_since(reading(fields), @details, turned_at)

  defp reading(fields) do
    Map.merge(
      %{
        block_time: @now,
        next_run_at: nil,
        assets: [],
        protocol_share_owed_since: nil,
        conversion_waiting_since: nil
      },
      Map.new(fields)
    )
  end

  defp held(asset, amount), do: %{asset: asset, held: amount, backed: 0}

  defp ago(seconds), do: DateTime.add(@now, -seconds)
end

defmodule Keyfleet.CodeAdmissionTest do
  use ExUnit.Case, async: false

  alias Keyfleet.{AccessCache, Code}

  @fleet "fleet_tech_classic"

  setup do
    Code.end_access(@fleet)
    :sys.get_state(AccessCache)
    :ok
  end

  # R-20261020-code-inflight-invalidation: a completed invalidation must not
  # be undone by an older ownership read that has not reached the cache yet.
  # This controls cache/read ordering only; no SQL concurrency is claimed.
  test "invalidation during an ownership read cannot restore that old admission" do
    assert after_invalidation({:ok, nil}) == {:ok, nil}
    assert Code.admitted(@fleet, "holder", fn -> {:ok, nil} end) == {:ok, nil}
  end

  test "a still-current holder remains admitted after a cache invalidation" do
    holder = holder(1)
    assert Code.admitted(@fleet, "holder", fn -> {:ok, holder} end) == {:ok, holder}
    Code.end_access(@fleet)
    :sys.get_state(AccessCache)
    assert Code.admitted(@fleet, "holder", fn -> {:ok, holder} end) == {:ok, holder}
  end

  test "an invalidated read returns current standing without caching the fallback" do
    current = holder(2)
    assert after_invalidation({:ok, current}) == {:ok, current}
    assert Code.admitted(@fleet, "holder", fn -> {:ok, nil} end) == {:ok, nil}
  end

  test "an invalidated read preserves a fresh read failure without a stale grant" do
    assert after_invalidation({:error, :read_failed}) == {:error, :read_failed}
    assert Code.admitted(@fleet, "holder", fn -> {:ok, nil} end) == {:ok, nil}
  end

  defp after_invalidation(current) do
    parent = self()
    reads = :atomics.new(1, [])
    former = holder(1)

    check = fn ->
      if :atomics.add_get(reads, 1, 1) == 1 do
        send(parent, {:ownership_read, self()})

        receive do
          :finish_old_read -> {:ok, former}
        after
          5_000 -> flunk("ownership-read barrier was never released")
        end
      else
        current
      end
    end

    reading = Task.async(fn -> Code.admitted(@fleet, "holder", check) end)
    assert_receive {:ownership_read, caller}
    Code.end_access(@fleet)
    :sys.get_state(AccessCache)
    send(caller, :finish_old_read)
    Task.await(reading)
  end

  defp holder(number),
    do: %{token_id: number, wallet: "0x" <> String.duplicate("a", 40), restricted?: false}
end

defmodule Keyfleet.Chain.RewardsWaitingTest do
  # The answers are kept in one table the whole application shares.
  use ExUnit.Case, async: false

  alias Keyfleet.Chain.RewardsWaiting
  alias Keyfleet.Chain.StubClient

  @fleet %{
    fleet_id: "fibonacci_cascade",
    rewards_address: "0x" <> String.duplicate("8", 40),
    usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  }
  @head_hash "0x" <> String.duplicate("c", 64)

  setup do
    :ets.delete_all_objects(RewardsWaiting)
    :ok
  end

  test "asks the fleet's rewards contract what the key has accrued in USDC, at the head" do
    answering(fn _to, _data, _block_hash -> {:ok, <<2_500_000::256>>} end)

    assert RewardsWaiting.read(@fleet, 12, StubClient) == {:ok, 2_500_000}

    <<selector::binary-size(4), _rest::binary>> = ExKeccak.hash_256("accrued(address,uint256)")
    usdc = Base.decode16!("833589fcd6edb6e08f4c7c32d4f71b54bda02913", case: :lower)

    assert StubClient.call_requests() == [
             {@fleet.rewards_address, selector <> <<0::96>> <> usdc <> <<12::256>>, @head_hash}
           ]
  end

  test "ten reads of one key within 30 seconds ask the chain once, and the next after asks again" do
    answering(fn _to, _data, _block_hash -> {:ok, <<7::256>>} end)

    for elapsed <- Enum.take_every(0..29_999, 3_333) do
      assert RewardsWaiting.read(@fleet, 12, StubClient, 1_000_000 + elapsed) == {:ok, 7}
    end

    assert length(StubClient.call_requests()) == 1

    assert RewardsWaiting.read(@fleet, 12, StubClient, 1_030_000) == {:ok, 7}
    assert length(StubClient.call_requests()) == 2
  end

  test "each key is read for itself" do
    answering(fn _to, <<_selector::32, _usdc::256, token_id::256>>, _block_hash ->
      {:ok, <<token_id * 1_000_000::256>>}
    end)

    assert RewardsWaiting.read(@fleet, 3, StubClient) == {:ok, 3_000_000}
    assert RewardsWaiting.read(@fleet, 20, StubClient) == {:ok, 20_000_000}
  end

  test "a read that fails keeps nothing, so the next one asks again" do
    answering(fn _to, _data, _block_hash -> {:error, :chain_unavailable} end)
    assert RewardsWaiting.read(@fleet, 12, StubClient) == {:error, :chain_unavailable}

    answering(fn _to, _data, _block_hash -> {:ok, <<1::256>>} end)
    assert RewardsWaiting.read(@fleet, 12, StubClient) == {:ok, 1}
  end

  test "an answer that is not one number is a failure" do
    answering(fn _to, _data, _block_hash -> {:ok, <<1::8>>} end)

    assert RewardsWaiting.read(@fleet, 12, StubClient) == {:error, :unreadable_answer}
  end

  defp answering(calls) do
    StubClient.put_chain(
      %{number: 1_000, hash: @head_hash, timestamp: DateTime.utc_now()},
      [],
      calls: calls
    )
  end
end

defmodule Keyfleet.Chain.RewardsWaitingTest do
  # The answers are kept in one table the whole application shares.
  use ExUnit.Case, async: false

  alias Keyfleet.Chain.RewardsWaiting
  alias Keyfleet.Chain.StubClient

  @fleet %{
    fleet_id: "fibonacci_cascade",
    chain_fleet_id: 3,
    rewards_address: "0x" <> String.duplicate("8", 40)
  }
  # Key 12 of fleet 3, as the reward ledger names it.
  @key 30_000_000_012
  @head_hash "0x" <> String.duplicate("c", 64)
  @eth "0x0000000000000000000000000000000000000000"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @holder "0x" <> String.duplicate("a", 40)

  # Pinned from `cast sig` of each view function.
  @reward_assets "0x880ec04e"
  @accrued "0xbfe87f4d"
  @credits "0x637cd7f0"

  setup do
    :ets.delete_all_objects(RewardsWaiting)
    :ok
  end

  # The ledger's assets, then for each what the key has accrued and the
  # holder's credit, all at the head. The ledger here says each key has
  # accrued its own number in its fleet, and the holder has 2 in credit.
  test "asks the fleet's reward ledger what waits for the key and its holder in each asset" do
    answering(fn
      _to, @reward_assets, _hash ->
        {:ok, addresses([@eth, @usdc])}

      _to, @accrued <> args, _hash ->
        {:ok,
         <<args |> String.slice(64, 64) |> String.to_integer(16) |> rem(10_000_000_000)::256>>}

      _to, @credits <> _args, _hash ->
        {:ok, <<2::256>>}
    end)

    assert RewardsWaiting.read(@fleet, 12, @holder, StubClient) ==
             {:ok,
              [
                %{asset: @eth, accrued: 12, credit: 2},
                %{asset: @usdc, accrued: 12, credit: 2}
              ]}

    assert StubClient.call_requests() == [
             {@fleet.rewards_address, @reward_assets, @head_hash},
             {@fleet.rewards_address, @accrued <> arg(@eth) <> number(@key), @head_hash},
             {@fleet.rewards_address, @credits <> arg(@eth) <> arg(@holder), @head_hash},
             {@fleet.rewards_address, @accrued <> arg(@usdc) <> number(@key), @head_hash},
             {@fleet.rewards_address, @credits <> arg(@usdc) <> arg(@holder), @head_hash}
           ]
  end

  test "ten reads of one key within 30 seconds ask the chain once, and the next after asks again" do
    answering(fn
      _to, @reward_assets, _hash -> {:ok, addresses([@usdc])}
      _to, _data, _hash -> {:ok, <<7::256>>}
    end)

    for elapsed <- Enum.take_every(0..29_999, 3_333) do
      assert {:ok, [%{accrued: 7}]} =
               RewardsWaiting.read(@fleet, 12, @holder, StubClient, 1_000_000 + elapsed)
    end

    assert length(StubClient.call_requests()) == 3

    assert {:ok, _waiting} = RewardsWaiting.read(@fleet, 12, @holder, StubClient, 1_030_000)
    assert length(StubClient.call_requests()) == 6
  end

  test "a read that fails keeps nothing, so the next one asks again" do
    answering(fn _to, _data, _hash -> {:error, :chain_unavailable} end)
    assert RewardsWaiting.read(@fleet, 12, @holder, StubClient) == {:error, :chain_unavailable}

    answering(fn
      _to, @reward_assets, _hash -> {:ok, addresses([@usdc])}
      _to, _data, _hash -> {:ok, <<1::256>>}
    end)

    assert {:ok, [%{accrued: 1, credit: 1}]} =
             RewardsWaiting.read(@fleet, 12, @holder, StubClient)
  end

  test "an answer that is not what was asked for is a failure" do
    answering(fn
      _to, @reward_assets, _hash -> {:ok, addresses([@usdc])}
      _to, _data, _hash -> {:ok, <<1::8>>}
    end)

    assert RewardsWaiting.read(@fleet, 12, @holder, StubClient) == {:error, :unreadable_answer}
  end

  defp answering(calls) do
    StubClient.put_chain(
      %{number: 1_000, hash: @head_hash, timestamp: DateTime.utc_now(), base_fee: 0},
      [],
      calls: calls
    )
  end

  defp addresses(list),
    do: <<32::256, length(list)::256>> <> Enum.map_join(list, &(<<0::96>> <> address(&1)))

  defp address("0x" <> hex), do: Base.decode16!(hex, case: :lower)
  defp arg("0x" <> hex), do: String.duplicate("0", 24) <> hex
  defp number(value), do: <<value::256>> |> Base.encode16(case: :lower)
end

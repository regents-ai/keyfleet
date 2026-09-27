defmodule Keyfleet.Keeper.AnvilTest do
  # The keeper's reveals and protocol share against a real node: a local
  # anvil, never a real network, with the fleet `KeeperLab.s.sol` puts on
  # it. The keeper is anvil's first test account and the lab's buyer its
  # second.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Keyfleet.KeeperHelpers

  alias Keyfleet.Actors.System
  alias Keyfleet.{AnvilLab, ChainHelpers, Fleets, Keeper, Repo}
  alias Keyfleet.Keeper.{Income, Reveals, RpcNode, Sender, Wallet}

  @moduletag :external
  @moduletag timeout: 600_000

  @fleet_id "fleet_tech_classic"
  @buyer "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  @max_fee 2_000_000_000

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()

    url = AnvilLab.start!()
    %{"fleet" => fleet, "staking" => staking} = AnvilLab.lab!(url, @buyer)
    deploy!(@fleet_id, fleet, 31_337)
    ChainHelpers.seed_cursor!(@fleet_id)

    {:ok, wallet} = Wallet.new(anvil_key())
    # Anvil answers a send before its block is written, so the keeper waits
    # a little between its looks for a receipt, as it waits a second on Base.
    {:ok, sender} = Sender.start(%{Sender.new(wallet, RpcNode) | receipt_poll_ms: 100})
    {:ok, reveals} = Reveals.start(sender)

    %{url: url, fleet: fleet, staking: staking, sender: sender, reveals: reveals}
  end

  test "a request the node leaves waiting is raised at the same nonce, and one of them is mined",
       %{url: url, fleet: fleet, sender: sender, reveals: reveals} do
    # Neither key's request was accepted when it was sold.
    assert requested_at(sender, fleet, 1) == 0
    assert requested_at(sender, fleet, 2) == 0

    # With nothing being mined, key 1's request is sent and raised three times,
    # and the round goes no further.
    AnvilLab.rpc!(url, "evm_setAutomine", [false])

    {{sender, reveals}, log} = with_log(fn -> Reveals.run(sender, reveals) end)

    [first | raises] = txs()
    assert length(raises) == 3

    for tx <- [first | raises] do
      assert %{nonce: 0, function: :request_reveal, args: %{"arg" => 1}, status: nil} = tx
    end

    for {earlier, later} <- Enum.zip([first | raises], raises) do
      assert later.max_fee == div(earlier.max_fee * 5 + 3, 4)
      assert later.max_priority_fee == div(earlier.max_priority_fee * 5 + 3, 4)
      assert later.replaces_tx_hash == earlier.tx_hash
    end

    newest = List.last(raises)
    assert newest.max_fee <= @max_fee
    assert log =~ "Keeper left #{newest.tx_hash} waiting"
    assert pending(url) == [newest.tx_hash]

    # One block, then a round with blocks mined again: the newest is the one
    # included, the three before it were replaced, and key 2 is asked for.
    AnvilLab.rpc!(url, "evm_mine")
    AnvilLab.rpc!(url, "evm_setAutomine", [true])
    {sender, _reveals} = Reveals.run(sender, reveals)

    assert [
             %{nonce: 0, args: %{"arg" => 1}, status: :replaced},
             %{nonce: 0, args: %{"arg" => 1}, status: :replaced},
             %{nonce: 0, args: %{"arg" => 1}, status: :replaced},
             %{nonce: 0, args: %{"arg" => 1}, status: :mined, result: "reveal_requested"} =
               mined,
             %{nonce: 1, args: %{"arg" => 2}, status: :mined, result: "reveal_requested"}
           ] = txs()

    assert mined.tx_hash == newest.tx_hash

    for tx <- [first | raises] -- [newest] do
      assert AnvilLab.rpc!(url, "eth_getTransactionByHash", [tx.tx_hash]) == nil
    end

    receipt = AnvilLab.receipt!(url, mined.tx_hash)
    assert receipt["status"] == "0x1"
    assert AnvilLab.number(receipt["blockNumber"]) == mined.block_number
    assert AnvilLab.number(receipt["gasUsed"]) == mined.gas_used

    assert requested_at(sender, fleet, 1) > 0
    assert requested_at(sender, fleet, 2) > 0
    assert runs() == [{:reveal, :sent}]
  end

  test "the fleet's protocol share is sent to staking once, and not again the same day",
       %{url: url, fleet: fleet, staking: staking, sender: sender} do
    # Two per cent of two ten-USDC keys.
    assert owed(sender, fleet) == 400_000

    sender = Income.run(sender)

    assert [%{function: :send_protocol_share, target: ^fleet, status: :mined} = sent] = txs()
    receipt = AnvilLab.receipt!(url, sent.tx_hash)
    assert receipt["status"] == "0x1"
    assert owed(sender, fleet) == 0
    assert registered(url, staking) == 400_000

    # A key sold since makes the fleet owe again, but the keeper's share
    # went less than a day ago.
    buy(url, fleet)
    assert owed(sender, fleet) == 200_000

    Income.run(sender)
    assert [^sent] = txs()
    assert runs() == [{:income, :sent}]
  end

  defp owed(sender, fleet) do
    {:ok, owed} = Sender.read(sender, fleet, :protocol_share_owed)
    owed
  end

  # What the stand-in staking contract has had registered with it.
  defp registered(url, staking) do
    AnvilLab.number(
      AnvilLab.rpc!(url, "eth_call", [
        %{to: staking, data: hex(selector("registered()"))},
        "latest"
      ])
    )
  end

  # The buyer's third key, at its ten-USDC price.
  defp buy(url, fleet) do
    data =
      selector("purchase(address,uint256,uint256)") <>
        words([0, 10_000_000, 2 ** 40])

    hash =
      AnvilLab.rpc!(url, "eth_sendTransaction", [%{from: @buyer, to: fleet, data: hex(data)}])

    assert AnvilLab.receipt!(url, hash)["status"] == "0x1"
  end

  defp selector(signature), do: binary_part(ExKeccak.hash_256(signature), 0, 4)
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  defp requested_at(sender, fleet, token_id) do
    {:ok, at} = Sender.read(sender, fleet, :reveal_requested_at, [token_id])
    at
  end

  # The keeper's transactions, by nonce, each nonce's in the order sent.
  defp txs do
    Keeper.Transaction
    |> Ash.read!(actor: %System{})
    |> Enum.sort_by(&{&1.nonce, &1.max_fee})
  end

  defp pending(url) do
    for {_from, by_nonce} <- AnvilLab.rpc!(url, "txpool_content")["pending"],
        {_nonce, tx} <- by_nonce,
        do: tx["hash"]
  end
end

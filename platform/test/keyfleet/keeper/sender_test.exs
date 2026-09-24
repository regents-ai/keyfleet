defmodule KeyFleet.Keeper.SenderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import KeyFleet.KeeperHelpers

  alias KeyFleet.Actors.System
  alias KeyFleet.{Fleets, Keeper, KeeperHelpers, Repo}
  alias KeyFleet.Keeper.{Calls, Sender, StubNode, Transaction, Wallet}

  @anvil_key KeeperHelpers.anvil_key()
  @keeper KeeperHelpers.address(:keeper)
  # Anvil's second public test account, as a keeper whose key was changed.
  @other_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @other_keeper "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

  @fleet_id "fibonacci_syndicate"
  @fleet KeeperHelpers.address(:fleet)
  @locker KeeperHelpers.address(:locker)
  @escrow KeeperHelpers.address(:escrow)
  @splitter KeeperHelpers.address(:splitter)
  @receiver KeeperHelpers.address(:receiver)
  @usdc KeeperHelpers.address(:usdc)
  @regent KeeperHelpers.address(:regent)
  @subject KeeperHelpers.address(:subject)
  @stranger KeeperHelpers.address(:stranger)
  @strategy KeeperHelpers.address(:strategy)
  @factory KeeperHelpers.address(:factory)
  @lp_token_id KeeperHelpers.lp_token_id()

  @gwei 1_000_000_000
  @bigint 9_223_372_036_854_775_807
  @system %System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    deploy!(@fleet_id, @fleet, 8_453)
    deploy!("fibonacci_cascade", "0x" <> String.duplicate("c1", 20), 1)

    test = self()

    :telemetry.attach_many(
      {__MODULE__, test},
      [[:keyfleet, :keeper, :tx], [:keyfleet, :keeper, :paused], [:keyfleet, :keeper]],
      &__MODULE__.forward/4,
      test
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, test}) end)
    :ok
  end

  # Handlers are global, so only this test's own events reach it.
  @doc false
  def forward(event, measurements, metadata, test) do
    if self() == test, do: send(test, {:telemetry, event, measurements, metadata})
  end

  describe "a fleet's own calls" do
    test "go to the fleet, recorded before they are sent and settled from the receipt" do
      sender = started!()

      assert {:ok, tx, receipt, _sender} = Sender.send(sender, reveal(7))

      assert [raw] = StubNode.sent()
      assert tx.tx_hash == hash(raw)

      # Priority 0.001 gwei, twice the 0.005 gwei base fee on top, and a
      # reveal's 200,000 gas floor over its 100,000 estimate.
      assert decode(raw) == %{
               chain_id: 8_453,
               nonce: 0,
               max_priority_fee: 1_000_000,
               max_fee: 11_000_000,
               gas_limit: 200_000,
               to: @fleet,
               data: calldata!(:request_reveal, @fleet, 7)
             }

      assert %{
               status: :mined,
               job: :reveal,
               fleet_id: @fleet_id,
               function: :request_reveal,
               target: @fleet,
               args: %{"arg" => 7},
               nonce: 0,
               block_number: 1_001,
               gas_used: 60_000,
               effective_gas_price: 6_000_000,
               l1_fee_wei: 2_000,
               cost_wei: 360_000_002_000
             } = Ash.get!(Transaction, tx.id, actor: @system)

      assert receipt.status == 1

      assert_received {:telemetry, [:keyfleet, :keeper, :tx], _count,
                       %{function: :request_reveal, outcome: :mined}}

      assert_received {:telemetry, [:keyfleet, :keeper],
                       %{
                         wallet_balance_wei: 50_000_000_000_000_000,
                         spent_24h_wei: 360_000_002_000
                       }, _metadata}
    end

    test "a reveal records whether the coordinator took it, and alerts when it refused" do
      StubNode.put_chain(
        mine: fn
          1, _raw ->
            {:mined, 1, [reveal_log(:requested, @fleet, 1)]}

          2, _raw ->
            {:mined, 1, [reveal_log(:refused, @fleet, 2)]}

          # Logs for another key, or from another contract, say nothing.
          3, _raw ->
            {:mined, 1, [reveal_log(:refused, @fleet, 4), reveal_log(:refused, @stranger, 3)]}

          4, _raw ->
            {:mined, 0, [reveal_log(:refused, @fleet, 4)]}
        end
      )

      sender = start!()

      {sender, log} =
        with_log(fn ->
          assert {:ok, %{result: "reveal_requested"}, _receipt, sender} =
                   Sender.send(sender, reveal(1))

          assert {:ok, %{result: "reveal_refused"}, _receipt, sender} =
                   Sender.send(sender, reveal(2))

          assert {:ok, %{result: nil}, _receipt, sender} = Sender.send(sender, reveal(3))
          sender
        end)

      assert [_alert] = Regex.scan(~r/Keeper alert: the VRF coordinator refused/, log)

      assert log =~
               "Keeper alert: the VRF coordinator refused #{@fleet_id}'s reveal of key 2 in "

      # A reverted request says nothing but that it reverted.
      capture_log(fn ->
        assert {:ok, %{status: :reverted, result: nil}, _receipt, _sender} =
                 Sender.send(sender, reveal(4))
      end)

      assert Enum.map(Keeper.list_latest_txs!(8_453, @keeper, actor: @system), & &1.result) ==
               [nil, nil, "reveal_refused", "reveal_requested"]
    end

    test "take the next nonce and a gas limit 30% over the estimate" do
      StubNode.put_chain(nonce: 12, estimate: fn _from, _to, _data -> {:ok, 250_001} end)
      sender = start!()

      assert {:ok, tx, _receipt, _sender} =
               Sender.send(sender, request(:send_protocol_share, @fleet, nil))

      assert %{nonce: 12, gas_limit: 325_002} = tx
    end

    test "a status of 0 is recorded as reverted, with an alert" do
      StubNode.put_chain(mine: fn _n, _raw -> {:mined, 0} end)
      sender = start!()

      log =
        capture_log(fn ->
          assert {:ok, %{status: :reverted, cost_wei: 360_000_002_000}, %{status: 0}, _sender} =
                   Sender.send(sender, reveal(1))
        end)

      assert log =~ "Keeper alert: request_reveal to #{@fleet} for #{@fleet_id} reverted"

      assert_received {:telemetry, [:keyfleet, :keeper, :tx], _count, %{outcome: :reverted}}
    end
  end

  describe "a target" do
    test "other than the call's own contract is refused, and nothing is sent" do
      sender = started!()

      for request <- [
            reveal(1, @stranger),
            request(:recognize_surplus, @escrow, @usdc),
            request(:send_protocol_share, @splitter, nil),
            request(:sync_launch, @escrow, nil),
            # Income contracts and the strategy are known only inside a round.
            request(:release, @escrow, nil),
            request(:sweep, @receiver, @usdc),
            request(:migrate, @strategy, @stranger)
          ] do
        assert {:error, :foreign_target, _sender} = Sender.send(sender, request)
      end

      assert {:ok, :refused, sender} =
               Sender.income_round(sender, @fleet_id, fn sender, _round ->
                 for request <- [
                       request(:release, @splitter, nil),
                       request(:collect, @escrow, @lp_token_id),
                       request(:sweep, @fleet, @usdc),
                       request(:recognize_surplus_revenue, @receiver, @usdc),
                       request(:recognize_surplus, @splitter, @usdc),
                       request(:migrate, @strategy, @stranger)
                     ] do
                   assert {:error, :foreign_target, _sender} = Sender.send(sender, request)
                 end

                 {:refused, sender}
               end)

      assert {:ok, :refused, sender} =
               Sender.settle_round(sender, @fleet_id, fn sender, _round ->
                 for request <- [
                       request(:migrate, @factory, @stranger),
                       request(:release, @escrow, nil)
                     ] do
                   assert {:error, :foreign_target, _sender} = Sender.send(sender, request)
                 end

                 for request <- [
                       request(:migrate, @strategy, @escrow),
                       request(:recognize_surplus, @fleet, @usdc)
                     ] do
                   assert {:error, :foreign_argument, _sender} = Sender.send(sender, request)
                 end

                 {:refused, sender}
               end)

      # The round closes after its function: none is left open.
      assert sender.income == %{}

      assert {:error, :foreign_target, _sender} =
               Sender.send(sender, request(:release, @escrow, nil))

      assert StubNode.sent() == []
      assert Keeper.list_latest_txs!(8_453, @keeper, actor: @system) == []
    end

    test "of a fleet the site does not know, or on another chain, is refused" do
      sender = started!()

      assert {:error, :unknown_fleet, _sender} =
               Sender.send(sender, %{
                 job: :reveal,
                 fleet_id: "elsewhere",
                 call: call!(:request_reveal, @fleet, 1)
               })

      cascade = "0x" <> String.duplicate("c1", 20)

      assert {:error, :wrong_chain, _sender} =
               Sender.send(sender, %{
                 job: :reveal,
                 fleet_id: "fibonacci_cascade",
                 call: call!(:request_reveal, cascade, 1)
               })

      assert StubNode.sent() == []
    end

    test "every function the keeper may call reaches its own contract" do
      sender = started!()

      requests = [
        reveal(1),
        request(:recognize_surplus, @fleet, @usdc),
        request(:send_protocol_share, @fleet, nil),
        request(:sync_launch, @fleet, nil),
        request(:release, @escrow, nil),
        request(:collect, @locker, @lp_token_id),
        request(:sweep, @receiver, @usdc),
        request(:recognize_surplus_revenue, @splitter, @usdc)
      ]

      settle = request(:migrate, @strategy, @stranger)
      assert Enum.sort(Enum.map([settle | requests], & &1.call.fn)) == Calls.functions()

      assert {:ok, round, sender} =
               Sender.income_round(sender, @fleet_id, fn sender, round ->
                 sender =
                   Enum.reduce(requests, sender, fn request, sender ->
                     assert {:ok, %{status: :mined}, _receipt, sender} =
                              Sender.send(sender, request)

                     sender
                   end)

                 {round, sender}
               end)

      assert round == %{
               escrow: @escrow,
               locker: @locker,
               receiver: @receiver,
               splitter: @splitter,
               lp_token_id: @lp_token_id,
               tokens: [@usdc, @regent, @subject]
             }

      assert {:ok, round, _sender} =
               Sender.settle_round(sender, @fleet_id, fn sender, round ->
                 assert {:ok, %{status: :mined}, _receipt, sender} = Sender.send(sender, settle)
                 {round, sender}
               end)

      assert round == %{strategy: @strategy, auction: @stranger}
      assert Enum.map(StubNode.sent(), &decode(&1).nonce) == Enum.to_list(0..8)
    end

    test "takes only the launch's LP position and its USDC, REGENT or subject token" do
      sender = started!()

      refused = [
        request(:collect, @locker, @lp_token_id + 1),
        request(:sweep, @receiver, @stranger),
        request(:recognize_surplus_revenue, @splitter, @stranger),
        request(:recognize_surplus, @fleet, @stranger)
      ]

      allowed = [
        request(:sweep, @receiver, @regent),
        request(:recognize_surplus_revenue, @splitter, @subject),
        request(:recognize_surplus, @fleet, @regent)
      ]

      {:ok, :done, sender} =
        Sender.income_round(sender, @fleet_id, fn sender, _round ->
          for request <- refused do
            assert {:error, :foreign_argument, _sender} = Sender.send(sender, request)
          end

          assert StubNode.sent() == []

          sender =
            Enum.reduce(allowed, sender, fn request, sender ->
              assert {:ok, %{status: :mined}, _receipt, sender} = Sender.send(sender, request)
              sender
            end)

          {:done, sender}
        end)

      # Outside a round no token is known.
      assert {:error, :foreign_argument, _sender} =
               Sender.send(sender, request(:recognize_surplus, @fleet, @usdc))
    end

    test "of an income round is opened only when escrow, splitter and receiver all pay the fleet" do
      for contract <- [@escrow, @splitter, @receiver] do
        StubNode.put_chain(calls: answering(launch(treasury: %{contract => @stranger})))

        log =
          capture_log(fn ->
            assert {:error, :treasury_mismatch, _sender} =
                     Sender.income_round(start!(), @fleet_id, &unreached/2)
          end)

        assert log =~ "Keeper alert: #{@fleet_id}'s"
        assert log =~ "pays #{@stranger}, not the fleet"
      end

      assert StubNode.sent() == []
    end

    test "of an income round is opened only when the launch record and distribution agree" do
      for distribution <- [
            %{splitter: @stranger},
            %{lp_token_id: @lp_token_id + 1}
          ] do
        StubNode.put_chain(calls: answering(launch(distribution: distribution)))

        log =
          capture_log(fn ->
            assert {:error, :launch_mismatch, _sender} =
                     Sender.income_round(start!(), @fleet_id, &unreached/2)
          end)

        assert log =~
                 "Keeper alert: #{@fleet_id}'s launch record and launch distribution disagree"
      end

      StubNode.put_chain(calls: answering(launch(distribution: %{treasury: @stranger})))

      log =
        capture_log(fn ->
          assert {:error, :treasury_mismatch, _sender} =
                   Sender.income_round(start!(), @fleet_id, &unreached/2)
        end)

      assert log =~ "#{@fleet_id}'s launch distribution pays #{@stranger}, not the fleet"
    end

    test "of an income round is not opened when the chain does not answer" do
      StubNode.put_chain(calls: fn _from, _to, _data -> {:error, :chain_unavailable} end)

      assert {:error, :chain_unavailable, %{income: income}} =
               Sender.income_round(start!(), @fleet_id, &unreached/2)

      assert income == %{}
    end
  end

  describe "fees and spending" do
    test "nothing is sent while the base fee is above 2 gwei" do
      StubNode.put_chain(block: %{number: 1, timestamp: 1, base_fee: 2 * @gwei + 1})
      assert {:error, :base_fee_too_high, _sender} = Sender.send(start!(), reveal(1))
      assert StubNode.sent() == []
    end

    test "the maximum fee is held to 2 gwei, with the priority fee under it" do
      StubNode.put_chain(block: %{number: 1, timestamp: 1, base_fee: 1_500_000_000})
      assert {:ok, tx, _receipt, _sender} = Sender.send(start!(), reveal(1))
      assert {tx.max_fee, tx.max_priority_fee} == {2 * @gwei, 1_000_000}

      StubNode.put_chain(nonce: 1, max_priority_fee: 3 * @gwei)
      assert {:error, :priority_fee_too_high, _sender} = Sender.send(start!(), reveal(1))
    end

    test "a call refused in its estimate is not sent" do
      revert = {:revert, <<1, 2, 3, 4>>, <<5::256>>}
      StubNode.put_chain(estimate: fn _from, _to, _data -> {:error, revert} end)

      assert {:error, ^revert, _sender} = Sender.send(start!(), reveal(1))
      assert StubNode.sent() == []
      assert Keeper.list_latest_txs!(8_453, @keeper, actor: @system) == []
    end

    test "nothing is sent that could take the day's spending past 0.01 ETH" do
      # Already spent: 0.01 ETH less 2,000,000 gwei-gas; a reveal may cost 2.2e12 wei.
      settled!(nonce: 90, cost_wei: 10_000_000_000_000_000 - 2_000_000_000_000)
      StubNode.put_chain(nonce: 91)
      sender = start!()

      {refused, log} =
        with_log(fn ->
          assert {:error, :spend_ceiling, sender} = Sender.send(sender, reveal(1))
          assert {:error, :spend_ceiling, sender} = Sender.send(sender, reveal(1))
          sender
        end)

      assert [_alert] = Regex.scan(~r/Keeper alert: sending would take/, log)
      assert log =~ "past its 0.01 ETH limit"
      assert StubNode.sent() == []
      assert runs() == [{:reveal, :paused_spend_ceiling}]

      assert_received {:telemetry, [:keyfleet, :keeper, :paused], _count,
                       %{job: :reveal, reason: :spend_ceiling}}

      refute_received {:telemetry, [:keyfleet, :keeper, :paused], _count, _metadata}

      # A cheaper call fits, and lifts the pause.
      StubNode.update(
        block: %{number: 1, timestamp: 1, base_fee: 1_000_000},
        receipt: %{gas_used: 60_000, effective_gas_price: 2_000_000, l1_fee: 2_000}
      )

      assert {:ok, _tx, _receipt, %{ceiling_reached?: false} = sender} =
               Sender.send(refused, request(:send_protocol_share, @fleet, nil))

      assert runs() == [{:reveal, :paused_spend_ceiling}, {:income, :unpaused_spend_ceiling}]

      # Only the end of a pause is recorded, not every send that fits.
      StubNode.update(nonce: 92)
      assert {:ok, _tx, _receipt, _sender} = Sender.send(sender, reveal(2))
      assert length(runs()) == 2
    end

    test "a spending pause in force at start is not recorded or alerted again, and ends" do
      settled!(nonce: 90, cost_wei: 10_000_000_000_000_000 - 2_000_000_000_000)
      StubNode.put_chain(nonce: 91)
      capture_log(fn -> Sender.send(start!(), reveal(1)) end)
      assert runs() == [{:reveal, :paused_spend_ceiling}]
      assert_received {:telemetry, [:keyfleet, :keeper, :paused], _count, _metadata}

      # The keeper restarts.
      assert %{ceiling_reached?: true} = sender = start!()

      {sender, log} =
        with_log(fn ->
          assert {:error, :spend_ceiling, sender} = Sender.send(sender, reveal(1))
          sender
        end)

      refute log =~ "Keeper alert"
      assert runs() == [{:reveal, :paused_spend_ceiling}]
      refute_received {:telemetry, [:keyfleet, :keeper, :paused], _count, _metadata}

      StubNode.update(
        block: %{number: 1, timestamp: 1, base_fee: 1_000_000},
        receipt: %{gas_used: 60_000, effective_gas_price: 2_000_000, l1_fee: 2_000}
      )

      assert {:ok, _tx, _receipt, %{ceiling_reached?: false}} =
               Sender.send(sender, request(:send_protocol_share, @fleet, nil))

      assert runs() == [{:reveal, :paused_spend_ceiling}, {:income, :unpaused_spend_ceiling}]
    end

    test "a replacement counts at its dearest in place of the one it replaces" do
      # Room for 3e12 wei: the reveal at 2.2e12 and its first replacement at
      # 2.75e12 fit; the second, at 3.4e12, does not.
      settled!(nonce: 90, cost_wei: 10_000_000_000_000_000 - 3_000_000_000_000)
      StubNode.put_chain(nonce: 91, mine: fn _n, _raw -> :pending end)

      {result, log} = with_log(fn -> Sender.send(start!(), reveal(1)) end)

      assert {:error, :spend_ceiling, %{ceiling_reached?: true}} = result
      assert log =~ "Keeper alert: sending would take"
      assert length(StubNode.sent()) == 2
      assert length(Keeper.list_outstanding_txs!(8_453, @keeper, actor: @system)) == 2
    end
  end

  describe "a transaction with no receipt" do
    test "is replaced at the same nonce with both fees a quarter higher" do
      StubNode.put_chain(mine: fn n, _raw -> if n == 1, do: :pending, else: {:mined, 1} end)

      assert {:ok, tx, _receipt, _sender} = Sender.send(start!(), reveal(1))

      assert [first_raw, second_raw] = StubNode.sent()
      first = decode(first_raw)
      second = decode(second_raw)

      assert second.nonce == first.nonce
      assert {second.max_fee, second.max_priority_fee} == {13_750_000, 1_250_000}
      assert {first.max_fee, first.max_priority_fee} == {11_000_000, 1_000_000}

      assert Map.drop(second, [:max_fee, :max_priority_fee]) ==
               Map.drop(first, [:max_fee, :max_priority_fee])

      assert tx.tx_hash == hash(second_raw)
      assert tx.replaces_tx_hash == hash(first_raw)

      assert [%{status: :mined}, %{status: :replaced, tx_hash: replaced}] =
               Keeper.list_latest_txs!(8_453, @keeper, actor: @system)

      assert replaced == hash(first_raw)
    end

    test "the original is taken when it arrives after its replacement was sent" do
      StubNode.put_chain(mine: fn _n, _raw -> :pending end)
      sender = start!()
      {:waiting, waiting, sender} = Sender.send(sender, reveal(1))
      [first | _replacements] = StubNode.sent()
      StubNode.mine(hash(first), 1)

      StubNode.update(mine: fn _n, _raw -> {:mined, 1} end)
      assert {:ok, next, _receipt, _sender} = Sender.send(sender, reveal(2))
      assert next.nonce == 1

      statuses =
        Map.new(Keeper.list_latest_txs!(8_453, @keeper, actor: @system), &{&1.tx_hash, &1.status})

      assert statuses[hash(first)] == :mined
      assert statuses[waiting.tx_hash] == :replaced
      assert Enum.count(statuses, fn {_hash, status} -> status == :replaced end) == 3
    end

    test "is left waiting after three replacements" do
      StubNode.put_chain(mine: fn _n, _raw -> :pending end)
      assert {:waiting, tx, _sender} = Sender.send(start!(), reveal(1))

      fees = Enum.map(StubNode.sent(), &decode(&1).max_fee)
      assert fees == [11_000_000, 13_750_000, 17_187_500, 21_484_375]
      assert tx.max_fee == 21_484_375

      assert Enum.all?(
               Keeper.list_latest_txs!(8_453, @keeper, actor: @system),
               &is_nil(&1.status)
             )
    end

    test "is sent again as it is where a raise would pass 2 gwei" do
      StubNode.put_chain(
        mine: fn _n, _raw -> :pending end,
        block: %{number: 1, timestamp: 1, base_fee: 999_000_000}
      )

      assert {:waiting, tx, _sender} = Sender.send(start!(), reveal(1))

      assert [raw, raw] = StubNode.sent()
      assert tx.tx_hash == hash(raw)
      assert [%{max_fee: 1_999_000_000}] = Keeper.list_latest_txs!(8_453, @keeper, actor: @system)
    end

    test "goes through once the node takes it at the highest fee" do
      # The node refuses the first four, the last at 1.955 gwei, as a node
      # does while the wallet cannot pay; the fifth attempt is that one again.
      StubNode.put_chain(
        block: %{number: 1, timestamp: 1, base_fee: 500_000_000},
        send: fn attempt, _raw ->
          if attempt <= 4, do: {:error, :insufficient_funds}, else: :ok
        end
      )

      sender = start!()
      # Sends are logged at info. Only this module sends while it runs.
      Logger.put_module_level(Sender, :info)
      on_exit(fn -> Logger.delete_module_level(Sender) end)

      {sender, log} =
        with_log(fn ->
          Enum.reduce(1..4, sender, fn _attempt, sender ->
            assert {:error, {:send_failed, :insufficient_funds}, sender} =
                     Sender.send(sender, reveal(1))

            sender
          end)
        end)

      assert [_alert, _, _, _] = Regex.scan(~r/Keeper alert: the node refused/, log)
      refute log =~ "Keeper sent"
      assert StubNode.sent() == []

      fees = Enum.map(Keeper.list_latest_txs!(8_453, @keeper, actor: @system), & &1.max_fee)
      assert fees == [1_955_078_125, 1_564_062_500, 1_251_250_000, 1_001_000_000]

      {result, log} = with_log(fn -> Sender.send(sender, reveal(2)) end)
      assert {:ok, %{nonce: 1}, _receipt, _sender} = result
      assert log =~ "Keeper sent request_reveal to #{@fleet} for #{@fleet_id} at nonce 0"

      assert [again, next] = StubNode.sent()
      assert decode(again).max_fee == 1_955_078_125
      assert decode(next).nonce == 1

      assert [%{nonce: 1, status: :mined}, %{status: :mined, tx_hash: included} | replaced] =
               Keeper.list_latest_txs!(8_453, @keeper, actor: @system)

      assert included == hash(again)
      assert Enum.map(replaced, & &1.status) == [:replaced, :replaced, :replaced]
    end

    test "is raised only while its call passes the checks again" do
      StubNode.put_chain(
        calls: answering(launch()),
        send: fn attempt, _raw -> if attempt == 1, do: {:error, :unavailable}, else: :ok end
      )

      sender = start!()

      capture_log(fn ->
        assert {:ok, {:error, {:send_failed, :unavailable}, _refused}, _sender} =
                 Sender.income_round(sender, @fleet_id, fn sender, _round ->
                   {Sender.send(sender, request(:release, @escrow, nil)), sender}
                 end)
      end)

      # The escrow now pays someone else: the release is left waiting.
      StubNode.update(calls: answering(launch(treasury: %{@escrow => @stranger})))

      log =
        capture_log(fn ->
          assert {:error, :waiting, _sender} = Sender.send(sender, reveal(1))
        end)

      assert log =~ "did not pass the checks again: :treasury_mismatch"
      assert StubNode.sent() == []

      assert [%{function: :release, status: nil}] =
               Keeper.list_latest_txs!(8_453, @keeper, actor: @system)
    end

    test "with a receipt it cannot have is left waiting, with an alert" do
      # More gas than a reveal's 200,000 limit, a price above any maximum fee
      # the keeper sets, and a cost past what the record holds. Each chain
      # knows none of the others' receipts, so each sends a replacement.
      for receipt <- [
            %{gas_used: 200_001},
            %{effective_gas_price: 3 * @gwei},
            %{l1_fee: @bigint}
          ] do
        StubNode.put_chain(receipt: receipt)

        {result, log} = with_log(fn -> Sender.send(start!(), reveal(1)) end)

        assert {:error, :impossible_receipt, _sender} = result
        assert log =~ "Keeper alert: the node gave"
        assert log =~ "a receipt it cannot have"
      end

      assert [_, _, _] = txs = Keeper.list_latest_txs!(8_453, @keeper, actor: @system)
      assert Enum.all?(txs, &is_nil(&1.status))
    end
  end

  describe "starting" do
    test "settles what was left waiting, from its receipt" do
      waiting!()
      [_first, second | _rest] = StubNode.sent()
      StubNode.mine(hash(second), 1)

      sender = start!()
      assert sender.stopped == nil

      statuses =
        Enum.map(
          Keeper.list_latest_txs!(8_453, @keeper, actor: @system),
          &{&1.tx_hash, &1.status}
        )

      assert {hash(second), :mined} in statuses
      assert Enum.count(statuses, &match?({_hash, :replaced}, &1)) == 3
    end

    test "leaves what another wallet left waiting to that wallet" do
      waiting!()
      sent = StubNode.sent()
      StubNode.update(mine: fn _n, _raw -> {:mined, 1} end)

      other = start!(@other_key)

      assert other.wallet.address == @other_keeper
      assert other.stopped == nil
      assert StubNode.sent() == sent
      assert Keeper.list_outstanding_txs!(8_453, @other_keeper, actor: @system) == []
      assert length(Keeper.list_outstanding_txs!(8_453, @keeper, actor: @system)) == 4
      assert Sender.spent_24h(other) == {:ok, 0}

      start!()
      assert Keeper.list_outstanding_txs!(8_453, @keeper, actor: @system) == []
    end

    test "replaces what is still waiting" do
      waiting!()
      StubNode.update(mine: fn _n, _raw -> {:mined, 1} end)

      start!()

      assert [newest | _older] = Keeper.list_latest_txs!(8_453, @keeper, actor: @system)
      assert %{status: :mined, max_fee: 26_855_469, nonce: 0} = newest
      assert Keeper.list_outstanding_txs!(8_453, @keeper, actor: @system) == []
    end

    test "stops when another transaction took the nonce" do
      waiting!()
      StubNode.update(latest: 1, pending: 1)

      {sender, log} = with_log(fn -> start!() end)

      assert sender.stopped == :replaced_externally
      assert log =~ "Keeper alert: another transaction took nonce 0 from #{@keeper}"

      assert Enum.all?(
               Keeper.list_latest_txs!(8_453, @keeper, actor: @system),
               &(&1.status == :replaced_externally)
             )

      assert {:error, :stopped, _sender} = Sender.send(sender, reveal(2))
      assert length(StubNode.sent()) == 4

      # The stop holds across a restart until it is resumed.
      assert %{stopped: :replaced_externally} = start!()
      assert {:ok, %{stop_reason: :replaced_externally}} = Keeper.resume()
      assert %{stopped: nil} = start!()
    end

    test "takes the nonce as someone else's only once a later block has no receipt either" do
      waiting!()
      [_first, second | _rest] = StubNode.sent()
      StubNode.update(latest: 1, pending: 1)
      StubNode.mine_later(hash(second), 1)

      sender = start!()

      assert sender.stopped == nil
      assert {:ok, nil} = Keeper.stopped()

      assert {hash(second), :mined} in Enum.map(
               Keeper.list_latest_txs!(8_453, @keeper, actor: @system),
               &{&1.tx_hash, &1.status}
             )
    end

    test "waits for a node behind a nonce it has seen taken" do
      StubNode.put_chain()
      assert {:ok, %{nonce: 0}, _receipt, sender} = Sender.send(start!(), reveal(1))

      StubNode.update(latest: 0, pending: 0)
      assert {:error, :node_behind, _sender} = Sender.send(sender, reveal(2))
      # So does a sender started again, from the record.
      assert {:error, :node_behind, _sender} = Sender.send(start!(), reveal(2))
      assert length(StubNode.sent()) == 1

      StubNode.update(latest: 1, pending: 1)
      assert {:ok, %{nonce: 1}, _receipt, _sender} = Sender.send(sender, reveal(2))
    end
  end

  test "a nonce the keeper did not use stops it" do
    StubNode.put_chain(nonce: 3, pending: 4)
    sender = start!()

    {result, log} = with_log(fn -> Sender.send(sender, reveal(1)) end)

    assert {:error, :stopped, %{stopped: :foreign_nonce} = sender} = result
    assert log =~ "Keeper alert: #{@keeper} has transactions pending from nonce 3"
    assert log =~ "The keeper has stopped sending"

    assert_received {:telemetry, [:keyfleet, :keeper, :paused], _count,
                     %{job: :reveal, reason: :foreign_nonce}}

    StubNode.update(pending: 3)
    assert {:error, :stopped, _sender} = Sender.send(sender, reveal(1))
    assert StubNode.sent() == []

    assert {:ok, %{stop_reason: :foreign_nonce, job: :reveal, notes: notes}} = Keeper.stopped()
    assert notes =~ "has transactions pending from nonce 3"
    assert %{stopped: :foreign_nonce} = start!()
  end

  test "a node naming another hash than the keeper's own stops it" do
    other = "0x" <> String.duplicate("ab", 32)
    StubNode.put_chain(send: fn _attempt, _raw -> {:ok, other} end)

    {result, log} = with_log(fn -> Sender.send(start!(), reveal(1)) end)

    assert {:error, :stopped, %{stopped: :tx_hash_mismatch}} = result
    assert log =~ "Keeper alert: the node named #{other} for the transaction the keeper signed"
    refute log =~ "Keeper sent"
    assert {:ok, %{stop_reason: :tx_hash_mismatch}} = Keeper.stopped()
  end

  test "a low balance raises one alert while it stays low" do
    StubNode.put_chain(balance: 9_000_000_000_000_000)

    log =
      capture_log(fn ->
        sender = start!()
        assert sender.low_balance?
        Sender.report(sender)
      end)

    assert [_alert] = Regex.scan(~r/Keeper alert: wallet under 0.01 ETH, 0.009 ETH left/, log)
  end

  test "shows the wallet's address in place of the wallet" do
    {:ok, wallet} = Wallet.new(@anvil_key)
    redacted = Sender.redact(Sender.new(wallet, StubNode))

    assert redacted.wallet == @keeper
    refute inspect(redacted, limit: :infinity) =~ String.slice(@anvil_key, 2..-1//1)
  end

  # Sends one reveal that never arrives, replaced three times, at nonce 0.
  defp waiting! do
    StubNode.put_chain(mine: fn _n, _raw -> :pending end)
    {:waiting, _tx, _sender} = Sender.send(start!(), reveal(1))
  end

  defp unreached(_sender, _round), do: flunk("the round was opened")

  defp started! do
    StubNode.put_chain(calls: answering(launch()))
    start!()
  end

  defp reveal(token_id, target \\ @fleet), do: request(:request_reveal, target, token_id)

  defp request(fun, target, arg),
    do: %{job: job(fun), fleet_id: @fleet_id, call: call!(fun, target, arg)}

  defp job(:request_reveal), do: :reveal
  defp job(_fun), do: :income

  defp settled!(attrs) do
    attrs = Map.new(attrs)

    tx =
      Keeper.record_sent_tx!(
        %{
          job: :reveal,
          fleet_id: @fleet_id,
          function: :request_reveal,
          target: @fleet,
          from_address: @keeper,
          args: %{"arg" => 1},
          chain_id: 8_453,
          nonce: attrs.nonce,
          tx_hash: "0x" <> String.duplicate("d", 63) <> Integer.to_string(rem(attrs.nonce, 10)),
          max_fee: 1,
          max_priority_fee: 1,
          gas_limit: 1
        },
        actor: @system
      )

    {:ok, tx} =
      Keeper.settle(tx, %{
        status: :mined,
        block_number: 1,
        gas_used: 1,
        effective_gas_price: 1,
        cost_wei: attrs.cost_wei
      })

    tx
  end
end

defmodule KeyFleet.Keeper.RevealsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import KeyFleet.KeeperHelpers

  require Logger

  alias KeyFleet.Actors.System
  alias KeyFleet.{ChainHelpers, Fleets, Keeper, KeeperHelpers, Keys, Repo}
  alias KeyFleet.Keeper.{Reveals, StubNode}

  @fleet_id "fibonacci_syndicate"
  @fleet KeeperHelpers.address(:fleet)
  @other_id "fleet_tech_classic"
  @other "0x" <> String.duplicate("c1", 20)
  @stranger KeeperHelpers.address(:stranger)
  @coordinator "0x" <> String.duplicate("c0", 20)
  @subscription_id 555
  @now 1_800_000_000
  @gwei 1_000_000_000
  @funded 20_000_000_000_000_000
  @seed "0x" <> String.duplicate("5e", 32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    deploy!(@fleet_id, @fleet, 8_453)

    test = self()

    :telemetry.attach_many(
      {__MODULE__, test},
      [[:keyfleet, :keeper, :paused], [:keyfleet, :keeper, :vrf], [:keyfleet, :keeper, :reveals]],
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

  describe "a round" do
    test "asks again for each sold key with no seed, never asked for or asked for an hour ago" do
      ChainHelpers.seed_cursor!(@fleet_id)
      record_reveal!(5)

      put_chain(
        minted: 6,
        keys: %{
          1 => {@seed, @now - 4_000},
          2 => {0, @now - 3_600},
          3 => {0, @now - 3_599},
          4 => {0, 0},
          6 => {0, @now - 60}
        }
      )

      assert {_sender, _reveals} = run(started!())

      assert requested() == [2, 4]
      assert runs() == [{:reveal, :sent}]
      assert [%{sent: 2, skipped: 3}] = Ash.read!(Keeper.Run, actor: %System{})

      assert_received {:telemetry, [:keyfleet, :keeper, :vrf], %{native_balance_wei: @funded},
                       %{fleet: @fleet_id}}

      # 2, 3 and 4 have waited over two minutes for a seed; 6 has not.
      assert_received {:telemetry, [:keyfleet, :keeper, :reveals], %{waiting: 3},
                       %{fleet: @fleet_id}}
    end

    test "leaves a key it asked for in the last hour, and asks again after" do
      ChainHelpers.seed_cursor!(@fleet_id)
      included!(@fleet_id, {:request_reveal, @fleet, 1}, 0, ago(3_540))
      included!(@fleet_id, {:request_reveal, @fleet, 2}, 1, ago(3_660))
      put_chain(nonce: 2, minted: 2, keys: %{1 => {0, @now - 3_600}, 2 => {0, @now - 3_600}})

      run(started!())

      assert requested() == [2]
    end

    test "asks for at most 25 keys, and for the rest in the next round" do
      ChainHelpers.seed_cursor!(@fleet_id)
      put_chain(minted: 30)

      {sender, reveals} = run(started!())
      assert requested() == Enum.to_list(1..25)

      run(sender, reveals)
      assert requested() == Enum.to_list(1..30)
    end

    test "records a request the coordinator refused, alerts once, and holds the fleet an hour" do
      ChainHelpers.seed_cursor!(@fleet_id)
      put_chain(minted: 3, mine: &refused/2)

      {{sender, reveals}, log} = with_log(fn -> run(started!()) end)

      assert [_alert] = Regex.scan(~r/Keeper alert/, log)

      assert log =~
               "Keeper alert: the VRF coordinator refused #{@fleet_id}'s reveal of key 1 in"

      assert log =~ "#{@fleet_id}'s reveals wait an hour."

      assert [%{result: "reveal_refused", status: :mined}] =
               Keeper.list_latest_txs!(8_453, address(:keeper), actor: %System{})

      # The chain still shows no request; the keeper's own record holds the fleet back.
      log = info_log(fn -> run(sender, reveals) end)
      refute log =~ "Keeper alert"
      assert requested() == [1]
    end

    test "a coordinator that refuses everything costs one transaction per fleet an hour" do
      deploy!(@other_id, @other, 8_453)
      Enum.each([@fleet_id, @other_id], &ChainHelpers.seed_cursor!/1)
      two_fleets(minted: 5, mine: &refused/2)

      log =
        capture_log(fn ->
          {sender, reveals} = run(started!())
          {sender, reveals} = run(sender, reveals)
          run(sender, reveals)
          # A restart holds them too.
          run(started!())
        end)

      assert requested() == [1]
      assert requested(@other) == [1]
      assert [_one, _other] = Regex.scan(~r/Keeper alert/, log)
    end

    test "asks again once a refusal is an hour old" do
      ChainHelpers.seed_cursor!(@fleet_id)
      included!(@fleet_id, {:request_reveal, @fleet, 1}, 0, ago(3_600), "reveal_refused")
      put_chain(nonce: 1, minted: 2)

      run(started!())

      assert requested() == [1, 2]
    end

    test "leaves a key whose request is still waiting" do
      ChainHelpers.seed_cursor!(@fleet_id)
      put_chain(minted: 1, mine: fn _n, _raw -> :pending end)
      {{sender, reveals}, _log} = with_log(fn -> run(started!()) end)
      waiting = length(sent())

      StubNode.update(mine: fn _n, _raw -> {:mined, 1} end)
      run(sender, reveals)

      assert length(sent()) == waiting
    end

    test "passes over a key the contract refuses in its estimate" do
      ChainHelpers.seed_cursor!(@fleet_id)
      refused = calldata!(:request_reveal, @fleet, 1)

      put_chain(
        minted: 2,
        estimate: fn _from, _to, data ->
          if data == refused, do: revert(<<0xAB, 0xCD, 0x00, 0x01>>), else: {:ok, 100_000}
        end
      )

      log = capture_log(fn -> run(started!()) end)

      assert log =~
               "Keeper passed over request_reveal to #{@fleet} for #{@fleet_id}: the contract refuses it (error 0xabcd0001)."

      assert requested() == [2]
    end

    test "ends when a request is left waiting" do
      ChainHelpers.seed_cursor!(@fleet_id)
      put_chain(minted: 3, mine: fn _n, _raw -> :pending end)

      log = capture_log(fn -> run(started!()) end)

      assert log =~ "its reveal round sends nothing more until the next"
      # The request and its three replacements, all for key 1.
      assert Enum.uniq(requested()) == [1]
      assert Enum.map(sent(), & &1.nonce) == [0, 0, 0, 0]
    end

    test "ends a fleet's part when one of its keys cannot be read; the others go on" do
      # Its round comes after the fleet whose key cannot be read.
      deploy!(@other_id, @other, 8_453)
      Enum.each([@fleet_id, @other_id], &ChainHelpers.seed_cursor!/1)
      answers = Map.delete(two_fleets_chain(minted: 3), {@fleet, view!(:reveal_seed, [2])})
      StubNode.put_chain(calls: answering(answers))

      log = capture_log(fn -> run(started!()) end)

      assert log =~
               "Keeper passed over the rest of #{@fleet_id}'s reveals this round: it could not read key 2"

      assert requested() == [1]
      assert requested(@other) == [1, 2, 3]
    end
  end

  describe "a fleet" do
    test "whose key history was not read recently is passed over" do
      put_chain(minted: 1)
      run(started!())

      ChainHelpers.seed_cursor!(@fleet_id, observed_at: ago(3_600))
      run(started!())

      assert sent() == []
      refute_received {:telemetry, [:keyfleet, :keeper, :vrf], _balance, _fleet}
    end

    test "whose subscription cannot be read is passed over, saying so" do
      ChainHelpers.seed_cursor!(@fleet_id)
      answers = Map.delete(chain(minted: 1), {@fleet, view!(:vrf_subscription_id)})
      StubNode.put_chain(calls: answering(answers))

      log = capture_log(fn -> run(started!()) end)

      assert log =~
               "Keeper passed over #{@fleet_id}'s reveals: its VRF subscription could not be read"

      assert sent() == []
    end

    test "on another chain is passed over" do
      deploy!(@other_id, @other, 1)
      Enum.each([@fleet_id, @other_id], &ChainHelpers.seed_cursor!/1)
      put_chain(minted: 1)

      log = capture_log(fn -> run(started!()) end)

      # Its contract is not even read.
      refute log =~ @other_id
      assert requested() == [1]
      assert Enum.uniq(Enum.map(sent(), & &1.to)) == [@fleet]
    end

    test "that is not a consumer of its subscription is passed over, alerted once" do
      ChainHelpers.seed_cursor!(@fleet_id)
      put_chain(minted: 1, consumers: [@stranger])

      {{sender, reveals}, log} =
        with_log(fn ->
          {sender, reveals} = run(started!())
          run(sender, reveals)
        end)

      assert [_alert] =
               Regex.scan(
                 ~r/Keeper alert: #{@fleet_id} is not a consumer of its VRF subscription 555/,
                 log
               )

      assert sent() == []
      assert runs() == []

      assert_received {:telemetry, [:keyfleet, :keeper, :paused], _count,
                       %{job: :reveal, reason: :not_consumer}}

      refute_received {:telemetry, [:keyfleet, :keeper, :paused], _count, _metadata}

      StubNode.update(calls: answering(chain(minted: 1)))
      log = info_log(fn -> run(sender, reveals) end)

      assert log =~ "Keeper reveals go on for #{@fleet_id}: it is a consumer"
      assert requested() == [1]
    end

    test "whose subscription holds under 0.02 ETH is paused until it is funded" do
      ChainHelpers.seed_cursor!(@fleet_id)
      put_chain(minted: 1, native_balance: @funded - 1)

      {{sender, reveals}, log} =
        with_log(fn ->
          {sender, reveals} = run(started!())
          run(sender, reveals)
        end)

      assert [_alert] =
               Regex.scan(
                 ~r/Keeper alert: #{@fleet_id}'s VRF subscription 555 holds 0.019999999999999999 ETH, under 0.02 ETH/,
                 log
               )

      assert sent() == []
      assert runs() == [{:reveal, :paused_vrf_balance}]

      assert_received {:telemetry, [:keyfleet, :keeper, :vrf], %{native_balance_wei: balance},
                       %{fleet: @fleet_id}}

      assert balance == @funded - 1

      StubNode.update(calls: answering(chain(minted: 1)))
      run(sender, reveals)

      assert runs() == [
               {:reveal, :paused_vrf_balance},
               {:reveal, :unpaused_vrf_balance},
               {:reveal, :sent}
             ]

      assert requested() == [1]
    end
  end

  test "nothing is asked for while the base fee is above 2 gwei, alerted once" do
    ChainHelpers.seed_cursor!(@fleet_id)
    put_chain(minted: 1, block: %{number: 1, timestamp: @now, base_fee: 2 * @gwei + 1})

    {{sender, reveals}, log} =
      with_log(fn ->
        {sender, reveals} = run(started!())
        run(sender, reveals)
      end)

    assert [_alert] =
             Regex.scan(~r/Keeper alert: the base fee is 2.000000001 gwei, above 2 gwei/, log)

    assert sent() == []
    assert runs() == [{:reveal, :paused_gas}]

    assert_received {:telemetry, [:keyfleet, :keeper, :paused], _count,
                     %{job: :reveal, reason: :gas}}

    refute_received {:telemetry, [:keyfleet, :keeper, :paused], _count, _metadata}
    # Nothing is read while it waits.
    refute_received {:telemetry, [:keyfleet, :keeper, :vrf], _balance, _fleet}

    StubNode.update(block: %{number: 2, timestamp: @now, base_fee: @gwei})
    log = info_log(fn -> run(sender, reveals) end)

    assert log =~ "Keeper reveals go on: the base fee is back at or under 2 gwei."
    assert runs() == [{:reveal, :paused_gas}, {:reveal, :unpaused_gas}, {:reveal, :sent}]
    assert requested() == [1]
  end

  describe "after a restart, a pause still in force" do
    test "on the base fee is not recorded or alerted again, and is recorded when it ends" do
      ChainHelpers.seed_cursor!(@fleet_id)
      put_chain(minted: 1, block: %{number: 1, timestamp: @now, base_fee: 2 * @gwei + 1})
      capture_log(fn -> run(started!()) end)
      assert_received {:telemetry, [:keyfleet, :keeper, :paused], _count, %{reason: :gas}}

      {{sender, reveals}, log} = with_log(fn -> run(started!()) end)

      refute log =~ "Keeper alert"
      assert runs() == [{:reveal, :paused_gas}]
      refute_received {:telemetry, [:keyfleet, :keeper, :paused], _count, _metadata}

      StubNode.update(block: %{number: 2, timestamp: @now, base_fee: @gwei})
      run(sender, reveals)

      assert runs() == [{:reveal, :paused_gas}, {:reveal, :unpaused_gas}, {:reveal, :sent}]
    end

    test "on a fleet's subscription balance is not recorded or alerted again, and is recorded when it ends" do
      ChainHelpers.seed_cursor!(@fleet_id)
      put_chain(minted: 1, native_balance: @funded - 1)
      capture_log(fn -> run(started!()) end)

      {{sender, reveals}, log} = with_log(fn -> run(started!()) end)

      refute log =~ "Keeper alert"
      assert runs() == [{:reveal, :paused_vrf_balance}]

      StubNode.update(calls: answering(chain(minted: 1)))
      run(sender, reveals)

      assert runs() == [
               {:reveal, :paused_vrf_balance},
               {:reveal, :unpaused_vrf_balance},
               {:reveal, :sent}
             ]

      # Both ends of the pause name the fleet.
      assert [@fleet_id, @fleet_id] =
               for(
                 %{fleet_id: fleet} <- Ash.read!(Keeper.Run, actor: %System{}),
                 fleet,
                 do: fleet
               )
    end
  end

  test "a stopped keeper asks for nothing" do
    ChainHelpers.seed_cursor!(@fleet_id)
    put_chain(minted: 2, nonce: 3, pending: 4)

    capture_log(fn -> run(started!()) end)

    assert sent() == []
    assert {:ok, %{stop_reason: :foreign_nonce}} = Keeper.stopped()
  end

  defp started! do
    sender = start!()
    {:ok, reveals} = Reveals.start(sender)
    {sender, reveals}
  end

  defp run({sender, reveals}), do: run(sender, reveals)
  defp run(sender, reveals), do: Reveals.run(sender, reveals)

  # The coordinator refuses every request.
  defp refused(_n, raw) do
    %{to: fleet, data: <<_selector::binary-size(4), token_id::256>>} = decode(raw)
    {:mined, 1, [reveal_log(:refused, fleet, token_id)]}
  end

  # A hold's end is logged at info. Only this module logs it.
  defp info_log(fun) do
    Logger.put_module_level(Reveals, :info)
    on_exit(fn -> Logger.delete_module_level(Reveals) end)
    capture_log([level: :info], fun)
  end

  # The keys the keeper sent `requestReveal` for to `fleet`, in order.
  defp requested(fleet \\ @fleet) do
    for %{to: ^fleet, data: <<_selector::binary-size(4), token_id::256>>} <- sent(),
        do: token_id
  end

  defp put_chain(opts) do
    {chain_opts, node_opts} = Keyword.split(opts, [:minted, :keys, :native_balance, :consumers])
    StubNode.put_chain([calls: answering(chain(chain_opts))] ++ node_opts)
  end

  defp two_fleets(opts) do
    {chain_opts, node_opts} = Keyword.split(opts, [:minted])
    StubNode.put_chain([calls: answering(two_fleets_chain(chain_opts))] ++ node_opts)
  end

  # Both fleets on Base, consumers of the one subscription, each with its keys.
  defp two_fleets_chain(opts) do
    opts = [consumers: [@fleet, @other]] ++ opts
    Map.merge(chain(opts), chain([fleet: @other] ++ opts))
  end

  # A fleet's VRF subscription and its keys as the chain answers them: each
  # key sold, from 1 to `:minted`, with the seed and request time in `:keys`,
  # or none.
  defp chain(opts) do
    fleet = Keyword.get(opts, :fleet, @fleet)
    minted = Keyword.fetch!(opts, :minted)
    keys = Keyword.get(opts, :keys, %{})
    native_balance = Keyword.get(opts, :native_balance, @funded)
    consumers = Keyword.get(opts, :consumers, [@stranger, @fleet])

    subscription =
      words([7, native_balance, 3, @stranger, 160, length(consumers)]) <> words(consumers)

    Map.merge(
      %{
        {fleet, view!(:vrf_coordinator)} => [@coordinator],
        {fleet, view!(:vrf_subscription_id)} => [@subscription_id],
        {@coordinator, view!(:get_subscription, [@subscription_id])} => subscription,
        {fleet, view!(:total_minted)} => [minted]
      },
      Map.new(1..minted//1, fn token_id -> {token_id, Map.get(keys, token_id, {0, 0})} end)
      |> Enum.flat_map(fn {token_id, {seed, requested_at}} ->
        [
          {{fleet, view!(:reveal_seed, [token_id])}, [seed]},
          {{fleet, view!(:reveal_requested_at, [token_id])}, [requested_at]}
        ]
      end)
      |> Map.new()
    )
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)

  defp record_reveal!(token_id) do
    Keys.record_reveal!(
      %{
        fleet_id: @fleet_id,
        token_id: token_id,
        request_id: 7,
        seed: @seed,
        block_number: 12,
        block_hash: "0x" <> String.duplicate("c", 64),
        transaction_hash: "0x" <> String.duplicate("d", 64),
        log_index: 0
      },
      actor: %System{}
    )
  end
end

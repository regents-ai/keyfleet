defmodule Keyfleet.Keeper.IncomeTest do
  # Checks what the keeper did not log, and a captured log holds every
  # process's lines, so no other test may log alongside it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Keyfleet.KeeperHelpers

  alias Keyfleet.Actors.System
  alias Keyfleet.{Fleets, Keeper, KeeperHelpers, Repo}
  alias Keyfleet.Keeper.{Income, StubNode}

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
  @lp_token_id KeeperHelpers.lp_token_id()
  @tokens [@usdc, @regent, @subject]
  @now 1_800_000_000
  @year 365 * 86_400
  @owes_nothing %{[@fleet, :protocol_share_owed] => [0]}
  @sync {:sync_launch, @fleet, nil}
  # The launch record's auction is the stranger's address.
  @migrate {:migrate, @strategy, @stranger}
  @other "0x" <> String.duplicate("c1", 20)
  @other_share {:send_protocol_share, @other, nil}

  # Every call the keeper may send for the fleet's income, in the order it
  # sends them.
  @calls [{:release, @escrow, nil}, {:collect, @locker, @lp_token_id}] ++
           for(token <- @tokens, do: {:sweep, @receiver, token}) ++
           for(token <- @tokens, do: {:recognize_surplus_revenue, @splitter, token}) ++
           for(token <- @tokens, do: {:recognize_surplus, @fleet, token}) ++
           [{:send_protocol_share, @fleet, nil}]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    deploy!(@fleet_id, @fleet, 8_453)
    :ok
  end

  describe "a round" do
    test "sends every call with something to do, in order, each once the one before is included" do
      StubNode.put_chain(calls: answering(chain(Enum.map(@calls, &due/1))))

      Income.run(start!())

      assert calls() == @calls
      assert Enum.map(sent(), & &1.nonce) == Enum.to_list(0..11)
      assert runs() == [{:income, :sent}]
      assert [%{sent: 12, skipped: 0}] = Ash.read!(Keeper.Run, actor: %System{})
    end

    test "sends nothing, and records nothing, when no call has anything to do" do
      StubNode.put_chain(calls: answering(chain([])))

      Income.run(start!())

      assert sent() == []
      assert runs() == []
    end

    test "sends each call only when its own check finds something to do" do
      @calls
      |> Enum.with_index()
      |> Enum.each(fn {call, nonce} ->
        StubNode.put_chain(nonce: nonce, calls: answering(chain([due(call)])))
        Income.run(start!())
        assert calls() == [call]
      end)
    end

    test "releases only what the escrow has vested and not released, once it graduated" do
      held = [@subject, :balance_of, [@escrow]]
      released = [@escrow, :total_released]
      start = [@escrow, :vesting_start]

      [
        # Half a year into the vesting of 1,000, none released yet.
        {%{held => [1_000], released => [0], start => [@now - div(@year, 2)]}, true},
        # Its vesting has not begun.
        {%{held => [1_000], released => [0], start => [@now]}, false},
        {%{held => [1_000], released => [0], start => [@now + 60]}, false},
        # All of it vested, and all released.
        {%{held => [0], released => [1_000]}, false},
        # Vesting, but not graduated, or failed.
        {%{held => [1_000], [@escrow, :lifecycle] => [0]}, false},
        {%{held => [1_000], [@escrow, :lifecycle] => [2]}, false}
      ]
      |> Enum.with_index()
      |> Enum.each(fn {{answers, due?}, nonce} ->
        StubNode.put_chain(nonce: nonce, calls: answering(chain([answers])))
        Income.run(start!())
        assert calls() == if(due?, do: [{:release, @escrow, nil}], else: []), inspect(answers)
      end)
    end

    test "passes over a call whose check the contract refuses, and goes on" do
      StubNode.put_chain(
        calls:
          answering(
            chain(
              [due({:release, @escrow, nil}), %{[@escrow, :total_released] => revert()}] ++
                [due({:sweep, @receiver, @usdc})]
            )
          )
      )

      log = capture_log(fn -> Income.run(start!()) end)

      assert log =~
               "Keeper passed over release to #{@escrow} for #{@fleet_id}: its check was refused"

      assert calls() == [{:sweep, @receiver, @usdc}]
    end

    test "passes over a call the contract refuses in its estimate, and goes on" do
      refused = calldata!(:release, @escrow, nil)

      StubNode.put_chain(
        calls: answering(chain(Enum.map(@calls, &due/1))),
        estimate: fn _from, _to, data ->
          if data == refused, do: revert(), else: {:ok, 100_000}
        end
      )

      log = capture_log(fn -> Income.run(start!()) end)

      assert log =~
               "Keeper passed over release to #{@escrow} for #{@fleet_id}: the contract refuses it"

      assert calls() == tl(@calls)
      assert [%{sent: 11, skipped: 1}] = Ash.read!(Keeper.Run, actor: %System{})
    end

    test "a check that cannot be answered ends that fleet's part of it; the others go on" do
      # Its round comes after the failing fleet's: its launch has no verdict,
      # and it owes a protocol share.
      deploy!("fleet_tech_classic", @other, 8_453)

      answers =
        chain(Enum.map(@calls, &due/1))
        |> Map.delete(key([@regent, :balance_of, [@receiver]]))
        |> Map.merge(%{
          {@other, view!(:launch_state)} => [0],
          {@other, view!(:protocol_share_owed)} => [1]
        })

      StubNode.put_chain(calls: answering(answers))

      log = capture_log(fn -> Income.run(start!()) end)

      assert log =~
               "Keeper passed over the rest of #{@fleet_id}'s income round: it could not check sweep to #{@receiver}"

      assert calls() == Enum.take(@calls, 3) ++ [@other_share]
    end

    test "ends when a send is left waiting" do
      StubNode.put_chain(
        calls: answering(chain(Enum.map(@calls, &due/1))),
        mine: fn _n, _raw -> :pending end
      )

      log = capture_log(fn -> Income.run(start!()) end)

      assert log =~ "its income round sends nothing more until the next"
      assert Enum.uniq(calls()) == [{:release, @escrow, nil}]
    end
  end

  describe "a launch" do
    test "whose contracts do not all pay the fleet gets nothing sent but the protocol share" do
      answers =
        Map.merge(
          chain(Enum.map(@calls, &due/1)),
          launch(treasury: %{@receiver => @stranger})
        )

      StubNode.put_chain(calls: answering(answers))

      log = capture_log(fn -> Income.run(start!()) end)

      assert log =~ "Keeper alert: #{@fleet_id}'s"
      assert log =~ "pays #{@stranger}, not the fleet"
      assert calls() == [{:send_protocol_share, @fleet, nil}]
    end

    test "not created, or failed, gets nothing sent" do
      for state <- [0, 3] do
        StubNode.put_chain(
          calls:
            answering(chain([due_all(), %{[@fleet, :launch_state] => [state]}, @owes_nothing]))
        )

        log = capture_log(fn -> Income.run(start!()) end)

        assert log == ""
        assert sent() == []
      end
    end

    test "that graduated before the fleet recorded it is synced, then gets its income round" do
      StubNode.put_chain(calls: answering(chain([due_all(), at_auction(2), @owes_nothing])))

      sender = Income.run(start!())
      assert calls() == [@sync]

      # The chain once the sync is included: the fleet has recorded its graduation.
      StubNode.update(calls: answering(chain([due_all(), @owes_nothing])))
      Income.run(sender)

      assert calls() == [@sync | Enum.drop(@calls, -1)]
    end

    test "that failed before the fleet recorded it is synced, then gets only the protocol share" do
      StubNode.put_chain(calls: answering(chain([due_all(), at_auction(3), @owes_nothing])))

      sender = Income.run(start!())
      assert calls() == [@sync]

      StubNode.update(calls: answering(chain([due_all(), %{[@fleet, :launch_state] => [3]}])))

      Income.run(sender)

      assert calls() == [@sync, {:send_protocol_share, @fleet, nil}]
    end

    test "at auction before its auction may settle gets nothing sent" do
      StubNode.put_chain(
        calls:
          answering(
            chain([due_all(), at_auction(1), @owes_nothing], %{
              lifecycle: 1,
              migration_block: 1_000_000
            })
          )
      )

      assert capture_log(fn -> Income.run(start!()) end) == ""
      assert sent() == []
    end

    test "at auction once its auction may settle is settled, then synced once settled" do
      StubNode.put_chain(
        calls:
          answering(
            chain([due_all(), at_auction(1), @owes_nothing], %{
              lifecycle: 1,
              migration_block: 1_000
            })
          )
      )

      sender = Income.run(start!())
      assert calls() == [@migrate]

      # The chain once the settle is included: the strategy has its verdict.
      StubNode.update(calls: answering(chain([due_all(), at_auction(2), @owes_nothing])))
      Income.run(sender)

      assert calls() == [@migrate, @sync]
    end

    test "whose sync the fleet refuses is not synced" do
      StubNode.put_chain(
        calls:
          answering(
            chain([
              due_all(),
              %{[@fleet, :launch_state] => [1], [@fleet, :sync_launch] => revert()},
              @owes_nothing
            ])
          )
      )

      log = capture_log(fn -> Income.run(start!()) end)

      assert log =~
               "Keeper passed over sync_launch to #{@fleet} for #{@fleet_id}: its check was refused"

      assert sent() == []
    end
  end

  describe "the protocol share" do
    test "is sent once a day while the fleet owes any" do
      share = {:send_protocol_share, @fleet, nil}
      StubNode.put_chain(calls: answering(chain([due(share)])))

      sender = Income.run(start!())
      Income.run(sender)

      assert calls() == [share]
    end

    test "waits 24 hours from the keeper's own last one" do
      share = {:send_protocol_share, @fleet, nil}

      included!(@fleet_id, share, 0, ago(23 * 3_600))
      StubNode.put_chain(nonce: 1, calls: answering(chain([due(share)])))
      Income.run(start!())

      assert sent() == []
    end

    test "waits while the keeper's own last one is still waiting" do
      share = {:send_protocol_share, @fleet, nil}

      StubNode.put_chain(
        calls: answering(chain([due(share)])),
        mine: fn _n, _raw -> :pending end
      )

      {sender, _log} = with_log(fn -> Income.run(start!()) end)
      waiting = length(sent())

      StubNode.update(mine: fn _n, _raw -> {:mined, 1} end)
      Income.run(sender)

      assert length(sent()) == waiting
    end

    test "is sent a day after the keeper's own last one" do
      share = {:send_protocol_share, @fleet, nil}

      included!(@fleet_id, share, 0, ago(24 * 3_600 + 60))
      StubNode.put_chain(nonce: 1, calls: answering(chain([due(share)])))
      Income.run(start!())

      assert calls() == [share]
    end

    test "is not sent while the fleet owes nothing" do
      StubNode.put_chain(calls: answering(chain([])))
      Income.run(start!())
      assert sent() == []
    end
  end

  # The calls the keeper sent, in order, as `{function, contract, argument}`.
  defp calls do
    by_calldata =
      Map.new([@sync, @migrate, @other_share | @calls], fn {fun, to, arg} = call ->
        {{to, calldata!(fun, to, arg)}, call}
      end)

    Enum.map(sent(), &Map.fetch!(by_calldata, {&1.to, &1.data}))
  end

  # The chain with nothing for the income job to do, changed by each of
  # `changes`: maps from `[contract, view]` or `[contract, view, args]` to
  # what it answers.
  defp chain(changes, distribution \\ %{}) do
    idle =
      %{
        [@fleet, :launch_state] => [2],
        [@escrow, :lifecycle] => [1],
        [@subject, :balance_of, [@escrow]] => [0],
        [@escrow, :total_released] => [1_000],
        [@escrow, :vesting_start] => [@now - 2 * @year],
        [@locker, :collect] => [0, 0],
        [@fleet, :protocol_share_owed] => [0],
        [@fleet, :sync_launch] => [1]
      }
      |> Map.merge(
        Map.new(
          Enum.flat_map(@tokens, fn token ->
            [
              {[token, :balance_of, [@receiver]], [0]},
              {[token, :balance_of, [@splitter]], [5]},
              {[@splitter, :protected_balance, [token]], [5]},
              {[@fleet, :surplus, [token]], [0]}
            ]
          end)
        )
      )

    changes
    |> Enum.reduce(idle, &Map.merge(&2, &1))
    |> Map.new(fn {path, answer} -> {key(path), answer} end)
    |> Map.merge(launch(distribution: distribution))
  end

  defp key([@locker, :collect]), do: {@locker, calldata!(:collect, @locker, @lp_token_id)}
  defp key([@fleet, :sync_launch]), do: {@fleet, calldata!(:sync_launch, @fleet, nil)}
  defp key([to, view]), do: {to, view!(view)}
  defp key([to, view, args]), do: {to, view!(view, args)}

  # What makes `call` have something to do.
  defp due({:release, _escrow, nil}), do: %{[@subject, :balance_of, [@escrow]] => [1_000]}
  defp due({:collect, _locker, _lp}), do: %{[@locker, :collect] => [1, 0]}
  defp due({:sweep, _receiver, token}), do: %{[token, :balance_of, [@receiver]] => [1]}

  defp due({:recognize_surplus_revenue, _splitter, token}),
    do: %{[token, :balance_of, [@splitter]] => [6]}

  defp due({:recognize_surplus, _fleet, token}), do: %{[@fleet, :surplus, [token]] => [1]}
  defp due({:send_protocol_share, _fleet, nil}), do: %{[@fleet, :protocol_share_owed] => [1]}

  # The fleet's launch at auction as it last recorded it, and the state a
  # sync would record now.
  defp at_auction(state),
    do: %{[@fleet, :launch_state] => [1], [@fleet, :sync_launch] => [state]}

  defp due_all, do: Enum.reduce(@calls, %{}, &Map.merge(&2, due(&1)))

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)
end

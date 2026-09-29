defmodule Keyfleet.Keeper.ProtocolShareTest do
  # Checks what the keeper logged, and a captured log holds every process's
  # lines, so no other test may log alongside it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Keyfleet.KeeperHelpers

  alias Keyfleet.Actors.System
  alias Keyfleet.{Fleets, Keeper, KeeperHelpers, Repo}
  alias Keyfleet.Keeper.{ProtocolShare, StubNode}

  @fleet_id "fibonacci_syndicate"
  @fleet KeeperHelpers.address(:fleet)
  @other_id "fleet_tech_classic"
  @other "0x" <> String.duplicate("c1", 20)
  @share {:send_protocol_share, @fleet, nil}
  @other_share {:send_protocol_share, @other, nil}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    deploy!(@fleet_id, @fleet, 1)
    :ok
  end

  test "sends the share while the fleet owes any, and records the round" do
    StubNode.put_chain(calls: answering(owed(%{@fleet => 1})))

    ProtocolShare.run(start!())

    assert calls() == [@share]
    assert runs() == [{:protocol_share, :sent}]
    assert [%{sent: 1, skipped: 0}] = Ash.read!(Keeper.Run, actor: %System{})
  end

  test "sends nothing, and records nothing, while the fleet owes nothing" do
    StubNode.put_chain(calls: answering(owed(%{@fleet => 0})))

    ProtocolShare.run(start!())

    assert sent() == []
    assert runs() == []
  end

  test "is sent once a day" do
    StubNode.put_chain(calls: answering(owed(%{@fleet => 1})))

    sender = ProtocolShare.run(start!())
    ProtocolShare.run(sender)

    assert calls() == [@share]
  end

  test "waits 24 hours from the keeper's own last one" do
    included!(@fleet_id, @share, 0, ago(23 * 3_600))
    StubNode.put_chain(nonce: 1, calls: answering(owed(%{@fleet => 1})))

    ProtocolShare.run(start!())

    assert sent() == []
  end

  test "is sent a day after the keeper's own last one" do
    included!(@fleet_id, @share, 0, ago(24 * 3_600 + 60))
    StubNode.put_chain(nonce: 1, calls: answering(owed(%{@fleet => 1})))

    ProtocolShare.run(start!())

    assert calls() == [@share]
  end

  test "waits while the keeper's own last one is still waiting" do
    StubNode.put_chain(
      calls: answering(owed(%{@fleet => 1})),
      mine: fn _n, _raw -> :pending end
    )

    {sender, log} = with_log(fn -> ProtocolShare.run(start!()) end)
    assert log =~ "its protocol_share round sends nothing more until the next"
    waiting = length(sent())

    StubNode.update(mine: fn _n, _raw -> {:mined, 1} end)
    ProtocolShare.run(sender)

    assert length(sent()) == waiting
  end

  test "passes over a fleet whose share cannot be checked, and goes on to the others" do
    deploy!(@other_id, @other, 1)

    StubNode.put_chain(
      calls:
        answering(%{
          {@fleet, view!(:protocol_share_owed)} => revert(),
          {@other, view!(:protocol_share_owed)} => [1]
        })
    )

    log = capture_log(fn -> ProtocolShare.run(start!()) end)

    assert log =~ "Keeper could not check #{@fleet_id}'s protocol share"
    assert calls() == [@other_share]
  end

  test "passes over a share the contract refuses in its estimate" do
    StubNode.put_chain(
      calls: answering(owed(%{@fleet => 1})),
      estimate: fn _from, _to, _data -> revert() end
    )

    log = capture_log(fn -> ProtocolShare.run(start!()) end)

    assert log =~ "Keeper passed over send_protocol_share to #{@fleet} for #{@fleet_id}"
    assert sent() == []
  end

  # What each fleet contract answers for the share it owes.
  defp owed(by_fleet),
    do: Map.new(by_fleet, fn {fleet, owed} -> {{fleet, view!(:protocol_share_owed)}, [owed]} end)

  # The calls the keeper sent, in order, as `{function, contract, argument}`.
  defp calls do
    by_calldata =
      Map.new([@share, @other_share], fn {fun, to, arg} = call ->
        {{to, calldata!(fun, to, arg)}, call}
      end)

    Enum.map(sent(), &Map.fetch!(by_calldata, {&1.to, &1.data}))
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)
end

defmodule KeyFleet.Keeper.RecordsTest do
  use ExUnit.Case, async: false

  alias KeyFleet.Actors.System
  alias KeyFleet.{Fleets, Keeper, Repo}
  alias KeyFleet.Keeper.{Run, Transaction}

  @fleet "fibonacci_syndicate"
  @target "0x5fbdb2315678afecb367f032d93f642f64180aa3"
  @system %System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    :ok
  end

  describe "a keeper transaction" do
    test "is recorded as sent, then settled once" do
      tx = sent!()
      assert %DateTime{} = tx.sent_at
      assert {tx.status, tx.settled_at} == {nil, nil}

      assert {:ok, settled} = Keeper.settle(tx, mined())

      assert {settled.status, settled.cost_wei, settled.result} ==
               {:mined, 130_000, "reveal_requested"}

      assert %DateTime{} = settled.settled_at

      assert Keeper.settle(tx, %{status: :replaced}) == {:error, :settled}
      assert Keeper.settle(settled, mined(result: "other")) == {:error, :settled}
      assert fields(Ash.get!(Transaction, tx.id, actor: @system)) == fields(settled)
    end

    test "is settled by one update that finds it only while it has no outcome" do
      tx = sent!()
      assert [update] = writes_during(fn -> {:ok, _tx} = Keeper.settle(tx, mined()) end)

      assert update =~ ~r/\AUPDATE "keyfleet_app"\."keeper_txs" AS k0 SET /

      assert update =~
               ~r/ WHERE \(k0\."id"::uuid = \$\d+::uuid\) AND \(k0\."status"::varchar IS NULL\) RETURNING /
    end

    test "a replaced one carries no receipt, a mined one needs its receipt" do
      assert {:ok, %{status: :replaced}} = Keeper.settle(sent!(), %{status: :replaced})

      assert {:ok, %{status: :replaced_externally}} =
               Keeper.settle(sent!(), %{status: :replaced_externally})

      tx = sent!()
      assert {:error, _error} = Keeper.settle(tx, %{status: :mined})
      assert {:error, _error} = Keeper.settle(tx, %{status: :replaced, block_number: 1})
      assert {:error, _error} = Keeper.settle(tx, Map.delete(mined(), :status))

      assert {:ok, %{status: :reverted, l1_fee_wei: nil}} =
               Keeper.settle(tx, mined(status: :reverted, l1_fee_wei: nil))
    end

    test "refuses changes to what was sent, deleting and emptying" do
      tx = sent!()

      for {field, value} <- [
            id: Ecto.UUID.dump!(Ash.UUID.generate()),
            job: "income",
            fleet_id: "fibonacci_cascade",
            function: "release",
            target: "0x" <> String.duplicate("1", 40),
            args: %{"arg" => 2},
            chain_id: 1,
            nonce: 9,
            tx_hash: hash("9"),
            replaces_tx_hash: hash("8"),
            max_fee: 1,
            max_priority_fee: 1,
            gas_limit: 1,
            sent_at: ~N[2000-01-01 00:00:00.000000]
          ] do
        assert_refused("UPDATE keyfleet_app.keeper_txs SET #{field} = $2 WHERE id = $1", [
          Ecto.UUID.dump!(tx.id),
          value
        ])
      end

      assert_refused("DELETE FROM keyfleet_app.keeper_txs WHERE id = $1", [Ecto.UUID.dump!(tx.id)])

      assert_refused("TRUNCATE keyfleet_app.keeper_txs", [])

      assert fields(Ash.get!(Transaction, tx.id, actor: @system)) == fields(tx)
    end

    # The database holds the outcome to once as well, however it is written.
    test "takes its outcome once, from nothing" do
      tx = sent!()
      id = Ecto.UUID.dump!(tx.id)

      settle =
        "UPDATE keyfleet_app.keeper_txs SET status = 'replaced', settled_at = now() WHERE id = $1"

      assert {:ok, %{num_rows: 1}} = Repo.query(settle, [id], mode: :savepoint)

      for sql <- [
            settle,
            "UPDATE keyfleet_app.keeper_txs SET status = NULL, settled_at = NULL WHERE id = $1",
            "UPDATE keyfleet_app.keeper_txs SET result = 'changed' WHERE id = $1",
            "UPDATE keyfleet_app.keeper_txs SET settled_at = now() WHERE id = $1"
          ] do
        assert_refused(sql, [id])
      end

      assert %{status: :replaced, result: nil} = Ash.get!(Transaction, tx.id, actor: @system)
    end

    test "takes no result before its outcome" do
      tx = sent!()

      assert_refused("UPDATE keyfleet_app.keeper_txs SET result = 'x' WHERE id = $1", [
        Ecto.UUID.dump!(tx.id)
      ])

      assert %{status: nil, result: nil} = Ash.get!(Transaction, tx.id, actor: @system)
    end

    test "settling one that was never recorded finds nothing" do
      assert Keeper.settle(%Transaction{id: Ash.UUID.generate()}, mined()) ==
               {:error, :not_found}
    end
  end

  describe "a keeper run" do
    test "is recorded once and never changed, deleted or emptied" do
      run = run!()
      id = Ecto.UUID.dump!(run.id)

      for {field, value} <- [
            job: "income",
            started_at: ~N[2000-01-01 00:00:00.000000],
            finished_at: ~N[2100-01-01 00:00:00.000000],
            outcome: "stopped",
            sent: 5,
            skipped: 5,
            notes: "changed"
          ] do
        assert_refused("UPDATE keyfleet_app.keeper_runs SET #{field} = $2 WHERE id = $1", [
          id,
          value
        ])
      end

      assert_refused("DELETE FROM keyfleet_app.keeper_runs WHERE id = $1", [id])
      assert_refused("TRUNCATE keyfleet_app.keeper_runs", [])
      assert fields(Ash.get!(Run, run.id, actor: @system)) == fields(run)
    end

    test "ends no earlier than it started" do
      now = DateTime.utc_now()

      assert {:error, _error} =
               Keeper.record_run(run_attrs(started_at: now, finished_at: DateTime.add(now, -1)),
                 actor: @system
               )
    end
  end

  test "only the keeper reads or writes the records" do
    tx = sent!()
    run = run!()

    for actor <- [nil, %KeyFleet.Actors.Human{human_account_id: Ash.UUID.generate()}] do
      assert {:error, %Ash.Error.Forbidden{}} = Keeper.record_sent_tx(tx_attrs(), actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = Keeper.record_run(run_attrs(), actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Transaction, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Run, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.get(Transaction, tx.id, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.get(Run, run.id, actor: actor)
    end
  end

  defp sent! do
    Keeper.record_sent_tx!(tx_attrs(tx_hash: hash(Ash.UUID.generate())), actor: @system)
  end

  defp tx_attrs(overrides \\ []) do
    Map.merge(
      %{
        job: :reveal,
        fleet_id: @fleet,
        function: :request_reveal,
        target: @target,
        args: %{"arg" => 1},
        chain_id: 8453,
        nonce: 0,
        tx_hash: hash("a"),
        max_fee: 2_000_000_000,
        max_priority_fee: 1_000_000,
        gas_limit: 200_000
      },
      Map.new(overrides)
    )
  end

  defp mined(overrides \\ []) do
    Map.merge(
      %{
        status: :mined,
        block_number: 36_000_000,
        gas_used: 100_000,
        effective_gas_price: 1_000,
        l1_fee_wei: 30_000,
        cost_wei: 130_000,
        result: "reveal_requested"
      },
      Map.new(overrides)
    )
  end

  defp run!, do: Keeper.record_run!(run_attrs(), actor: @system)

  defp run_attrs(overrides \\ []) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        job: :reveal,
        started_at: now,
        finished_at: now,
        outcome: :sent,
        sent: 2,
        skipped: 1,
        notes: "keys 4 and 5"
      },
      Map.new(overrides)
    )
  end

  defp fields(%resource{} = record),
    do: Map.take(record, Ash.Resource.Info.attribute_names(resource) |> MapSet.to_list())

  defp assert_refused(sql, params) do
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(sql, params, mode: :savepoint),
           sql
  end

  # A hash made from any text, in the shape a transaction hash has.
  defp hash(seed), do: "0x" <> Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  # The statements that changed the database while `fun` ran in this process.
  defp writes_during(fun) do
    test_pid = self()
    handler = "keeper-records-writes"

    :telemetry.attach(
      handler,
      [:key_fleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test_pid and
             not String.starts_with?(meta.query, ["SELECT", "begin", "commit"]),
           do: send(test_pid, {:write, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    receive_writes([])
  end

  defp receive_writes(writes) do
    receive do
      {:write, query} -> receive_writes([query | writes])
    after
      0 -> Enum.reverse(writes)
    end
  end
end

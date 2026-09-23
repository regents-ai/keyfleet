defmodule KeyFleet.KeyAttachmentsTest do
  use ExUnit.Case, async: false
  require Ash.Query

  alias KeyFleet.{Fleets, Keys, Repo}
  alias KeyFleet.Keys.KeyAttachment

  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"
  @system %KeyFleet.Actors.System{}

  setup context do
    if context[:independent_connections] do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &Fleets.bootstrap_catalog!/0)
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Fleets.bootstrap_catalog!()
    end

    :ok
  end

  test "replays preserve row identity and database observation time; conflicting epoch values fail" do
    input = event()
    first = Keys.record_epoch!(input, actor: @system)
    assert %DateTime{} = first.observed_at
    replay = Keys.record_epoch!(input, actor: @system)
    assert {replay.id, replay.observed_at} == {first.id, first.observed_at}

    for {field, value} <- [
          owner_wallet: wallet("b"),
          block_number: 11,
          block_hash: hash("b"),
          transaction_hash: hash("c"),
          log_index: 1
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               Keys.record_epoch(Map.put(input, field, value), actor: @system)
    end

    assert [row] = Keys.key_history!(@fleet, 1)
    assert Map.take(row, Map.keys(input)) == input
  end

  test "one chain event cannot be reused for another fleet, token or epoch" do
    input = event()
    Keys.record_epoch!(input, actor: @system)

    for {field, value} <- [fleet_id: @other_fleet, token_id: 2, ownership_epoch: 1] do
      assert {:error, %Ash.Error.Invalid{}} =
               Keys.record_epoch(Map.put(input, field, value), actor: @system)
    end

    assert length(Keys.key_history!(@fleet, 1)) == 1
    assert Keys.key_history!(@other_fleet, 1) == []
    assert Keys.key_history!(@fleet, 2) == []
  end

  test "transfers and self-transfers add current epochs while history stays stable" do
    first = Keys.record_epoch!(event(), actor: @system)

    third =
      Keys.record_epoch!(event(ownership_epoch: 2, owner_wallet: wallet("b"), log_index: 2),
        actor: @system
      )

    second =
      Keys.record_epoch!(event(ownership_epoch: 1, owner_wallet: wallet("b"), log_index: 1),
        actor: @system
      )

    assert third.owner_wallet == second.owner_wallet
    assert third.ownership_epoch == second.ownership_epoch + 1
    assert Enum.map(Keys.key_history!(@fleet, 1), & &1.id) == [first.id, second.id, third.id]
    current = Keys.current_key!(@fleet, 1)
    assert current.id == third.id
    assert persisted_fields(hd(Keys.key_history!(@fleet, 1))) == persisted_fields(first)
    assert Keys.current_key!(@fleet, 99) == nil

    query =
      KeyAttachment
      |> Ash.Query.sort(ownership_epoch: :asc)
      |> Ash.Query.offset(1)
      |> Ash.Query.limit(0)

    assert Ash.read_one!(Ash.Query.for_read(query, :current, %{fleet_id: @fleet, token_id: 1})).id ==
             third.id

    history =
      KeyAttachment
      |> Ash.Query.for_read(:history, %{fleet_id: @fleet, token_id: 1})
      |> Ash.Query.sort(ownership_epoch: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.offset(1)
      |> Ash.read!()

    assert Enum.map(history, & &1.id) == [first.id, second.id, third.id]
  end

  test "read scope arguments are required and caller filters cannot widen fleet or token" do
    Keys.record_epoch!(event(), actor: @system)
    Keys.record_epoch!(event(fleet_id: @other_fleet, log_index: 1), actor: @system)
    Keys.record_epoch!(event(token_id: 2, log_index: 2), actor: @system)

    for action <- [:history, :current] do
      for args <- [%{}, %{fleet_id: @fleet}, %{token_id: 1}] do
        assert {:error, %Ash.Error.Invalid{}} =
                 KeyAttachment |> Ash.Query.for_read(action, args) |> Ash.read()
      end

      query =
        KeyAttachment
        |> Ash.Query.for_read(action, %{fleet_id: @fleet, token_id: 1})
        |> Ash.Query.filter(fleet_id == ^@other_fleet or token_id == 2)

      assert Ash.read!(query) == []

      restored =
        KeyAttachment
        |> Ash.Query.for_read(action, %{fleet_id: @fleet, token_id: 1})
        |> Ash.Query.unset(:filter)
        |> Ash.read!()

      assert [%{fleet_id: @fleet, token_id: 1}] = restored
    end

    assert_raise Ash.Error.Invalid, fn -> Ash.read!(KeyAttachment) end
  end

  test "only the exact system actor writes and callers cannot supply generated fields" do
    for actor <- [
          nil,
          %KeyFleet.Actors.Human{human_account_id: 1},
          %KeyFleet.Actors.Agent{
            wallet_address: wallet("a"),
            chain_id: 8453,
            audience: "keyfleet"
          },
          %{role: :system}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = Keys.record_epoch(event(), actor: actor)
    end

    for {field, value} <- [
          id: Ash.UUID.generate(),
          observed_at: DateTime.utc_now()
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               Keys.record_epoch(Map.put(event(), field, value), actor: @system)
    end

    assert Keys.key_history!(@fleet, 1) == []
  end

  test "action rejects malformed wallets, hashes and numeric bounds" do
    for {field, value} <- invalid_values() do
      assert {:error, %Ash.Error.Invalid{}} =
               Keys.record_epoch(Map.put(event(), field, value), actor: @system)
    end

    assert Keys.key_history!(@fleet, 1) == []
  end

  test "bigint boundaries accept the maximum and reject overflow before reaching the database" do
    maximum = 9_223_372_036_854_775_807
    fields = [:token_id, :ownership_epoch, :block_number, :log_index]

    for field <- fields do
      assert {:error, %Ash.Error.Invalid{}} =
               Keys.record_epoch(Map.put(event(), field, maximum + 1), actor: @system)
    end

    input = Map.merge(event(), Map.new(fields, &{&1, maximum}))
    row = Keys.record_epoch!(input, actor: @system)
    assert Map.take(row, fields) == Map.take(input, fields)
    assert Keys.current_key!(@fleet, maximum).id == row.id
    assert Enum.map(Keys.key_history!(@fleet, maximum), & &1.id) == [row.id]

    for action <- [:history, :current] do
      assert {:error, %Ash.Error.Invalid{}} =
               KeyAttachment
               |> Ash.Query.for_read(action, %{fleet_id: @fleet, token_id: maximum + 1})
               |> Ash.read()
    end
  end

  test "SQL constraints protect identities, references, shape, bounds and immutable history" do
    row = Keys.record_epoch!(event(), actor: @system)

    for overrides <- [%{}, %{token_id: 2}, %{transaction_hash: hash("b")}] do
      assert_sql_error(event() |> Map.merge(overrides), :unique_violation)
    end

    for {field, value} <- invalid_values() do
      assert_sql_error(
        event(token_id: 3, log_index: 3) |> Map.put(field, value),
        :check_violation
      )
    end

    assert_sql_error(event(fleet_id: "unknown", log_index: 4), :foreign_key_violation)

    for {field, value} <- [
          id: Ecto.UUID.dump!(Ash.UUID.generate()),
          fleet_id: @other_fleet,
          token_id: 2,
          ownership_epoch: 1,
          owner_wallet: wallet("b"),
          block_number: 11,
          block_hash: hash("b"),
          transaction_hash: hash("b"),
          log_index: 1,
          observed_at: ~N[2000-01-01 00:00:00.000000]
        ] do
      sql = "UPDATE keyfleet_app.key_attachments SET #{field} = $2 WHERE id = $1"

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(sql, [Ecto.UUID.dump!(row.id), value], mode: :savepoint)
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "DELETE FROM keyfleet_app.key_attachments WHERE id = $1",
               [Ecto.UUID.dump!(row.id)],
               mode: :savepoint
             )

    assert persisted_fields(Keys.current_key!(@fleet, 1)) == persisted_fields(row)
  end

  @tag :independent_connections
  test "simultaneous exact replays on independent database transactions return one stable row" do
    input =
      event(
        token_id: :rand.uniform(1_000_000_000) + 100,
        transaction_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      )

    on_exit(fn -> forget(input.token_id) end)

    assert [{:ok, first}, {:ok, second}] = race_inputs([input, input])
    assert first.id == second.id
    assert first.observed_at == second.observed_at

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert [row] = Keys.key_history!(@fleet, input.token_id)
      assert row.id == first.id
    end)
  end

  @tag :independent_connections
  test "simultaneous conflicting observations cannot replace the winning epoch" do
    input =
      event(
        token_id: :rand.uniform(1_000_000_000) + 100,
        transaction_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      )

    on_exit(fn -> forget(input.token_id) end)

    results = race_inputs([input, Map.put(input, :owner_wallet, wallet("b"))])
    assert [winner] = for({:ok, row} <- results, do: row)
    assert [{:error, %Ash.Error.Invalid{}}] = Enum.filter(results, &match?({:error, _}, &1))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert [row] = Keys.key_history!(@fleet, input.token_id)
      assert persisted_fields(row) == persisted_fields(winner)
    end)
  end

  # A key these races commit is removed when the test ends, so no other test
  # reads it as sold. Key records refuse deletion; their guard is set aside
  # inside this one transaction, which no other connection sees.
  defp forget(token_id) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        Repo.query!(
          "ALTER TABLE keyfleet_app.key_attachments DISABLE TRIGGER immutable_key_epochs"
        )

        Repo.query!(
          "DELETE FROM keyfleet_app.key_attachments WHERE fleet_id = $1 AND token_id = $2",
          [@fleet, token_id]
        )

        Repo.query!(
          "ALTER TABLE keyfleet_app.key_attachments ENABLE TRIGGER immutable_key_epochs"
        )
      end)
    end)
  end

  defp race_inputs(inputs) do
    parent = self()

    callers =
      for input <- inputs do
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, self()})

          receive do
            :go -> Keys.record_epoch(input, actor: @system)
          after
            10_000 -> raise "replay barrier timed out"
          end
        end)
      end

    for _ <- callers do
      assert_receive {:ready, _}, 10_000
    end

    Enum.each(callers, &send(&1.pid, :go))
    Task.await_many(callers, 15_000)
  end

  defp assert_sql_error(input, code) do
    fields = [
      :id,
      :fleet_id,
      :token_id,
      :ownership_epoch,
      :owner_wallet,
      :block_number,
      :block_hash,
      :transaction_hash,
      :log_index
    ]

    input = Map.put(input, :id, Ecto.UUID.dump!(Ash.UUID.generate()))

    sql =
      "INSERT INTO keyfleet_app.key_attachments (" <>
        Enum.map_join(fields, ",", &Atom.to_string/1) <>
        ") VALUES (" <> Enum.map_join(1..length(fields), ",", &"$#{&1}") <> ")"

    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
             Repo.query(sql, Enum.map(fields, &Map.get(input, &1)), mode: :savepoint)
  end

  defp invalid_values do
    [
      token_id: 0,
      token_id: -1,
      ownership_epoch: -1,
      block_number: -1,
      log_index: -1,
      owner_wallet: wallet("A"),
      owner_wallet: "0x123",
      owner_wallet: wallet("a") <> "\n",
      block_hash: hash("A"),
      block_hash: "0x123",
      transaction_hash: hash("A"),
      transaction_hash: "0x123"
    ]
  end

  defp event(overrides \\ []) do
    Map.merge(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 0,
        owner_wallet: wallet("a"),
        block_number: 10,
        block_hash: hash("a"),
        transaction_hash: hash("a"),
        log_index: 0
      },
      Map.new(overrides)
    )
  end

  defp wallet(char), do: "0x" <> String.duplicate(char, 40)
  defp hash(char), do: "0x" <> String.duplicate(char, 64)

  defp persisted_fields(row),
    do:
      Map.take(row, [
        :id,
        :fleet_id,
        :token_id,
        :ownership_epoch,
        :owner_wallet,
        :block_number,
        :block_hash,
        :transaction_hash,
        :log_index,
        :observed_at
      ])
end

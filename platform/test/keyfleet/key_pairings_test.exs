defmodule KeyFleet.KeyPairingsTest do
  use ExUnit.Case, async: false

  alias KeyFleet.Actors
  alias KeyFleet.Agents
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Repo

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}
  @decision [:id, :status, :ended_reason, :approved_at, :ended_at]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    owner = agent("a")
    %{owner: owner, epoch: epoch!(owner_wallet: owner.wallet_address)}
  end

  test "an agent signing as the owner attaches at once; anyone else leaves a request", %{
    owner: owner
  } do
    operator = agent("b")
    profile!(owner, "Owner agent")
    profile!(operator, "Operator agent")

    requested = Keys.request_pairing!(@fleet, 1, %{}, actor: operator)
    assert requested.status == :requested
    assert requested.approved_at == nil
    assert requested.operator_wallet == operator.wallet_address
    assert requested.owner_wallet == owner.wallet_address
    assert requested.ownership_epoch == 0
    assert Keys.current_operator!(@fleet, 1) == nil

    attached = Keys.request_pairing!(@fleet, 1, %{}, actor: owner)
    assert attached.status == :active
    assert %DateTime{} = attached.approved_at
    assert Keys.current_operator!(@fleet, 1).id == attached.id

    assert {:error, %Ash.Error.Invalid{errors: [%Keys.Errors.AlreadyOperatingError{}]}} =
             Keys.request_pairing(@fleet, 1, %{}, actor: owner)
  end

  test "a request needs a recorded key and a profile", %{owner: owner} do
    stranger = agent("c")
    profile!(owner, "Owner agent")

    assert {:error, %Ash.Error.Invalid{errors: [%Keys.Errors.UnknownKeyError{}]}} =
             Keys.request_pairing(@fleet, 99, %{}, actor: owner)

    assert {:error, %Ash.Error.Invalid{errors: [%Keys.Errors.ProfileRequiredError{}]}} =
             Keys.request_pairing(@fleet, 1, %{}, actor: stranger)

    assert Keys.pairing_history!(@fleet, 1) == []
  end

  test "approval attaches the operator, replaces the one before and turns down the rest", %{
    owner: owner
  } do
    first = attach!(agent("b"), "First operator")
    second = request!(agent("c"), "Second operator")
    third = request!(agent("d"), "Third operator")

    approved = Keys.approve_pairing!(second, %{}, actor: human(owner))
    assert approved.status == :active
    assert %DateTime{} = approved.approved_at
    assert Keys.current_operator!(@fleet, 1).id == approved.id
    assert Keys.list_pairing_requests!(@fleet, 1) == []

    assert Enum.map(Keys.pairing_history!(@fleet, 1), &{&1.id, &1.status, &1.ended_reason}) ==
             [
               {first.id, :ended, :replaced},
               {second.id, :active, nil},
               {third.id, :ended, :declined}
             ]
  end

  test "only the wallet that owns the key today may approve, decline or detach", %{owner: owner} do
    request = request!(agent("b"), "Operator")
    other = human(agent("e"))

    for actor <- [nil, other, @system, owner] do
      assert {:error, %Ash.Error.Forbidden{}} = Keys.approve_pairing(request, %{}, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = Keys.decline_pairing(request, %{}, actor: actor)
    end

    declined = Keys.decline_pairing!(request, %{}, actor: human(owner))
    assert {declined.status, declined.ended_reason} == {:ended, :declined}

    attached = attach!(agent("f"), "Attached operator")
    assert {:error, %Ash.Error.Forbidden{}} = Keys.detach_operator(attached, %{}, actor: other)
    detached = Keys.detach_operator!(attached, %{}, actor: human(owner))
    assert {detached.status, detached.ended_reason} == {:ended, :detached}
    assert Keys.current_operator!(@fleet, 1) == nil
  end

  test "a transfer detaches the operator without writing, and freezes the old owner out", %{
    owner: owner
  } do
    attached = attach!(agent("b"), "Operator")
    request = request!(agent("c"), "Hopeful operator")
    new_owner = agent("1")

    epoch!(ownership_epoch: 1, owner_wallet: new_owner.wallet_address, log_index: 1)

    assert Keys.current_operator!(@fleet, 1) == nil
    assert Keys.list_pairing_requests!(@fleet, 1) == []

    assert {:error, %Ash.Error.Forbidden{}} =
             Keys.approve_pairing(request, %{}, actor: human(owner))

    assert {:error, %Ash.Error.Forbidden{}} =
             Keys.detach_operator(attached, %{}, actor: human(owner))

    assert Enum.map(Keys.pairing_history!(@fleet, 1), &{&1.id, &1.status, &1.effective?}) ==
             [{attached.id, :active, false}, {request.id, :requested, false}]

    renewed = Keys.request_pairing!(@fleet, 1, %{}, actor: new_owner_with_profile(new_owner))
    assert renewed.ownership_epoch == 1
    assert Keys.current_operator!(@fleet, 1).id == renewed.id

    approved =
      Keys.approve_pairing!(request!(agent("3"), "Later hopeful"), %{}, actor: human(new_owner))

    assert Keys.current_operator!(@fleet, 1).id == approved.id

    assert Enum.find(Keys.pairing_history!(@fleet, 1), &(&1.id == request.id)).status ==
             :requested
  end

  test "an agent withdraws only its own request and sees only its own pairings", %{owner: owner} do
    operator = agent("b")
    request = request!(operator, "Operator")
    intruder = agent("2")
    profile!(intruder, "Intruder")

    assert {:error, %Ash.Error.Forbidden{}} =
             Keys.withdraw_pairing_request(request, %{}, actor: intruder)

    assert {:error, %Ash.Error.Forbidden{}} =
             Keys.withdraw_pairing_request(request, %{}, actor: human(owner))

    assert Keys.my_pairings!(actor: intruder) == []
    assert Enum.map(Keys.my_pairings!(actor: operator), & &1.id) == [request.id]

    withdrawn = Keys.withdraw_pairing_request!(request, %{}, actor: operator)
    assert {withdrawn.status, withdrawn.ended_reason} == {:ended, :declined}
    assert Keys.list_pairing_requests!(@fleet, 1) == []
  end

  test "a decision already taken cannot be retaken from a stale record", %{owner: owner} do
    operator = agent("b")
    request = request!(operator, "Operator")
    withdrawn = Keys.withdraw_pairing_request!(request, %{}, actor: operator)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Keys.approve_pairing(request, %{}, actor: human(owner))

    assert [unchanged] = Keys.pairing_history!(@fleet, 1)
    assert Map.take(unchanged, @decision) == Map.take(withdrawn, @decision)
    assert Keys.current_operator!(@fleet, 1) == nil
  end

  test "the database refuses a second attached operator, a delete, and an edited identity" do
    attached = attach!(agent("b"), "Operator")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               """
               INSERT INTO keyfleet_app.key_pairings
                 (id, fleet_id, token_id, ownership_epoch, owner_wallet, operator_wallet,
                  agent_profile_id, status, requested_at)
               SELECT $1, fleet_id, token_id, ownership_epoch, owner_wallet, operator_wallet,
                      agent_profile_id, status, requested_at
               FROM keyfleet_app.key_pairings WHERE id = $2
               """,
               [Ecto.UUID.dump!(Ash.UUID.generate()), Ecto.UUID.dump!(attached.id)],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "DELETE FROM keyfleet_app.key_pairings WHERE id = $1",
               [Ecto.UUID.dump!(attached.id)],
               mode: :savepoint
             )

    for {field, value} <- [
          id: Ecto.UUID.dump!(Ash.UUID.generate()),
          fleet_id: "fibonacci_cascade",
          token_id: 2,
          ownership_epoch: 1,
          owner_wallet: wallet("3"),
          operator_wallet: wallet("3"),
          agent_profile_id: Ecto.UUID.dump!(Ash.UUID.generate()),
          requested_at: ~N[2000-01-01 00:00:00.000000]
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "UPDATE keyfleet_app.key_pairings SET #{field} = $2 WHERE id = $1",
                 [Ecto.UUID.dump!(attached.id), value],
                 mode: :savepoint
               )
    end

    assert Keys.current_operator!(@fleet, 1).id == attached.id
  end

  defp agent(character) do
    %Actors.Agent{wallet_address: wallet(character), chain_id: 8453, audience: "keyfleet"}
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(%Actors.Agent{wallet_address: wallet}),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet]}

  defp profile!(actor, name),
    do: Agents.ensure_profile!(%{name: name, declared_harness: "test"}, actor: actor)

  defp request!(actor, name) do
    profile!(actor, name)
    Keys.request_pairing!(@fleet, 1, %{}, actor: actor)
  end

  defp attach!(actor, name) do
    request = request!(actor, name)
    Keys.approve_pairing!(request, %{}, actor: owner_of(request))
  end

  defp owner_of(%{owner_wallet: wallet}),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet]}

  defp new_owner_with_profile(actor) do
    profile!(actor, "New owner agent")
    actor
  end

  defp epoch!(overrides) do
    %{
      fleet_id: @fleet,
      token_id: 1,
      ownership_epoch: 0,
      owner_wallet: wallet("a"),
      block_number: 10,
      block_hash: "0x" <> String.duplicate("a", 64),
      transaction_hash: "0x" <> String.duplicate("a", 64),
      log_index: 0
    }
    |> Map.merge(Map.new(overrides))
    |> then(fn event ->
      event
      |> Map.put(
        :transaction_hash,
        "0x" <> String.duplicate(to_string(event.ownership_epoch), 64)
      )
      |> Keys.record_epoch!(actor: @system)
    end)
  end
end

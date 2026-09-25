defmodule Keyfleet.KeyPairingsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}
  @decision [:id, :status, :ended_reason, :approved_at, :ended_at]
  @limits [
    :limits_money,
    :limits_information,
    :limits_outside,
    :limits_check_first,
    :limits_written_at
  ]
  @edited %{
    money: "Spend nothing.",
    information: "Keep my name out of it.",
    outside: "Stay inside Keyfleet.",
    check_first: "Any promise to anyone."
  }
  @identity [
    :id,
    :fleet_id,
    :token_id,
    :ownership_epoch,
    :owner_wallet,
    :operator_wallet,
    :agent_profile_id,
    :requested_at
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
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
    # An agent holding its own key answers to no one else's limits.
    assert Enum.all?(@limits, &(Map.fetch!(attached, &1) == nil))
    assert Keys.current_operator!(@fleet, 1).id == attached.id

    assert {:error, %Ash.Error.Invalid{errors: [%Keys.Errors.AlreadyOperatingError{}]}} =
             Keys.request_pairing(@fleet, 1, %{}, actor: owner)
  end

  # The fleet's pages redraw a key's agent mark when an agent starts or stops
  # running it; a request still waiting for the owner changes nothing shown.
  test "a key gaining or losing the agent running it is announced; a waiting request is not", %{
    owner: owner
  } do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))

    request = request!(agent("b"), "Operator agent")
    refute_received {:keys_changed, _fleet, _token_ids}

    approved = Keys.approve_pairing!(request, Keys.default_limits(), actor: human(owner))
    assert_received {:keys_changed, @fleet, [1]}

    Keys.detach_operator!(approved, %{}, actor: human(owner))
    assert_received {:keys_changed, @fleet, [1]}

    declined = request!(agent("c"), "Declined agent")
    Keys.decline_pairing!(declined, %{}, actor: human(owner))
    refute_received {:keys_changed, _fleet, _token_ids}

    profile!(owner, "Owner agent")
    Keys.request_pairing!(@fleet, 1, %{}, actor: owner)
    assert_received {:keys_changed, @fleet, [1]}
  end

  # The key map marks the keys an agent runs today and the keys a person's
  # wallets hold today; a key that changed hands is neither any more.
  test "a fleet's keys run by an agent and held by a wallet are read under today's owner", %{
    owner: owner
  } do
    epoch!(token_id: 2, block_number: 11, log_index: 1, owner_wallet: wallet("e"))
    attach!(agent("b"), "Operator agent")

    assert run_keys() == [1]
    assert held_keys([owner.wallet_address, wallet("e")]) == [1, 2]

    epoch!(ownership_epoch: 1, owner_wallet: wallet("e"), block_number: 20)

    assert run_keys() == []
    assert held_keys([owner.wallet_address]) == []
    assert held_keys([wallet("e")]) == [1, 2]
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

    approved = Keys.approve_pairing!(second, Keys.default_limits(), actor: human(owner))
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
      assert {:error, %Ash.Error.Forbidden{}} =
               Keys.approve_pairing(request, Keys.default_limits(), actor: actor)

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

  # Holding a key grants nothing while its ownership may be out of date.
  test "while ownership is being refreshed the owner can neither approve nor attach its agent",
       %{owner: owner} do
    request = request!(agent("b"), "Operator")
    profile!(owner, "Owner agent")

    ChainHelpers.seed_cursor!(@fleet,
      observed_at: DateTime.add(DateTime.utc_now(), -121, :second)
    )

    assert {:error, %Ash.Error.Forbidden{}} =
             Keys.approve_pairing(request, Keys.default_limits(), actor: human(owner))

    assert {:error, %Ash.Error.Forbidden{errors: [%Keys.Errors.OwnershipRefreshingError{}]}} =
             Keys.request_pairing(@fleet, 1, %{}, actor: owner)

    assert Keys.current_operator!(@fleet, 1) == nil
    assert Keys.list_pairing_requests!(@fleet, 1) |> Enum.map(& &1.id) == [request.id]
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
             Keys.approve_pairing(request, Keys.default_limits(), actor: human(owner))

    assert {:error, %Ash.Error.Forbidden{}} =
             Keys.detach_operator(attached, %{}, actor: human(owner))

    assert Enum.map(Keys.pairing_history!(@fleet, 1), &{&1.id, &1.status, &1.effective?}) ==
             [{attached.id, :active, false}, {request.id, :requested, false}]

    renewed = Keys.request_pairing!(@fleet, 1, %{}, actor: new_owner_with_profile(new_owner))
    assert renewed.ownership_epoch == 1
    assert Keys.current_operator!(@fleet, 1).id == renewed.id

    approved =
      Keys.approve_pairing!(request!(agent("3"), "Later hopeful"), Keys.default_limits(),
        actor: human(new_owner)
      )

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

  test "the running agent steps down: the pairing ends and keeps who it was", %{owner: owner} do
    runner = agent("b")
    attached = attach!(runner, "Runner")
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))

    assert Keys.my_active_pairing!(@fleet, 1, actor: runner).id == attached.id
    stepped_down = Keys.step_down!(attached, %{}, actor: runner)
    assert_received {:keys_changed, @fleet, [1]}

    assert {stepped_down.status, stepped_down.ended_reason} == {:ended, :stepped_down}
    assert %DateTime{} = stepped_down.ended_at
    assert Keys.current_operator!(@fleet, 1) == nil
    assert Keys.my_active_pairing!(@fleet, 1, actor: runner) == nil

    assert [stored] = Keys.pairing_history!(@fleet, 1)
    assert Map.take(stored, @identity) == Map.take(attached, @identity)
    assert stored.owner_wallet == owner.wallet_address
    assert {stored.status, stored.ended_reason} == {:ended, :stepped_down}
  end

  test "only the agent running the key may step down from it", %{owner: owner} do
    attached = attach!(agent("b"), "Runner")
    intruder = agent("2")
    profile!(intruder, "Intruder")

    for actor <- [intruder, human(owner), @system, nil] do
      assert {:error, %Ash.Error.Forbidden{}} = Keys.step_down(attached, %{}, actor: actor)
    end

    assert Keys.my_active_pairing!(@fleet, 1, actor: intruder) == nil
    assert [unchanged] = Keys.pairing_history!(@fleet, 1)
    assert Map.take(unchanged, @decision) == Map.take(attached, @decision)
    assert Keys.current_operator!(@fleet, 1).id == attached.id
  end

  test "stepping down a second time finds the pairing already ended" do
    runner = agent("b")
    attached = attach!(runner, "Runner")
    stepped_down = Keys.step_down!(attached, %{}, actor: runner)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Keys.step_down(attached, %{}, actor: runner)

    assert [unchanged] = Keys.pairing_history!(@fleet, 1)
    assert Map.take(unchanged, @decision) == Map.take(stepped_down, @decision)
  end

  # Giving a key up never waits on ownership: the agent may leave a key that
  # changed hands, or while ownership is being refreshed.
  test "an agent steps down from a pairing made under an earlier owner" do
    runner = agent("b")
    attached = attach!(runner, "Runner")

    ChainHelpers.seed_cursor!(@fleet,
      observed_at: DateTime.add(DateTime.utc_now(), -121, :second)
    )

    stepped_down = Keys.step_down!(attached, %{}, actor: runner)
    assert {stepped_down.status, stepped_down.ended_reason} == {:ended, :stepped_down}
  end

  test "after stepping down the agent can no longer post as the key, and keeps what it wrote" do
    Rooms.bootstrap_rooms!()
    runner = agent("b")
    attached = attach!(runner, "Runner")
    post = &%{fleet_id: @fleet, slug: "general", body: "Hello", idempotency_key: &1}

    sent = Rooms.send_message!(post.("k-1"), actor: runner)
    Keys.step_down!(attached, %{}, actor: runner)

    assert {:error, %Ash.Error.Forbidden{}} = Rooms.send_message(post.("k-2"), actor: runner)

    assert [kept] = Rooms.read_messages!(@fleet, "general")
    assert {kept.id, kept.agent_profile_id} == {sent.id, attached.agent_profile_id}
  end

  test "an agent that stepped down may ask for the key again, leaving the old row in history",
       %{owner: owner} do
    runner = agent("b")
    attached = attach!(runner, "Runner")
    Keys.step_down!(attached, %{}, actor: runner)

    again = Keys.request_pairing!(@fleet, 1, %{}, actor: runner)
    assert again.id != attached.id
    assert again.status == :requested

    Keys.approve_pairing!(again, Keys.default_limits(), actor: human(owner))

    assert Enum.map(Keys.pairing_history!(@fleet, 1), &{&1.id, &1.status, &1.ended_reason}) ==
             [{attached.id, :ended, :stepped_down}, {again.id, :active, nil}]
  end

  test "a decision already taken cannot be retaken from a stale record", %{owner: owner} do
    operator = agent("b")
    request = request!(operator, "Operator")
    withdrawn = Keys.withdraw_pairing_request!(request, %{}, actor: operator)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Keys.approve_pairing(request, Keys.default_limits(), actor: human(owner))

    assert [unchanged] = Keys.pairing_history!(@fleet, 1)
    assert Map.take(unchanged, @decision) == Map.take(withdrawn, @decision)
    assert Keys.current_operator!(@fleet, 1) == nil
  end

  test "an owner approves only with all four limits, and the pairing keeps them", %{
    owner: owner
  } do
    request = request!(agent("b"), "Operator")

    for missing <- Map.keys(@edited) do
      assert {:error, %Ash.Error.Invalid{}} =
               Keys.approve_pairing(request, Map.delete(@edited, missing), actor: human(owner))
    end

    assert {:error, %Ash.Error.Invalid{}} =
             Keys.approve_pairing(request, %{@edited | outside: "   "}, actor: human(owner))

    assert {:error, %Ash.Error.Invalid{}} =
             Keys.approve_pairing(request, %{@edited | money: String.duplicate("m", 501)},
               actor: human(owner)
             )

    assert [waiting] = Keys.list_pairing_requests!(@fleet, 1)

    assert {waiting.id, waiting.status, waiting.limits_written_at} ==
             {request.id, :requested, nil}

    approved = Keys.approve_pairing!(request, @edited, actor: human(owner))

    assert Map.take(approved, Enum.drop(@limits, -1)) == %{
             limits_money: "Spend nothing.",
             limits_information: "Keep my name out of it.",
             limits_outside: "Stay inside Keyfleet.",
             limits_check_first: "Any promise to anyone."
           }

    assert %DateTime{} = approved.limits_written_at
    assert Map.take(Keys.current_operator!(@fleet, 1), @limits) == Map.take(approved, @limits)
  end

  test "the owner rewrites the limits of the agent running the key; nothing else moves", %{
    owner: owner
  } do
    attached = attach!(agent("b"), "Operator")
    changed = Keys.set_limits!(attached, @edited, actor: human(owner))

    assert changed.limits_money == "Spend nothing."
    assert changed.limits_check_first == "Any promise to anyone."
    assert DateTime.after?(changed.limits_written_at, attached.limits_written_at)

    assert [stored] = Keys.pairing_history!(@fleet, 1)
    assert Map.take(stored, @identity ++ @decision) == Map.take(attached, @identity ++ @decision)
    assert Map.take(stored, @limits) == Map.take(changed, @limits)

    assert {:error, %Ash.Error.Invalid{}} =
             Keys.set_limits(changed, %{@edited | information: String.duplicate("i", 501)},
               actor: human(owner)
             )

    assert Map.take(Keys.current_operator!(@fleet, 1), @limits) == Map.take(changed, @limits)
  end

  test "only the wallet that owns the key today may change its agent's limits", %{owner: owner} do
    runner = agent("b")
    attached = attach!(runner, "Operator")

    for actor <- [human(agent("e")), runner, owner, @system, nil] do
      assert {:error, %Ash.Error.Forbidden{}} = Keys.set_limits(attached, @edited, actor: actor)
    end

    assert Map.take(Keys.current_operator!(@fleet, 1), @limits) == Map.take(attached, @limits)

    new_owner = agent("1")
    epoch!(ownership_epoch: 1, owner_wallet: new_owner.wallet_address, log_index: 1)

    assert {:error, %Ash.Error.Forbidden{}} =
             Keys.set_limits(attached, @edited, actor: human(owner))

    assert [unchanged] = Keys.pairing_history!(@fleet, 1)
    assert Map.take(unchanged, @limits) == Map.take(attached, @limits)
  end

  test "a request waiting for the owner has no limits to change", %{owner: owner} do
    request = request!(agent("b"), "Operator")

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Keys.set_limits(request, @edited, actor: human(owner))

    assert [waiting] = Keys.list_pairing_requests!(@fleet, 1)
    assert Map.take(waiting, @limits) == Map.take(request, @limits)
    assert waiting.limits_written_at == nil
  end

  test "an owner writes limits for the agent holding their own key", %{owner: owner} do
    profile!(owner, "Owner agent")
    held = Keys.request_pairing!(@fleet, 1, %{}, actor: owner)
    assert held.limits_written_at == nil

    Keys.set_limits!(held, @edited, actor: human(owner))

    assert [stored] = Keys.pairing_history!(@fleet, 1)

    assert %{
             limits_money: "Spend nothing.",
             limits_information: "Keep my name out of it.",
             limits_outside: "Stay inside Keyfleet.",
             limits_check_first: "Any promise to anyone.",
             limits_written_at: %DateTime{}
           } = Map.take(stored, @limits)
  end

  test "the limits of a pairing that has ended stay as they were", %{owner: owner} do
    runner = agent("b")
    attached = attach!(runner, "Operator")
    Keys.step_down!(attached, %{}, actor: runner)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Keys.set_limits(attached, @edited, actor: human(owner))

    assert [ended] = Keys.pairing_history!(@fleet, 1)
    assert Map.take(ended, @limits) == Map.take(attached, @limits)
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

    # Limits come whole: all four and when they were written, or none at all.
    for field <- @limits do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "UPDATE keyfleet_app.key_pairings SET #{field} = NULL WHERE id = $1",
                 [Ecto.UUID.dump!(attached.id)],
                 mode: :savepoint
               )
    end

    assert Keys.current_operator!(@fleet, 1).id == attached.id
  end

  # Other suites commit Syndicate keys outside the sandbox; only this test's
  # keys are read.
  @these_keys [query: [filter: [token_id: [in: [1, 2]]]]]

  defp run_keys, do: Enum.map(Keys.keys_run_in_fleet!(@fleet, @these_keys), & &1.token_id)

  defp held_keys(wallets),
    do: Enum.map(Keys.keys_held_in_fleet!(@fleet, wallets, @these_keys), & &1.token_id)

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
    Keys.approve_pairing!(request, Keys.default_limits(), actor: owner_of(request))
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

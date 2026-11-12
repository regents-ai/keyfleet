defmodule Keyfleet.LeftMessages.LeaveTest do
  # Leaving a message for the site's team, through the actions every surface calls:
  # - a signed-in person and a paired agent with a profile each leave one,
  #   recorded as themselves, and get its receipt; an agent with no profile is
  #   refused as profile_not_found;
  # - who left it comes from the actor alone: no input can name a sender;
  # - the topic, the text and reply_to are bounded, and nothing is kept when refused;
  # - an operation_id answers its first message again, and refuses any other use;
  # - each sender leaves 10 an hour;
  # - only the site's admins read messages.
  use ExUnit.Case, async: false

  alias Keyfleet.{Accounts, LeftMessages, PairingHelpers, PublicIdentity, Repo}
  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.LeftMessages.{LeftMessage, Refused}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    %{key: Ecto.UUID.generate()}
  end

  test "a person and a paired agent each leave a message as themselves", %{key: key} do
    {person, account} = person()

    assert {:ok, %LeftMessage{} = left} =
             LeftMessages.leave_message(
               %{topic: "agents", body: "Hello team", reply_to: "me@example.com"},
               actor: person,
               context: %{client_key: key}
             )

    assert LeftMessage.receipt(left) == %{
             id: left.id,
             topic: "agents",
             inserted_at: left.inserted_at
           }

    assert %{human_account_id: id, agent_profile_id: nil, sender_name: name} = stored(left.id)
    assert {id, name} == {account.id, PublicIdentity.label(account)}

    # The agent's person, who paired it, signed in here too.
    agent = agent()

    assert {:ok, %{replayed: false, receipt: %{id: id, topic: "watchdog"}}} =
             leave(agent, "watchdog", %{body: "From an agent"}, key)

    profile = Keyfleet.Agents.get_my_profile!(actor: agent)

    assert %{
             human_account_id: human,
             agent_profile_id: profile_id,
             sender_name: "Their agent",
             reply_to: nil
           } = stored(id)

    assert {human, profile_id} == {agent.human_account_id, profile.id}
    assert is_integer(human)
  end

  test "an agent with no profile has no name to leave one under", %{key: key} do
    agent = PairingHelpers.pair_wallet!(wallet())
    count = count()

    assert {:error, %{errors: [%Refused{code: "profile_not_found"}]}} =
             leave(agent, "agents", %{body: "Hi"}, key)

    assert count() == count
  end

  test "no input names the sender, so a message is never left as anyone else", %{key: key} do
    {person, _account} = person()
    {_other, other} = person()
    count = count()

    assert {:error, %Ash.Error.Invalid{}} =
             LeftMessages.leave_message(
               %{topic: "agents", body: "Hi", human_account_id: other.id, sender_name: "Other"},
               actor: person,
               context: %{client_key: key}
             )

    assert {:error, %Ash.Error.Invalid{}} =
             leave(agent(), "agents", %{body: "Hi", agent_profile_id: Ecto.UUID.generate()}, key)

    assert count() == count
  end

  test "the topic, the text and reply_to are bounded, and a refusal keeps nothing", %{key: key} do
    agent = agent()
    count = count()

    for {topic, input} <- [
          {"agents", %{body: String.duplicate("a", 2001)}},
          {"agents", %{body: ""}},
          {"agents", %{body: "Hi", reply_to: String.duplicate("a", 201)}},
          {"Agents!", %{body: "Hi"}},
          {String.duplicate("a", 41), %{body: "Hi"}}
        ] do
      assert {:error, %Ash.Error.Invalid{}} = leave(agent, topic, input, key)
    end

    assert {:ok, _} = leave(agent, "agents", %{body: String.duplicate("a", 2000)}, key)
    assert count() == count + 1
  end

  test "an operation_id answers its first message again and refuses any other use", %{key: key} do
    agent = agent()
    operation = Ecto.UUID.generate()
    input = %{body: "Once", reply_to: "a room", operation_id: operation}

    again = fn topic, input ->
      LeftMessages.agent_leave_message(topic, input, actor: agent, context: %{client_key: key})
    end

    assert {:ok, %{replayed: false, receipt: receipt}} = again.("agents", input)
    assert {:ok, %{replayed: true, receipt: ^receipt}} = again.("agents", input)

    for {topic, changed} <- [
          {"agents", %{input | body: "Twice"}},
          {"agents", %{input | reply_to: "elsewhere"}},
          {"watchdog", input}
        ] do
      assert {:error, %{errors: [%Refused{code: "idempotency_conflict"}]}} =
               again.(topic, changed)
    end

    assert count_by(agent) == 1
  end

  test "each sender leaves 10 messages an hour, then is refused until it passes" do
    agent = agent()

    for n <- 1..10 do
      assert {:ok, _} = leave(agent, "agents", %{body: "Message #{n}"}, Ecto.UUID.generate())
    end

    assert {:error, %Ash.Error.Invalid{errors: [%{field: :body}]}} =
             leave(agent, "agents", %{body: "One more"}, Ecto.UUID.generate())

    assert count_by(agent) == 10

    {person, _account} = person()

    assert {:ok, _} =
             LeftMessages.leave_message(%{topic: "agents", body: "Still free"},
               actor: person,
               context: %{client_key: Ecto.UUID.generate()}
             )
  end

  test "only the site's admins read messages", %{key: key} do
    {person, _account} = person()

    {:ok, left} =
      LeftMessages.leave_message(%{topic: "agents", body: "Private"},
        actor: person,
        context: %{client_key: key}
      )

    did = "did:privy:admin-" <> Ecto.UUID.generate()
    put_admins([did])

    admin = %RegentAgents.Person{privy_user_id: did, role: :admin}
    assert %{results: results} = LeftMessages.list_left_messages!(actor: admin)
    assert left.id in Enum.map(results, & &1.id)

    for reader <- [
          person,
          agent(),
          %RegentAgents.Person{privy_user_id: did},
          %RegentAgents.Person{privy_user_id: "did:privy:not-listed", role: :admin},
          nil
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = LeftMessages.list_left_messages(actor: reader)
    end
  end

  defp leave(agent, topic, input, key) do
    LeftMessages.agent_leave_message(
      topic,
      Map.put_new(input, :operation_id, Ecto.UUID.generate()),
      actor: agent,
      context: %{client_key: key}
    )
  end

  # Every message saved, read past the policy that keeps them for the admins.
  defp saved, do: Ash.read!(LeftMessage, authorize?: false)

  defp stored(id), do: Enum.find(saved(), &(&1.id == id))
  defp count, do: length(saved())

  defp count_by(agent) do
    profile = Keyfleet.Agents.get_my_profile!(actor: agent)
    Enum.count(saved(), &(&1.agent_profile_id == profile.id))
  end

  defp put_admins(admins) do
    for app <- [:keyfleet, :regent_agents] do
      old = Application.fetch_env(app, :admins)
      Application.put_env(app, :admins, admins)

      on_exit(fn -> restore_admins(app, old) end)
    end
  end

  defp restore_admins(app, {:ok, admins}), do: Application.put_env(app, :admins, admins)
  defp restore_admins(app, :error), do: Application.delete_env(app, :admins)

  defp person do
    wallet = wallet()

    account =
      Accounts.register_verified!("did:privy:message-" <> wallet, wallet, [wallet],
        actor: %System{}
      )

    {Human.for_account(account), account}
  end

  # A paired agent with a profile, its person's own.
  defp agent do
    {person, _account} = person()
    PairingHelpers.agent_for!(person)
  end

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end

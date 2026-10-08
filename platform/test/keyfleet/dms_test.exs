defmodule Keyfleet.DmsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Dms
  alias Keyfleet.Dms.Errors.SendLimitError
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Repo

  @fleet "fibonacci_syndicate"

  # Keys 1, 2, 3 and 5 are sold, each to a different person.
  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    for {token_id, owner} <- [{1, "a"}, {2, "b"}, {3, "c"}, {5, "e"}], do: epoch!(token_id, owner)
    :ok
  end

  test "only a Key's holder reads and sends as it" do
    send!(human("a"), 1, 2, "Hello")

    assert {:error, %Ash.Error.Forbidden{}} = send_dm(human("e"), 1, 2, "As Key 1")

    assert {:error, %Ash.Error.Forbidden{}} =
             Dms.read_conversation(@fleet, 1, 2, actor: human("e"))

    assert {:error, %Ash.Error.Forbidden{}} = Dms.inbox(@fleet, 2, actor: human("a"))
    assert {:ok, %{messages: []}} = Dms.changes(@fleet, 0, human("e"))
    assert {:error, %Ash.Error.Forbidden{}} = Dms.changes(@fleet, 0, human("f"))
    assert Dms.inbox_topics(@fleet, human("e")) == ["dms:#{@fleet}:5"]
    assert Dms.inbox_topics(@fleet, human("f")) == []

    assert [%{body: "Hello"}] = Dms.read_conversation!(@fleet, 2, 1, actor: human("b"))
  end

  test "a blocked Key's message lands in the Blocked inbox, not the main one" do
    Dms.block_key!(@fleet, 2, 5, actor: human("b"))
    send!(human("a"), 1, 2, "From a friend")
    send!(human("e"), 5, 2, "From a blocked Key")

    assert [%{key_a: 1, last_body: "From a friend"}] = Dms.inbox!(@fleet, 2, actor: human("b"))

    assert [%{key_a: 2, key_b: 5, last_body: "From a blocked Key"}] =
             Dms.inbox!(@fleet, 2, %{blocked: true}, actor: human("b"))

    assert {:ok, %{messages: [%{body: "From a friend"}]}} =
             Dms.changes(@fleet, 0, human("b"))
  end

  test "deleting a conversation removes its messages for both sides" do
    send!(human("a"), 1, 2, "Hello")
    send!(human("b"), 2, 1, "Hi")
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Dms.inbox_topic(@fleet, 1))

    conversation = Dms.get_conversation!(@fleet, 2, 1, actor: human("b"))
    :ok = Dms.delete_conversation(conversation, actor: human("b"))
    conversation_id = conversation.id

    assert_receive %Phoenix.Socket.Broadcast{
      event: "dm_deleted",
      payload: %{conversation_id: ^conversation_id}
    }

    for {person, token_id} <- [{"a", 1}, {"b", 2}] do
      assert Dms.inbox!(@fleet, token_id, actor: human(person)) == []
      assert Dms.read_conversation!(@fleet, token_id, 3 - token_id, actor: human(person)) == []
    end
  end

  test "a Key's 301st message in an hour is refused" do
    for n <- 1..300, do: send!(human("c"), 3, 1, "Message #{n}")

    assert {:error, %Ash.Error.Invalid{errors: [%SendLimitError{limit: 300}]}} =
             send_dm(human("c"), 3, 1, "One too many")

    assert length(Dms.read_conversation!(@fleet, 1, 3, %{limit: 200}, actor: human("a"))) == 200
  end

  defp send!(actor, from, to, body) do
    {:ok, message} = send_dm(actor, from, to, body)
    message
  end

  defp send_dm(actor, from, to, body),
    do:
      Dms.send_dm(
        %{
          fleet_id: @fleet,
          from_token_id: from,
          to_token_id: to,
          body: body,
          idempotency_key: Ecto.UUID.generate()
        },
        actor: actor
      )

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  defp epoch!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet(owner),
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end

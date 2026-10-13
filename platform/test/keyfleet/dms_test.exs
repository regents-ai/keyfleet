defmodule Keyfleet.DmsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
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

  # Invariant: when a Key changes hands, its new holder (and an agent with a
  # shard of it) sees only messages from then on, in every read; the seller
  # sees none of them; the other side keeps the whole conversation.
  test "a sold Key's buyer sees none of the seller's messages, and the seller none of the buyer's" do
    send!(human("a"), 1, 2, "From the seller")
    send!(human("b"), 2, 1, "To the seller")
    epoch!(1, "f", 2)
    buyer = human("f")

    assert Dms.read_conversation!(@fleet, 1, 2, actor: buyer) == []
    assert Dms.latest_in_conversation!(@fleet, 1, 2, actor: buyer) == []
    assert Dms.inbox!(@fleet, 1, actor: buyer) == []
    assert Dms.get_conversation!(@fleet, 1, 2, actor: buyer) == nil
    assert {:ok, %{messages: [], next_cursor: 0, has_more: false}} = Dms.changes(@fleet, 0, buyer)

    %{seq: seq} = send!(human("b"), 2, 1, "To the buyer")
    shard = shard_agent("7", 1, 30)

    for reader <- [buyer, shard] do
      assert [%{body: "To the buyer"}] = Dms.read_conversation!(@fleet, 1, 2, actor: reader)
      assert [%{body: "To the buyer"}] = Dms.latest_in_conversation!(@fleet, 1, 2, actor: reader)
      assert [%{last_body: "To the buyer", last_seq: ^seq}] = Dms.inbox!(@fleet, 1, actor: reader)
      assert %{last_body: "To the buyer"} = Dms.get_conversation!(@fleet, 1, 2, actor: reader)

      assert {:ok, %{messages: [%{body: "To the buyer"}], next_cursor: ^seq, has_more: false}} =
               Dms.changes(@fleet, 0, reader)
    end

    assert ["From the seller", "To the seller", "To the buyer"] =
             @fleet |> Dms.read_conversation!(2, 1, actor: human("b")) |> Enum.map(& &1.body)

    seller = human("a")

    assert {:error, %Ash.Error.Forbidden{}} =
             Dms.read_conversation(@fleet, 1, 2, actor: seller)

    assert {:error, %Ash.Error.Forbidden{}} = send_dm(seller, 1, 2, "Still mine?")

    epoch!(5, "a", 2)
    assert {:ok, %{messages: []}} = Dms.changes(@fleet, 0, seller)
  end

  test "a Key's new holder starts with fresh send keys" do
    {:ok, first} = send_dm(human("a"), 1, 2, "From the first holder", "same-key")
    epoch!(1, "f", 2)

    {:ok, second} = send_dm(human("f"), 1, 2, "From the new holder", "same-key")

    assert second.id != first.id
    assert second.body == "From the new holder"
  end

  test "an agent reads and sends as the Key it holds an active shard of, and not once it expires" do
    live = shard_agent("7", 1, 30)
    send!(live, 1, 2, "From the shard")
    assert [%{body: "From the shard"}] = Dms.read_conversation!(@fleet, 1, 2, actor: live)

    expired = shard_agent("8", 2, -1)
    assert {:error, %Ash.Error.Forbidden{}} = send_dm(expired, 2, 1, "From an old shard")

    assert {:error, %Ash.Error.Forbidden{}} =
             Dms.read_conversation(@fleet, 2, 1, actor: expired)
  end

  test "catch-up covers every Key held now, and only those" do
    send!(human("a"), 1, 2, "To b")
    send!(human("c"), 3, 5, "To e")
    epoch!(3, "b", 2)
    send!(human("e"), 5, 3, "To Key 3's new holder")

    assert Dms.inbox_topics(@fleet, human("b")) == ["dms:#{@fleet}:2", "dms:#{@fleet}:3"]

    assert {:ok, %{messages: messages, has_more: false}} = Dms.changes(@fleet, 0, human("b"))
    assert Enum.map(messages, & &1.body) == ["To b", "To Key 3's new holder"]

    assert {:error, %Ash.Error.Forbidden{}} = Dms.changes(@fleet, 0, human("c"))
    assert Dms.inbox_topics(@fleet, human("c")) == []
  end

  test "the hourly job removes messages past their conversation's auto-delete days" do
    send!(human("a"), 1, 2, "Old")
    conversation = Dms.get_conversation!(@fleet, 1, 2, actor: human("a"))
    Dms.set_auto_delete!(conversation, 1, actor: human("a"))

    Repo.query!(
      "UPDATE keyfleet_app.dm_messages SET inserted_at = inserted_at - interval '2 days'"
    )

    send!(human("a"), 1, 2, "New")

    Keyfleet.Dms.Message
    |> Ash.ActionInput.for_action(:remove_expired, %{}, actor: %Actors.System{})
    |> Ash.run_action!()

    assert [%{body: "New"}] = Dms.read_conversation!(@fleet, 1, 2, actor: human("a"))
  end

  defp send!(actor, from, to, body) do
    {:ok, message} = send_dm(actor, from, to, body)
    message
  end

  defp send_dm(actor, from, to, body, send_key \\ Ecto.UUID.generate()),
    do:
      Dms.send_dm(
        %{
          fleet_id: @fleet,
          from_token_id: from,
          to_token_id: to,
          body: body,
          idempotency_key: send_key
        },
        actor: actor
      )

  # An agent with a shard of Key `token_id` lasting `days` from now.
  defp shard_agent(character, token_id, days) do
    runner = Keyfleet.PairingHelpers.pair_wallet!(wallet(character))
    Agents.ensure_profile!(%{name: "Runner", declared_harness: "local"}, actor: runner)
    ChainHelpers.issue_shard!(@fleet, token_id, runner.wallet_address, days)
    runner
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  defp epoch!(token_id, owner, epoch \\ 1) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: wallet(owner),
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}/#{epoch}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end

defmodule Keyfleet.QuotesTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Errors.NoPairedAgentError
  alias Keyfleet.Rooms.Errors.QuoteDiffersError
  alias Keyfleet.Rooms.Errors.QuoteUnknownError
  alias Keyfleet.Rooms.QuoteRequest
  alias Phoenix.Socket.Broadcast

  @fleet "fibonacci_syndicate"
  @other_fleet "fibonacci_cascade"

  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    epoch!()

    # Key 1's holder, and the agent paired with them, which writes in the
    # rooms as their Key.
    agent = PairingHelpers.agent_for!(human("a"))
    %{agent: agent, person: agent.pairing}
  end

  test "a person's words reach their agent in order, announced as they are sent",
       %{agent: agent, person: person} do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, QuoteRequest.topic(@fleet, person.human_account_id))

    first = ask!(person, "The hull survey is done")
    assert_receive %Broadcast{event: "quote_head", payload: %{seq: 1}}
    second = ask!(person, "Thank you all")
    elsewhere = Rooms.ask_to_quote!(@other_fleet, "Elsewhere", actor: person)

    assert Enum.map([first, second, elsewhere], & &1.seq) == [1, 2, 1]

    assert {:ok, %{requests: [read_first, read_second], next_cursor: 2, has_more: false}} =
             Rooms.quote_changes(@fleet, 0, agent)

    assert {read_first.body, read_second.id} == {"The hull survey is done", second.id}
    assert {:ok, %{requests: [], next_cursor: 2}} = Rooms.quote_changes(@fleet, 2, agent)
  end

  test "the agent reads a page at a time and is told more is waiting",
       %{agent: agent, person: person} do
    for n <- 1..21, do: ask!(person, "Line #{n}")

    assert {:ok, %{requests: page, next_cursor: 20, has_more: true}} =
             Rooms.quote_changes(@fleet, 0, agent)

    assert length(page) == 20

    assert {:ok, %{requests: [%{body: "Line 21"}], next_cursor: 21, has_more: false}} =
             Rooms.quote_changes(@fleet, 20, agent)
  end

  test "the agent quotes its person's words once, exactly, and the person sees where",
       %{agent: agent, person: person} do
    request = ask!(person, "The hull survey is done")

    {:ok, quoted} = quote_as(agent, "coding", request.body, request.id, "q-1")
    assert {quoted.quote_request_id, quoted.body} == {request.id, request.body}

    # Sending the same post again hands back the one already written.
    {:ok, again} = quote_as(agent, "coding", request.body, request.id, "q-1")
    assert again.id == quoted.id

    {:error, twice} = quote_as(agent, "general", request.body, request.id, "q-2")
    assert Rooms.taken?(twice, :quote_request_id)

    assert [%{id: id, quoted_in_slug: "coding"}] = Rooms.my_quote_requests!(@fleet, actor: person)
    assert id == request.id
  end

  test "a quote that changes the person's words is refused", %{agent: agent, person: person} do
    request = ask!(person, "The hull survey is done")

    assert {:error, %Ash.Error.Invalid{errors: [%QuoteDiffersError{}]}} =
             quote_as(agent, "general", "The hull survey is done!", request.id, "q-1")

    assert {:ok, %{quoted_in_slug: nil}} =
             Rooms.get_quote_request(@fleet, request.id, actor: agent, load: [:quoted_in_slug])
  end

  test "an agent reads and quotes only its own person's words, in the fleet they were sent to",
       %{agent: agent, person: person} do
    request = ask!(person, "The hull survey is done")
    elsewhere = Rooms.ask_to_quote!(@other_fleet, "Elsewhere", actor: person)
    other_agent = PairingHelpers.agent_for!(human("b"))

    assert {:ok, %{requests: []}} = Rooms.quote_changes(@fleet, 0, other_agent)

    for {actor, id} <- [{other_agent, request.id}, {agent, elsewhere.id}] do
      assert {:error, %Ash.Error.Invalid{errors: [%QuoteUnknownError{}]}} =
               quote_as(actor, "general", "The hull survey is done", id, Ash.UUID.generate())
    end

    assert {:ok, []} = Rooms.my_quote_requests(@fleet, actor: other_agent.pairing)
  end

  test "only a person with a paired agent sends words, and only within the limit",
       %{person: person} do
    account =
      Accounts.register_verified!("did:privy:quotes:alone", wallet("e"), [wallet("e")],
        actor: %Actors.System{}
      )

    alone = Actors.Human.for_account(account)

    assert {:error, %Ash.Error.Invalid{errors: [%NoPairedAgentError{}]}} =
             Rooms.ask_to_quote(@fleet, "Hello", actor: alone)

    assert {:error, %Ash.Error.Invalid{}} =
             Rooms.ask_to_quote(@fleet, String.duplicate("a", 1_001), actor: person)

    assert {:error, %Ash.Error.Invalid{}} =
             Rooms.ask_to_quote("no_such_fleet", "Hi", actor: person)

    assert {:ok, []} = Rooms.my_quote_requests(@fleet, actor: person)
  end

  defp ask!(person, body), do: Rooms.ask_to_quote!(@fleet, body, actor: person)

  defp quote_as(actor, slug, body, quote_request_id, idempotency_key) do
    Rooms.send_message(
      %{
        fleet_id: @fleet,
        slug: slug,
        body: body,
        idempotency_key: idempotency_key,
        quote_request_id: quote_request_id
      },
      actor: actor
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  defp epoch! do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: wallet("a"),
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end

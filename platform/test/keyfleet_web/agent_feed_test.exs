defmodule KeyfleetWeb.AgentFeedTest do
  # A signed agent opens its live feed on a real connection and hears, the
  # moment it is posted, what is its own to answer in the fleets where it acts
  # as a Key: and never another Key's, a muted Key's, its own, or a room its
  # reader may not read.
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Dms
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @path "/api/v1/feed"

  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    # Keys 1, 2 and 3 are sold, each to a different person.
    for {token_id, owner} <- [{1, "a"}, {2, "b"}, {3, "c"}], do: epoch!(token_id, owner)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    site = SignedAgentHelpers.serve!(:site, @endpoint)

    # The agent whose feed is read acts as Key 2, its person's Key; the
    # outsider's person holds no Key.
    {me, my_signer} = signing_agent!(wallet("b"))
    {_outsider, outsider_signer} = signing_agent!(wallet("e"))

    %{
      secret: secret,
      site: site,
      me: me,
      signer: my_signer,
      outsider: outsider_signer,
      a: PairingHelpers.agent_for!(human("a")),
      c: PairingHelpers.agent_for!(human("c"))
    }
  end

  test "each kind reaches the agent whose Key it concerns, naming its place and never its words",
       c do
    feed = open!(c, c.signer)

    in_room = post!(c.a, "general", "The hull is sound")
    assert {[%{id: id, data: event}], feed} = take(feed, 1)

    assert event == %{
             "kind" => "room_post",
             "id" => in_room.id,
             "at" => DateTime.to_iso8601(in_room.inserted_at),
             "fleet" => @fleet,
             "room" => "general",
             "seq" => in_room.seq,
             "as_key" => 1,
             "read" => "POST /api/v1/agent/fleets/#{@fleet}/rooms/general/messages/get"
           }

    assert id == Integer.to_string(DateTime.to_unix(in_room.inserted_at, :microsecond))

    # A post naming its Key is one mention, in a members' room too.
    asked = post!(c.a, "coding", "@Key 2 can you check the hull?")
    assert {[%{data: mention}], feed} = take(feed, 1)

    assert %{"kind" => "mention", "id" => asked_id, "room" => "coding", "as_key" => 1} = mention
    assert asked_id == asked.id

    on_wall = wall!(c.c, 2, "The spares came")
    assert {[%{data: wall_post}], feed} = take(feed, 1)

    assert wall_post == %{
             "kind" => "wall_post",
             "id" => on_wall.id,
             "at" => DateTime.to_iso8601(on_wall.inserted_at),
             "fleet" => @fleet,
             "wall" => 2,
             "seq" => on_wall.seq,
             "as_key" => 3,
             "read" => "POST /api/v1/agent/keys/#{@fleet}/2/messages/get"
           }

    dm = dm!(human("a"), 1, 2, "Can you redo the deploy?")
    assert {[%{data: dm_event}], feed} = take(feed, 1)

    assert dm_event == %{
             "kind" => "dm",
             "id" => dm.id,
             "at" => DateTime.to_iso8601(dm.inserted_at),
             "fleet" => @fleet,
             "conversation_id" => dm.conversation_id,
             "as_key" => 1,
             "to_key" => 2,
             "read" => "POST /api/v1/agent/fleets/#{@fleet}/keys/2/dms/1/read"
           }

    for event <- [event, mention, wall_post, dm_event],
        words <- ["The hull is sound", "check the hull", "The spares came", "redo the deploy"],
        do: refute(Jason.encode!(event) =~ words)

    quiet!(feed)
  end

  test "the agent never hears another Key's messages, a muted Key's posts, a blocked Key's messages or its own posts",
       c do
    Rooms.mute_key!(@fleet, 3, actor: c.me)
    Dms.block_key!(@fleet, 2, 1, actor: human("b"))
    feed = open!(c, c.signer)

    post!(c.c, "general", "From a Key it muted")
    wall!(c.c, 2, "On its wall, from a Key it muted")
    post!(c.me, "general", "Its own post")
    wall!(c.a, 3, "On another Key's wall")
    dm!(human("a"), 1, 3, "To another Key")
    dm!(human("a"), 1, 2, "From a Key it blocked")
    heard = post!(c.a, "general", "Heard")

    assert {[%{data: %{"kind" => "room_post", "id" => id}}], feed} = take(feed, 1)
    assert id == heard.id
    quiet!(feed)
  end

  test "an agent whose person holds no Key in the fleet hears nothing from it", c do
    feed = open!(c, c.outsider)

    post!(c.a, "general", "In public")
    post!(c.a, "coding", "@Key 2 in the members' room")
    wall!(c.a, 2, "On Key 2's wall")
    dm!(human("a"), 1, 2, "To Key 2")

    quiet!(feed)
  end

  test "a reconnect gets what it missed after its last event, and a resync past 100", c do
    feed = open!(c, c.signer)
    post!(c.a, "general", "First")
    assert {[%{id: last}], _feed} = take(feed, 1)

    second = post!(c.a, "general", "Second")
    third = wall!(c.a, 2, "Third")

    feed = open!(c, c.signer, [{"last-event-id", last}])
    assert {[%{data: one}, %{data: two}], feed} = take(feed, 2)
    assert {one["id"], two["id"]} == {second.id, third.id}
    quiet!(feed)

    # An id that is not one of the feed's says to resync, and carries no id.
    feed = open!(c, c.signer, [{"last-event-id", "yesterday"}])
    assert {[%{id: nil, data: %{"kind" => "resync"}}], _feed} = take(feed, 1)

    for n <- 1..101, do: post!(c.a, "general", "Missed #{n}")
    feed = open!(c, c.signer, [{"last-event-id", last}])
    assert {[%{id: nil, data: %{"kind" => "resync"}}], _feed} = take(feed, 1)
  end

  test "a reader that is not a member is never told of a members' room", c do
    feed = open!(c, c.signer)
    post!(c.a, "general", "Before")
    assert {[%{id: before}], _feed} = take(feed, 1)

    post!(c.a, "coding", "The members' plan")
    public = post!(c.a, "general", "In public")

    # Key ownership read too long ago makes no one a member.
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))

    feed = open!(c, c.signer, [{"last-event-id", before}])
    assert {[%{data: %{"id" => id, "room" => "general"}}], feed} = take(feed, 1)
    assert id == public.id
    quiet!(feed)
  end

  test "opening another feed closes the first, as does a pairing that ends", c do
    first = open!(c, c.signer)
    second = open!(c, c.signer)
    assert {[%{data: %{"kind" => "closed", "reason" => "replaced"}}], first} = take(first, 1)
    assert_done!(first)

    person = %RegentAgents.Person{privy_user_id: "did:privy:test-" <> wallet("b")}
    {:ok, agents} = RegentAgents.list_my_agents(actor: person)

    :ok =
      RegentAgents.unpair_agent(Enum.find(agents, &(&1.wallet == c.me.wallet_address)),
        actor: person
      )

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      RegentAgents.topic(person.privy_user_id),
      :agents_changed
    )

    assert {[%{data: %{"kind" => "closed", "reason" => "pairing_changed"}}], second} =
             take(second, 1)

    assert_done!(second)
  end

  test "past the machine's limit a feed is refused until one closes", c do
    put_feeds(max_open: 200)

    holders =
      for n <- 1..200 do
        spawn_holder("0x" <> String.pad_leading(Integer.to_string(n), 40, "0"))
      end

    full = refused!(c, c.signer)
    assert full.status == 503
    assert full.body["error"]["code"] == "feed_full"
    assert ContractSchema.response_errors(full.body, "GET", @path, 503) == []

    Process.exit(hd(holders), :kill)
    wait_until(fn -> Registry.count(KeyfleetWeb.OpenFeeds) < 200 end)
    feed = open!(c, c.signer)
    quiet!(feed)
  end

  test "an unsigned request is refused", c do
    unsigned = Req.get!(c.site <> @path, retry: false)
    assert unsigned.status == 401
    assert ContractSchema.response_errors(unsigned.body, "GET", @path, 401) == []
  end

  ## The feed, read as a client reads it

  defp open!(c, signer, headers \\ []) do
    response =
      Req.get!(c.site <> @path, headers: signed(c, signer) ++ headers, into: :self, retry: false)

    assert response.status == 200
    assert ["text/event-stream" <> _] = Req.Response.get_header(response, "content-type")
    %{response: response, buffer: ""}
  end

  defp refused!(c, signer),
    do: Req.get!(c.site <> @path, headers: signed(c, signer), retry: false)

  defp signed(c, signer) do
    request =
      SignedAgentHelpers.sign(
        signer,
        c.secret,
        Siwa.Contract.authority(c.site),
        "GET",
        @path,
        nil
      )

    Map.to_list(request.headers)
  end

  # The next `count` events, skipping keep-alive lines.
  defp take(feed, count, taken \\ [])
  defp take(feed, count, taken) when length(taken) == count, do: {Enum.reverse(taken), feed}

  defp take(%{buffer: buffer} = feed, count, taken) do
    case String.split(buffer, "\n\n", parts: 2) do
      [frame, rest] ->
        taken = if event = event(frame), do: [event | taken], else: taken
        take(%{feed | buffer: rest}, count, taken)

      [_partial] ->
        take(receive_data!(feed, 3_000), count, taken)
    end
  end

  defp event(frame) do
    lines = String.split(frame, "\n")

    case for("data: " <> data <- lines, do: Jason.decode!(data)) do
      [data] ->
        assert ContractSchema.errors(data, "FeedEvent") == []
        %{id: Enum.find_value(lines, fn line -> match_id(line) end), data: data}

      [] ->
        nil
    end
  end

  defp match_id("id: " <> id), do: id
  defp match_id(_line), do: nil

  # Nothing but keep-alive lines for a while.
  defp quiet!(feed) do
    feed = receive_data!(feed, 1_000)
    feed = receive_data!(feed, 1_000)
    assert String.contains?(feed.buffer, ": keep-alive")
    assert feed.buffer |> String.split("\n\n", trim: true) |> Enum.all?(&(event(&1) == nil))
  end

  # Only this feed's own messages: another feed may be open beside it.
  defp receive_data!(%{response: response, buffer: buffer} = feed, wait) do
    ref = response.body.ref

    receive do
      {^ref, _part} = message ->
        {:ok, parts} = Req.parse_message(response, message)
        %{feed | buffer: buffer <> Enum.join(for({:data, data} <- parts, do: data))}
    after
      wait -> flunk("no data within #{wait} ms")
    end
  end

  defp assert_done!(%{response: response}) do
    ref = response.body.ref
    assert_receive {^ref, :done}, 3_000
  end

  # A feed open on this machine, as far as the limit counts.
  defp spawn_holder(wallet) do
    test = self()

    pid =
      spawn(fn ->
        Registry.register(KeyfleetWeb.OpenFeeds, wallet, nil)
        send(test, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp wait_until(fun) do
    unless fun.() do
      Process.sleep(10)
      wait_until(fun)
    end
  end

  defp put_feeds(settings) do
    before = Application.fetch_env!(:keyfleet, KeyfleetWeb.FeedController)
    Application.put_env(:keyfleet, KeyfleetWeb.FeedController, Keyword.merge(before, settings))
    on_exit(fn -> Application.put_env(:keyfleet, KeyfleetWeb.FeedController, before) end)
  end

  ## The fleet

  defp signing_agent!(person) do
    {:ok, signer} = Siwa.LocalSigner.new()
    agent = PairingHelpers.pair_wallet!(String.downcase(signer.address), person)
    Keyfleet.Agents.ensure_profile!(%{name: "Feed agent", declared_harness: "test"}, actor: agent)
    {agent, signer}
  end

  defp post!(actor, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp wall!(actor, token_id, body) do
    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: token_id, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp dm!(actor, from, to, body) do
    Dms.send_dm!(
      %{
        fleet_id: @fleet,
        from_token_id: from,
        to_token_id: to,
        body: body,
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{
      human_account_id: :binary.first(character),
      wallet_addresses: [wallet(character)]
    }

  defp epoch!(token_id, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet(owner),
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}/1"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end
end

defmodule KeyfleetWeb.AgentFeedTest do
  # A signed agent opens its live feed on a real connection and hears, the
  # moment it is posted, what is its own to answer in the fleets where it acts
  # as a Key: and never another Key's, a muted Key's, its own, or a room its
  # reader may not read. The feed ends when its sign-in runs out. What it sent
  # after a cursor is also one signed read, which answers what a reconnect
  # replays once it is thirty seconds old.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Keyfleet.FeedHelpers

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Dms
  alias Keyfleet.Feed
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias KeyfleetWeb.Plugs.SignedAgent
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @path "/api/v1/feed"
  @missed "/api/v1/feed/missed"

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

  test "an open feed follows its person choosing another Key to post as", c do
    epoch!(4, "b")
    feed = open!(c, c.signer)

    assert {:ok, _choice} = Keys.choose_posting_key(@fleet, 4, actor: c.me.pairing)
    asked = post!(c.a, "general", "@Key 4 are you there?")

    assert {[%{data: %{"kind" => "mention", "id" => id}}], _feed} = take(feed, 1)
    assert id == asked.id
  end

  test "an open feed follows its agent being put on another Key", c do
    epoch!(4, "b")
    feed = open!(c, c.signer)

    assert {:ok, _assigned} =
             Keys.assign_agent(@fleet, 4, c.me.wallet_address, actor: c.me.pairing)

    asked = post!(c.a, "general", "@Key 4 are you there?")

    assert {[%{data: %{"kind" => "mention", "id" => id}}], _feed} = take(feed, 1)
    assert id == asked.id
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

    # An id that is not one of the feed's says to resync, with the time it was
    # read as its id: a reconnect sending that replays only what came after.
    feed = open!(c, c.signer, [{"last-event-id", "yesterday"}])
    assert {[%{id: read_at, data: %{"kind" => "resync"}}], _feed} = take(feed, 1)
    after_resync = post!(c.a, "general", "After the resync")

    feed = open!(c, c.signer, [{"last-event-id", read_at}])
    assert {[%{data: %{"id" => id}}], feed} = take(feed, 1)
    assert id == after_resync.id
    quiet!(feed)

    for n <- 1..101, do: post!(c.a, "general", "Missed #{n}")
    feed = open!(c, c.signer, [{"last-event-id", last}])
    assert {[%{id: read_at, data: %{"kind" => "resync"}}], _feed} = take(feed, 1)

    feed = open!(c, c.signer, [{"last-event-id", read_at}])
    quiet!(feed)
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

  test "an open feed ends with the sign-in refusal the moment its sign-in runs out", c do
    sign_in_lasts!(c, 300)
    feed = open!(c, c.signer)

    assert {[%{id: nil, data: closed}], feed} = take(feed, 1)
    %{error: %{code: code, message: message, hint: hint}} = SignedAgent.unauthorized()
    assert closed == %{"kind" => "closed", "reason" => code, "message" => message, "hint" => hint}
    assert_done!(feed)
  end

  ## What the feed missed, read once

  # The read answers only events thirty seconds old by the database's clock;
  # the tests make their events older instead of waiting (`age!/0`).

  test "the missed read answers what a reconnect replays, in order, once thirty seconds old", c do
    feed = open!(c, c.signer)
    post!(c.a, "general", "First")
    assert {[%{id: last}], _feed} = take(feed, 1)

    post!(c.a, "general", "Second")
    post!(c.a, "coding", "@Key 2 the third")
    wall!(c.c, 2, "Fourth")
    dm!(human("a"), 1, 2, "Fifth")

    # An id from the open feed is later than the settled moment: nothing yet,
    # and the same cursor back.
    assert missed!(c, c.signer, %{"cursor" => last}) ==
             %{"events" => [], "cursor" => last, "resync" => false}

    age!()
    last = earlier(last)
    feed = open!(c, c.signer, [{"last-event-id", last}])
    assert {replayed, _feed} = take(feed, 4)

    read = missed!(c, c.signer, %{"cursor" => last})
    assert read["events"] == Enum.map(replayed, & &1.data)
    assert micros(read["cursor"]) > micros(List.last(replayed).id)
    refute read["resync"]

    assert %{"events" => [], "resync" => false} =
             missed!(c, c.signer, %{"cursor" => read["cursor"]})

    # An id that is not one of the feed's says to resync.
    assert %{"events" => [], "resync" => true} = missed!(c, c.signer, %{"cursor" => "yesterday"})
  end

  test "with no cursor, or nothing new, the cursor answered is the settled moment", c do
    before = database_clock()
    assert %{"events" => [], "cursor" => from, "resync" => false} = missed!(c, c.signer, %{})
    assert_settled(from, before)

    before = database_clock()

    assert %{"events" => [], "cursor" => cursor, "resync" => false} =
             missed!(c, c.signer, %{"cursor" => earlier(from)})

    assert_settled(cursor, before)
  end

  test "an event younger than thirty seconds waits for the next read", c do
    %{"cursor" => from} = missed!(c, c.signer, %{})
    young = post!(c.a, "general", "Young")

    assert %{"events" => [], "cursor" => cursor, "resync" => false} =
             missed!(c, c.signer, %{"cursor" => from})

    age!()
    assert ids(missed!(c, c.signer, %{"cursor" => earlier(cursor)})) == [young.id]
  end

  test "a message stamped before an event and committed after a read is answered by a later read",
       c do
    {room_post, late, read} = committed_after_read!(c, -1)
    assert ids(read) == [late.id, room_post.id]
    assert missed!(c, c.signer, %{"cursor" => read["cursor"]})["events"] == []
  end

  test "two events in the same microsecond are both answered", c do
    {room_post, late, read} = committed_after_read!(c, 0)
    assert Enum.sort(ids(read)) == Enum.sort([room_post.id, late.id])
    assert missed!(c, c.signer, %{"cursor" => read["cursor"]})["events"] == []
  end

  test "a cursor later than now is no event's id, read once or sent on a reconnect", c do
    for future <- [Feed.id(DateTime.add(database_clock(), 3600)), "253402300799999999"] do
      assert %{"events" => [], "cursor" => cursor, "resync" => true} =
               missed!(c, c.signer, %{"cursor" => future})

      assert micros(cursor) < micros(future)

      feed = open!(c, c.signer, [{"last-event-id", future}])
      assert {[%{id: read_at, data: %{"kind" => "resync"}}], _feed} = take(feed, 1)
      assert micros(read_at) < micros(future)
    end
  end

  test "a cursor is 1 to 20 digits: 21 say to resync, read once or sent on a reconnect", c do
    %{"cursor" => from} = missed!(c, c.signer, %{})
    posted = post!(c.a, "general", "One")
    age!()
    from = earlier(from)

    assert ids(missed!(c, c.signer, %{"cursor" => String.pad_leading(from, 20, "0")})) ==
             [posted.id]

    padded = String.pad_leading(from, 21, "0")
    assert %{"events" => [], "resync" => true} = missed!(c, c.signer, %{"cursor" => padded})

    feed = open!(c, c.signer, [{"last-event-id", padded}])
    assert {[%{data: %{"kind" => "resync"}}], _feed} = take(feed, 1)
  end

  test "the missed read answers up to 100 events, and past 100 says to resync", c do
    %{"cursor" => from} = missed!(c, c.signer, %{})
    [first | rest] = for n <- 0..100, do: post!(c.a, "general", "Missed #{n}")
    age!()

    read = missed!(c, c.signer, %{"cursor" => aged_id(first)})
    assert ids(read) == Enum.map(rest, & &1.id)
    refute read["resync"]

    assert %{"events" => [], "cursor" => settled, "resync" => true} =
             missed!(c, c.signer, %{"cursor" => earlier(from)})

    assert missed!(c, c.signer, %{"cursor" => settled})["events"] == []
  end

  test "the missed read tells an agent only what is its own, and refuses one that may not read",
       c do
    %{"cursor" => cursor} = missed!(c, c.outsider, %{})
    post!(c.a, "general", "In public")
    post!(c.a, "coding", "@Key 2 in the members' room")
    wall!(c.a, 2, "On Key 2's wall")
    dm!(human("a"), 1, 2, "To Key 2")
    age!()

    assert %{"events" => [], "resync" => false} =
             missed!(c, c.outsider, %{"cursor" => earlier(cursor)})

    unsigned = Req.post!(c.site <> @missed, json: %{}, retry: false)
    assert unsigned.status == 401
    assert ContractSchema.response_errors(unsigned.body, "POST", @missed, 401) == []

    {:ok, unpaired} = Siwa.LocalSigner.new()
    refused = read_missed(c, unpaired, %{})
    assert {refused.status, refused.body["error"]["code"]} == {403, "agent_not_paired"}

    for body <- [%{"cursor" => 5}, %{"cursor" => cursor, "after" => cursor}, ["cursor"]] do
      refused = read_missed(c, c.signer, body)
      assert {refused.status, refused.body["error"]["code"]} == {422, "invalid_request"}
    end
  end

  # For every cursor, the read answers exactly the events posted after it,
  # oldest first, and a cursor past them that reads on to none; anything that
  # is no event's id says to resync.
  property "the missed read answers every event after any cursor, in order", c do
    %{"cursor" => from} = missed!(c, c.signer, %{})

    posted =
      for n <- 1..6 do
        if rem(n, 2) == 0,
          do: wall!(c.c, 2, "On the wall #{n}"),
          else: post!(c.a, "general", "#{n}")
      end

    age!()
    ids = Enum.map(posted, & &1.id)
    cursors = [earlier(from) | Enum.map(posted, &aged_id/1)]

    check all(after_n <- integer(0..length(posted)), max_runs: 14) do
      read = missed!(c, c.signer, %{"cursor" => Enum.at(cursors, after_n)})

      assert ids(read) == Enum.drop(ids, after_n)
      assert micros(read["cursor"]) > micros(List.last(cursors))
      assert missed!(c, c.signer, %{"cursor" => read["cursor"]})["events"] == []
    end

    check all(
            cursor <-
              one_of([
                string(:printable, max_length: 24),
                string(?0..?9, min_length: 21, max_length: 40)
              ]),
            not String.match?(cursor, ~r/\A[0-9]{1,20}\z/),
            max_runs: 20
          ) do
      assert %{"events" => [], "resync" => true} = missed!(c, c.signer, %{"cursor" => cursor})
    end
  end

  # A room post, a read right after it, then a direct message written
  # `offset` microseconds from the room post but committed after that read:
  # posts in different rooms, walls and conversations take no common lock,
  # and an id is when a post was written, not committed. Then the read that
  # follows on from the first's cursor.
  defp committed_after_read!(c, offset) do
    %{"cursor" => from} = missed!(c, c.signer, %{})
    room_post = post!(c.a, "general", "Committed first")
    %{"cursor" => cursor} = missed!(c, c.signer, %{"cursor" => from})

    late = dm!(human("a"), 1, 2, "Committed after the read")
    backdate_dm!(late.id, DateTime.add(room_post.inserted_at, offset, :microsecond))
    age!()
    {room_post, late, missed!(c, c.signer, %{"cursor" => earlier(cursor)})}
  end

  defp backdate_dm!(id, at) do
    %{num_rows: 1} =
      Repo.query!("UPDATE keyfleet_app.dm_messages SET inserted_at = $1 WHERE id = $2", [
        DateTime.to_naive(at),
        Ecto.UUID.dump!(id)
      ])
  end

  # `cursor` is the database's now, read between `before` and this check,
  # less the settling time.
  defp assert_settled(cursor, before) do
    settled = fn at -> at |> DateTime.add(-Feed.settling_seconds()) |> Feed.id() |> micros() end
    assert micros(cursor) >= settled.(before)
    assert micros(cursor) <= settled.(database_clock())
  end

  defp ids(read), do: Enum.map(read["events"], & &1["id"])

  defp micros(id), do: String.to_integer(id)

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

  defp missed!(c, signer, body) do
    read = read_missed(c, signer, body)
    assert read.status == 200
    read.body
  end

  # The missed read as the agent signs and sends it, its answer checked
  # against the contract.
  defp read_missed(c, signer, body) do
    request =
      SignedAgentHelpers.sign(
        signer,
        c.secret,
        Siwa.Contract.authority(c.site),
        "POST",
        @missed,
        Jason.encode!(body)
      )

    response =
      Req.post!(c.site <> @missed,
        headers: Map.to_list(request.headers),
        body: request.body,
        retry: false
      )

    assert ContractSchema.response_errors(response.body, "POST", @missed, response.status) == []
    response
  end

  # From here on the sign-in server grants each signed request a sign-in that
  # runs out `ms` after it answers. Setup's sign-in server comes back after
  # the test.
  defp sign_in_lasts!(c, ms) do
    broker =
      SignedAgentHelpers.serve!(:short_sign_in, fn conn, _opts ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        {200, verdict} = SignedAgentHelpers.verdict(Jason.decode!(raw), c.secret)
        ends = DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(put_in(verdict.data.receiptExpiresAt, ends)))
      end)

    Application.put_env(:keyfleet, :siwa_broker_url, broker)
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

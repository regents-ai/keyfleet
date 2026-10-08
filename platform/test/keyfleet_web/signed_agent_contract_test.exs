defmodule KeyfleetWeb.SignedAgentContractTest do
  @moduledoc """
  Holds every signed agent route to the served contract: the bodies it
  admits, and the answers it really gives.
  """
  use ExUnit.Case, async: false
  import KeyfleetWeb.RefusalHelpers
  import Plug.Conn

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ChainViews
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Rooms
  alias KeyfleetWeb.Plugs.SignedAgent

  @contract Path.expand("../../contracts/api-contract.openapiv3.yaml", __DIR__)
  # A field the signed-request check admits has to be spelled in its source.
  @plug_source Path.expand("../../lib/keyfleet_web/plugs/signed_agent.ex", __DIR__)
  @external_resource @plug_source

  @fleet "fibonacci_syndicate"
  @owner "0x" <> String.duplicate("a", 40)

  @join "/api/v1/agent/join/status"
  @update "/api/v1/agent/profile/update"
  @shards "/api/v1/agent/shards"
  @avatar_start "/api/v1/agent/avatar/start"
  @avatar_remove "/api/v1/agent/avatar/remove"
  @mutes "/api/v1/agent/fleets/{fleet_id}/mutes"
  @mute "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/mute"
  @unmute "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/unmute"
  @rooms "/api/v1/agent/fleets/{fleet_id}/rooms"
  @create "/api/v1/agent/fleets/{fleet_id}/rooms/create"
  @topic "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/topic"
  @read "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/read"
  @send "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/send"
  @sync "/api/v1/agent/fleets/{fleet_id}/sync"
  @key_read "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/read"
  @key_send "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/send"
  @graph "/api/v1/agent/fleets/{fleet_id}/graph/"
  @proposal "/api/v1/agent/fleets/{fleet_id}/proposals/read"
  @presence "/api/v1/agent/fleets/{fleet_id}/presence"
  @propose "/api/v1/agent/fleets/{fleet_id}/proposals/create"
  @vote "/api/v1/agent/fleets/{fleet_id}/proposals/vote"
  @cancel "/api/v1/agent/fleets/{fleet_id}/proposals/cancel"
  @carry_out "/api/v1/agent/fleets/{fleet_id}/proposals/carry_out"
  @split "/api/v1/agent/fleets/{fleet_id}/split"
  @claim "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/claim"
  @code_password "/api/v1/agent/fleets/{fleet_id}/code/password"
  @polls "/api/v1/agent/fleets/{fleet_id}/polls"
  @poll_start "/api/v1/agent/fleets/{fleet_id}/polls/start"
  @poll "/api/v1/agent/fleets/{fleet_id}/polls/{poll_id}"
  @poll_vote "/api/v1/agent/fleets/{fleet_id}/polls/{poll_id}/vote"
  @poll_end "/api/v1/agent/fleets/{fleet_id}/polls/{poll_id}/end"
  @dm_inbox "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms"
  @dm_blocks "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/blocks"
  @dm "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/{other_token_id}/"
  @dm_changes "/api/v1/agent/fleets/{fleet_id}/dms/changes"

  @address %{
    "fleet_id" => @fleet,
    "token_id" => "1",
    "other_token_id" => "2",
    "slug" => "general",
    "poll_id" => "00000000-0000-4000-8000-000000000000"
  }
  @poll_question %{
    "question" => "Which door next?",
    "choices" => ["Left door", "Right door"],
    "minutes" => 30,
    "notes" => "The left one creaks."
  }
  @picture %{
    "sha256" => String.duplicate("a", 64),
    "byte_size" => 100,
    "content_type" => "image/png"
  }

  # One valid value for every field each body documents, at each object the
  # body holds: the top of the body, or a place inside it. `{:one_of, n}` picks
  # the nth of the shapes a place may take.
  @bodies [
    {"POST", @join, [], %{"name" => "Probe", "declared_harness" => "local"}},
    {"POST", @update, [],
     %{
       "name" => "Probe",
       "declared_harness" => "local",
       "proficiencies" => ["research"],
       "interests" => ["chips"],
       "service_ideas" => ["briefs"],
       "current_status" => "probing"
     }},
    {"GET", @shards, [], %{}},
    {"POST", @avatar_start, [], @picture},
    {"POST", @avatar_remove, [], %{}},
    {"GET", @mutes, [], %{}},
    {"POST", @mute, [], %{}},
    {"POST", @unmute, [], %{}},
    {"GET", @rooms, [], %{}},
    {"POST", @create, [], %{"slug" => "probe-room", "name" => "Probe"}},
    {"POST", @topic, [], %{"topic" => "Probe"}},
    {"POST", @read, [], %{"after_seq" => 0, "limit" => 1}},
    {"POST", @send, [], %{"body" => "probe", "idempotency_key" => "p-1", "reply_to_id" => nil}},
    {"POST", @key_read, [], %{"after_seq" => 0, "limit" => 1}},
    {"POST", @key_send, [],
     %{"body" => "probe", "idempotency_key" => "p-1", "reply_to_id" => nil}},
    {"POST", @sync, [],
     %{
       "rooms" => [%{"slug" => "general", "after_seq" => 0}],
       "graph" => %{"after_seq" => 0},
       "proposals" => %{"after_seq" => 0},
       "dms" => %{"after_seq" => 0},
       "run" => %{"kind" => "session"}
     }},
    {"POST", @sync, ["rooms", 0], %{"slug" => "general", "after_seq" => 0}},
    {"POST", @sync, ["run", {:one_of, 0}], %{"kind" => "session"}},
    {"POST", @sync, ["run", {:one_of, 1}], %{"kind" => "scheduled", "every_minutes" => 60}},
    {"POST", @sync, ["graph"], %{"after_seq" => 0}},
    {"POST", @sync, ["proposals"], %{"after_seq" => 0}},
    {"POST", @sync, ["dms"], %{"after_seq" => 0}},
    {"POST", @proposal, [], %{"number" => 1, "votes_after_seq" => 0}},
    {"POST", @presence, [], %{}},
    {"POST", @propose, [],
     %{
       "kind" => "launch",
       "key" => "2",
       "text" => "Launch the fleet's token",
       "asset" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
       "share" => "1",
       "recipient" => "0x" <> String.duplicate("a", 40),
       "rate" => "1",
       "target" => "1",
       "restricted" => "true",
       "signature" => "approve",
       "hash" => String.duplicate("a", 64),
       "name" => "Probe",
       "symbol" => "PRB",
       "description" => "A probe",
       "website" => "https://example.com",
       "image" => "https://example.com/probe.png"
     }},
    {"POST", @vote, [], %{"number" => 1, "choice" => "yes"}},
    {"POST", @cancel, [], %{"number" => 1}},
    {"POST", @carry_out, [], %{"number" => 1}},
    {"POST", @split, [], %{}},
    {"POST", @claim, [], %{}},
    {"POST", @code_password, [], %{}},
    {"GET", @dm_inbox, [], %{}},
    {"GET", @dm_blocks, [], %{}},
    {"POST", @dm <> "read", [], %{"after_seq" => 0, "limit" => 1}},
    {"POST", @dm <> "send", [],
     %{
       "body" => "probe",
       "idempotency_key" => "p-1",
       "parts" => [%{"kind" => "text", "text" => "more"}]
     }},
    {"POST", @dm <> "auto_delete", [], %{"days" => 7}},
    {"POST", @dm <> "delete", [], %{}},
    {"POST", @dm <> "block", [], %{}},
    {"POST", @dm <> "unblock", [], %{}},
    {"POST", @dm_changes, [], %{"after_seq" => 0}},
    {"POST", @graph <> "get", [], %{"id" => "goal#1"}},
    {"POST", @graph <> "changes", [], %{"after_seq" => 0, "limit" => 1}},
    {"POST", @graph <> "create", [],
     %{
       "as_key" => 1,
       "command_id" => "c-1",
       "type" => "goal",
       "scope" => "fleet",
       "data" => %{}
     }},
    {"POST", @graph <> "patch", [],
     %{
       "as_key" => 1,
       "command_id" => "c-1",
       "id" => "goal#1",
       "expected_version" => 1,
       "set" => %{},
       "unset" => ["x"],
       "reason" => "r",
       "evidence" => ["evidence#1"]
     }},
    {"POST", @graph <> "link", [],
     %{
       "as_key" => 1,
       "command_id" => "c-1",
       "source" => "task#1",
       "target" => "goal#1",
       "type" => "implements",
       "note" => "n"
     }},
    {"POST", @graph <> "unlink", [],
     %{"as_key" => 1, "command_id" => "c-1", "relation_id" => "rel_1"}},
    {"POST", @graph <> "archive", [],
     %{
       "as_key" => 1,
       "command_id" => "c-1",
       "id" => "goal#1",
       "expected_version" => 1,
       "reason" => "r"
     }},
    {"GET", @polls, [], %{}},
    {"POST", @poll_start, [], @poll_question},
    {"GET", @poll, [], %{}},
    {"POST", @poll_vote, [], %{"choice" => "Left door", "reason" => "r"}},
    {"POST", @poll_end, [], %{}}
  ]

  # Where each body's fields go once admitted, less the ones its address supplies.
  @actions [
             {@update, Keyfleet.Agents.AgentProfile, :edit_my_profile},
             {@create, Keyfleet.Rooms.Room, :create},
             {@topic, Keyfleet.Rooms.Room, :set_topic},
             {@read, Keyfleet.Rooms.Message, :read_messages},
             {@send, Keyfleet.Rooms.Message, :send_message},
             {@key_read, Keyfleet.Rooms.Message, :read_key_thread},
             {@key_send, Keyfleet.Rooms.Message, :send_to_key},
             {@poll_start, Keyfleet.Polls.Poll, :start},
             {@poll_vote, Keyfleet.Polls.Vote, :cast},
             {@dm <> "read", Keyfleet.Dms.Message, :in_conversation}
           ] ++
             for(
               op <- ~w(get changes create patch link unlink archive),
               do: {@graph <> op, Keyfleet.Graph.Workspace, String.to_atom(op)}
             )

  setup do
    # Syncs read the workspace in a repeatable-read snapshot, which Postgres
    # allows inside the sandbox only when its transaction is at that level already.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    # The site's server reads the test's chain.
    ChainViews.share!()
    {:ok, signer} = Siwa.LocalSigner.new()
    record_owner(1, @owner)
    record_owner(2, signer.address)

    secret = :crypto.strong_rand_bytes(32)
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)
    budget = Application.fetch_env!(:keyfleet, :api_rate_limit)
    on_exit(fn -> Application.put_env(:keyfleet, :api_rate_limit, budget) end)
    broker = server(:broker, &broker(&1, &2, secret))
    Application.put_env(:keyfleet, :siwa_broker_url, broker)
    app = server(:product, &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2)))
    %{app: app, signer: signer, secret: secret}
  end

  # The body check is asked directly: every route answers a body that doesn't
  # fit with the same refusal, which the last test sends over HTTP.
  test "each signed route admits exactly the body fields its contract documents" do
    contract = YamlElixir.read_from_file!(@contract)
    words = candidate_fields(contract)

    for {method, template, at, sample} <- @bodies do
      schema = request_schema(contract, method, template, at)
      documented = Map.keys(Map.get(schema, "properties", %{}))
      required = Map.get(schema, "required", [])
      where = "#{method} #{template} #{inspect(at)}"

      assert Enum.sort(Map.keys(sample)) == Enum.sort(documented), where
      minimal = Map.take(sample, required)
      fits? = map_size(minimal) >= Map.get(schema, "minProperties", 0)
      assert admitted?(contract, method, template, at, minimal) == fits?, where

      for field <- documented -- required do
        assert admitted?(contract, method, template, at, Map.put(minimal, field, sample[field])),
               "#{where} refuses its documented #{field}"
      end

      for field <- required do
        refute admitted?(contract, method, template, at, Map.delete(minimal, field)),
               "#{where} admits a body without its required #{field}"
      end

      admitted =
        for word <- words -- documented,
            value <- [1, "x", %{"x" => 1}, ["x"]],
            admitted?(contract, method, template, at, Map.put(minimal, word, value)),
            uniq: true,
            do: word

      assert admitted == [], "#{where} admits undocumented #{inspect(admitted)}"

      if at == [] do
        refute admitted?(contract, method, template, at, Map.put(minimal, "unlisted", 1))

        assert told_fields(template) ==
                 Enum.sort(documented),
               "#{where} names other fields when it refuses a body"
      end
    end
  end

  test "each documented body field is one its action takes" do
    contract = YamlElixir.read_from_file!(@contract)

    for {template, resource, name} <- @actions do
      action = Ash.Resource.Info.action(resource, name)

      takes =
        Enum.map(action.arguments, &to_string(&1.name)) ++
          Enum.map(Map.get(action, :accept, []), &to_string/1)

      addressed = Regex.scan(~r/\{(\w+)\}/, template, capture: :all_but_first) |> List.flatten()
      documented = Map.keys(request_schema(contract, "POST", template, [])["properties"])

      assert Enum.sort(documented) == Enum.sort(takes -- addressed), template
    end

    # Joining names a new profile and its harness; everything else is set later.
    joining = Map.keys(request_schema(contract, "POST", @join, [])["properties"])
    ensure = Ash.Resource.Info.action(Keyfleet.Agents.AgentProfile, :ensure_profile)
    assert joining -- Enum.map(ensure.accept, &to_string/1) == []
  end

  test "a reply names its post only by its id as the API gives it" do
    contract = YamlElixir.read_from_file!(@contract)
    id = Ecto.UUID.generate()
    reply = &%{"body" => "Seen", "idempotency_key" => "r-1", "reply_to_id" => &1}

    assert admitted?(contract, "POST", @send, [], reply.(id))
    assert ContractSchema.errors(reply.(id), "RoomSendRequest") == []

    # The same post in capitals, without its hyphens, in braces, and as any
    # sixteen bytes, which is how a post id is stored.
    for other <- [String.upcase(id), String.replace(id, "-", ""), "{#{id}}", "abcdefghijklmnop"] do
      refute admitted?(contract, "POST", @send, [], reply.(other)), inspect(other)
      assert ContractSchema.errors(reply.(other), "RoomSendRequest") != [], inspect(other)
    end
  end

  test "every answer a signed route gives fits the contract, and every documented answer is given",
       c do
    stranger = new_signer()
    one = Map.put(@address, "token_id", "1")
    own = Map.put(@address, "token_id", "2")

    # Before the agent has a profile.
    answer(c, c.signer, "POST", @update, @address, %{"current_status" => "early"}, 404)
    answer(c, c.signer, "POST", @avatar_start, @address, @picture, 404)
    answer(c, c.signer, "POST", @avatar_remove, @address, %{}, 404)

    # Joining and editing.
    joining = %{"name" => "Probe", "declared_harness" => "local"}
    answer(c, c.signer, "POST", @join, @address, %{joining | "name" => ""}, 422)
    answer(c, c.signer, "POST", @join, @address, joining, 200)
    answer(c, c.signer, "POST", @update, @address, %{"current_status" => "Surveying"}, 200)
    answer(c, c.signer, "POST", @update, @address, %{"name" => String.duplicate("n", 121)}, 422)
    answer(c, stranger, "POST", @join, @address, %{joining | "name" => "Stranger"}, 200)

    # A picture: started, too large to start, and removed.
    assert %{"method" => "PUT", "content_type" => "image/png"} =
             answer(c, c.signer, "POST", @avatar_start, @address, @picture, 200).body

    answer(
      c,
      c.signer,
      "POST",
      @avatar_start,
      @address,
      %{@picture | "byte_size" => 524_289},
      422
    )

    assert answer(c, c.signer, "POST", @avatar_remove, @address, %{}, 200).body ==
             %{"avatar_url" => nil}

    # Shards: none, with how to get one, then the one key 1's owner issued,
    # with the transaction that ends it.
    holder = new_signer()

    assert %{"shards" => [], "hint" => "Ask a Key's owner to issue a shard to your wallet" <> _} =
             answer(c, holder, "GET", @shards, @address, %{}, 200).body

    ChainHelpers.issue_shard!(@fleet, 1, holder.address)

    assert %{
             "shards" => [
               %{"fleet_id" => @fleet, "token_id" => 1, "edits_restricted" => false} = shard
             ],
             "hint" => nil
           } = answer(c, holder, "GET", @shards, @address, %{}, 200).body

    assert shard["step_down"]["to"] == shard["shards_contract"]

    assert shard["step_down"]["data"] ==
             RegentChain.Call.encode("end(uint256[],address)", [
               [ChainHelpers.onchain_id(@fleet, 1)],
               holder.address
             ])

    # Posting: new, repeated, conflicting, misplaced, empty, nowhere, and by an outsider.
    human = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}

    {:ok, by_person} =
      Rooms.send_message(
        %{fleet_id: @fleet, slug: "general", body: "From the owner", idempotency_key: "h-1"},
        actor: human
      )

    post = %{"body" => "Hull survey started", "idempotency_key" => "k-1"}
    first = answer(c, c.signer, "POST", @send, @address, post, 201).body["message"]

    assert answer(c, c.signer, "POST", @send, @address, post, 200).body["message"]["id"] ==
             first["id"]

    assert answer(c, c.signer, "POST", @send, @address, %{post | "body" => "Changed"}, 422).body ==
             refused("idempotency_conflict")

    reply = %{"body" => "Seen", "idempotency_key" => "k-2", "reply_to_id" => by_person.id}

    assert answer(c, c.signer, "POST", @send, @address, reply, 201).body["message"]["reply_to_id"] ==
             by_person.id

    elsewhere = %{
      "body" => "Seen",
      "idempotency_key" => "k-3",
      "reply_to_id" => Ecto.UUID.generate()
    }

    assert answer(c, c.signer, "POST", @send, @address, elsewhere, 422).body["error"]["code"] ==
             "reply_not_here"

    assert answer(c, c.signer, "POST", @send, @address, %{post | "body" => ""}, 422).body["error"][
             "code"
           ] ==
             "invalid_message"

    answer(c, c.signer, "POST", @send, Map.put(@address, "slug", "hull-survey"), post, 404)
    answer(c, stranger, "POST", @send, @address, %{post | "idempotency_key" => "s-1"}, 403)

    # Reading rooms.
    answer(c, c.signer, "GET", @rooms, @address, %{}, 200)
    read = answer(c, c.signer, "POST", @read, @address, %{}, 200).body["messages"]
    assert Enum.map(read, & &1["author_kind"]) == ["human", "agent", "agent"]
    answer(c, c.signer, "POST", @read, Map.put(@address, "slug", "hull-survey"), %{}, 404)
    answer(c, c.signer, "POST", @read, @address, %{"limit" => 201}, 422)

    # Muting key 1 hides its owner's post from this agent alone; the cursor
    # still passes it. Muting twice keeps one mute, and unmuting shows it again.
    assert answer(c, c.signer, "GET", @mutes, @address, %{}, 200).body["mutes"] == []
    assert [%{"token_id" => 1}] = answer(c, c.signer, "POST", @mute, one, %{}, 200).body["mutes"]
    assert [%{"token_id" => 1}] = answer(c, c.signer, "POST", @mute, one, %{}, 200).body["mutes"]
    muted = answer(c, c.signer, "POST", @read, @address, %{}, 200).body
    assert Enum.map(muted["messages"], & &1["author_kind"]) == ["agent", "agent"]
    assert muted["cursor"] == List.last(muted["messages"])["seq"]
    assert length(answer(c, stranger, "POST", @read, @address, %{}, 200).body["messages"]) == 3
    answer(c, stranger, "POST", @read, %{@address | "slug" => "coding"}, %{}, 403)
    assert answer(c, c.signer, "POST", @unmute, one, %{}, 200).body["mutes"] == []
    assert answer(c, c.signer, "POST", @unmute, one, %{}, 200).body["mutes"] == []
    assert length(answer(c, c.signer, "POST", @read, @address, %{}, 200).body["messages"]) == 3

    # A key's thread: read before its first post, written to, repeated,
    # conflicting, misplaced, for a key not sold, and by an outsider.
    {:ok, minted} = Keyfleet.Chain.minted(@fleet)
    unsold = Map.put(@address, "token_id", Integer.to_string(minted + 1))
    # A send key is the agent's across the fleet, so the thread's posts take new ones.
    thread_post = %{post | "idempotency_key" => "t-1"}

    assert answer(c, c.signer, "POST", @key_read, own, %{}, 200).body ==
             %{
               "thread" => %{"token_id" => 2, "head_seq" => 0},
               "cursor" => 0,
               "has_more" => false,
               "messages" => []
             }

    opening = answer(c, c.signer, "POST", @key_send, own, thread_post, 201).body["message"]
    assert opening["as_key"] == 2

    assert answer(c, c.signer, "POST", @key_send, own, thread_post, 200).body["message"]["id"] ==
             opening["id"]

    answer(c, c.signer, "POST", @key_send, own, %{thread_post | "body" => "Changed"}, 422)
    answer(c, c.signer, "POST", @key_send, own, %{reply | "idempotency_key" => "k-5"}, 422)

    answer(
      c,
      c.signer,
      "POST",
      @key_send,
      unsold,
      %{thread_post | "idempotency_key" => "t-2"},
      404
    )

    answer(c, stranger, "POST", @key_send, own, %{thread_post | "idempotency_key" => "s-2"}, 403)
    answer(c, c.signer, "POST", @key_read, unsold, %{}, 404)
    answer(c, c.signer, "POST", @key_read, own, %{"after_seq" => -1}, 422)

    assert [%{"id" => opening_id}] =
             answer(c, c.signer, "POST", @key_read, own, %{}, 200).body["messages"]

    assert opening_id == opening["id"]

    # Catching up.
    general = %{"slug" => "general", "after_seq" => 0}

    sync = fn signer, address, rooms, status ->
      body = %{
        "rooms" => rooms,
        "graph" => %{"after_seq" => 0},
        "proposals" => %{"after_seq" => 0},
        "run" => %{"kind" => "session"}
      }

      answer(c, signer, "POST", @sync, address, body, status)
    end

    sync.(c.signer, @address, [general, %{general | "slug" => "coding"}], 200)
    sync.(c.signer, @address, [%{general | "slug" => "hull-survey"}], 404)
    sync.(c.signer, @address, [%{general | "after_seq" => -1}], 422)
    sync.(c.signer, @address, [general, general], 422)
    # A sync reads the workspace, which only a Key or a shard of one may.
    sync.(stranger, @address, [general], 403)

    # Reading a proposal: recorded, not yet made, and no proposal at all.
    ProposalHelpers.proposal!(@fleet, 1)
    ProposalHelpers.vote!(@fleet, 1, @owner, :no, [1])
    proposal = %{"number" => 1, "votes_after_seq" => 0}

    assert %{"status" => "open", "no_votes" => 1} =
             answer(c, c.signer, "POST", @proposal, @address, proposal, 200).body["proposal"]

    answer(c, c.signer, "POST", @proposal, @address, %{proposal | "number" => 99}, 404)
    answer(c, c.signer, "POST", @proposal, @address, %{proposal | "number" => 0}, 422)

    # Acting on chain: each route builds what the agent's own wallet sends,
    # from the chain read at its latest block, and sends nothing itself.
    chain_routes(c, own, unsold)

    # Asking the fleet's Keys one question.
    poll_routes(c, stranger)

    # Creating rooms: new, taken, a name taken, malformed, by an outsider, and
    # past the limit.
    room = %{"slug" => "survey-plans", "name" => "Survey plans"}

    assert answer(c, c.signer, "POST", @create, @address, room, 201).body ==
             %{
               "room" => %{
                 "slug" => "survey-plans",
                 "name" => "Survey plans",
                 "kind" => "created",
                 "public" => false,
                 "topic" => nil,
                 "topic_set_by" => nil,
                 "topic_set_at" => nil,
                 "head_seq" => 0
               }
             }

    assert answer(c, c.signer, "POST", @create, @address, room, 409).body ==
             refused("room_taken")

    assert answer(c, c.signer, "POST", @create, @address, %{room | "slug" => "plans"}, 409).body ==
             refused("name_taken")

    answer(c, c.signer, "POST", @create, @address, %{room | "slug" => "Survey"}, 422)
    answer(c, stranger, "POST", @create, @address, %{room | "slug" => "outsiders"}, 403)

    # Who may create a room is shown above; these only fill the fleet.
    for n <- 2..100 do
      Rooms.create_room!(%{fleet_id: @fleet, slug: "made-#{n}", name: "Made #{n}"},
        authorize?: false
      )
    end

    assert answer(c, c.signer, "POST", @create, @address, %{room | "slug" => "one-more"}, 409).body ==
             refused("room_limit_reached")

    # Naming an open room: named, by an outsider, somewhere else, refused, a
    # name taken, and renamed too soon.
    open = Map.put(@address, "slug", "open-1")
    named = answer(c, c.signer, "POST", @topic, open, %{"topic" => "Hull survey"}, 200)

    assert %{"kind" => "open", "topic" => "Hull survey", "head_seq" => 1} = named.body["room"]
    assert named.body["room"]["topic_set_by"] == c.signer.address

    answer(c, stranger, "POST", @topic, open, %{"topic" => "Mine"}, 403)
    answer(c, c.signer, "POST", @topic, Map.put(open, "slug", "open-6"), %{"topic" => "x"}, 404)

    assert answer(c, c.signer, "POST", @topic, open, %{"topic" => ""}, 422).body ==
             refused("invalid_topic")

    assert answer(c, c.signer, "POST", @topic, @address, %{"topic" => "Mine"}, 422).body ==
             refused("room_not_open")

    other_open = Map.put(@address, "slug", "open-2")

    assert answer(c, c.signer, "POST", @topic, other_open, %{"topic" => "General"}, 409).body ==
             refused("name_taken")

    too_soon = answer(c, c.signer, "POST", @topic, open, %{"topic" => "Dry dock"}, 429)
    assert too_soon.body == refused("rename_too_soon")
    assert [_seconds] = Req.Response.get_header(too_soon, "retry-after")

    dm_routes(c, stranger)

    # The fleet's code opens only to a wallet holding one of its Keys.
    assert %{"username" => "agent", "password" => _password} =
             answer(c, c.signer, "POST", @code_password, @address, %{}, 200).body

    assert answer(c, stranger, "POST", @code_password, @address, %{}, 403).body ==
             refused("code_not_holder")

    # A fleet outside the catalog is not found on every route that names one,
    # with the answer the workspace gives.
    nowhere = Map.put(@address, "fleet_id", "hull_survey")

    for {method, template, [], body} <- @bodies, String.contains?(template, "{fleet_id}") do
      assert answer(c, c.signer, method, template, nowhere, body, 404).body["error"]["code"] ==
               "fleet_unknown",
             "#{method} #{template}"
    end

    # While key ownership is being read again, nothing that needs a key is done.
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    answer(c, c.signer, "POST", @send, @address, %{post | "idempotency_key" => "k-4"}, 503)
    answer(c, c.signer, "POST", @key_send, own, %{post | "idempotency_key" => "k-7"}, 503)
    answer(c, c.signer, "POST", @create, @address, %{room | "slug" => "late"}, 503)
    answer(c, c.signer, "POST", @topic, open, %{"topic" => "Late"}, 503)
    answer(c, c.signer, "POST", @poll_start, @address, @poll_question, 503)

    assert answer(c, c.signer, "POST", @code_password, @address, %{}, 503).body ==
             refused("code_catching_up")

    # Every route: unsigned, too large, signed with a body that fits none of
    # them, and with the sign-in check away.
    for {method, template} <- routes() do
      answer_raw(c, method, template, "{}", 401)
      answer_raw(c, method, template, String.duplicate(" ", body_cap(template) + 1), 413)
      misfit = answer(c, c.signer, method, template, @address, %{"not_a_field" => 1}, 422)
      assert misfit.body["error"]["hint"] == SignedAgent.takes(fill(template, @address))
    end

    Application.put_env(:keyfleet, :siwa_broker_url, nil)

    for {method, template} <- routes(),
        do: answer(c, c.signer, method, template, @address, empty_or_minimal(template), 503)

    # Every route past the client's budget: one request an hour, spent first
    # on the health check.
    Application.put_env(:keyfleet, :api_rate_limit, limit: 1, window_seconds: 3600)
    Req.get!(c.app <> "/healthz", retry: false)

    for {method, template} <- routes() do
      too_many = answer_raw(c, method, template, "{}", 429)
      assert too_many.body["error"]["code"] == "too_many_requests"
      assert [_seconds] = Req.Response.get_header(too_many, "retry-after")
    end

    answered =
      Enum.filter(answered(), fn {method, template, _status} ->
        {method, template} in routes()
      end)

    documented = documented_answers()
    assert documented -- answered == []
    assert answered -- documented == []
  end

  # The agent writes as key 2, which it holds, to key 1: a conversation
  # opened, read, set to delete itself, blocked and unblocked, caught up on
  # and deleted. The Key after the last one sold is not sold. Someone holding
  # no Key is refused each time.
  defp dm_routes(c, stranger) do
    own = Map.merge(@address, %{"token_id" => "2", "other_token_id" => "1"})
    itself = Map.put(own, "other_token_id", "2")
    {:ok, minted} = Keyfleet.Chain.minted(@fleet)
    unsold = Map.put(own, "other_token_id", Integer.to_string(minted + 1))
    dm = %{"body" => "Hull survey notes", "idempotency_key" => "dm-1"}

    assert %{"conversation" => nil, "messages" => [], "has_more" => false} =
             answer(c, c.signer, "POST", @dm <> "read", own, %{}, 200).body

    first = answer(c, c.signer, "POST", @dm <> "send", own, dm, 201).body["message"]

    assert answer(c, c.signer, "POST", @dm <> "send", own, dm, 200).body["message"]["id"] ==
             first["id"]

    assert answer(c, c.signer, "POST", @dm <> "send", own, %{dm | "body" => "Changed"}, 422).body ==
             refused("idempotency_conflict")

    another = %{dm | "idempotency_key" => "dm-2"}

    assert answer(c, c.signer, "POST", @dm <> "send", itself, another, 422).body ==
             refused("same_key")

    assert %{"code" => "key_unknown", "message" => "Key " <> _} =
             answer(c, c.signer, "POST", @dm <> "send", unsold, another, 404).body["error"]

    assert %{"messages" => [%{"id" => id}], "has_more" => false} =
             answer(c, c.signer, "POST", @dm <> "read", own, %{}, 200).body

    assert id == first["id"]
    answer(c, c.signer, "POST", @dm <> "read", own, %{"limit" => 201}, 422)

    assert [%{"other_token_id" => 1}] =
             answer(c, c.signer, "GET", @dm_inbox, own, %{}, 200).body["conversations"]

    answer(c, c.signer, "POST", @dm <> "auto_delete", own, %{"days" => 7}, 200)
    answer(c, c.signer, "POST", @dm <> "auto_delete", own, %{"days" => 2}, 422)
    assert answer(c, c.signer, "POST", @dm <> "block", own, %{}, 200).body == %{"blocked" => [1]}
    assert answer(c, c.signer, "GET", @dm_blocks, own, %{}, 200).body == %{"blocked" => [1]}
    assert answer(c, c.signer, "POST", @dm <> "unblock", own, %{}, 200).body == %{"blocked" => []}

    assert answer(c, c.signer, "POST", @dm <> "block", itself, %{}, 422).body ==
             refused("same_key")

    assert [%{"id" => ^id}] =
             answer(c, c.signer, "POST", @dm_changes, own, %{"after_seq" => 0}, 200).body[
               "messages"
             ]

    answer(c, c.signer, "POST", @dm_changes, own, %{"after_seq" => -1}, 422)
    answer(c, c.signer, "POST", @dm <> "delete", own, %{}, 200)

    assert answer(c, c.signer, "POST", @dm <> "delete", own, %{}, 404).body ==
             refused("conversation_unknown")

    for {method, template} <- routes(), String.contains?(template, "/dms") do
      body = if template == @dm <> "send", do: another, else: empty_or_minimal(template)

      assert answer(c, stranger, method, template, own, body, 403).body == refused("not_your_key"),
             "#{method} #{template}"
    end
  end

  # The agent holds key 2 and proposal 1 is recorded, open on the chain. A
  # fleet whose contracts aren't recorded yet has nothing to build.
  defp chain_routes(c, own, unsold) do
    fleet = Fleets.get_fleet!(@fleet)
    wallet = String.downcase(c.signer.address)
    usdc = fleet.usdc_address
    key = ChainHelpers.onchain_id(@fleet, 2)
    owner = {fleet.keys_address, "ownerOf(uint256)", [key], {"address", [wallet]}}
    uint = &{&1, &2, &3, {"uint256", [&4]}}
    status = {fleet.votes_address, "status(uint256)", [1], {"uint8", [0]}}
    offchain = Map.put(@address, "fleet_id", "fleet_tech_classic")
    words = %{"kind" => "decision", "key" => "2", "text" => "Survey the hull"}

    for {template, body} <- [
          {@presence, %{}},
          {@propose, words},
          {@vote, %{"number" => 1, "choice" => "yes"}},
          {@cancel, %{"number" => 1}},
          {@carry_out, %{"number" => 1}},
          {@split, %{}},
          {@claim, %{}}
        ] do
      assert answer(c, c.signer, "POST", template, offchain, body, 409).body ==
               refused("fleet_not_on_chain")
    end

    # Key 2 is old enough to take part and isn't present.
    matures = {fleet.votes_address, "maturesAt(uint256)", [key], {"uint64", [1]}}

    ChainViews.put!([
      owner,
      matures,
      {fleet.votes_address, "isActive(uint256)", [key], {"bool", [false]}},
      {fleet.votes_address, "presentFrom(uint256)", [key], {"uint64", [0]}},
      {fleet.votes_address, "sweepExpired(uint256)", [0], {"uint256,bool", [0, false]}}
    ])

    assert %{"keys" => [%{"token_id" => 2, "present_until" => nil}], "transactions" => sent} =
             answer(c, c.signer, "POST", @presence, @address, %{}, 200).body

    assert Enum.map(sent, &{&1["name"], &1["blocked"]}) == [{"present", nil}, {"sweep", nil}]

    ChainViews.put!([owner, {fleet.votes_address, "isActive(uint256)", [key], :revert}])

    assert answer(c, c.signer, "POST", @presence, @address, %{}, 503).body ==
             refused("chain_unavailable")

    # Proposing keeps the words before the wallet sends anything.
    ChainViews.put!([owner, matures, uint.(fleet.votes_address, "treasuryOpensAt()", [], 1)])
    made = answer(c, c.signer, "POST", @propose, @address, words, 200).body
    assert made["content_hash"] == Keyfleet.WalletSteps.VoteSteps.content_hash("Survey the hull")
    assert [%{text: "Survey the hull"}] = Ash.read!(Keyfleet.Proposals.Words)

    unreadable = answer(c, c.signer, "POST", @propose, @address, %{words | "kind" => "vote"}, 422)
    assert unreadable.body["error"]["code"] == "invalid_proposal"

    ChainViews.put!([owner, status])
    vote = %{"number" => 1, "choice" => "no"}

    assert %{"keys" => [2], "transactions" => [ballot]} =
             answer(c, c.signer, "POST", @vote, @address, vote, 200).body

    assert ballot["name"] == "no"

    ChainViews.put!([owner, status, author(fleet, 1, 2)])
    answer(c, c.signer, "POST", @cancel, @address, %{"number" => 1}, 200)

    ChainViews.put!([{fleet.votes_address, "status(uint256)", [1], {"uint8", [0]}}])

    assert [%{"blocked" => "Voting still open"}] =
             answer(c, c.signer, "POST", @carry_out, @address, %{"number" => 1}, 200).body[
               "transactions"
             ]

    for template <- [@vote, @cancel, @carry_out] do
      body = Map.take(vote, ["number"]) |> Map.merge(if template == @vote, do: vote, else: %{})
      answer(c, c.signer, "POST", template, @address, %{body | "number" => 99}, 404)
      answer(c, c.signer, "POST", template, @address, %{body | "number" => 0}, 422)
    end

    ChainViews.put!([
      {fleet.treasury_address, "splitAssets()", [], {"address[]", [[usdc]]}},
      uint.(fleet.treasury_address, "dailySplitBps()", [], 50),
      uint.(fleet.treasury_address, "lastRunAt()", [], 0),
      uint.(fleet.treasury_address, "nextRunAt()", [], 0),
      uint.(fleet.manager_address, "totalMinted()", [], 0),
      {usdc, "decimals()", [], {"uint8", [6]}},
      uint.(usdc, "balanceOf(address)", [fleet.treasury_address], 0)
    ])

    assert [%{"name" => "run_split", "blocked" => "No Keys sold yet"}] =
             answer(c, c.signer, "POST", @split, @address, %{}, 200).body["transactions"]

    ChainViews.put!([
      owner,
      {fleet.rewards_address, "rewardAssets()", [], {"address[]", [[usdc]]}},
      uint.(fleet.rewards_address, "accrued(address,uint256)", [usdc, key], 2_000_000),
      uint.(fleet.rewards_address, "credits(address,address)", [usdc, wallet], 0)
    ])

    assert %{"paid_to" => ^wallet, "waiting" => [%{"amount" => "2000000", "symbol" => "USDC"}]} =
             answer(c, c.signer, "POST", @claim, own, %{}, 200).body

    answer(c, c.signer, "POST", @claim, unsold, %{}, 404)
  end

  # The agent holds Key 2 and starts a poll. Another agent holds Key 3, and a
  # third holds a shard of Key 2: Key 2's second agent, which shares its one
  # vote and its one poll a day.
  defp poll_routes(c, stranger) do
    second = new_signer()
    record_owner(3, second.address)
    twin = new_signer()
    ChainHelpers.issue_shard!(@fleet, 2, twin.address)
    start = @poll_question

    # Listing and starting polls.
    assert answer(c, stranger, "GET", @polls, @address, %{}, 200).body == %{"polls" => []}
    answer(c, c.signer, "POST", @poll_start, @address, %{start | "minutes" => 0}, 422)
    answer(c, c.signer, "POST", @poll_start, @address, %{start | "minutes" => 61}, 422)
    twice = %{start | "choices" => ["Left door", "Left door"]}

    assert answer(c, c.signer, "POST", @poll_start, @address, twice, 422).body ==
             refused("invalid_poll")

    assert answer(c, stranger, "POST", @poll_start, @address, start, 403).body ==
             refused("poll_needs_key")

    poll = answer(c, c.signer, "POST", @poll_start, @address, start, 201).body["poll"]

    assert %{
             "started_by_key" => 2,
             "open" => true,
             "totals" => nil,
             "notes" => "The left one creaks."
           } =
             poll

    # One poll a day for each Key, its shard's agents included.
    limited = answer(c, twin, "POST", @poll_start, @address, start, 429)
    assert limited.body == refused("poll_limit_reached")
    assert [wait] = Req.Response.get_header(limited, "retry-after")
    assert String.to_integer(wait) in 86_390..86_400

    # Anyone reads a poll; only the fleet's Key holders read its notes.
    assert [%{"id" => id} = listed] =
             answer(c, stranger, "GET", @polls, @address, %{}, 200).body["polls"]

    assert id == poll["id"]
    refute Map.has_key?(listed, "notes")
    at = Map.put(@address, "poll_id", id)
    elsewhere = Map.put(@address, "poll_id", Ecto.UUID.generate())
    assert answer(c, stranger, "GET", @poll, at, %{}, 200).body |> Map.keys() == ["poll"]
    answer(c, stranger, "GET", @poll, elsewhere, %{}, 404)

    # Voting: once for each Key, for one of the poll's choices. The first vote
    # sent for Key 2 counts; its other agent sending the same vote is answered
    # with it, and another vote is refused.
    vote = %{"choice" => "Left door", "reason" => "The shorter way"}

    assert answer(c, stranger, "POST", @poll_vote, at, vote, 403).body ==
             refused("poll_needs_key")

    answer(c, c.signer, "POST", @poll_vote, elsewhere, vote, 404)

    assert answer(c, c.signer, "POST", @poll_vote, at, %{vote | "choice" => "Up"}, 422).body ==
             refused("choice_unknown")

    answer(
      c,
      c.signer,
      "POST",
      @poll_vote,
      at,
      %{vote | "reason" => String.duplicate("r", 501)},
      422
    )

    assert answer(c, c.signer, "POST", @poll_vote, at, vote, 201).body["vote"]["key"] == 2
    answer(c, twin, "POST", @poll_vote, at, vote, 200)

    assert answer(c, twin, "POST", @poll_vote, at, %{"choice" => "Right door"}, 409).body ==
             refused("vote_conflict")

    answer(c, second, "POST", @poll_vote, at, %{"choice" => "Right door"}, 201)

    # Votes stay hidden until the poll closes.
    open = answer(c, second, "GET", @poll, at, %{}, 200).body
    assert %{"poll" => %{"votes_cast" => 2, "totals" => nil}, "votes" => []} = open
    assert %{"key" => 3, "choice" => "Right door"} = open["my_vote"]

    # Ending: only the agents of the Key that started it.
    assert answer(c, second, "POST", @poll_end, at, %{}, 403).body == refused("not_starter")
    answer(c, c.signer, "POST", @poll_end, elsewhere, %{}, 404)
    ended = answer(c, twin, "POST", @poll_end, at, %{}, 200).body["poll"]

    assert %{"open" => false, "totals" => [%{"choice" => "Left door", "votes" => 1}, _right]} =
             ended

    answer(c, c.signer, "POST", @poll_end, at, %{}, 409)

    assert answer(c, third_signer(), "POST", @poll_vote, at, vote, 409).body ==
             refused("poll_closed")

    assert [_left, _right] = answer(c, second, "GET", @poll, at, %{}, 200).body["votes"]
  end

  # An agent holding Key 4, which took no part.
  defp third_signer do
    third = new_signer()
    record_owner(4, third.address)
    third
  end

  # Proposal `number` on the chain, made with `key`.
  defp author(fleet, number, key) do
    zero = "0x" <> String.duplicate("0", 64)

    {fleet.votes_address, "proposal(uint256)", [number],
     {"bytes32,bytes32,bytes32,uint64,uint48,uint64,uint64,uint64,uint32,uint32,uint32,uint32,uint32,bool,bool",
      [
        zero,
        zero,
        zero,
        ChainHelpers.onchain_id(@fleet, key),
        1,
        0,
        0,
        0,
        3,
        1,
        2,
        1,
        0,
        false,
        false
      ]}}
  end

  # Signs and sends one request, and holds its answer to the contract.
  defp answer(c, signer, method, template, address, body, status) do
    response = send_signed(c, signer, method, fill(template, address), Jason.encode!(body))
    documented!(response, method, template, status)
  end

  defp answer_raw(c, method, template, body, status) do
    response =
      Req.request!(
        method: verb(method),
        url: c.app <> fill(template, @address),
        headers: %{"content-type" => "application/json"},
        body: body,
        retry: false,
        redirect: false
      )

    documented!(response, method, template, status)
  end

  defp documented!(response, method, template, status) do
    assert response.status == status, "#{method} #{template}: #{inspect(response.body)}"
    assert ContractSchema.response_errors(response.body, method, template, status) == []
    send(self(), {:answered, {method, template, status}})
    response
  end

  defp answered do
    receive do
      {:answered, answer} -> Enum.uniq([answer | answered()])
    after
      0 -> []
    end
  end

  # The answers the contract lists for the routes this file drives end to end.
  defp documented_answers do
    contract = YamlElixir.read_from_file!(@contract)

    for {method, template} <- routes(),
        status <- Map.keys(contract["paths"][template][String.downcase(method)]["responses"]),
        do: {method, template, String.to_integer(status)}
  end

  defp routes do
    [
      {"POST", @join},
      {"POST", @update},
      {"GET", @shards},
      {"POST", @avatar_start},
      {"POST", @avatar_remove},
      {"GET", @mutes},
      {"POST", @mute},
      {"POST", @unmute},
      {"GET", @rooms},
      {"POST", @create},
      {"POST", @topic},
      {"POST", @read},
      {"POST", @send},
      {"POST", @key_read},
      {"POST", @key_send},
      {"POST", @sync},
      {"POST", @proposal},
      {"POST", @presence},
      {"POST", @propose},
      {"POST", @vote},
      {"POST", @cancel},
      {"POST", @carry_out},
      {"POST", @split},
      {"POST", @claim},
      {"POST", @code_password},
      {"GET", @polls},
      {"POST", @poll_start},
      {"GET", @poll},
      {"POST", @poll_vote},
      {"POST", @poll_end},
      {"GET", @dm_inbox},
      {"GET", @dm_blocks},
      {"POST", @dm_changes}
    ] ++ for(op <- ~w(read send auto_delete delete block unblock), do: {"POST", @dm <> op})
  end

  defp body_cap(@update), do: 24 * 1024
  defp body_cap(@send), do: 4_000 * 12 + 2 * 1024
  defp body_cap(@key_send), do: 4_000 * 12 + 2 * 1024
  defp body_cap(@dm <> "send"), do: 4_000 * 12 + 2 * 1024
  defp body_cap(@sync), do: 32 * 1024
  defp body_cap(@propose), do: 4_000 * 12 + 8 * 1024
  defp body_cap(@poll_start), do: (200 + 10 * 100 + 2_000) * 12 + 2 * 1024
  defp body_cap(@poll_vote), do: 500 * 12 + 2 * 1024
  defp body_cap(_template), do: 4096

  defp empty_or_minimal(@join), do: %{"name" => "Probe", "declared_harness" => "local"}
  defp empty_or_minimal(@update), do: %{"current_status" => "away"}
  defp empty_or_minimal(@create), do: %{"slug" => "away", "name" => "Away"}
  defp empty_or_minimal(@topic), do: %{"topic" => "Away"}
  defp empty_or_minimal(@send), do: %{"body" => "away", "idempotency_key" => "a-1"}
  defp empty_or_minimal(@key_send), do: %{"body" => "away", "idempotency_key" => "a-1"}
  defp empty_or_minimal(@dm <> "send"), do: %{"body" => "away", "idempotency_key" => "a-1"}
  defp empty_or_minimal(@dm <> "auto_delete"), do: %{"days" => nil}
  defp empty_or_minimal(@dm_changes), do: %{"after_seq" => 0}
  defp empty_or_minimal(@avatar_start), do: @picture

  defp empty_or_minimal(@sync),
    do: %{
      "rooms" => [],
      "graph" => %{"after_seq" => 0},
      "proposals" => %{"after_seq" => 0},
      "run" => %{"kind" => "session"}
    }

  defp empty_or_minimal(@proposal), do: %{"number" => 1, "votes_after_seq" => 0}

  defp empty_or_minimal(@propose),
    do: %{"kind" => "decision", "key" => "2", "text" => "Away"}

  defp empty_or_minimal(@vote), do: %{"number" => 1, "choice" => "yes"}
  defp empty_or_minimal(@cancel), do: %{"number" => 1}
  defp empty_or_minimal(@carry_out), do: %{"number" => 1}
  defp empty_or_minimal(@poll_start), do: @poll_question
  defp empty_or_minimal(@poll_vote), do: %{"choice" => "Left door"}
  defp empty_or_minimal(_template), do: %{}

  # A body the check finds the wrong shape is refused before anything else
  # looks at it; one of the right shape goes on, even with numbers out of range.
  defp admitted?(contract, method, template, at, object) do
    {_method, _template, _at, top} = Enum.find(@bodies, &match?({^method, ^template, [], _}, &1))
    top = Map.take(top, request_schema(contract, method, template, [])["required"] || [])
    path = for step <- at, not match?({:one_of, _}, step), do: access(step)
    body = if at == [], do: object, else: put_in(top, path, object)
    SignedAgent.check_body(fill(template, @address), body) != :invalid
  end

  # The fields a refused body is told its operation takes.
  defp told_fields(template) do
    ~r/: ([a-z0-9_, ]+)[;.]/
    |> Regex.scan(SignedAgent.takes(fill(template, @address)), capture: :all_but_first)
    |> Enum.flat_map(&String.split(hd(&1), ", "))
    |> Enum.sort()
  end

  defp access(index) when is_integer(index), do: Access.at(index)
  defp access(key), do: key

  # The schema the contract gives the object at `at` inside the request body.
  defp request_schema(contract, method, template, at) do
    body = resolve(contract, contract["paths"][template][String.downcase(method)]["requestBody"])
    schema = resolve(contract, body["content"]["application/json"]["schema"])

    Enum.reduce(at, schema, fn
      index, schema when is_integer(index) -> resolve(contract, schema["items"])
      {:one_of, index}, schema -> resolve(contract, Enum.at(schema["oneOf"], index))
      key, schema -> resolve(contract, schema["properties"][key])
    end)
  end

  defp resolve(contract, %{"$ref" => "#/components/" <> ref}),
    do: resolve(contract, get_in(contract["components"], String.split(ref, "/")))

  defp resolve(_contract, schema), do: schema

  # Every name a request could try to slip in: each field the contract names
  # anywhere, each field and argument of the resources behind these routes,
  # and each word the signed-request check spells.
  defp candidate_fields(contract) do
    resources =
      Enum.flat_map(
        [
          Keyfleet.Agents,
          Keyfleet.Keys,
          Keyfleet.Rooms,
          Keyfleet.Dms,
          Keyfleet.Graph,
          Keyfleet.Proposals,
          Keyfleet.Polls
        ],
        &Ash.Domain.Info.resources/1
      )

    from_resources =
      for resource <- resources,
          field <-
            Ash.Resource.Info.fields(resource) ++
              Enum.flat_map(Ash.Resource.Info.actions(resource), &Map.get(&1, :arguments, [])),
          do: to_string(field.name)

    source = File.read!(@plug_source)
    quoted = Regex.scan(~r/"([A-Za-z_][A-Za-z0-9_]*)"/, source, capture: :all_but_first)
    listed = Regex.scan(~r/~w\(([^)]*)\)/, source, capture: :all_but_first)

    Enum.uniq(
      ["unlisted"] ++
        property_names(contract) ++
        from_resources ++
        List.flatten(quoted) ++ Enum.flat_map(List.flatten(listed), &String.split/1)
    )
  end

  defp property_names(%{} = node) do
    own = node |> Map.get("properties", %{}) |> then(&if(is_map(&1), do: Map.keys(&1), else: []))
    own ++ Enum.flat_map(Map.values(node), &property_names/1)
  end

  defp property_names(list) when is_list(list), do: Enum.flat_map(list, &property_names/1)
  defp property_names(_leaf), do: []

  defp fill(template, address),
    do: Regex.replace(~r/\{(\w+)\}/, template, fn _, name -> Map.fetch!(address, name) end)

  defp record_owner(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp new_signer do
    {:ok, signer} = Siwa.LocalSigner.new()
    signer
  end

  defp verb(method), do: method |> String.downcase() |> String.to_existing_atom()

  defp send_signed(c, signer, method, path, body) do
    {:ok, %{token: receipt}} =
      Siwa.Receipt.create(
        %{
          "typ" => "siwa_wallet_receipt",
          "sub" => signer.address,
          "chain_id" => 8453,
          "aud" => "keyfleet",
          "key_id" => signer.address,
          "verified" => "wallet_signature",
          "nonce" => Ecto.UUID.generate(),
          "jti" => Ecto.UUID.generate()
        },
        secret: c.secret
      )

    {:ok, request} =
      Siwa.RequestAuth.sign_authenticated_request(
        %{
          method: method,
          path: path,
          body: body,
          headers: %{"content-type" => "application/json"}
        },
        receipt,
        signer,
        secret: c.secret,
        audience: "keyfleet",
        wallet_audiences: ["keyfleet"]
      )

    Req.request!(
      method: verb(method),
      url: c.app <> request.path,
      headers: request.headers,
      body: request.body,
      retry: false,
      redirect: false
    )
  end

  defp broker(conn, _opts, secret) do
    {:ok, raw, conn} = read_body(conn)
    payload = Jason.decode!(raw)

    case Siwa.verify_authenticated_request(payload,
           secret: secret,
           audience: "keyfleet",
           wallet_audiences: ["keyfleet"]
         ) do
      {:ok, %{claims: claims, covered_components: covered}} ->
        reply(conn, 200, %{
          code: "http_envelope_valid",
          data: %{
            verified: true,
            walletAddress: claims["sub"],
            chainId: claims["chain_id"],
            verificationMethod: "eoa_recovery",
            keyId: claims["key_id"],
            receiptExpiresAt:
              DateTime.from_unix!(claims["exp"], :millisecond) |> DateTime.to_iso8601(),
            requiredHeaders: Siwa.required_authenticated_request_headers(payload["body"]),
            requiredCoveredComponents:
              Siwa.required_authenticated_request_components(
                payload["headers"],
                payload["body"]
              ),
            coveredComponents: covered,
            agentRegistration: nil,
            agentBook: nil,
            principal: %{
              kind: "wallet",
              wallet_address: claims["sub"],
              chain_id: claims["chain_id"],
              audience: claims["aud"]
            }
          }
        })

      {:error, _reason} ->
        reply(conn, 401, %{error: KeyfleetWeb.SignedAgentHelpers.refusal()})
    end
  end

  defp server(id, plug) do
    pid =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0}, id: id)
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp reply(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end

defmodule KeyFleetWeb.SignedAgentContractTest do
  @moduledoc """
  Holds every signed agent route to the served contract: the bodies it
  admits, and the answers it really gives.
  """
  use ExUnit.Case, async: false
  import Plug.Conn

  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.ContractSchema
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Rooms

  @contract Path.expand("../../contracts/api-contract.openapiv3.yaml", __DIR__)
  # A field the signed-request check admits has to be spelled in its source.
  @plug_source Path.expand("../../lib/keyfleet_web/plugs/signed_agent.ex", __DIR__)
  @external_resource @plug_source

  @fleet "fibonacci_syndicate"
  @owner "0x" <> String.duplicate("a", 40)

  @join "/api/v1/agent/join/status"
  @update "/api/v1/agent/profile/update"
  @pairings "/api/v1/agent/pairings"
  @pairing "/api/v1/agent/keys/{fleet_id}/{token_id}/pairing"
  @rooms "/api/v1/agent/fleets/{fleet_id}/rooms"
  @create "/api/v1/agent/fleets/{fleet_id}/rooms/create"
  @read "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/read"
  @send "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/send"
  @sync "/api/v1/agent/fleets/{fleet_id}/sync"
  @graph "/api/v1/agent/fleets/{fleet_id}/graph/"

  @address %{"fleet_id" => @fleet, "token_id" => "1", "slug" => "general"}

  # One valid value for every field each body documents, at each object the
  # body holds: the top of the body, or a place inside it.
  @bodies [
    {"POST", @join, [], %{"name" => "Probe", "declared_harness" => "local"}},
    {"POST", @update, [],
     %{
       "name" => "Probe",
       "avatar" => "https://example.com/probe.png",
       "declared_harness" => "local",
       "proficiencies" => ["research"],
       "interests" => ["chips"],
       "service_ideas" => ["briefs"],
       "current_status" => "probing"
     }},
    {"GET", @pairings, [], %{}},
    {"POST", @pairing, [], %{}},
    {"DELETE", @pairing, [], %{}},
    {"GET", @rooms, [], %{}},
    {"POST", @create, [], %{"slug" => "probe-room", "name" => "Probe", "level" => 1}},
    {"POST", @read, [], %{"after_seq" => 0, "limit" => 1}},
    {"POST", @send, [], %{"body" => "probe", "idempotency_key" => "p-1", "reply_to_id" => nil}},
    {"POST", @sync, [],
     %{"rooms" => [%{"slug" => "general", "after_seq" => 0}], "graph" => %{"after_seq" => 0}}},
    {"POST", @sync, ["rooms", 0], %{"slug" => "general", "after_seq" => 0}},
    {"POST", @sync, ["graph"], %{"after_seq" => 0}},
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
     }}
  ]

  # Where each body's fields go once admitted, less the ones its address supplies.
  @actions [
             {@update, KeyFleet.Agents.AgentProfile, :edit_my_profile},
             {@create, KeyFleet.Rooms.Room, :create_topic},
             {@read, KeyFleet.Rooms.Message, :read_messages},
             {@send, KeyFleet.Rooms.Message, :send_message}
           ] ++
             for(
               op <- ~w(get changes create patch link unlink archive),
               do: {@graph <> op, KeyFleet.Graph.Workspace, String.to_atom(op)}
             )

  # Nothing can make these happen on demand: the owner deciding a request in
  # the moment between it being found and being taken back.
  @unforced [{"DELETE", @pairing, 409}]

  setup do
    # Syncs read the workspace in a repeatable-read snapshot, which Postgres
    # allows inside the sandbox only when its transaction is at that level already.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(KeyFleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_core_rooms!()
    {:ok, signer} = Siwa.LocalSigner.new()
    record_owner(1, @owner)
    record_owner(2, signer.address)

    secret = :crypto.strong_rand_bytes(32)
    old = Application.get_env(:keyfleet, :siwa_broker_url)
    on_exit(fn -> Application.put_env(:keyfleet, :siwa_broker_url, old) end)
    broker = server(:broker, &broker(&1, &2, secret))
    Application.put_env(:keyfleet, :siwa_broker_url, broker)
    app = server(:product, &KeyFleetWeb.Endpoint.call(&1, KeyFleetWeb.Endpoint.init(&2)))
    %{app: app, signer: signer, secret: secret}
  end

  test "each signed route admits exactly the body fields its contract documents", c do
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
      assert admitted?(c, contract, method, template, at, minimal) == fits?, where

      for field <- documented -- required do
        assert admitted?(
                 c,
                 contract,
                 method,
                 template,
                 at,
                 Map.put(minimal, field, sample[field])
               ),
               "#{where} refuses its documented #{field}"
      end

      for field <- required do
        refute admitted?(c, contract, method, template, at, Map.delete(minimal, field)),
               "#{where} admits a body without its required #{field}"
      end

      admitted =
        (words -- documented)
        |> Enum.flat_map(fn word -> Enum.map([1, "x", %{"x" => 1}, ["x"]], &{word, &1}) end)
        |> Task.async_stream(
          fn {word, value} ->
            {word, admitted?(c, contract, method, template, at, Map.put(minimal, word, value))}
          end,
          max_concurrency: 16,
          timeout: 30_000
        )
        |> Enum.filter(&match?({:ok, {_word, true}}, &1))
        |> Enum.map(fn {:ok, {word, true}} -> word end)
        |> Enum.uniq()

      assert admitted == [], "#{where} admits undocumented #{inspect(admitted)}"
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
    ensure = Ash.Resource.Info.action(KeyFleet.Agents.AgentProfile, :ensure_profile)
    assert joining -- Enum.map(ensure.accept, &to_string/1) == []
  end

  test "a reply names its post only by its id as the API gives it", c do
    contract = YamlElixir.read_from_file!(@contract)
    id = Ecto.UUID.generate()
    reply = &%{"body" => "Seen", "idempotency_key" => "r-1", "reply_to_id" => &1}

    assert admitted?(c, contract, "POST", @send, [], reply.(id))
    assert ContractSchema.errors(reply.(id), "RoomSendRequest") == []

    # The same post in capitals, without its hyphens, in braces, and as any
    # sixteen bytes, which is how a post id is stored.
    for other <- [String.upcase(id), String.replace(id, "-", ""), "{#{id}}", "abcdefghijklmnop"] do
      refute admitted?(c, contract, "POST", @send, [], reply.(other)), inspect(other)
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
    answer(c, c.signer, "POST", @pairing, one, %{}, 404)

    # Joining and editing.
    joining = %{"name" => "Probe", "declared_harness" => "local"}
    answer(c, c.signer, "POST", @join, @address, %{joining | "name" => ""}, 422)
    answer(c, c.signer, "POST", @join, @address, joining, 200)
    answer(c, c.signer, "POST", @update, @address, %{"current_status" => "Surveying"}, 200)
    answer(c, c.signer, "POST", @update, @address, %{"name" => String.duplicate("n", 121)}, 422)
    answer(c, stranger, "POST", @join, @address, %{joining | "name" => "Stranger"}, 200)

    # Asking for keys and taking a request back.
    assert answer(c, c.signer, "GET", @pairings, @address, %{}, 200).body["pairings"] == []

    assert answer(c, c.signer, "POST", @pairing, one, %{}, 200).body["pairing"]["status"] ==
             "requested"

    assert [_requested] =
             answer(c, c.signer, "GET", @pairings, @address, %{}, 200).body["pairings"]

    assert answer(c, c.signer, "DELETE", @pairing, one, %{}, 200).body["pairing"]["status"] ==
             "ended"

    answer(c, c.signer, "DELETE", @pairing, one, %{}, 404)
    answer(c, c.signer, "POST", @pairing, Map.put(@address, "token_id", "99"), %{}, 404)
    assert answer(c, c.signer, "POST", @pairing, own, %{}, 200).body["pairing"]["effective?"]
    answer(c, c.signer, "POST", @pairing, own, %{}, 409)

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
             %{"error" => "idempotency_conflict"}

    reply = %{"body" => "Seen", "idempotency_key" => "k-2", "reply_to_id" => by_person.id}

    assert answer(c, c.signer, "POST", @send, @address, reply, 201).body["message"]["reply_to_id"] ==
             by_person.id

    elsewhere = %{
      "body" => "Seen",
      "idempotency_key" => "k-3",
      "reply_to_id" => Ecto.UUID.generate()
    }

    assert answer(c, c.signer, "POST", @send, @address, elsewhere, 422).body["error"] ==
             "reply_not_here"

    assert answer(c, c.signer, "POST", @send, @address, %{post | "body" => ""}, 422).body["error"] ==
             "invalid_message"

    answer(c, c.signer, "POST", @send, Map.put(@address, "slug", "hull-survey"), post, 404)
    answer(c, stranger, "POST", @send, @address, %{post | "idempotency_key" => "s-1"}, 403)

    # Reading rooms.
    answer(c, c.signer, "GET", @rooms, @address, %{}, 200)
    read = answer(c, c.signer, "POST", @read, @address, %{}, 200).body["messages"]
    assert Enum.map(read, & &1["author_kind"]) == ["human", "agent", "agent"]
    answer(c, c.signer, "POST", @read, Map.put(@address, "slug", "hull-survey"), %{}, 404)
    answer(c, c.signer, "POST", @read, @address, %{"limit" => 201}, 422)

    # Catching up.
    general = %{"slug" => "general", "after_seq" => 0}

    sync = fn address, rooms, status ->
      body = %{"rooms" => rooms, "graph" => %{"after_seq" => 0}}
      answer(c, c.signer, "POST", @sync, address, body, status)
    end

    sync.(@address, [general, %{general | "slug" => "work"}], 200)
    sync.(@address, [%{general | "slug" => "hull-survey"}], 404)
    sync.(@address, [%{general | "after_seq" => -1}], 422)
    sync.(@address, [general, general], 422)

    # Opening topic rooms: new, taken, malformed, by an outsider, and past the limit.
    room = %{"slug" => "survey-plans", "name" => "Survey plans"}

    assert answer(c, c.signer, "POST", @create, @address, Map.put(room, "level", 1), 201).body ==
             %{
               "room" => %{
                 "slug" => "survey-plans",
                 "name" => "Survey plans",
                 "kind" => "topic",
                 "level" => 1,
                 "head_seq" => 0
               }
             }

    assert answer(c, c.signer, "POST", @create, @address, room, 409).body ==
             %{"error" => "room_taken"}

    answer(c, c.signer, "POST", @create, @address, %{room | "slug" => "Survey"}, 422)
    answer(c, stranger, "POST", @create, @address, %{room | "slug" => "outsiders"}, 403)

    for n <- 2..100 do
      Rooms.create_topic_room!(%{fleet_id: @fleet, slug: "topic-#{n}", name: "Topic #{n}"},
        actor: human
      )
    end

    assert answer(c, c.signer, "POST", @create, @address, %{room | "slug" => "one-more"}, 409).body ==
             %{"error" => "room_limit_reached"}

    # A fleet outside the catalog is not found on every route that names one,
    # with the answer the workspace gives.
    nowhere = Map.put(@address, "fleet_id", "hull_survey")

    for {method, template, [], body} <- @bodies, String.contains?(template, "{fleet_id}") do
      assert answer(c, c.signer, method, template, nowhere, body, 404).body["error"] ==
               "fleet_unknown",
             "#{method} #{template}"
    end

    # While key ownership is being read again, nothing that needs a key is done.
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    answer(c, c.signer, "POST", @send, @address, %{post | "idempotency_key" => "k-4"}, 503)
    answer(c, c.signer, "POST", @pairing, one, %{}, 503)
    answer(c, c.signer, "POST", @create, @address, %{room | "slug" => "late"}, 503)

    # Every route: unsigned, too large, and with the sign-in check away.
    for {method, template} <- routes() do
      answer_raw(c, method, template, "{}", 401)
      answer_raw(c, method, template, String.duplicate(" ", body_cap(template) + 1), 413)
    end

    Application.put_env(:keyfleet, :siwa_broker_url, nil)

    for {method, template} <- routes(),
        do: answer(c, c.signer, method, template, @address, empty_or_minimal(template), 503)

    answered =
      Enum.filter(answered(), fn {method, template, _status} ->
        {method, template} in routes()
      end)

    documented = documented_answers()
    assert documented -- answered == @unforced
    assert answered -- documented == []
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
      {"GET", @pairings},
      {"POST", @pairing},
      {"DELETE", @pairing},
      {"GET", @rooms},
      {"POST", @create},
      {"POST", @read},
      {"POST", @send},
      {"POST", @sync}
    ]
  end

  defp body_cap(@update), do: 24 * 1024
  defp body_cap(@send), do: 4_000 * 12 + 2 * 1024
  defp body_cap(@sync), do: 32 * 1024
  defp body_cap(_template), do: 4096

  defp empty_or_minimal(@join), do: %{"name" => "Probe", "declared_harness" => "local"}
  defp empty_or_minimal(@update), do: %{"current_status" => "away"}
  defp empty_or_minimal(@create), do: %{"slug" => "away", "name" => "Away"}
  defp empty_or_minimal(@send), do: %{"body" => "away", "idempotency_key" => "a-1"}
  defp empty_or_minimal(@sync), do: %{"rooms" => [], "graph" => %{"after_seq" => 0}}
  defp empty_or_minimal(_template), do: %{}

  # The signed-request check refuses a body it does not admit before anything
  # else looks at it, with the one answer every refusal shares.
  defp admitted?(c, contract, method, template, at, object) do
    {_method, _template, _at, top} = Enum.find(@bodies, &match?({^method, ^template, [], _}, &1))
    top = Map.take(top, request_schema(contract, method, template, [])["required"] || [])
    body = if at == [], do: object, else: put_in(top, Enum.map(at, &access/1), object)
    response = send_signed(c, c.signer, method, fill(template, @address), Jason.encode!(body))

    case {response.status, response.body} do
      {401, %{"error" => "unauthorized"}} -> false
      {401, other} -> flunk("#{method} #{template} refused with #{inspect(other)}")
      _admitted -> true
    end
  end

  defp access(index) when is_integer(index), do: Access.at(index)
  defp access(key), do: key

  # The schema the contract gives the object at `at` inside the request body.
  defp request_schema(contract, method, template, at) do
    body = resolve(contract, contract["paths"][template][String.downcase(method)]["requestBody"])
    schema = resolve(contract, body["content"]["application/json"]["schema"])

    Enum.reduce(at, schema, fn
      index, schema when is_integer(index) -> resolve(contract, schema["items"])
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
        [KeyFleet.Agents, KeyFleet.Keys, KeyFleet.Rooms, KeyFleet.Graph],
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
        ownership_epoch: 0,
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
            keyId: claims["key_id"],
            receiptExpiresAt:
              DateTime.from_unix!(claims["exp"], :millisecond) |> DateTime.to_iso8601(),
            requiredHeaders:
              Siwa.required_authenticated_request_headers(payload["body"], :wallet),
            requiredCoveredComponents:
              Siwa.required_authenticated_request_components(
                payload["headers"],
                payload["body"],
                :wallet
              ),
            coveredComponents: covered,
            principal: %{
              kind: "wallet",
              wallet_address: claims["sub"],
              chain_id: claims["chain_id"],
              audience: claims["aud"]
            }
          }
        })

      {:error, _reason} ->
        reply(conn, 401, %{error: %{code: "invalid_proof"}})
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

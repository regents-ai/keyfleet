defmodule KeyfleetWeb.Plugs.SignedAgent do
  @moduledoc "Captures bounded signed agent requests before any parser."
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  import Plug.Conn
  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents.CheckInStatus
  alias RegentAgents.HumanBacking

  @join_path "/api/v1/agent/join/status"
  @update_path "/api/v1/agent/profile/update"
  @profile_path "/api/v1/agent/profile"
  @credits_history_path "/api/v1/agent/account/credits/history"
  @account_paths ~w(/api/v1/agent/account/balances /api/v1/agent/account/points)
  @shards_path "/api/v1/agent/shards"
  # An agent's picture: a signed start names the upload, whose bytes then go
  # to the address it answers, outside this plug (`AgentAvatarController`).
  @avatar_start_path "/api/v1/agent/avatar/start"
  @avatar_remove_path "/api/v1/agent/avatar/remove"
  # The fleet, the room and the key a request is about are part of the signed
  # path, in the same canonical spelling the product's own addresses use.
  @fleet ~S"[a-z][a-z0-9_]{0,62}"
  @slug ~S"[a-z0-9][a-z0-9-]{0,62}"
  @token ~S"[1-9][0-9]{0,17}"
  # A post is named by its id as the API answers it: lowercase and hyphenated.
  @post_id ~r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"
  @rooms_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms\z"
  @create_room_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/create\z"
  @topic_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/topic\z"
  @read_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/messages/read\z"
  @send_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/messages/send\z"
  @sync_path ~r"\A/api/v1/agent/fleets/#{@fleet}/sync\z"
  @mutes_path ~r"\A/api/v1/agent/fleets/#{@fleet}/mutes\z"
  @mute_path ~r"\A/api/v1/agent/fleets/#{@fleet}/keys/#{@token}/(mute|unmute)\z"
  @key_read_path ~r"\A/api/v1/agent/keys/#{@fleet}/#{@token}/messages/read\z"
  @key_send_path ~r"\A/api/v1/agent/keys/#{@fleet}/#{@token}/messages/send\z"
  @proposal_read_path ~r"\A/api/v1/agent/fleets/#{@fleet}/proposals/read\z"
  @code_pushes_path ~r"\A/api/v1/agent/fleets/#{@fleet}/code/pushes\z"
  # A fleet's notebooks and their runs: a notebook and a run named as the hub
  # names them.
  @notebook ~S"nb-[0-9a-z]{16}"
  @run ~S"run_[0-9A-HJKMNP-TV-Z]{26}"
  @notebooks_path ~r"\A/api/v1/agent/fleets/#{@fleet}/notebooks\z"
  @run_start_path ~r"\A/api/v1/agent/fleets/#{@fleet}/notebooks/#{@notebook}/runs/start\z"
  @run_path ~r"\A/api/v1/agent/fleets/#{@fleet}/notebooks/#{@notebook}/runs/#{@run}\z"

  # A poll is named by its id as the API answers it.
  @poll ~S"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @polls_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls\z"
  @poll_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls/#{@poll}\z"
  @poll_start_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls/start\z"
  @poll_vote_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls/#{@poll}/vote\z"
  @poll_end_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls/#{@poll}/end\z"
  @empty_body_paths [@mute_path, @poll_end_path]
  @poll_post_paths [@poll_start_path, @poll_vote_path, @poll_end_path]

  # Direct messages: a Key's conversations and blocks, what it does in one
  # conversation with another Key, and catching up on the agent's Keys.
  @dm_inbox_path ~r"\A/api/v1/agent/fleets/#{@fleet}/keys/#{@token}/dms(/blocks)?\z"
  @dm_ops ~w(read send delete auto_delete block unblock)
  @dm_path ~r"\A/api/v1/agent/fleets/#{@fleet}/keys/#{@token}/dms/#{@token}/(#{Enum.join(@dm_ops, "|")})\z"
  @dm_changes_path ~r"\A/api/v1/agent/fleets/#{@fleet}/dms/changes\z"
  # What an agent's own wallet sends to the fleet's contracts.
  @chain_path ~r"\A/api/v1/agent/fleets/#{@fleet}/(presence|split|treasury/(?:send_share|convert)|proposals/(?:create|vote|cancel|carry_out)|keys/#{@token}/claim)\z"
  @graph_ops ~w(get changes create patch link unlink archive)
  @graph_path ~r"\A/api/v1/agent/fleets/#{@fleet}/graph/(#{Enum.join(@graph_ops, "|")})\z"

  # The fields each room, sync, proposal read and poll body holds: the ones it
  # must name, then the ones it may add.
  @body_fields [
    {@sync_path, {~w(rooms graph proposals run), ~w(keys dms quotes)}},
    {@proposal_read_path, {~w(number votes_after_seq), []}},
    {@create_room_path, {~w(slug name), []}},
    {@run_start_path, {~w(idempotency_key), []}},
    {@topic_path, {~w(topic), []}},
    {@read_path, {[], ~w(after_seq limit)}},
    {@key_read_path, {[], ~w(after_seq limit)}},
    {@send_path, {~w(body idempotency_key), ~w(reply_to_id quote_request_id)}},
    {@key_send_path, {~w(body idempotency_key), ~w(reply_to_id)}},
    {@poll_start_path, {~w(question choices minutes), ~w(notes)}},
    {@poll_vote_path, {~w(choice), ~w(reason)}}
  ]

  @editable ~w(name declared_harness proficiencies interests service_ideas current_status)
  # Separate transport bound from Ash field limits: the broker embeds these raw
  # bytes in JSON inside its 64 KiB envelope, potentially doubling escape bytes.
  @update_max_body 24 * 1024
  # A post is at most 4,000 characters. The longest a client can write one is a
  # character outside the Basic Multilingual Plane escaped as a surrogate pair,
  # `\ud83d\ude00`: twelve bytes. The send key and the rest of the object fit in
  # the 2 KiB beside it. Inside the broker's 64 KiB envelope each such pair
  # grows to fourteen bytes, which still fits.
  @send_max_body 4_000 * 12 + 2 * 1024
  # A workspace write holds a few thousand characters of text at most, and
  # fits the broker's envelope the same way a post does.
  @graph_write_max_body @send_max_body
  # A proposal holds its text, up to 4,000 bytes, and a launch's fields
  # beside it, escaped the same way.
  @propose_max_body 4_000 * 12 + 8 * 1024
  # A poll holds its question (200 characters), up to 10 choices of 100 and
  # notes of up to 2,000, each character escaped the way a post's can be; it
  # fits the broker's envelope the same way. A vote's reason is up to 500.
  @poll_start_max_body (200 + 10 * 100 + 2_000) * 12 + 2 * 1024
  @poll_vote_max_body 500 * 12 + 2 * 1024
  # What a proposal's body may name: what every proposal has, then the
  # fields of its kind, each a string as the proposals page's form sends it.
  @propose_required ~w(kind key text)
  @propose_fields @propose_required ++
                    ~w(asset share recipient rate target restricted signature issued_at name symbol description website image)
  @choices ~w(yes no abstain)
  # A direct message's parts sit beside its words, so it fits the same body
  # as a post.
  @max_dm_parts 8
  @auto_delete_days [nil, 1, 7, 30, 90]
  # One catch-up names up to 110 rooms, as many as a fleet holds (five fixed
  # rooms, five open rooms and a hundred created ones), up to 100 keys' walls,
  # how far the workspace and the proposals were read, and a place in each of
  # up to 2,000 Keys' direct messages: every Key of the largest fleet with a
  # supply limit (the Regents Club's 1,998). Catching up on direct messages
  # alone fits the same body.
  @sync_max_body 128 * 1024
  @max_sync_rooms 110
  @max_sync_walls 100
  @max_dm_keys 2_000
  @too_many_keys "Name at most 100 walls in keys and at most 2000 Keys in a dms keys list. " <>
                   "Split a longer list across several requests."
  # Places in a room are counted in a Postgres bigint.
  @max_seq 9_223_372_036_854_775_807
  @max_page 200
  @max_graph_page 500
  # What each workspace operation's body holds: its required fields, then the
  # ones it may add. A write names the key it acts as and its command id.
  @command_fields %{"as_key" => :key, "command_id" => :text}
  @graph_bodies %{
    "get" => {%{"id" => :text}, %{}},
    "changes" => {%{}, %{"after_seq" => :seq, "limit" => :graph_page}},
    "create" =>
      {Map.merge(@command_fields, %{"type" => :text, "scope" => :text, "data" => :object}), %{}},
    "patch" =>
      {Map.merge(@command_fields, %{"id" => :text, "expected_version" => :version}),
       %{"set" => :object, "unset" => :texts, "reason" => :text, "evidence" => :texts}},
    "link" =>
      {Map.merge(@command_fields, %{"source" => :text, "target" => :text, "type" => :text}),
       %{"note" => :text}},
    "unlink" => {Map.merge(@command_fields, %{"relation_id" => :text}), %{}},
    "archive" =>
      {Map.merge(@command_fields, %{"id" => :text, "expected_version" => :version}),
       %{"reason" => :text}}
  }
  @verification_methods %{
    "eoa_recovery" => :eoa_recovery,
    "erc1271" => :erc1271,
    "erc6492" => :erc6492
  }

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if agent_request?(conn), do: authenticate(conn), else: conn
  end

  defp agent_request?(conn),
    do: Enum.map(Enum.take(conn.path_info, 3), &URI.decode/1) == ["api", "v1", "agent"]

  defp authenticate(conn) do
    with true <- supported_request?(conn),
         true <- json_or_bodyless_get?(conn),
         %Plug.Conn.Unfetched{} <- conn.body_params do
      case read_signed(conn) do
        {:ok, "", %{method: "GET"} = conn} ->
          verify(%{conn | assigns: Map.delete(conn.assigns, :raw_body)})

        {:ok, _raw, conn} ->
          verify_json(conn)

        {:error, _reason} ->
          deny(conn, %{reason: :invalid_request})

        {:more, _raw, conn} ->
          answer(conn, 413, "request_too_large")

        :too_large ->
          answer(conn, 413, "request_too_large")
      end
    else
      _ -> deny(conn, %{reason: :invalid_request})
    end
  end

  defp verify_json(conn) do
    if json_or_bodyless_get?(%{conn | method: "POST"}),
      do: verify(conn),
      else: deny(conn, %{reason: :invalid_request})
  end

  defp json_or_bodyless_get?(conn) do
    case get_req_header(conn, "content-type") do
      [] -> conn.method == "GET"
      [type] -> match?({:ok, "application", "json", _}, Plug.Conn.Utils.media_type(type))
      _ -> false
    end
  end

  # The shared reader keeps the exact bytes the signature covers, and no more
  # than the operation takes.
  defp read_signed(conn) do
    Siwa.AgentAuthPlug.read_body(conn, [], body_limit(conn.request_path))
  rescue
    Plug.Parsers.RequestTooLargeError -> :too_large
  end

  # The raw body is signed, through its content digest, and checked against
  # it before anything is read from it; `accept/3` then reads it. The shared
  # plug forwards only the signed headers, so any other header changes nothing.
  defp verify(conn) do
    Siwa.AgentAuthPlug.call(conn,
      client: Keyfleet.SiwaBroker,
      hooks: __MODULE__,
      audience: "keyfleet",
      body: if(conn.method == "GET", do: :if_present, else: :always)
    )
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, _headers) do
    if supported_request?(conn),
      do: {:ok, nil},
      else: {:error, %{reason: :invalid_request}}
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def accept(conn, data, _context) do
    with {:ok, actor} <- actor(conn, data),
         {:ok, conn} <- take_body(conn),
         do: admit(conn, actor)
  end

  @doc """
  Admits the agent a verified answer names without reading the request's
  body. The notebook gateway carries that body to the fleet's hub as it
  came, and the hub checks it.
  """
  def accept_agent(conn, data) do
    with {:ok, actor} <- actor(conn, data), do: admit(conn, actor)
  end

  # The fields Keyfleet acts on; anything else the sign-in server says is
  # its own. The agent's page in the agent registry and the World ID person
  # behind it, each null when there is none, ride on the actor, and the
  # agent's profile saves them.
  defp actor(
         conn,
         %{
           "verified" => true,
           "walletAddress" => wallet,
           "chainId" => chain_id,
           "verificationMethod" => method,
           "keyId" => wallet,
           "receiptExpiresAt" => expires,
           "requiredHeaders" => required_headers,
           "requiredCoveredComponents" => required_components,
           "coveredComponents" => covered_components,
           "agentRegistration" => registration,
           "agentBook" => book,
           "principal" => %{
             "kind" => "wallet",
             "wallet_address" => wallet,
             "chain_id" => chain_id,
             "audience" => "keyfleet"
           }
         }
       )
       when is_binary(expires) and is_map_key(@verification_methods, method) and
              is_list(required_headers) and is_list(required_components) and
              is_list(covered_components) do
    with {:ok, registry_url} <- registry_url(registration),
         {:ok, backing} <- HumanBacking.read(book),
         {:ok, receipt_expires_at, _offset} <- DateTime.from_iso8601(expires) do
      {:ok,
       struct!(
         Agent,
         Map.merge(backing, %{
           wallet_address: wallet,
           chain_id: chain_id,
           verification_method: Map.fetch!(@verification_methods, method),
           audience: "keyfleet",
           credential_ref: credential_ref(conn),
           receipt_expires_at: receipt_expires_at,
           registry_url: registry_url
         })
       )}
    else
      _unreadable -> invalid_principal()
    end
  end

  defp actor(_conn, _data), do: invalid_principal()

  # Only a request whose signature verified is told what is wrong with its
  # body, and nothing it asks for is acted on until the body fits. A read
  # carries no body.
  defp take_body(%{method: "GET", assigns: assigns} = conn)
       when not is_map_key(assigns, :raw_body),
       do: {:ok, %{conn | body_params: %{}, params: %{}}}

  defp take_body(%{method: "GET"}), do: {:error, %{reason: :body_does_not_fit}}

  defp take_body(%{assigns: %{raw_body: raw}} = conn) do
    with {:ok, params} <- Jason.decode(raw),
         :ok <- check_body(conn.request_path, params) do
      {:ok, %{conn | body_params: params, params: params}}
    else
      :out_of_range -> {:error, %{reason: :out_of_range}}
      :too_many_keys -> {:error, %{reason: :too_many_keys}}
      _invalid -> {:error, %{reason: :body_does_not_fit}}
    end
  end

  defp registry_url(nil), do: {:ok, nil}
  defp registry_url(%{"registryUrl" => "https://" <> _rest = url}), do: {:ok, url}
  defp registry_url(_other), do: :error

  defp admit(conn, actor) do
    cond do
      Agent.authenticated?(actor) ->
        case Keyfleet.Agents.with_pairing(actor) do
          {:ok, paired} ->
            # A listing that could not be saved is logged there and saved by
            # the agent's next request; this request goes on.
            _saved_or_logged = Keyfleet.Agents.save_listing(paired)
            {:ok, assign(conn, :agent_actor, paired)}

          {:error, :not_paired} ->
            {:error, %{reason: :agent_not_paired}}

          {:error, _} ->
            {:error, %{reason: :pairing_unavailable}}
        end

      smart_wallet_on_ethereum?(actor) ->
        {:error, %{reason: :smart_wallet_on_ethereum}}

      true ->
        invalid_principal()
    end
  end

  defp invalid_principal, do: {:error, %{reason: :invalid_principal}}

  # A smart wallet proven on Ethereum says nothing about the same address on
  # Base, where the keys are. Signing in again on Ethereum can't fix it, so the
  # agent is told to sign in on Base instead.
  defp smart_wallet_on_ethereum?(%Agent{chain_id: 1, verification_method: method}),
    do: method in [:erc1271, :erc6492]

  defp smart_wallet_on_ethereum?(_actor), do: false

  # The receipt and key id each appear exactly once: the shared plug refuses a
  # repeat and the sign-in server a request missing either.
  defp credential_ref(conn) do
    [receipt] = get_req_header(conn, Siwa.Contract.header_for("receipt"))
    [key_id] = get_req_header(conn, Siwa.Contract.header_for("key_id"))
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, [receipt, "\n", key_id]), case: :lower)
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, %{reason: :smart_wallet_on_ethereum}),
    do: answer(conn, 401, "smart_wallet_on_ethereum")

  def deny(conn, %{reason: :agent_not_paired}), do: answer(conn, 403, "agent_not_paired")
  def deny(conn, %{reason: :pairing_unavailable}), do: answer(conn, 503, "pairing_unavailable")

  def deny(conn, %{reason: :out_of_range}), do: answer(conn, 422, "out_of_range")

  def deny(conn, %{reason: :too_many_keys}),
    do: send_refusal(conn, 422, KeyfleetWeb.Refusal.body("out_of_range", @too_many_keys))

  def deny(conn, %{reason: :body_does_not_fit}) do
    body = KeyfleetWeb.Refusal.body("invalid_request", takes(conn.request_path))
    send_refusal(conn, 422, body)
  end

  # The shared plug's own refusals keep its reason as the code, as on every site.
  def deny(conn, %{source: :siwa_plug, reason: reason}),
    do: answer(conn, 401, Atom.to_string(reason))

  def deny(conn, %{reason: :siwa_request_failed}), do: answer(conn, 503, "siwa_request_failed")

  # The sign-in service answered with a refusal or a failure: its status and its
  # own words, as on every site.
  def deny(conn, %{siwa_status: status} = failure) do
    send_refusal(conn, status, %{
      error: %{
        code: failure[:siwa_code] || "sign_in_refused",
        message: failure[:siwa_message] || "The request's wallet signature was not accepted.",
        hint: failure[:siwa_hint] || "Sign the request again with your agent key, then send it."
      }
    })
  end

  def deny(conn, _metadata), do: answer(conn, 401, "unauthorized")

  defp answer(conn, status, code), do: send_refusal(conn, status, KeyfleetWeb.Refusal.body(code))

  defp send_refusal(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  # A read is a GET with no body: its method and path are all it asks. Every
  # other admitted request carries a signed JSON body, an empty object when its
  # method and path say everything. What a request asks for is never in the
  # address, so the signature covers all of it; the shared plug refuses a query
  # string.
  defp supported_request?(conn), do: supported?(conn.method, conn.request_path)

  defp supported?("POST", @join_path), do: true
  defp supported?("POST", @update_path), do: true
  defp supported?("POST", @avatar_start_path), do: true
  defp supported?("POST", @avatar_remove_path), do: true
  defp supported?("GET", @shards_path), do: true
  defp supported?("GET", @profile_path), do: true
  defp supported?("GET", path) when path in @account_paths, do: true
  defp supported?("POST", @credits_history_path), do: true

  defp supported?("GET", path),
    do:
      Enum.any?(
        [
          @rooms_path,
          @mutes_path,
          @polls_path,
          @poll_path,
          @dm_inbox_path,
          @code_pushes_path,
          @notebooks_path,
          @run_path
        ],
        &Regex.match?(&1, path)
      )

  defp supported?("POST", path) do
    Enum.any?(
      [
        @mute_path,
        @create_room_path,
        @topic_path,
        @read_path,
        @send_path,
        @key_read_path,
        @key_send_path,
        @sync_path,
        @proposal_read_path,
        @run_start_path,
        @chain_path,
        @graph_path,
        @dm_path,
        @dm_changes_path
        | @poll_post_paths
      ],
      &Regex.match?(&1, path)
    )
  end

  defp supported?(_method, _path), do: false

  defp body_limit(@update_path), do: @update_max_body

  defp body_limit(path) do
    cond do
      Regex.match?(@send_path, path) or Regex.match?(@key_send_path, path) -> @send_max_body
      dm_op(path) == "send" -> @send_max_body
      catch_up?(path) -> @sync_max_body
      limit = poll_body_limit(path) -> limit
      chain_op(path) == "proposals/create" -> @propose_max_body
      graph_op(path) in ~w(create patch link unlink archive) -> @graph_write_max_body
      true -> 4096
    end
  end

  # A sync, and catching up on direct messages alone.
  defp catch_up?(path), do: Regex.match?(@sync_path, path) or dm_op(path) == "changes"

  defp poll_body_limit(path) do
    cond do
      Regex.match?(@poll_start_path, path) -> @poll_start_max_body
      Regex.match?(@poll_vote_path, path) -> @poll_vote_max_body
      true -> nil
    end
  end

  @doc """
  Whether a signed request's decoded body fits the operation at `path`: `:ok`,
  `:invalid` for the wrong shape or a room named twice, which is told the
  fields its operation takes, `:out_of_range` for the right shape with
  numbers outside what the operation holds, or `:too_many_keys` for more
  walls or Keys named than one request takes.
  """
  def check_body(@join_path, %{"name" => name, "declared_harness" => harness} = params),
    do: admit(map_size(params) == 2 and is_binary(name) and is_binary(harness))

  def check_body(@update_path, params) when is_map(params),
    do: admit(map_size(params) > 0 and Enum.all?(Map.keys(params), &(&1 in @editable)))

  # The newest page is {}; an older one names the previous page's cursor,
  # which the controller and the shared history action check.
  def check_body(@credits_history_path, params) when is_map(params),
    do: admit(Map.keys(params) -- ["after"] == [])

  def check_body(@credits_history_path, _params), do: :invalid

  def check_body(
        @avatar_start_path,
        %{"sha256" => sha256, "byte_size" => size, "content_type" => type} = params
      ),
      do:
        admit(
          map_size(params) == 3 and is_binary(sha256) and is_integer(size) and is_binary(type)
        )

  def check_body(@avatar_start_path, _params), do: :invalid
  def check_body(@avatar_remove_path, params), do: admit(params == %{})

  def check_body(path, params) do
    cond do
      Enum.any?(@empty_body_paths, &Regex.match?(&1, path)) -> admit(params == %{})
      op = fleet_op(path) -> check_fleet_body(op, params)
      op = dm_op(path) -> check_dm_body(op, params)
      op = chain_op(path) -> check_chain_body(op, params)
      op = graph_op(path) -> check_graph_body(op, params)
      poll_write?(path) -> check_poll_body(path, params)
      true -> check_room_body(path, params)
    end
  end

  defp check_room_body(path, params) do
    cond do
      Regex.match?(@create_room_path, path) ->
        admit(valid_room_body?(params))

      Regex.match?(@topic_path, path) ->
        admit(valid_topic_body?(params))

      Regex.match?(@read_path, path) or Regex.match?(@key_read_path, path) ->
        check_read_body(params)

      Regex.match?(@send_path, path) ->
        admit(valid_send_body?(params, ~w(body idempotency_key reply_to_id quote_request_id)))

      Regex.match?(@key_send_path, path) ->
        admit(valid_send_body?(params, ~w(body idempotency_key reply_to_id)))

      true ->
        :invalid
    end
  end

  # Catching up, reading a proposal and starting a notebook run each name
  # fields of their own.
  defp fleet_op(path) do
    Enum.find_value(
      [sync: @sync_path, proposal_read: @proposal_read_path, run_start: @run_start_path],
      fn {op, pattern} -> if Regex.match?(pattern, path), do: op end
    )
  end

  defp check_fleet_body(:sync, params), do: check_sync_body(params)
  defp check_fleet_body(:proposal_read, params), do: check_proposal_read_body(params)
  defp check_fleet_body(:run_start, params), do: check_run_start_body(params)

  defp chain_op(path) do
    case Regex.run(@chain_path, path, capture: :all_but_first) do
      [op] -> op
      nil -> nil
    end
  end

  # Presence, the split, sending the staking share and a claim say nothing
  # more than their path. Turning USDC into REGENT names its amount as a
  # string. A proposal names its fields as strings; a vote, a cancellation and
  # carrying out name the proposal, and a vote its choice.
  defp check_chain_body(op, params) when op in ["presence", "split", "treasury/send_share"],
    do: admit(params == %{})

  defp check_chain_body(
         "treasury/convert",
         %{"inputs" => %{"amount" => amount} = inputs} = params
       )
       when map_size(params) == 1 and map_size(inputs) == 1 and is_binary(amount),
       do: :ok

  defp check_chain_body("proposals/create", params) when is_map(params) do
    admit(
      Enum.all?(@propose_required, &Map.has_key?(params, &1)) and
        Enum.all?(params, fn {key, value} -> key in @propose_fields and is_binary(value) end)
    )
  end

  defp check_chain_body("proposals/vote", %{"number" => number, "choice" => choice} = params)
       when map_size(params) == 2 and is_integer(number) and choice in @choices,
       do: in_range(number in 1..@max_seq)

  defp check_chain_body(op, %{"number" => number} = params)
       when op in ["proposals/cancel", "proposals/carry_out"] and map_size(params) == 1 and
              is_integer(number),
       do: in_range(number in 1..@max_seq)

  defp check_chain_body("keys/" <> _claim, params), do: admit(params == %{})
  defp check_chain_body(_op, _params), do: :invalid

  # "changes" for catching up, or what is done in one conversation.
  defp dm_op(path) do
    case Regex.run(@dm_path, path, capture: :all_but_first) do
      [op] -> op
      nil -> if Regex.match?(@dm_changes_path, path), do: "changes"
    end
  end

  # A message names its words, the send key it is filed under and its parts;
  # auto-delete names its days, null to keep messages; catching up names only
  # where to start in each Key's messages; the rest say nothing more than
  # their path. The Key a message is from is always the path's.
  defp check_dm_body("read", params), do: check_read_body(params)
  defp check_dm_body("changes", params), do: check_dm_cursors(params)

  defp check_dm_body("send", %{"body" => body, "idempotency_key" => key} = params) do
    parts = Map.get(params, "parts", [])

    admit(
      is_binary(body) and is_binary(key) and is_list(parts) and
        length(parts) <= @max_dm_parts and Enum.all?(parts, &is_map/1) and
        Enum.all?(Map.keys(params), &(&1 in ~w(body idempotency_key parts)))
    )
  end

  defp check_dm_body("auto_delete", %{"days" => days} = params)
       when map_size(params) == 1 and (is_nil(days) or is_integer(days)),
       do: in_range(days in @auto_delete_days)

  defp check_dm_body(op, params) when op in ~w(delete block unblock),
    do: admit(params == %{})

  defp check_dm_body(_op, _params), do: :invalid

  defp graph_op(path) do
    case Regex.run(@graph_path, path, capture: :all_but_first) do
      [op] -> op
      nil -> nil
    end
  end

  # Nothing outside an operation's own fields is admitted, so a request can
  # never name its own author, standing or scope rules.
  defp check_graph_body(op, params) when is_map(params) do
    {required, optional} = Map.fetch!(@graph_bodies, op)
    fields = Map.merge(required, optional)

    cond do
      not (Enum.all?(Map.keys(required), &Map.has_key?(params, &1)) and
               Enum.all?(params, fn {key, value} -> shaped?(fields[key], value) end)) ->
        :invalid

      Enum.all?(params, fn {key, value} -> in_bounds?(fields[key], value) end) ->
        :ok

      true ->
        :out_of_range
    end
  end

  defp check_graph_body(_op, _params), do: :invalid

  defp shaped?(:text, value), do: is_binary(value)
  defp shaped?(:object, value), do: is_map(value)
  defp shaped?(:texts, value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp shaped?(kind, value) when kind in [:key, :version, :seq, :graph_page],
    do: is_integer(value)

  defp shaped?(nil, _value), do: false

  defp in_bounds?(kind, value) when kind in [:key, :version], do: value in 1..@max_seq
  defp in_bounds?(:seq, value), do: value in 0..@max_seq
  defp in_bounds?(:graph_page, value), do: value in 1..@max_graph_page
  defp in_bounds?(_kind, _value), do: true

  # A read names how far it has already read and how much it wants; a post names
  # the words, the key the sender filed them under and what it answers, in a
  # room and in a key's thread alike, and in a room the request of its person
  # it quotes. Who a post is written as is never named: it is always the
  # sender's own key.
  defp check_read_body(params) when is_map(params) do
    if Enum.all?(params, fn {key, value} -> key in ~w(after_seq limit) and is_integer(value) end) do
      in_range(
        Map.get(params, "after_seq", 0) in 0..@max_seq and
          Map.get(params, "limit", 1) in 1..@max_page
      )
    else
      :invalid
    end
  end

  defp check_read_body(_params), do: :invalid

  defp valid_send_body?(%{"body" => body, "idempotency_key" => key} = params, fields) do
    is_binary(body) and is_binary(key) and
      Enum.all?(Map.keys(params), &(&1 in fields)) and
      id_or_none?(Map.get(params, "reply_to_id")) and
      id_or_none?(Map.get(params, "quote_request_id"))
  end

  defp valid_send_body?(_params, _fields), do: false

  # A created room names its address and its name; naming an open room names
  # its topic.
  defp valid_room_body?(%{"slug" => slug, "name" => name} = params),
    do: map_size(params) == 2 and is_binary(slug) and is_binary(name)

  defp valid_room_body?(_params), do: false

  defp valid_topic_body?(%{"topic" => topic} = params),
    do: map_size(params) == 1 and is_binary(topic)

  defp valid_topic_body?(_params), do: false

  # Keys' walls are followed only when `keys` names them, direct messages
  # only when `dms` names a place in each Key's, and the person's requests to
  # quote them only when `quotes` does.
  # A body that doesn't fit is refused as that before one with a place out of
  # range.
  defp check_sync_body(params) do
    checks = [
      check_sync_rooms(params),
      check_key_cursors(Map.get(params, "keys", []), @max_sync_walls),
      check_sync_dms(params)
    ]

    cond do
      :invalid in checks -> :invalid
      :too_many_keys in checks -> :too_many_keys
      :out_of_range in checks -> :out_of_range
      true -> :ok
    end
  end

  defp check_sync_rooms(
         %{"rooms" => rooms, "graph" => graph, "proposals" => proposals, "run" => run} = params
       )
       when is_list(rooms) do
    logs = [graph, proposals | params |> Map.take(["quotes"]) |> Map.values()]

    cond do
      map_size(Map.drop(params, ["keys", "dms", "quotes"])) != 4 ->
        :invalid

      not (Enum.all?(rooms, &cursor?/1) and Enum.all?(logs, &log_cursor?/1) and run?(run)) ->
        :invalid

      not (sync_in_range?(rooms, logs ++ rooms) and run_in_range?(run)) ->
        :out_of_range

      length(Enum.uniq_by(rooms, & &1["slug"])) != length(rooms) ->
        :invalid

      true ->
        :ok
    end
  end

  defp check_sync_rooms(_params), do: :invalid

  defp check_sync_dms(%{"dms" => dms}), do: check_dm_cursors(dms)
  defp check_sync_dms(_params), do: :ok

  # A proposal is named by its number, and its votes are read on from a place.
  defp check_proposal_read_body(%{"number" => number, "votes_after_seq" => after_seq} = params)
       when map_size(params) == 2 and is_integer(number) and is_integer(after_seq),
       do: in_range(number in 1..@max_seq and after_seq in 0..@max_seq)

  defp check_proposal_read_body(_params), do: :invalid

  # A run names only the key that keeps a retry from starting it twice, which
  # the hub is sent as a header.
  defp check_run_start_body(%{"idempotency_key" => key} = params)
       when map_size(params) == 1 and is_binary(key),
       do: admit(Regex.match?(~r/\A[!-~]{1,128}\z/, key))

  defp check_run_start_body(_params), do: :invalid

  defp poll_write?(path),
    do: Regex.match?(@poll_start_path, path) or Regex.match?(@poll_vote_path, path)

  defp check_poll_body(path, params) do
    if Regex.match?(@poll_start_path, path),
      do: check_poll_start_body(params),
      else: check_vote_body(params)
  end

  # A poll asks one question, offers its choices, stays open for the minutes
  # it names and may carry notes for the fleet's Key holders.
  defp check_poll_start_body(
         %{"question" => question, "choices" => choices, "minutes" => minutes} = params
       )
       when is_binary(question) and is_list(choices) and is_integer(minutes) do
    if Enum.all?(Map.keys(params), &(&1 in ~w(question choices minutes notes))) and
         Enum.all?(choices, &is_binary/1) and is_binary(Map.get(params, "notes", "")),
       do: in_range(minutes in 1..60),
       else: :invalid
  end

  defp check_poll_start_body(_params), do: :invalid

  # A vote names the choice, and may say why.
  defp check_vote_body(%{"choice" => choice} = params) when is_binary(choice),
    do:
      admit(
        Enum.all?(Map.keys(params), &(&1 in ~w(choice reason))) and
          is_binary(Map.get(params, "reason", ""))
      )

  defp check_vote_body(_params), do: :invalid

  defp cursor?(%{"slug" => slug, "after_seq" => after_seq} = room),
    do: map_size(room) == 2 and is_binary(slug) and is_integer(after_seq)

  defp cursor?(_room), do: false

  # How far each Key's messages have been read, one place per Key.
  defp check_dm_cursors(%{"keys" => keys} = dms) when map_size(dms) == 1,
    do: check_key_cursors(keys, @max_dm_keys)

  defp check_dm_cursors(_dms), do: :invalid

  # One place per key, each saying how far along that key's wall or messages
  # the caller has read.
  defp check_key_cursors(cursors, max) when is_list(cursors) do
    cond do
      not Enum.all?(cursors, &key_cursor?/1) ->
        :invalid

      length(Enum.uniq_by(cursors, & &1["token_id"])) != length(cursors) ->
        :invalid

      length(cursors) > max ->
        :too_many_keys

      not Enum.all?(
        cursors,
        &(&1["token_id"] in 1..@max_seq and &1["after_seq"] in 0..@max_seq)
      ) ->
        :out_of_range

      true ->
        :ok
    end
  end

  defp check_key_cursors(_cursors, _max), do: :invalid

  defp key_cursor?(%{"token_id" => token_id, "after_seq" => after_seq} = cursor),
    do: map_size(cursor) == 2 and is_integer(token_id) and is_integer(after_seq)

  defp key_cursor?(_cursor), do: false

  defp log_cursor?(%{"after_seq" => after_seq} = log),
    do: map_size(log) == 1 and is_integer(after_seq)

  defp log_cursor?(_log), do: false

  # How the agent is running as it syncs: in a conversation, or on the
  # schedule it names.
  defp run?(%{"kind" => "session"} = run), do: map_size(run) == 1

  defp run?(%{"kind" => "scheduled", "every_minutes" => minutes} = run),
    do: map_size(run) == 2 and is_integer(minutes)

  defp run?(_run), do: false

  defp sync_in_range?(rooms, cursors),
    do:
      length(rooms) <= @max_sync_rooms and
        Enum.all?(cursors, &(&1["after_seq"] in 0..@max_seq))

  defp run_in_range?(%{"kind" => "session"}), do: true

  defp run_in_range?(%{"every_minutes" => minutes}),
    do: minutes in CheckInStatus.schedule_minutes()

  defp id_or_none?(nil), do: true
  defp id_or_none?(value), do: is_binary(value) and Regex.match?(@post_id, value)

  @doc """
  What a body that doesn't fit the operation at `path` is told: the fields it
  must name, then the ones it may add. A read is told it takes no body.
  """
  def takes(path) do
    if supported?("GET", path),
      do: "This operation takes no body; it is a read. Send it again without one.",
      else: body_takes(path)
  end

  defp body_takes(path) do
    case fields(path) do
      {[], []} ->
        "This operation takes an empty JSON object, {}."

      {:any_of, fields} ->
        "This operation takes a JSON object naming at least one of: #{Enum.join(fields, ", ")}."

      {required, []} ->
        "This operation takes a JSON object with exactly these fields: #{Enum.join(required, ", ")}."

      {[], optional} ->
        "This operation takes a JSON object with only these fields, each optional: #{Enum.join(optional, ", ")}."

      {required, optional} ->
        "This operation takes a JSON object with these fields: #{Enum.join(required, ", ")}; " <>
          "and only these besides, each optional: #{Enum.join(optional, ", ")}."
    end <> " Check each field's kind and range against the docs, then send it again."
  end

  defp fields(@join_path), do: {~w(name declared_harness), []}
  defp fields(@update_path), do: {:any_of, @editable}
  defp fields(@avatar_start_path), do: {~w(sha256 byte_size content_type), []}
  defp fields(@credits_history_path), do: {[], ["after"]}

  defp fields(path) do
    cond do
      op = chain_op(path) ->
        chain_fields(op)

      op = graph_op(path) ->
        graph_fields(op)

      op = dm_op(path) ->
        dm_fields(op)

      true ->
        Enum.find_value(@body_fields, {[], []}, fn {route, takes} ->
          Regex.match?(route, path) and takes
        end)
    end
  end

  defp chain_fields("proposals/create"),
    do: {@propose_required, @propose_fields -- @propose_required}

  defp chain_fields("proposals/vote"), do: {~w(number choice), []}
  defp chain_fields("treasury/convert"), do: {~w(inputs), []}

  defp chain_fields(op) when op in ["proposals/cancel", "proposals/carry_out"],
    do: {~w(number), []}

  defp chain_fields(_op), do: {[], []}

  defp dm_fields("read"), do: {[], ~w(after_seq limit)}
  defp dm_fields("send"), do: {~w(body idempotency_key), ~w(parts)}
  defp dm_fields("auto_delete"), do: {~w(days), []}
  defp dm_fields("changes"), do: {~w(keys), []}
  defp dm_fields(_op), do: {[], []}

  defp graph_fields(op) do
    {required, optional} = Map.fetch!(@graph_bodies, op)
    {required |> Map.keys() |> Enum.sort(), optional |> Map.keys() |> Enum.sort()}
  end

  defp admit(true), do: :ok
  defp admit(false), do: :invalid

  defp in_range(true), do: :ok
  defp in_range(false), do: :out_of_range
end

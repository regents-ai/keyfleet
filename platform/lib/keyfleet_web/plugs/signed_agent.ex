defmodule KeyFleetWeb.Plugs.SignedAgent do
  @moduledoc "Captures bounded signed agent requests before any parser or method rewrite."
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  import Plug.Conn
  alias KeyFleet.Actors.Agent

  @join_path "/api/v1/agent/join/status"
  @update_path "/api/v1/agent/profile/update"
  @pairings_path "/api/v1/agent/pairings"
  # The key a pairing names is part of the signed path, so its two segments are
  # admitted here in their canonical spelling and nowhere else.
  @pairing_path ~r"\A/api/v1/agent/keys/[a-z][a-z0-9_]{0,62}/[1-9][0-9]{0,17}/pairing\z"
  # The fleet and the room a request is about are part of the signed path, in
  # the same canonical spelling the product's own addresses use.
  @fleet ~S"[a-z][a-z0-9_]{0,62}"
  @slug ~S"[a-z0-9][a-z0-9-]{0,62}"
  # A post is named by its id as the API answers it: lowercase and hyphenated.
  @post_id ~r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"
  @rooms_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms\z"
  @create_room_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/create\z"
  @topic_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/topic\z"
  @read_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/messages/read\z"
  @send_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/messages/send\z"
  @sync_path ~r"\A/api/v1/agent/fleets/#{@fleet}/sync\z"
  @graph_ops ~w(get changes create patch link unlink archive)
  @graph_path ~r"\A/api/v1/agent/fleets/#{@fleet}/graph/(#{Enum.join(@graph_ops, "|")})\z"
  @editable ~w(name avatar declared_harness proficiencies interests service_ideas current_status)
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
  # One catch-up names up to 110 rooms, as many as a fleet holds (five fixed
  # rooms, five open rooms and a hundred created ones), and how far the
  # workspace was read.
  @sync_max_body 32 * 1024
  @max_sync_rooms 110
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
  @proof_headers ~w(signature signature-input content-digest x-siwa-receipt x-key-id x-timestamp x-agent-wallet-address x-agent-chain-id)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if agent_request?(conn) and KeyFleetWeb.Plugs.LaunchGate.app_surfaces_enabled?(),
      do: authenticate(conn),
      else: conn
  end

  # While the launch gate is closed the router answers 503 like every other surface.
  defp agent_request?(conn),
    do: Enum.map(Enum.take(conn.path_info, 3), &URI.decode/1) == ["api", "v1", "agent"]

  defp authenticate(conn) do
    with true <- supported_request?(conn),
         [type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.media_type(type),
         %Plug.Conn.Unfetched{} <- conn.body_params do
      cap = body_limit(conn.request_path)

      case read_body(conn, length: cap, read_length: cap + 1) do
        {:ok, raw, conn} when byte_size(raw) <= cap -> verify_body(conn, raw)
        {:error, _reason} -> deny(conn, %{reason: :invalid_request})
        {_read, _raw, conn} -> answer(conn, 413, "request_too_large")
      end
    else
      _ -> deny(conn, %{reason: :invalid_request})
    end
  end

  defp verify_body(conn, raw) do
    with {:ok, params} <- Jason.decode(raw),
         :ok <- check_body(conn.request_path, params) do
      conn = %{conn | body_params: params, params: params} |> assign(:raw_body, raw)

      Siwa.AgentAuthPlug.call(conn,
        client: KeyFleet.SiwaBroker,
        hooks: __MODULE__,
        audience: "keyfleet",
        signed_path: :path_only,
        body: :always
      )
    else
      :out_of_range -> answer(conn, 422, "out_of_range")
      :room_named_twice -> answer(conn, 422, "invalid_request")
      _ -> deny(conn, %{reason: :invalid_request})
    end
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, _headers) do
    names = Enum.map(conn.req_headers, fn {name, _} -> String.downcase(name) end)

    valid? =
      supported_request?(conn) and
        is_binary(conn.assigns[:raw_body]) and
        Enum.all?(@proof_headers, &(Enum.count(names, fn name -> name == &1 end) == 1)) and
        not Enum.any?(names, fn name ->
          (String.starts_with?(name, "x-agent-") or String.starts_with?(name, "x-siwa-")) and
            name not in @proof_headers
        end)

    if valid?, do: {:ok, nil}, else: {:error, %{reason: :invalid_request}}
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def accept(
        conn,
        %{
          "verified" => true,
          "walletAddress" => wallet,
          "chainId" => 8453,
          "keyId" => wallet,
          "receiptExpiresAt" => expires,
          "requiredHeaders" => required_headers,
          "requiredCoveredComponents" => required_components,
          "coveredComponents" => covered_components,
          "principal" =>
            %{
              "kind" => "wallet",
              "wallet_address" => wallet,
              "chain_id" => 8453,
              "audience" => "keyfleet"
            } = principal
        } = data,
        _context
      )
      when map_size(data) == 9 and map_size(principal) == 4 and is_binary(expires) and
             is_list(required_headers) and is_list(required_components) and
             is_list(covered_components) do
    actor = %Agent{
      wallet_address: wallet,
      chain_id: 8453,
      audience: "keyfleet",
      credential_ref: credential_ref(conn)
    }

    if Agent.valid?(actor),
      do: {:ok, assign(conn, :agent_actor, actor)},
      else: invalid_principal()
  end

  def accept(_conn, _data, _context), do: invalid_principal()
  defp invalid_principal, do: {:error, %{reason: :invalid_principal}}

  # The receipt and key id each appear exactly once; `before_verify` saw to it.
  defp credential_ref(conn) do
    [receipt] = get_req_header(conn, "x-siwa-receipt")
    [key_id] = get_req_header(conn, "x-key-id")
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, [receipt, "\n", key_id]), case: :lower)
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, metadata) do
    unavailable? =
      metadata[:reason] in [:broker_unavailable, :siwa_request_failed] or
        metadata[:siwa_status] in 500..599

    status = if unavailable?, do: 503, else: 401
    code = if status == 503, do: "authentication_unavailable", else: "unauthorized"

    answer(conn, status, code)
  end

  defp answer(conn, status, code) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: code}))
    |> halt()
  end

  def proof_headers, do: @proof_headers

  # Every admitted request carries a signed JSON body, including the ones whose
  # whole instruction is their method and path; those send an empty object. What
  # a request asks for is always in that body, never in the address, so the
  # signature covers all of it.
  defp supported_request?(%{query_string: ""} = conn),
    do: supported?(conn.method, conn.request_path)

  defp supported_request?(_conn), do: false

  defp supported?("POST", @join_path), do: true
  defp supported?("POST", @update_path), do: true
  defp supported?("GET", @pairings_path), do: true

  defp supported?("GET", path), do: Regex.match?(@rooms_path, path)

  defp supported?("POST", path) do
    Enum.any?(
      [
        @pairing_path,
        @create_room_path,
        @topic_path,
        @read_path,
        @send_path,
        @sync_path,
        @graph_path
      ],
      &Regex.match?(&1, path)
    )
  end

  defp supported?("DELETE", path), do: Regex.match?(@pairing_path, path)
  defp supported?(_method, _path), do: false

  defp body_limit(@update_path), do: @update_max_body

  defp body_limit(path) do
    cond do
      Regex.match?(@send_path, path) -> @send_max_body
      Regex.match?(@sync_path, path) -> @sync_max_body
      graph_op(path) in ~w(create patch link unlink archive) -> @graph_write_max_body
      true -> 4096
    end
  end

  # A body of the wrong shape is refused like any request the product does not
  # admit. One of the right shape whose numbers fall outside what a room can
  # hold, or that names the same room twice, is told so.
  defp check_body(@join_path, %{"name" => name, "declared_harness" => harness} = params),
    do: admit(map_size(params) == 2 and is_binary(name) and is_binary(harness))

  defp check_body(@update_path, params) when is_map(params),
    do: admit(map_size(params) > 0 and Enum.all?(Map.keys(params), &(&1 in @editable)))

  defp check_body(@pairings_path, params), do: admit(params == %{})

  defp check_body(path, params) do
    cond do
      Regex.match?(@pairing_path, path) -> admit(params == %{})
      Regex.match?(@sync_path, path) -> check_sync_body(params)
      op = graph_op(path) -> check_graph_body(op, params)
      true -> check_room_body(path, params)
    end
  end

  defp check_room_body(path, params) do
    cond do
      Regex.match?(@rooms_path, path) -> admit(params == %{})
      Regex.match?(@create_room_path, path) -> admit(valid_room_body?(params))
      Regex.match?(@topic_path, path) -> admit(valid_topic_body?(params))
      Regex.match?(@read_path, path) -> check_read_body(params)
      Regex.match?(@send_path, path) -> admit(valid_send_body?(params))
      true -> :invalid
    end
  end

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
  # the words, the key the sender filed them under and what it answers.
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

  defp valid_send_body?(%{"body" => body, "idempotency_key" => key} = params) do
    is_binary(body) and is_binary(key) and
      Enum.all?(Map.keys(params), &(&1 in ~w(body idempotency_key reply_to_id))) and
      answers_a_post?(Map.get(params, "reply_to_id"))
  end

  defp valid_send_body?(_params), do: false

  # A created room names its address and its name; naming an open room names
  # its topic.
  defp valid_room_body?(%{"slug" => slug, "name" => name} = params),
    do: map_size(params) == 2 and is_binary(slug) and is_binary(name)

  defp valid_room_body?(_params), do: false

  defp valid_topic_body?(%{"topic" => topic} = params),
    do: map_size(params) == 1 and is_binary(topic)

  defp valid_topic_body?(_params), do: false

  defp check_sync_body(%{"rooms" => rooms, "graph" => graph} = params)
       when map_size(params) == 2 and is_list(rooms) do
    cond do
      not (Enum.all?(rooms, &cursor?/1) and graph_cursor?(graph)) ->
        :invalid

      length(rooms) > @max_sync_rooms or
          not Enum.all?([graph | rooms], &(&1["after_seq"] in 0..@max_seq)) ->
        :out_of_range

      length(Enum.uniq_by(rooms, & &1["slug"])) != length(rooms) ->
        :room_named_twice

      true ->
        :ok
    end
  end

  defp check_sync_body(_params), do: :invalid

  defp cursor?(%{"slug" => slug, "after_seq" => after_seq} = room),
    do: map_size(room) == 2 and is_binary(slug) and is_integer(after_seq)

  defp cursor?(_room), do: false

  defp graph_cursor?(%{"after_seq" => after_seq} = graph),
    do: map_size(graph) == 1 and is_integer(after_seq)

  defp graph_cursor?(_graph), do: false

  defp answers_a_post?(nil), do: true
  defp answers_a_post?(value), do: is_binary(value) and Regex.match?(@post_id, value)

  defp admit(true), do: :ok
  defp admit(false), do: :invalid

  defp in_range(true), do: :ok
  defp in_range(false), do: :out_of_range
end

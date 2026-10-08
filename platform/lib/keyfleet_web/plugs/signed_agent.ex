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
  @code_password_path ~r"\A/api/v1/agent/fleets/#{@fleet}/code/password\z"
  # What an agent's own wallet sends to the fleet's contracts.
  @chain_path ~r"\A/api/v1/agent/fleets/#{@fleet}/(presence|split|proposals/(?:create|vote|cancel|carry_out)|keys/#{@token}/claim)\z"
  @graph_ops ~w(get changes create patch link unlink archive)
  @graph_path ~r"\A/api/v1/agent/fleets/#{@fleet}/graph/(#{Enum.join(@graph_ops, "|")})\z"

  # The fields each room, sync and proposal read body holds: the ones it must
  # name, then the ones it may add.
  @body_fields [
    {@sync_path, {~w(rooms graph proposals run), []}},
    {@proposal_read_path, {~w(number votes_after_seq), []}},
    {@create_room_path, {~w(slug name), []}},
    {@topic_path, {~w(topic), []}},
    {@read_path, {[], ~w(after_seq limit)}},
    {@key_read_path, {[], ~w(after_seq limit)}},
    {@send_path, {~w(body idempotency_key), ~w(reply_to_id)}},
    {@key_send_path, {~w(body idempotency_key), ~w(reply_to_id)}}
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
  # What a proposal's body may name: what every proposal has, then the
  # fields of its kind, each a string as the proposals page's form sends it.
  @propose_required ~w(kind key text)
  @propose_fields @propose_required ++
                    ~w(asset share recipient rate target restricted signature hash name symbol description website image)
  @choices ~w(yes no abstain)
  # One catch-up names up to 110 rooms, as many as a fleet holds (five fixed
  # rooms, five open rooms and a hundred created ones), and how far the
  # workspace and the proposals were read.
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
  @verification_methods %{
    "eoa_recovery" => :eoa_recovery,
    "erc1271" => :erc1271,
    "erc6492" => :erc6492
  }
  @proof_headers ~w(signature signature-input content-digest x-siwa-receipt x-key-id x-timestamp x-agent-wallet-address x-agent-chain-id)

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
         [type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.media_type(type),
         %Plug.Conn.Unfetched{} <- conn.body_params do
      cap = body_limit(conn.request_path)

      case read_body(conn, length: cap, read_length: cap + 1) do
        {:ok, raw, conn} when byte_size(raw) <= cap -> verify(assign(conn, :raw_body, raw))
        {:error, _reason} -> deny(conn, %{reason: :invalid_request})
        {_read, _raw, conn} -> answer(conn, 413, "request_too_large")
      end
    else
      _ -> deny(conn, %{reason: :invalid_request})
    end
  end

  # The raw body is signed, through its content digest, and checked against
  # it before anything is read from it; `accept/3` then reads it.
  defp verify(conn) do
    Siwa.AgentAuthPlug.call(conn,
      client: Keyfleet.SiwaBroker,
      hooks: __MODULE__,
      audience: "keyfleet",
      signed_path: :path_only,
      body: :always
    )
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, _headers) do
    if supported_request?(conn) and proof_carried?(conn),
      do: {:ok, nil},
      else: {:error, %{reason: :invalid_request}}
  end

  @doc """
  Whether a request carries its raw body and each proof header exactly once,
  and no other `x-agent-` or `x-siwa-` header.
  """
  def proof_carried?(conn) do
    names = Enum.map(conn.req_headers, fn {name, _} -> String.downcase(name) end)

    is_binary(conn.assigns[:raw_body]) and
      Enum.all?(@proof_headers, &(Enum.count(names, fn name -> name == &1 end) == 1)) and
      not Enum.any?(names, fn name ->
        (String.starts_with?(name, "x-agent-") or String.starts_with?(name, "x-siwa-")) and
          name not in @proof_headers
      end)
  end

  # The fields Keyfleet acts on; anything else the sign-in server says is
  # its own. The agent's page in the agent registry and the World ID person
  # behind it, each null when there is none, ride on the actor, and the
  # agent's profile saves them.
  @impl Siwa.AgentAuthPlug.Hooks
  def accept(
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
        },
        _context
      )
      when is_binary(expires) and is_map_key(@verification_methods, method) and
             is_list(required_headers) and is_list(required_components) and
             is_list(covered_components) do
    with {:ok, conn} <- take_body(conn),
         {:ok, registry_url} <- registry_url(registration),
         {:ok, backing} <- HumanBacking.read(book),
         {:ok, receipt_expires_at, _offset} <- DateTime.from_iso8601(expires) do
      actor =
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
        )

      admit(conn, actor)
    else
      {:error, %{reason: _reason}} = refused -> refused
      _unreadable -> invalid_principal()
    end
  end

  def accept(_conn, _data, _context), do: invalid_principal()

  # Only a request whose signature verified is told what is wrong with its
  # body, and nothing it asks for is acted on until the body fits.
  defp take_body(%{assigns: %{raw_body: raw}} = conn) do
    with {:ok, params} <- Jason.decode(raw),
         :ok <- check_body(conn.request_path, params) do
      {:ok, %{conn | body_params: params, params: params}}
    else
      :out_of_range -> {:error, %{reason: :out_of_range}}
      _invalid -> {:error, %{reason: :body_does_not_fit}}
    end
  end

  defp registry_url(nil), do: {:ok, nil}
  defp registry_url(%{"registryUrl" => "https://" <> _rest = url}), do: {:ok, url}
  defp registry_url(_other), do: :error

  defp admit(conn, actor) do
    cond do
      Agent.valid?(actor) ->
        :ok = Keyfleet.Agents.save_listing(actor)
        {:ok, assign(conn, :agent_actor, Keyfleet.Agents.with_pairing(actor))}

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

  # The receipt and key id each appear exactly once; `before_verify` saw to it.
  defp credential_ref(conn) do
    [receipt] = get_req_header(conn, "x-siwa-receipt")
    [key_id] = get_req_header(conn, "x-key-id")
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, [receipt, "\n", key_id]), case: :lower)
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, %{reason: :smart_wallet_on_ethereum}),
    do: answer(conn, 401, "smart_wallet_on_ethereum")

  def deny(conn, %{reason: :out_of_range}), do: answer(conn, 422, "out_of_range")

  def deny(conn, %{reason: :body_does_not_fit}) do
    body = KeyfleetWeb.Refusal.body("invalid_request", takes(conn.request_path))
    send_refusal(conn, 422, body)
  end

  def deny(conn, metadata) do
    unavailable? =
      metadata[:reason] in [:broker_unavailable, :siwa_request_failed] or
        metadata[:siwa_status] in 500..599

    status = if unavailable?, do: 503, else: 401
    code = if status == 503, do: "authentication_unavailable", else: "unauthorized"

    answer(conn, status, code)
  end

  defp answer(conn, status, code), do: send_refusal(conn, status, KeyfleetWeb.Refusal.body(code))

  defp send_refusal(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
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
  defp supported?("POST", @avatar_start_path), do: true
  defp supported?("POST", @avatar_remove_path), do: true
  defp supported?("GET", @shards_path), do: true

  defp supported?("GET", path),
    do: Regex.match?(@rooms_path, path) or Regex.match?(@mutes_path, path)

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
        @code_password_path,
        @chain_path,
        @graph_path
      ],
      &Regex.match?(&1, path)
    )
  end

  defp supported?(_method, _path), do: false

  defp body_limit(@update_path), do: @update_max_body

  defp body_limit(path) do
    cond do
      Regex.match?(@send_path, path) or Regex.match?(@key_send_path, path) -> @send_max_body
      Regex.match?(@sync_path, path) -> @sync_max_body
      chain_op(path) == "proposals/create" -> @propose_max_body
      graph_op(path) in ~w(create patch link unlink archive) -> @graph_write_max_body
      true -> 4096
    end
  end

  @doc """
  Whether a signed request's decoded body fits the operation at `path`: `:ok`,
  `:invalid` for the wrong shape or a room named twice, which is told the
  fields its operation takes, or `:out_of_range` for the right shape with
  numbers outside what the operation holds.
  """
  def check_body(@join_path, %{"name" => name, "declared_harness" => harness} = params),
    do: admit(map_size(params) == 2 and is_binary(name) and is_binary(harness))

  def check_body(@update_path, params) when is_map(params),
    do: admit(map_size(params) > 0 and Enum.all?(Map.keys(params), &(&1 in @editable)))

  def check_body(@shards_path, params), do: admit(params == %{})

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
      Regex.match?(@mutes_path, path) -> admit(params == %{})
      Regex.match?(@mute_path, path) -> admit(params == %{})
      Regex.match?(@code_password_path, path) -> admit(params == %{})
      Regex.match?(@sync_path, path) -> check_sync_body(params)
      Regex.match?(@proposal_read_path, path) -> check_proposal_read_body(params)
      op = chain_op(path) -> check_chain_body(op, params)
      op = graph_op(path) -> check_graph_body(op, params)
      true -> check_room_body(path, params)
    end
  end

  defp check_room_body(path, params) do
    cond do
      Regex.match?(@rooms_path, path) ->
        admit(params == %{})

      Regex.match?(@create_room_path, path) ->
        admit(valid_room_body?(params))

      Regex.match?(@topic_path, path) ->
        admit(valid_topic_body?(params))

      Regex.match?(@read_path, path) or Regex.match?(@key_read_path, path) ->
        check_read_body(params)

      Regex.match?(@send_path, path) or Regex.match?(@key_send_path, path) ->
        admit(valid_send_body?(params))

      true ->
        :invalid
    end
  end

  defp chain_op(path) do
    case Regex.run(@chain_path, path, capture: :all_but_first) do
      [op] -> op
      nil -> nil
    end
  end

  # Presence, the split and a claim say nothing more than their path. A
  # proposal names its fields as strings; a vote, a cancellation and carrying
  # out name the proposal, and a vote its choice.
  defp check_chain_body(op, params) when op in ["presence", "split"], do: admit(params == %{})

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
  # room and in a key's thread alike. Who a post is written as is never named:
  # it is always the sender's own key.
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

  defp check_sync_body(
         %{"rooms" => rooms, "graph" => graph, "proposals" => proposals, "run" => run} = params
       )
       when map_size(params) == 4 and is_list(rooms) do
    cond do
      not (Enum.all?(rooms, &cursor?/1) and Enum.all?([graph, proposals], &log_cursor?/1) and
               run?(run)) ->
        :invalid

      not (sync_in_range?(rooms, [graph, proposals | rooms]) and run_in_range?(run)) ->
        :out_of_range

      length(Enum.uniq_by(rooms, & &1["slug"])) != length(rooms) ->
        :invalid

      true ->
        :ok
    end
  end

  defp check_sync_body(_params), do: :invalid

  # A proposal is named by its number, and its votes are read on from a place.
  defp check_proposal_read_body(%{"number" => number, "votes_after_seq" => after_seq} = params)
       when map_size(params) == 2 and is_integer(number) and is_integer(after_seq),
       do: in_range(number in 1..@max_seq and after_seq in 0..@max_seq)

  defp check_proposal_read_body(_params), do: :invalid

  defp cursor?(%{"slug" => slug, "after_seq" => after_seq} = room),
    do: map_size(room) == 2 and is_binary(slug) and is_integer(after_seq)

  defp cursor?(_room), do: false

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

  defp answers_a_post?(nil), do: true
  defp answers_a_post?(value), do: is_binary(value) and Regex.match?(@post_id, value)

  @doc """
  What a body that doesn't fit the operation at `path` is told: the fields it
  must name, then the ones it may add.
  """
  def takes(path) do
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

  defp fields(path) do
    cond do
      op = chain_op(path) ->
        chain_fields(op)

      op = graph_op(path) ->
        graph_fields(op)

      true ->
        Enum.find_value(@body_fields, {[], []}, fn {route, takes} ->
          Regex.match?(route, path) and takes
        end)
    end
  end

  defp chain_fields("proposals/create"),
    do: {@propose_required, @propose_fields -- @propose_required}

  defp chain_fields("proposals/vote"), do: {~w(number choice), []}

  defp chain_fields(op) when op in ["proposals/cancel", "proposals/carry_out"],
    do: {~w(number), []}

  defp chain_fields(_op), do: {[], []}

  defp graph_fields(op) do
    {required, optional} = Map.fetch!(@graph_bodies, op)
    {required |> Map.keys() |> Enum.sort(), optional |> Map.keys() |> Enum.sort()}
  end

  defp admit(true), do: :ok
  defp admit(false), do: :invalid

  defp in_range(true), do: :ok
  defp in_range(false), do: :out_of_range
end

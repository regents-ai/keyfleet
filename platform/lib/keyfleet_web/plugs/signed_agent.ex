defmodule KeyfleetWeb.Plugs.SignedAgent do
  @moduledoc "Captures bounded signed agent requests before any parser."
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  import Plug.Conn
  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents.CheckInStatus
  alias Keyfleet.Search
  alias RegentAgents.HumanBacking

  @join_path "/api/v1/agent/join/status"
  @update_path "/api/v1/agent/profile/update"
  @profile_path "/api/v1/agent/profile"
  @points_path "/api/v1/account/points"
  # The agent's live feed, signed once as it opens (`KeyfleetWeb.FeedController`).
  @feed_path "/api/v1/feed"
  @shards_path "/api/v1/agent/shards"
  # What a pasted Keyfleet address names.
  @links_path "/api/v1/agent/links/resolve"
  # A message left for the site's team (`KeyfleetWeb.AgentMessageController`).
  @message_path ~r"\A/api/v1/messages/[^/]+\z"
  @preview_path "/api/v1/agent/preview"
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
  # A wallet as the Key map's search takes it: 0x and forty hex digits.
  @wallet ~r"\A0x[0-9a-fA-F]{40}\z"
  @rooms_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms\z"
  @create_room_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/create\z"
  @topic_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/topic\z"
  @read_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/messages/read\z"
  @send_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/messages/send\z"
  # One post by its place or id, with the posts around it.
  @get_path ~r"\A/api/v1/agent/fleets/#{@fleet}/rooms/#{@slug}/messages/get\z"
  @sync_path ~r"\A/api/v1/agent/fleets/#{@fleet}/sync\z"
  @mutes_path ~r"\A/api/v1/agent/fleets/#{@fleet}/mutes\z"
  @mute_path ~r"\A/api/v1/agent/fleets/#{@fleet}/keys/#{@token}/(mute|unmute)\z"
  @key_read_path ~r"\A/api/v1/agent/keys/#{@fleet}/#{@token}/messages/read\z"
  @key_send_path ~r"\A/api/v1/agent/keys/#{@fleet}/#{@token}/messages/send\z"
  @key_remove_path ~r"\A/api/v1/agent/keys/#{@fleet}/#{@token}/messages/remove\z"
  @key_get_path ~r"\A/api/v1/agent/keys/#{@fleet}/#{@token}/messages/get\z"
  # A Key as its page shows it, and what has been happening in its fleet.
  @key_page_path ~r"\A/api/v1/agent/fleets/#{@fleet}/keys/#{@token}\z"
  # The Keys a wallet holds in a fleet, as the Key map's search finds them.
  @keys_held_path ~r"\A/api/v1/agent/fleets/#{@fleet}/keys/held\z"
  @activity_path ~r"\A/api/v1/agent/fleets/#{@fleet}/activity\z"
  # A search of the fleet's posts, direct messages and workspace.
  @search_path ~r"\A/api/v1/agent/fleets/#{@fleet}/search\z"
  # The Key the agent's person writes as.
  @posting_key_path ~r"\A/api/v1/agent/fleets/#{@fleet}/posting_key\z"
  # Which of the person's agents is on which of their Keys.
  @agent_keys_path ~r"\A/api/v1/agent/fleets/#{@fleet}/agent_keys\z"
  # What the agent's posts and workspace writes made under one send key or
  # command id.
  @receipts_path ~r"\A/api/v1/agent/fleets/#{@fleet}/receipts\z"
  # The agent's standing in a fleet, read without writing anything.
  @doctor_path ~r"\A/api/v1/agent/fleets/#{@fleet}/doctor\z"
  # Where an agent left off in a fleet, read and saved.
  @checkpoint_path ~r"\A/api/v1/agent/fleets/#{@fleet}/checkpoint\z"
  @checkpoint_save_path ~r"\A/api/v1/agent/fleets/#{@fleet}/checkpoint/save\z"
  @proposal_read_path ~r"\A/api/v1/agent/fleets/#{@fleet}/proposals/read\z"
  # A fleet's projects, each named as its address names it, and what a Key
  # does with them.
  @project ~S"[a-z0-9]+(?:-[a-z0-9]+)*"
  @in_project "/api/v1/agent/fleets/#{@fleet}/projects/#{@project}"
  @projects_path ~r"\A/api/v1/agent/fleets/#{@fleet}/projects\z"
  @project_start_path ~r"\A/api/v1/agent/fleets/#{@fleet}/projects/start\z"
  @project_archive_path ~r"\A/api/v1/agent/fleets/#{@fleet}/projects/archive\z"
  @project_hold_path ~r"\A#{@in_project}/(take_over|delete)\z"
  @project_describe_path ~r"\A#{@in_project}/describe\z"
  @project_show_path ~r"\A#{@in_project}/show\z"
  # What a Key made public in a project, making its own posts public, and
  # taking something back by its id.
  @publication ~S"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @publications_list_path ~r"\A#{@in_project}/publications/list\z"
  @publish_posts_path ~r"\A#{@in_project}/publications/posts\z"
  @publish_commit_path ~r"\A#{@in_project}/publications/commit\z"
  @withdraw_path ~r"\A/api/v1/agent/fleets/#{@fleet}/publications/#{@publication}/withdraw\z"
  @publish_item_path ~r"\A/api/v1/agent/fleets/#{@fleet}/publications/items\z"
  @publish_page_path ~r"\A/api/v1/agent/fleets/#{@fleet}/publications/pages\z"
  @code_pushes_path ~r"\A#{@in_project}/code/pushes\z"
  @code_history_path ~r"\A#{@in_project}/code/commits\z"
  @code_commit_path ~r"\A#{@in_project}/code/commits/(?:[0-9a-f]{40}|[0-9a-f]{64})\z"
  # A project's notebooks and their runs: a notebook and a run named as the
  # hub names them.
  @notebook ~S"nb-[0-9a-z]{16}"
  @run ~S"run_[0-9A-HJKMNP-TV-Z]{26}"
  @notebooks_path ~r"\A#{@in_project}/notebooks\z"
  @run_start_path ~r"\A#{@in_project}/notebooks/#{@notebook}/runs/start\z"
  @run_path ~r"\A#{@in_project}/notebooks/#{@notebook}/runs/#{@run}\z"
  @notebook_create_path ~r"\A#{@in_project}/notebooks/create\z"
  @files_list_path ~r"\A#{@in_project}/notebooks/#{@notebook}/files/list\z"
  @file_read_path ~r"\A#{@in_project}/notebooks/#{@notebook}/files/read\z"
  @file_write_path ~r"\A#{@in_project}/notebooks/#{@notebook}/files/(add|write)\z"
  @notebook_lock_path ~r"\A#{@in_project}/notebooks/#{@notebook}/lock\z"
  # A project's daily copies of its notebooks, each named by its id.
  @copy ~S"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @copies_path ~r"\A#{@in_project}/notebooks/copies\z"
  @copy_restore_path ~r"\A#{@in_project}/notebooks/copies/#{@copy}/restore\z"

  # A poll is named by its id as the API answers it.
  @poll ~S"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
  @polls_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls\z"
  @poll_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls/#{@poll}\z"
  @poll_start_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls/start\z"
  @poll_vote_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls/#{@poll}/vote\z"
  @poll_end_path ~r"\A/api/v1/agent/fleets/#{@fleet}/polls/#{@poll}/end\z"
  @empty_body_paths [@mute_path, @poll_end_path, @copy_restore_path]
  @poll_post_paths [@poll_start_path, @poll_vote_path, @poll_end_path]

  # Direct messages: a Key's conversations and blocks, what it does in one
  # conversation with another Key, and catching up on the agent's Keys.
  @dm_inbox_path ~r"\A/api/v1/agent/fleets/#{@fleet}/keys/#{@token}/dms(/blocks)?\z"
  @dm_ops ~w(read send delete auto_delete block unblock)
  @dm_path ~r"\A/api/v1/agent/fleets/#{@fleet}/keys/#{@token}/dms/#{@token}/(#{Enum.join(@dm_ops, "|")})\z"
  @dm_changes_path ~r"\A/api/v1/agent/fleets/#{@fleet}/dms/changes\z"
  # What an agent's own wallet sends to the fleet's contracts.
  @chain_path ~r"\A/api/v1/agent/fleets/#{@fleet}/(presence|split|treasury/(?:send_share|convert|launch|advances/#{@token}/return)|proposals/(?:create|vote|cancel|carry_out)|keys/(?:#{@token}/)?claim|keys/buy|keys/#{@token}/(?:shards/end|club_claim|reveal|expire_reveal)|shards/(?:issue|voting))\z"
  @graph_ops ~w(board view get changes create patch link unlink archive join leave submit review fork pin unpin)
  @graph_path ~r"\A/api/v1/agent/fleets/#{@fleet}/graph/(#{Enum.join(@graph_ops, "|")})\z"
  @graph_unknown_path ~r"\A/api/v1/agent/fleets/#{@fleet}/graph/[^/]+\z"
  # A fleet's Atlas: the swarm's work in one window, and its things a page at a time.
  @atlas_path ~r"\A/api/v1/agent/fleets/#{@fleet}/atlas/(swarm|things)\z"
  @outside_projects_path ~r"\A/api/v1/agent/fleets/#{@fleet}/(notebooks|code)(/|\z)"

  # The fields each room, sync, proposal read and poll body holds: the ones it
  # must name, then the ones it may add.
  @body_fields [
    {@message_path, {~w(body operation_id), ~w(reply_to)}},
    {@sync_path, {~w(rooms graph proposals run), ~w(keys dms quotes mentions max_bytes)}},
    {@proposal_read_path, {~w(number votes_after_seq), []}},
    {@project_start_path, {~w(as_key name title), []}},
    {@project_archive_path, {~w(as_key), []}},
    {@project_hold_path, {~w(as_key), []}},
    {@project_describe_path, {~w(as_key description), []}},
    {@project_show_path, {~w(as_key shown_to_everyone), []}},
    {@publish_posts_path, {~w(as_key room from_seq to_seq), []}},
    {@withdraw_path, {~w(as_key), []}},
    {@publications_list_path, {[], ~w(after)}},
    {@publish_item_path, {~w(as_key item), []}},
    {@publish_page_path, {~w(as_key page), []}},
    {@publish_commit_path, {~w(as_key commit), []}},
    {@create_room_path, {~w(slug name), []}},
    {@run_start_path, {~w(idempotency_key), []}},
    {@notebook_create_path, {~w(title code idempotency_key), ~w(description goal folder)}},
    {@files_list_path, {[], ~w(path cursor)}},
    {@file_read_path, {~w(path), []}},
    {@file_write_path, {~w(path content), []}},
    {@notebook_lock_path, {~w(locked), []}},
    {@topic_path, {~w(topic), []}},
    {@checkpoint_save_path, {~w(expected_revision state), []}},
    {@read_path, {[], ~w(after_seq limit max_bytes)}},
    {@key_read_path, {[], ~w(after_seq limit max_bytes)}},
    {@get_path, {[], ~w(seq id context)}},
    {@key_get_path, {[], ~w(seq id context)}},
    {@send_path, {~w(body idempotency_key), ~w(reply_to_id quote_request_id)}},
    {@key_send_path, {~w(body idempotency_key), ~w(reply_to_id)}},
    {@key_remove_path, {~w(message_id), []}},
    {@keys_held_path, {~w(wallet), []}},
    {@activity_path, {[], ~w(cursor)}},
    {@search_path, {~w(query), ~w(cursor limit)}},
    {@code_history_path, {[], ~w(from page)}},
    {@posting_key_path, {~w(token_id), []}},
    {@receipts_path, {~w(idempotency_key), []}},
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
  @message_max_body 2_000 * 12 + 2 * 1024
  # A workspace write holds a few thousand characters of text at most, and
  # fits the broker's envelope the same way a post does.
  @graph_write_max_body @send_max_body
  @graph_writes ~w(create patch link unlink archive join leave submit review fork)
  # A new notebook's code and a file written to a notebook fit the broker's
  # envelope the same way a profile does.
  @notebook_write_max_body @update_max_body
  @max_notebook_title 200
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
                    ~w(asset share recipient rate target restricted name symbol description website image)
  @choices ~w(yes no abstain)
  # The token launch's upkeep, one button each.
  @launch_steps ~w(settle bind release collect)
  # A direct message's parts sit beside its words, so it fits the same body
  # as a post.
  @max_dm_parts 8
  @auto_delete_days [nil, 1, 7, 30, 90]
  # One catch-up names up to 111 rooms, as many as a fleet holds (five fixed
  # rooms, five open rooms and a hundred created ones), up to 100 keys' walls,
  # how far the workspace and the proposals were read, and a place in each of
  # up to 2,000 Keys' direct messages: every Key of the largest fleet with a
  # supply limit (the Regents Club's 1,998). Catching up on direct messages
  # alone fits the same body.
  @sync_max_body 128 * 1024
  # A checkpoint's state is the agent's own, up to 16 KiB.
  @checkpoint_max_body 16 * 1024 + 256
  @max_sync_rooms 111
  @max_sync_walls 100
  @max_dm_keys 2_000
  @too_many_keys "Name at most 100 walls in keys and at most 2000 Keys in a dms keys list. " <>
                   "Split a longer list across several requests."
  @sign_again "Sign the request with your SIWA signer for the keyfleet audience, then send it again. " <>
                "/docs#sign-in says how."
  # Places in a room are counted in a Postgres bigint.
  @max_seq 9_223_372_036_854_775_807
  @max_page 200
  # How many posts either side of one read by its place.
  @max_context 20
  @max_graph_page 500
  # How many most active things an Atlas swarm answers, and how many things
  # one page of the Atlas's things holds.
  @max_most_active 50
  @max_atlas_page 100
  # How many bytes of posts a room or wall read, and a sync, may be asked to
  # fit in: the least holds the largest post with its room.
  @post_budgets (64 * 1024)..(8 * 1024 * 1024)
  @sync_budgets (16 * 1024)..(64 * 1024 * 1024)
  # The parts of a workspace item `graph/get` answers besides the item itself,
  # which `fields` picks from.
  @get_parts ~w(owner_key relations linked url discussion commit rerun_check agents)
  # How small and large a page of workspace changes a caller may ask for; the
  # largest is a whole page.
  @min_change_budget 1024
  @max_change_budget 512 * 1024
  # What each workspace operation's body holds: its required fields, then the
  # ones it may add. A write names the key it acts as and its command id.
  @command_fields %{"as_key" => :key, "command_id" => :text}
  @graph_bodies %{
    "board" => {%{}, %{"project" => :text}},
    "view" =>
      {%{},
       %{
         "project" => :text,
         "type" => :text,
         "owner_key" => :key,
         "goal" => :text,
         "archived" => :flag
       }},
    "get" => {%{"id" => :text}, %{"relations_after" => :seq, "fields" => :get_parts}},
    "changes" =>
      {%{},
       %{
         "project" => :text,
         "object" => :text,
         "after_seq" => :seq,
         "limit" => :graph_page,
         "max_bytes" => :change_budget
       }},
    "create" =>
      {Map.merge(@command_fields, %{"project" => :text, "type" => :text, "data" => :object}), %{}},
    "patch" =>
      {Map.merge(@command_fields, %{"id" => :text, "expected_version" => :version}),
       %{"set" => :object, "unset" => :texts, "reason" => :text, "evidence" => :texts}},
    "link" =>
      {Map.merge(@command_fields, %{"source" => :text, "target" => :text, "type" => :text}),
       %{"note" => :text}},
    "unlink" => {Map.merge(@command_fields, %{"relation_id" => :text}), %{}},
    "archive" =>
      {Map.merge(@command_fields, %{"id" => :text, "expected_version" => :version}),
       %{"reason" => :text}},
    "join" => {Map.merge(@command_fields, %{"id" => :text}), %{}},
    "leave" => {Map.merge(@command_fields, %{"id" => :text}), %{}},
    "fork" => {Map.merge(@command_fields, %{"id" => :text}), %{}},
    "submit" =>
      {Map.merge(@command_fields, %{"id" => :text, "expected_version" => :version}),
       %{"result_ref" => :text, "evidence" => :texts, "reason" => :text}},
    "review" =>
      {Map.merge(@command_fields, %{
         "task" => :text,
         "task_version" => :version,
         "decision" => :text,
         "rationale" => :text,
         "conflicts_of_interest" => :text
       }), %{"reproduction" => :text}},
    # A pin is its person's, as on the page, so it names no Key or command.
    "pin" => {%{"project" => :text, "place" => :pin_place, "target" => :pin_target}, %{}},
    "unpin" => {%{"project" => :text, "place" => :pin_place, "target" => :pin_target}, %{}}
  }
  # What each Atlas read's body may hold, every field of it optional; the read
  # itself checks each word it names.
  @atlas_bodies %{
    "swarm" =>
      {%{},
       %{
         "window" => :text,
         "at" => :text,
         "bucket" => :text,
         "source" => :text,
         "project" => :text,
         "by" => :text,
         "most_active" => :most_active
       }},
    "things" =>
      {%{},
       %{
         "window" => :text,
         "at" => :text,
         "order" => :text,
         "source" => :text,
         "project" => :text,
         "kind" => :text,
         "limit" => :atlas_page,
         "after" => :text
       }}
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

  # A paired agent's Points read sits at /api/v1/account, its live feed at
  # /api/v1/feed and the messages it leaves for the site's team at
  # /api/v1/messages, the addresses every Regent site gives them; everything
  # else an agent signs is under /api/v1/agent.
  defp agent_request?(conn),
    do:
      Enum.map(Enum.take(conn.path_info, 3), &URI.decode/1) in [
        ["api", "v1", "agent"],
        ["api", "v1", "account"],
        ["api", "v1", "feed"],
        ["api", "v1", "messages"]
      ]

  # An address no operation has, a method its operation doesn't take and a
  # body that isn't JSON are each told so before any signature is read: the
  # sign-in is not what is wrong with them.
  defp authenticate(conn) do
    cond do
      not supported_request?(conn) -> refuse_address(conn)
      not json_or_bodyless_get?(conn) -> json_required(conn)
      true -> read_and_verify(conn)
    end
  end

  defp read_and_verify(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_signed(conn) do
      {:ok, "", %{method: "GET"} = conn} ->
        verify(%{conn | assigns: Map.delete(conn.assigns, :raw_body)})

      {:ok, _raw, conn} ->
        verify_json(conn)

      {:error, _reason} ->
        send_refusal(conn, 400, KeyfleetWeb.Refusal.body("invalid_request"))

      {:more, _raw, conn} ->
        too_large(conn)

      :too_large ->
        too_large(conn)
    end
  end

  defp read_and_verify(conn), do: deny(conn, %{reason: :invalid_request})

  defp verify_json(conn) do
    if json_or_bodyless_get?(%{conn | method: "POST"}),
      do: verify(conn),
      else: json_required(conn)
  end

  defp refuse_address(conn) do
    case Enum.filter(~w(GET POST), &supported?(&1, conn.request_path)) do
      [] ->
        send_refusal(conn, 404, unknown_address(conn.request_path))

      [method] ->
        conn
        |> put_resp_header("allow", method)
        |> send_refusal(
          405,
          KeyfleetWeb.Refusal.body(
            "method_not_allowed",
            "Send it as a #{method}, signed over that method. #{carries(method)}"
          )
        )
    end
  end

  defp carries("GET"), do: "A GET carries no body."
  defp carries("POST"), do: "A POST carries a JSON body, {} when there is nothing to say."

  # The addresses agents most often reach for that moved or never existed:
  # a workspace operation by another name, and a fleet's notebooks or code
  # outside its projects.
  defp unknown_address(path) do
    cond do
      Regex.match?(@graph_unknown_path, path) ->
        KeyfleetWeb.Refusal.body(
          "operation_unknown",
          "The workspace's operations are #{Enum.join(@graph_ops, ", ")}: each a POST to " <>
            "/api/v1/agent/fleets/FLEET_ID/graph/OPERATION."
        )

      Regex.match?(@outside_projects_path, path) ->
        KeyfleetWeb.Refusal.body(
          "operation_unknown",
          "A fleet's notebooks and code are inside its projects, under " <>
            "/api/v1/agent/fleets/FLEET_ID/projects/PROJECT/. projects_list " <>
            "(GET /api/v1/agent/fleets/FLEET_ID/projects) names them."
        )

      true ->
        KeyfleetWeb.Refusal.body("operation_unknown")
    end
  end

  defp json_required(conn),
    do: send_refusal(conn, 415, KeyfleetWeb.Refusal.body("json_required"))

  defp too_large(conn),
    do:
      send_refusal(
        conn,
        413,
        KeyfleetWeb.Refusal.body(
          "request_too_large",
          "This operation takes a body of at most #{body_limit(conn.request_path)} bytes. " <>
            "Send a shorter one."
        )
      )

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

  @doc """
  The actor a connected app's own identity acts as here
  (`KeyfleetWeb.Plugs.McpAgent`): its wallet, which the sign-in server holds
  for it, with its pairing read as a signed request's is (`admit/2`).
  `connection` is the app's token, as `RegentOAuth.verify/3` answered for it;
  the token is the sign-in, so the actor's sign-in ends when the token does,
  and `credential_ref` names the token as a signed request's names its receipt.
  """
  @spec actor_for(String.t(), map()) :: {:ok, Agent.t()} | {:error, term()}
  def actor_for(address, %{token_id: token_id, expires_at: expires_at} = connection) do
    Keyfleet.Agents.with_pairing(%Agent{
      wallet_address: address,
      chain_id: 8453,
      verification_method: :connected_app,
      audience: "keyfleet",
      credential_ref:
        "sha256:" <> Base.encode16(:crypto.hash(:sha256, to_string(token_id)), case: :lower),
      receipt_expires_at: expires_at,
      connection: connection
    })
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
  def deny(conn, metadata) do
    {status, body} = refusal(conn, metadata)
    send_refusal(conn, status, body)
  end

  @doc """
  The status and refusal body (`KeyfleetWeb.Refusal`) for a request the shared
  plug or this site's checks turned away, for a caller that answers in a shape
  of its own (`KeyfleetWeb.Plugs.CodeGateway`).
  """
  def refusal(_conn, %{reason: :smart_wallet_on_ethereum}),
    do: answer(401, "smart_wallet_on_ethereum")

  def refusal(_conn, %{reason: :agent_not_paired}), do: answer(403, "agent_not_paired")
  def refusal(_conn, %{reason: :pairing_unavailable}), do: answer(503, "pairing_unavailable")

  def refusal(conn, %{reason: reason})
      when reason in [:out_of_range, :too_many_keys, :body_does_not_fit],
      do: body_refusal(conn.request_path, reason)

  # The shared plug's own refusals keep its reason as the code, as on every site.
  def refusal(_conn, %{source: :siwa_plug, reason: reason}),
    do: answer(401, Atom.to_string(reason))

  def refusal(_conn, %{reason: :siwa_request_failed}), do: answer(503, "siwa_request_failed")

  # The sign-in service answered with a refusal or a failure: its status and its
  # own words, as on every site.
  def refusal(_conn, %{siwa_status: status} = failure) do
    {status,
     %{
       error: %{
         code: failure[:siwa_code] || "sign_in_refused",
         message: failure[:siwa_message] || "The request's wallet signature was not accepted.",
         hint: failure[:siwa_hint] || "Sign the request again with your agent key, then send it."
       }
     }}
  end

  def refusal(_conn, _metadata), do: {401, KeyfleetWeb.Refusal.body("unauthorized", @sign_again)}

  @doc """
  The status and refusal body for a body that doesn't fit the operation at
  `path`, as `check_body/2` found it: the same for a signed request and for
  the Claude connector's tool that sends it.
  """
  def body_refusal(_path, :out_of_range), do: answer(422, "out_of_range")

  def body_refusal(_path, :too_many_keys),
    do: {422, KeyfleetWeb.Refusal.body("out_of_range", @too_many_keys)}

  def body_refusal(path, _does_not_fit),
    do: {422, KeyfleetWeb.Refusal.body("invalid_request", takes(path))}

  defp answer(status, code), do: {status, KeyfleetWeb.Refusal.body(code)}

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

  @doc "Whether a signed agent operation answers `method` at `path`."
  def operation?(method, path), do: supported?(method, path)

  defp supported?("POST", @join_path), do: true
  defp supported?("POST", @update_path), do: true
  defp supported?("POST", @avatar_start_path), do: true
  defp supported?("POST", @avatar_remove_path), do: true
  defp supported?("GET", @shards_path), do: true
  defp supported?("POST", @links_path), do: true
  defp supported?("POST", @preview_path), do: true
  defp supported?("GET", @profile_path), do: true
  defp supported?("GET", @points_path), do: true
  defp supported?("GET", @feed_path), do: true

  defp supported?("GET", path),
    do:
      Enum.any?(
        [
          @rooms_path,
          @doctor_path,
          @checkpoint_path,
          @agent_keys_path,
          @key_page_path,
          @mutes_path,
          @polls_path,
          @poll_path,
          @dm_inbox_path,
          @code_pushes_path,
          @code_commit_path,
          @notebooks_path,
          @copies_path,
          @run_path,
          @projects_path
        ],
        &Regex.match?(&1, path)
      )

  defp supported?("POST", path) do
    Enum.any?(
      [
        @message_path,
        @mute_path,
        @checkpoint_save_path,
        @create_room_path,
        @topic_path,
        @read_path,
        @get_path,
        @send_path,
        @key_read_path,
        @key_get_path,
        @key_send_path,
        @key_remove_path,
        @keys_held_path,
        @activity_path,
        @search_path,
        @posting_key_path,
        @receipts_path,
        @sync_path,
        @proposal_read_path,
        @project_start_path,
        @project_archive_path,
        @project_hold_path,
        @project_describe_path,
        @project_show_path,
        @publish_posts_path,
        @withdraw_path,
        @publications_list_path,
        @publish_item_path,
        @publish_page_path,
        @publish_commit_path,
        @run_start_path,
        @notebook_create_path,
        @files_list_path,
        @file_read_path,
        @file_write_path,
        @notebook_lock_path,
        @copy_restore_path,
        @chain_path,
        @graph_path,
        @atlas_path,
        @dm_path,
        @code_history_path,
        @dm_changes_path
        | @poll_post_paths
      ],
      &Regex.match?(&1, path)
    )
  end

  defp supported?(_method, _path), do: false

  @doc "The most bytes a body sent to `path` may hold."
  def body_limit(@update_path), do: @update_max_body
  def body_limit(@preview_path), do: @sync_max_body + 1024

  def body_limit(path) do
    cond do
      send?(path) -> @send_max_body
      Regex.match?(@checkpoint_save_path, path) -> @checkpoint_max_body
      catch_up?(path) -> @sync_max_body
      limit = form_body_limit(path) -> limit
      chain_op(path) == "proposals/create" -> @propose_max_body
      fleet_op(path) in [:notebook_create, :file_write] -> @notebook_write_max_body
      graph_op(path) in @graph_writes -> @graph_write_max_body
      true -> 4096
    end
  end

  # A room message, a Key's message or a direct message.
  defp send?(path),
    do:
      Regex.match?(@send_path, path) or Regex.match?(@key_send_path, path) or
        dm_op(path) == "send"

  # A sync, and catching up on direct messages alone.
  defp catch_up?(path), do: Regex.match?(@sync_path, path) or dm_op(path) == "changes"

  # A message for the site's team, and starting or voting in a poll.
  defp form_body_limit(path) do
    cond do
      Regex.match?(@message_path, path) -> @message_max_body
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

  def check_body(
        @avatar_start_path,
        %{"sha256" => sha256, "byte_size" => size, "content_type" => type} = params
      ),
      do:
        admit(
          map_size(params) == 3 and is_binary(sha256) and is_integer(size) and is_binary(type)
        )

  def check_body(@avatar_start_path, _params), do: :invalid

  # An address, as long as a browser's address bar takes.
  def check_body(@links_path, %{"url" => url} = params),
    do: admit(map_size(params) == 1 and is_binary(url) and byte_size(url) in 1..2048)

  def check_body(@links_path, _params), do: :invalid

  # A write named by its browser tool, with the input that tool takes.
  def check_body(@preview_path, %{"tool" => tool, "input" => input} = params),
    do: admit(map_size(params) == 2 and is_binary(tool) and is_map(input))

  def check_body(@preview_path, _params), do: :invalid
  def check_body(@avatar_remove_path, params), do: admit(params == %{})

  def check_body(path, params) do
    cond do
      Regex.match?(@message_path, path) -> check_message_body(params)
      op = atlas_op(path) -> check_fields(Map.fetch!(@atlas_bodies, op), params)
      true -> check_op_body(path, params)
    end
  end

  defp check_op_body(path, params) do
    cond do
      Enum.any?(@empty_body_paths, &Regex.match?(&1, path)) -> admit(params == %{})
      op = fleet_op(path) -> check_fleet_body(op, params)
      op = dm_op(path) -> check_dm_body(op, params)
      op = chain_op(path) -> check_chain_body(op, params)
      op = graph_op(path) -> check_graph_body(op, params)
      op = key_op(path) -> check_key_body(op, params)
      poll_write?(path) -> check_poll_body(path, params)
      true -> path |> room_op() |> check_room_body(params)
    end
  end

  # Making a room, setting its topic, reading it, reading one post and
  # posting each name fields of their own; a Key's wall reads and posts as a
  # room does.
  defp room_op(path) do
    Enum.find_value(
      [
        create: [@create_room_path],
        topic: [@topic_path],
        read: [@read_path, @key_read_path],
        get: [@get_path, @key_get_path],
        send: [@send_path],
        key_send: [@key_send_path]
      ],
      fn {op, patterns} -> if Enum.any?(patterns, &Regex.match?(&1, path)), do: op end
    )
  end

  defp check_room_body(:create, params), do: admit(valid_room_body?(params))
  defp check_room_body(:topic, params), do: admit(valid_topic_body?(params))
  defp check_room_body(:read, params), do: with_budget(params, @post_budgets, &check_read_body/1)
  defp check_room_body(:get, params), do: check_place_body(params)

  defp check_room_body(:send, params),
    do: admit(valid_send_body?(params, ~w(body idempotency_key reply_to_id quote_request_id)))

  defp check_room_body(:key_send, params),
    do: admit(valid_send_body?(params, ~w(body idempotency_key reply_to_id)))

  defp check_room_body(nil, _params), do: :invalid

  # Taking a post off a Key's wall, finding the Keys a wallet holds, reading
  # the fleet's activity, searching it and choosing the Key a person posts as
  # each name fields of their own.
  defp key_op(path) do
    Enum.find_value(
      [
        key_remove: @key_remove_path,
        keys_held: @keys_held_path,
        activity: @activity_path,
        search: @search_path,
        posting_key: @posting_key_path
      ],
      fn {op, pattern} -> if Regex.match?(pattern, path), do: op end
    )
  end

  defp check_key_body(:key_remove, params), do: admit(valid_remove_body?(params))
  defp check_key_body(:keys_held, params), do: admit(valid_held_body?(params))
  defp check_key_body(:activity, params), do: admit(valid_activity_body?(params))
  defp check_key_body(:search, params), do: check_search_body(params)
  defp check_key_body(:posting_key, params), do: check_posting_key_body(params)

  # Catching up, reading a proposal, starting a notebook run, making a
  # notebook and working with its files each name fields of their own.
  defp fleet_op(path) do
    Enum.find_value(
      [
        sync: @sync_path,
        proposal_read: @proposal_read_path,
        project_start: @project_start_path,
        project_archive: @project_archive_path,
        project_hold: @project_hold_path,
        project_describe: @project_describe_path,
        project_show: @project_show_path,
        publish_posts: @publish_posts_path,
        withdraw: @withdraw_path,
        publications_list: @publications_list_path,
        publish_item: @publish_item_path,
        publish_page: @publish_page_path,
        publish_commit: @publish_commit_path,
        run_start: @run_start_path,
        notebook_create: @notebook_create_path,
        files_list: @files_list_path,
        file_read: @file_read_path,
        file_write: @file_write_path,
        notebook_lock: @notebook_lock_path,
        receipts: @receipts_path,
        checkpoint_save: @checkpoint_save_path,
        code_history: @code_history_path
      ],
      fn {op, pattern} -> if Regex.match?(pattern, path), do: op end
    )
  end

  defp check_fleet_body(:sync, params),
    do: with_budget(params, @sync_budgets, &check_sync_body/1)

  defp check_fleet_body(:proposal_read, params), do: check_proposal_read_body(params)

  # A project is started with its address name and its title, as a Key.
  defp check_fleet_body(
         :project_start,
         %{"as_key" => key, "name" => name, "title" => title} = params
       )
       when map_size(params) == 3 and is_integer(key) and is_binary(name) and is_binary(title),
       do: in_range(key in 1..@max_seq)

  defp check_fleet_body(:project_start, _params), do: :invalid

  # Archiving, taking over, deleting and taking something back name only the
  # Key they act as.
  defp check_fleet_body(op, %{"as_key" => key} = params)
       when op in [:project_archive, :project_hold, :withdraw] and map_size(params) == 1 and
              is_integer(key),
       do: in_range(key in 1..@max_seq)

  defp check_fleet_body(op, _params) when op in [:project_archive, :project_hold, :withdraw],
    do: :invalid

  # A description names the Key and the line, or null to take it away.
  defp check_fleet_body(:project_describe, %{"as_key" => key, "description" => line} = params)
       when map_size(params) == 2 and is_integer(key) and (is_binary(line) or is_nil(line)),
       do: in_range(key in 1..@max_seq)

  defp check_fleet_body(:project_describe, _params), do: :invalid

  # Showing a project's page's work names the Key and whether to everyone.
  defp check_fleet_body(:project_show, %{"as_key" => key, "shown_to_everyone" => shown} = params)
       when map_size(params) == 2 and is_integer(key) and is_boolean(shown),
       do: in_range(key in 1..@max_seq)

  defp check_fleet_body(:project_show, _params), do: :invalid

  # Posts go public from one room, from one post to another, as a Key.
  defp check_fleet_body(
         :publish_posts,
         %{"as_key" => key, "room" => room, "from_seq" => from, "to_seq" => to} = params
       )
       when map_size(params) == 4 and is_integer(key) and is_binary(room) and is_integer(from) and
              is_integer(to),
       do: in_range(key in 1..@max_seq and from in 1..@max_seq and to in 1..@max_seq)

  defp check_fleet_body(:publish_posts, _params), do: :invalid

  # What is public reads from the newest, or on from the last page's cursor.
  defp check_fleet_body(:publications_list, params) when map_size(params) == 0, do: :ok

  defp check_fleet_body(:publications_list, %{"after" => cursor} = params)
       when map_size(params) == 1 and is_binary(cursor) and byte_size(cursor) in 1..1024,
       do: :ok

  defp check_fleet_body(:publications_list, _params), do: :invalid

  # An item goes public by its id, as a Key.
  defp check_fleet_body(:publish_item, %{"as_key" => key, "item" => item} = params)
       when map_size(params) == 2 and is_integer(key) and is_binary(item) and
              byte_size(item) in 1..128,
       do: in_range(key in 1..@max_seq)

  defp check_fleet_body(:publish_item, _params), do: :invalid

  # A saved notebook page goes public by its address, as a Key.
  defp check_fleet_body(:publish_page, %{"as_key" => key, "page" => page} = params)
       when map_size(params) == 2 and is_integer(key) and is_binary(page) and
              byte_size(page) in 1..512,
       do: in_range(key in 1..@max_seq)

  defp check_fleet_body(:publish_page, _params), do: :invalid

  # A project's code goes public at one commit, by its full hash, as a Key.
  defp check_fleet_body(:publish_commit, %{"as_key" => key, "commit" => hash} = params)
       when map_size(params) == 2 and is_integer(key) and is_binary(hash) and
              byte_size(hash) in [40, 64],
       do: in_range(key in 1..@max_seq)

  defp check_fleet_body(:publish_commit, _params), do: :invalid
  defp check_fleet_body(:run_start, params), do: check_run_start_body(params)

  # A send key or command id, as long as either may be.
  defp check_fleet_body(:receipts, %{"idempotency_key" => key} = params)
       when map_size(params) == 1 and is_binary(key),
       do: admit(String.length(key) in 1..128)

  defp check_fleet_body(:receipts, _params), do: :invalid
  defp check_fleet_body(:checkpoint_save, params), do: check_checkpoint_body(params)
  defp check_fleet_body(:notebook_create, params), do: check_notebook_create_body(params)
  defp check_fleet_body(:files_list, params), do: check_files_list_body(params)

  defp check_fleet_body(:file_read, %{"path" => path} = params),
    do: admit(map_size(params) == 1 and is_binary(path))

  defp check_fleet_body(:file_read, _params), do: :invalid

  # Adding or writing a file names the file and its whole text.
  defp check_fleet_body(:file_write, %{"path" => path, "content" => content} = params),
    do: admit(map_size(params) == 2 and is_binary(path) and is_binary(content))

  defp check_fleet_body(:file_write, _params), do: :invalid

  # Locking or unlocking a notebook says which.
  defp check_fleet_body(:notebook_lock, %{"locked" => locked} = params),
    do: admit(map_size(params) == 1 and is_boolean(locked))

  defp check_fleet_body(:notebook_lock, _params), do: :invalid

  # A project's history reads from the newest, or on from the commit its first
  # page started at, by page number; a page it doesn't have is the
  # controller's to refuse.
  defp check_fleet_body(:code_history, params) do
    from = Map.get(params, "from")
    page = Map.get(params, "page", 1)

    admit(
      Map.keys(params) -- ~w(from page) == [] and (is_nil(from) or is_binary(from)) and
        is_integer(page)
    )
  end

  defp chain_op(path) do
    case Regex.run(@chain_path, path, capture: :all_but_first) do
      [op] -> op
      nil -> nil
    end
  end

  # Presence, the split, sending the staking share, claiming, buying a Key,
  # claiming a Regents Club Key, asking again for a Key's draw and ending a
  # Key's shards say nothing more than their path. Issuing shards names the
  # Keys, the wallet and the days as typed, and agent voting the Keys and on
  # or off. Turning USDC into REGENT names its amount as a string, and so does
  # returning an advance; the launch's upkeep names its one step. A proposal
  # names its fields as strings; a vote, a cancellation and carrying out name
  # the proposal, and a vote its choice.
  defp check_chain_body(op, params) when op in ["presence", "split", "treasury/send_share"],
    do: admit(params == %{})

  defp check_chain_body(
         "treasury/convert",
         %{"inputs" => %{"amount" => amount} = inputs} = params
       )
       when map_size(params) == 1 and map_size(inputs) == 1,
       do: admit(typed?(amount, 100))

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

  defp check_chain_body("treasury/advances/" <> _return, %{"amount" => amount} = params),
    do: admit(map_size(params) == 1 and typed?(amount, 100))

  defp check_chain_body("treasury/launch", %{"step" => step} = params),
    do: admit(map_size(params) == 1 and step in @launch_steps)

  defp check_chain_body("keys/" <> _path_only, params), do: admit(params == %{})

  defp check_chain_body(
         "shards/issue",
         %{"keys" => keys, "wallet" => wallet, "days" => days} = params
       ),
       do:
         admit(
           map_size(params) == 3 and typed?(keys, 1000) and typed?(wallet, 100) and
             typed?(days, 10)
         )

  defp check_chain_body("shards/voting", %{"keys" => keys, "voting" => voting} = params),
    do: admit(map_size(params) == 2 and typed?(keys, 1000) and voting in ~w(on off))

  defp check_chain_body(_op, _params), do: :invalid

  # A field as a form types it, no longer than the contract says.
  defp typed?(value, max_length), do: is_binary(value) and String.length(value) <= max_length

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

  defp atlas_op(path) do
    case Regex.run(@atlas_path, path, capture: :all_but_first) do
      [op] -> op
      nil -> nil
    end
  end

  # One project's changes or one object's, never both.
  defp check_graph_body("changes", %{"project" => _, "object" => _}), do: :invalid
  defp check_graph_body(op, params), do: check_fields(Map.fetch!(@graph_bodies, op), params)

  # Nothing outside an operation's own fields is admitted, so a request can
  # never name its own author, standing or scope rules.
  defp check_fields({required, optional}, params) when is_map(params) do
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

  defp check_fields(_spec, _params), do: :invalid

  defp shaped?(:text, value), do: is_binary(value)
  defp shaped?(:object, value), do: is_map(value)
  defp shaped?(:texts, value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp shaped?(:flag, value), do: is_boolean(value)
  defp shaped?(:pin_place, value), do: value in ~w(docs code)
  defp shaped?(:pin_target, value), do: is_binary(value)

  # Parts named once each, joined by commas, as a command line flag sends them.
  defp shaped?(:get_parts, value) when is_binary(value) do
    parts = String.split(value, ",")
    parts == Enum.uniq(parts) and Enum.all?(parts, &(&1 in @get_parts))
  end

  defp shaped?(:get_parts, _value), do: false

  defp shaped?(kind, value)
       when kind in [:key, :version, :seq, :graph_page, :change_budget, :most_active, :atlas_page],
       do: is_integer(value)

  defp shaped?(nil, _value), do: false

  defp in_bounds?(kind, value) when kind in [:key, :version], do: value in 1..@max_seq
  defp in_bounds?(:seq, value), do: value in 0..@max_seq
  defp in_bounds?(:graph_page, value), do: value in 1..@max_graph_page
  defp in_bounds?(:change_budget, value), do: value in @min_change_budget..@max_change_budget
  defp in_bounds?(:most_active, value), do: value in 0..@max_most_active
  defp in_bounds?(:atlas_page, value), do: value in 1..@max_atlas_page
  # As long as a pin's target is kept (`Keyfleet.Graph.Pin`).
  defp in_bounds?(:pin_target, value), do: byte_size(value) in 1..1024
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

  # A checkpoint is saved whole, from the revision read: 0 for the first.
  defp check_checkpoint_body(%{"expected_revision" => revision, "state" => state} = params)
       when map_size(params) == 2 and is_integer(revision) and is_map(state),
       do: in_range(revision in 0..@max_seq)

  defp check_checkpoint_body(_params), do: :invalid

  # A read that takes `max_bytes` is checked without it, then the budget.
  defp with_budget(params, budgets, check) when is_map(params) do
    case Map.pop(params, "max_bytes", :none) do
      {:none, params} ->
        check.(params)

      {bytes, params} when is_integer(bytes) ->
        with :ok <- check.(params), do: in_range(bytes in budgets)

      {_not_a_number, _params} ->
        :invalid
    end
  end

  defp with_budget(_params, _budgets, _check), do: :invalid

  # One post is named by its place or by its id, never both, with up to
  # `@max_context` posts either side.
  defp check_place_body(params) when is_map(params) do
    {context, place} = Map.pop(params, "context", 0)

    case Map.to_list(place) do
      [{"seq", seq}] when is_integer(seq) and is_integer(context) ->
        in_range(seq in 1..@max_seq and context in 0..@max_context)

      [{"id", id}] when is_binary(id) and is_integer(context) ->
        if Regex.match?(@post_id, id), do: in_range(context in 0..@max_context), else: :invalid

      _other ->
        :invalid
    end
  end

  defp check_place_body(_params), do: :invalid

  defp valid_send_body?(%{"body" => body, "idempotency_key" => key} = params, fields) do
    is_binary(body) and is_binary(key) and
      Enum.all?(Map.keys(params), &(&1 in fields)) and
      id_or_none?(Map.get(params, "reply_to_id")) and
      id_or_none?(Map.get(params, "quote_request_id"))
  end

  defp valid_send_body?(_params, _fields), do: false

  # Taking a post off a Key's wall names the post, by its id as the API gives it.
  defp valid_remove_body?(%{"message_id" => id} = params),
    do: map_size(params) == 1 and is_binary(id) and Regex.match?(@post_id, id)

  defp valid_remove_body?(_params), do: false

  # Finding the Keys a wallet holds names the wallet, in either case.
  defp valid_held_body?(%{"wallet" => wallet} = params),
    do: map_size(params) == 1 and is_binary(wallet) and Regex.match?(@wallet, wallet)

  defp valid_held_body?(_params), do: false

  # The fleet's activity is read from the newest page, {}, or on from the
  # cursor the last page answered.
  defp valid_activity_body?(params) when is_map(params),
    do: Enum.all?(params, fn {key, value} -> key == "cursor" and is_binary(value) end)

  defp valid_activity_body?(_params), do: false

  # A search names its words, and may name the cursor its last page answered
  # and how many matches a page holds.
  defp check_search_body(%{"query" => query} = params) when is_binary(query) do
    cond do
      not Enum.all?(params, &search_field?/1) -> :invalid
      Map.has_key?(params, "limit") -> in_range(params["limit"] in 1..Search.limits().max)
      true -> :ok
    end
  end

  defp check_search_body(_params), do: :invalid

  defp search_field?({"query", _query}), do: true
  defp search_field?({"cursor", cursor}), do: is_binary(cursor)
  defp search_field?({"limit", limit}), do: is_integer(limit)
  defp search_field?(_field), do: false

  # Choosing the Key the agent's person writes as names that Key.
  defp check_posting_key_body(%{"token_id" => token_id} = params)
       when map_size(params) == 1 and is_integer(token_id),
       do: in_range(token_id in 1..@max_seq)

  defp check_posting_key_body(_params), do: :invalid

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
  # quote them only when `quotes` does. The Key's mentions are read on from
  # `mentions`' cursor when it names one, and over the last week otherwise.
  # A body that doesn't fit is refused as that before one with a place out of
  # range.
  defp check_sync_body(params) do
    checks = [
      check_sync_rooms(params),
      check_key_cursors(Map.get(params, "keys", []), @max_sync_walls),
      check_sync_dms(params),
      check_sync_mentions(params)
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
    others = [proposals | params |> Map.take(["quotes"]) |> Map.values()]
    logs = [graph | others]

    cond do
      not sync_shape?(params, rooms, graph, others, run) ->
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

  # The sync body names its rooms, graph, proposals and run, and may name keys,
  # direct messages, quotes and mentions; each part is shaped as its cursor is.
  defp sync_shape?(params, rooms, graph, others, run) do
    map_size(Map.drop(params, ["keys", "dms", "quotes", "mentions"])) == 4 and
      Enum.all?(rooms, &cursor?/1) and graph_cursor?(graph) and
      Enum.all?(others, &log_cursor?/1) and run?(run)
  end

  defp check_sync_dms(%{"dms" => dms}), do: check_dm_cursors(dms)
  defp check_sync_dms(_params), do: :ok

  # A cursor a sync answered in `yours.mentions.next_cursor`, unchanged, or null.
  defp check_sync_mentions(%{"mentions" => %{"after" => cursor} = mentions})
       when map_size(mentions) == 1 do
    case KeyfleetWeb.MentionJSON.opened(cursor) do
      {:ok, _place} -> :ok
      :error -> :invalid
    end
  end

  defp check_sync_mentions(%{"mentions" => _mentions}), do: :invalid
  defp check_sync_mentions(_params), do: :ok

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

  # A new notebook names its title and code, and the key that keeps a retry
  # from making it twice; it may say what it is for, and the goal it serves.
  defp check_notebook_create_body(
         %{"title" => title, "code" => code, "idempotency_key" => key} = params
       )
       when is_binary(title) and is_binary(code) and is_binary(key) do
    cond do
      not notebook_create_fields?(params, key) ->
        :invalid

      String.length(title) in 1..@max_notebook_title ->
        :ok

      true ->
        :out_of_range
    end
  end

  defp check_notebook_create_body(_params), do: :invalid

  defp notebook_create_fields?(params, key) do
    Enum.all?(Map.keys(params), &(&1 in ~w(title code idempotency_key description goal folder))) and
      is_binary(Map.get(params, "description", "")) and notebook_goal?(params["goal"]) and
      notebook_folder?(params["folder"]) and Regex.match?(~r/\A[!-~]{1,128}\z/, key)
  end

  defp notebook_goal?(nil), do: true

  defp notebook_goal?(goal) when is_binary(goal),
    do: Regex.match?(~r/\Agoal#[1-9][0-9]{0,9}\z/, goal)

  defp notebook_goal?(_goal), do: false

  # A folder is one name: letters, digits, dots, dashes and underscores.
  defp notebook_folder?(nil), do: true

  defp notebook_folder?(folder) when is_binary(folder),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, folder)

  defp notebook_folder?(_folder), do: false

  # A listing may name the folder and the page it reads on from.
  defp check_files_list_body(params) when is_map(params),
    do:
      admit(Enum.all?(params, fn {key, value} -> key in ~w(path cursor) and is_binary(value) end))

  defp check_files_list_body(_params), do: :invalid

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

  # The workspace's log is followed for the whole fleet, or for one project.
  defp graph_cursor?(%{"project" => project} = graph),
    do: is_binary(project) and log_cursor?(Map.delete(graph, "project"))

  defp graph_cursor?(graph), do: log_cursor?(graph)

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
  defp fields(@links_path), do: {~w(url), []}
  defp fields(@preview_path), do: {~w(tool input), []}

  defp fields(path) do
    cond do
      op = chain_op(path) ->
        chain_fields(op)

      op = graph_op(path) ->
        spec_fields(Map.fetch!(@graph_bodies, op))

      op = atlas_op(path) ->
        spec_fields(Map.fetch!(@atlas_bodies, op))

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
  defp chain_fields("shards/issue"), do: {~w(keys wallet days), []}
  defp chain_fields("shards/voting"), do: {~w(keys voting), []}
  defp chain_fields("treasury/launch"), do: {~w(step), []}
  defp chain_fields("treasury/advances/" <> _return), do: {~w(amount), []}

  defp chain_fields(op) when op in ["proposals/cancel", "proposals/carry_out"],
    do: {~w(number), []}

  defp chain_fields(_op), do: {[], []}

  defp dm_fields("read"), do: {[], ~w(after_seq limit)}
  defp dm_fields("send"), do: {~w(body idempotency_key), ~w(parts)}
  defp dm_fields("auto_delete"), do: {~w(days), []}
  defp dm_fields("changes"), do: {~w(keys), []}
  defp dm_fields(_op), do: {[], []}

  defp spec_fields({required, optional}),
    do: {required |> Map.keys() |> Enum.sort(), optional |> Map.keys() |> Enum.sort()}

  defp admit(true), do: :ok
  defp admit(false), do: :invalid

  # A message's text, the key it is left under once and where to answer it;
  # the message itself checks their lengths and spelling.
  defp check_message_body(params) do
    admit(
      Map.keys(params) -- ~w(body operation_id reply_to) == [] and
        is_binary(params["body"]) and is_binary(params["operation_id"]) and
        (not Map.has_key?(params, "reply_to") or is_binary(params["reply_to"]))
    )
  end

  defp in_range(true), do: :ok
  defp in_range(false), do: :out_of_range
end

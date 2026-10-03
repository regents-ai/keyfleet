defmodule KeyfleetWeb.ShellLive do
  @moduledoc """
  One LiveView holds the header, sidebar and account control across every in-app
  route and patches between them, so the frame never remounts on navigation.
  """

  use KeyfleetWeb, :live_view

  import KeyfleetWeb.Components.Shell

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.LinkedIdentity.Providers
  alias Keyfleet.Actors.Human
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Notebooks
  alias Keyfleet.Proposals
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Muter

  alias KeyfleetWeb.{
    AccountLive,
    FleetLive,
    KeyMap,
    KeyProfileLive,
    KeysLive,
    ProposalsLive,
    Read,
    RoomsLive,
    WorkspaceLive
  }

  alias KeyfleetWeb.{PublicDocuments, RouteCatalog}
  alias Phoenix.Socket.Broadcast

  # The events each area's page sends, which that area's module answers.
  @fleet_events ~w(open_send_agent close_send_agent activity_earlier keymap_ready select_key)
  @room_events ~w(validate_post send_message validate_naming name_room mute_key unmute_key)
  @key_profile_events ~w(post_to_key close_key)

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> follow_mutes()
     |> stream_configure(:posts, dom_id: &"post-#{&1.id}")
     |> stream(:posts, [])
     |> stream_configure(:fleet_keys, dom_id: &"fleet-key-#{&1.token_id}")
     |> stream(:fleet_keys, [])
     |> stream_configure(:key_thread, dom_id: &"key-message-#{&1.id}")
     |> stream(:key_thread, [])
     |> stream_configure(:activity, dom_id: &FleetLive.activity_dom_id/1)
     |> stream(:activity, [])
     |> assign(
       route_spec: RouteCatalog.fetch!(socket.assigns.live_action, params),
       shell_instance: System.unique_integer([:positive, :monotonic]),
       verified_connections: %Read{},
       verified_connections_notice: nil,
       notebooks_notice: nil,
       connection_outcome: nil,
       held_keys: [],
       fleet: nil,
       fleet_params: nil,
       keys_topic: nil,
       activity: nil,
       activity_refresh: nil,
       key_profile: nil,
       key: nil,
       room: nil,
       room_notice: nil,
       room_topic: nil,
       post_form: nil,
       naming_form: nil,
       workspace: nil,
       workspace_params: nil,
       workspace_topic: nil,
       workspace_refresh?: false,
       proposals: nil,
       proposals_params: nil,
       proposals_topic: nil,
       proposals_refresh?: false,
       check_ins_timer: nil,
       send_agent_open: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    route_spec = RouteCatalog.fetch!(socket.assigns.live_action, params)

    if coming_soon_inside?(route_spec, params) do
      {:noreply, push_patch(socket, to: "/app/fleets/#{params["fleet_id"]}", replace: true)}
    else
      # Going anywhere, back and forward included, closes "Send your agent".
      {:noreply,
       socket
       |> assign(route_spec: route_spec, send_agent_open: false)
       |> assign(PublicDocuments.page(route_spec.route_id))
       |> load_verified_connections(route_spec)
       |> load_held_keys(route_spec)
       |> follow_keys(keys_fleet(route_spec, params))
       |> load_fleet(route_spec, params)
       |> load_key_profile(socket.assigns)
       |> load_key(route_spec, params)
       |> load_room(route_spec, params)
       |> load_workspace(route_spec, params)
       |> load_proposals(route_spec, params)}
    end
  end

  # A coming-soon fleet has only its own page: its rooms, workspace and
  # proposals open with the fleet.
  defp coming_soon_inside?(%{route_id: route_id}, %{"fleet_id" => fleet_id})
       when route_id in [:rooms, :workspace, :workspace_item, :proposals, :proposal],
       do: Fleets.coming_soon?(fleet_id, Fleets.get_fleet!(fleet_id))

  defp coming_soon_inside?(_route_spec, _params), do: false

  @impl true
  def handle_event(
        "request_verified_connection",
        %{"action" => action, "provider" => provider},
        socket
      ) do
    with %Human{} <- human_actor(socket),
         {:ok, provider} <- Providers.parse(provider),
         {:ok, request} <-
           identity_request(action, provider, socket.assigns.verified_connections.value) do
      {:noreply,
       socket
       |> assign(
         verified_connections_notice: %{tone: :info, message: connection_started(request)}
       )
       |> push_event("verified-connections:request", request)}
    else
      _error ->
        {:noreply,
         assign(socket,
           verified_connections_notice: %{
             tone: :error,
             message: "That connection couldn’t be updated. Refresh the page and try again."
           }
         )}
    end
  end

  # The outcome is judged against the connections read after the provider came
  # back, so it waits for that read to land.
  def handle_event("refresh_verified_connections", params, socket) do
    {:noreply,
     socket
     |> assign(connection_outcome: params, verified_connections_notice: nil)
     |> read_verified_connections()}
  end

  # The fleet's notebooks open on their own address, signed in by a link that
  # works once; only a holder of one of the fleet's keys gets one.
  def handle_event("open_notebooks", _params, socket) do
    with %Human{} = actor <- human_actor(socket),
         {:ok, url} <-
           Notebooks.open(
             actor,
             socket.assigns.session_lineage,
             socket.assigns.workspace.fleet_id
           ) do
      {:noreply, redirect(socket, external: url)}
    else
      nil ->
        {:noreply, assign(socket, notebooks_notice: "Sign in to open this fleet’s notebooks.")}

      {:error, :signed_out} ->
        {:noreply, assign(socket, notebooks_notice: "Sign in to open this fleet’s notebooks.")}

      {:error, :not_holder} ->
        {:noreply,
         assign(socket,
           notebooks_notice: "Only holders of this fleet’s keys can open its notebooks."
         )}

      {:error, _error} ->
        {:noreply,
         assign(socket,
           notebooks_notice: "The notebooks can’t be opened right now. Try again in a minute."
         )}
    end
  end

  def handle_event(event, params, socket) when event in @room_events,
    do: RoomsLive.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @key_profile_events,
    do: KeyProfileLive.handle_event(event, params, socket)

  def handle_event(event, params, socket) when event in @fleet_events,
    do: FleetLive.handle_event(event, params, socket)

  # A notice that the open room has taken a post it is not showing yet is only a
  # nudge to look again. The new posts are read back from the room itself.
  @impl true
  def handle_info(
        %Broadcast{event: "room_head", payload: %{room_id: room_id, seq: seq}},
        %{assigns: %{room: %{room_id: room_id, last_seq: last_seq}}} = socket
      )
      when seq > last_seq,
      do: {:noreply, RoomsLive.show_new_posts(socket)}

  # The page only hears about the rooms of the fleet it shows.
  def handle_info(%Broadcast{event: "room_head"}, socket),
    do: {:noreply, FleetLive.refresh_activity_soon(socket, fleet_on_show(socket))}

  def handle_info(%Broadcast{event: "key_activity"} = notice, socket),
    do: KeyProfileLive.handle_info(notice, socket)

  def handle_info(%Broadcast{event: event} = notice, socket)
      when event in ["rooms_changed", "mutes_changed"],
      do: RoomsLive.handle_info(notice, socket)

  # Keys changed in the fleet on show: its sales figures, the key on offer and
  # the agents here are read again (an agent starting or stopping on a key
  # sends this notice too), the key list only when a changed key is on it, the
  # open key's profile when the key or one of its holder's changed, and the
  # map is told the changed keys' marks, or told to load again when too many
  # changed to list.
  def handle_info(
        {:keys_changed, fleet_id, token_ids},
        %{assigns: %{fleet: %{fleet_id: fleet_id, deployed?: true}}} = socket
      ) do
    socket =
      socket
      |> FleetLive.refresh_sales()
      |> FleetLive.refresh_agents()
      |> FleetLive.refresh_listed(token_ids)
      |> KeyProfileLive.refresh_key_profile(token_ids)
      |> FleetLive.refresh_activity_soon(fleet_id)

    progress = socket.assigns.fleet.progress

    case KeyMap.change(fleet_id, progress, token_ids, human_actor(socket)) do
      :reset -> {:noreply, push_event(socket, "keymap:reset", %{})}
      {:patch, patch} -> {:noreply, push_event(socket, "keymap:patch", patch)}
    end
  end

  # A notice for the key page on show, or for a fleet the page has since
  # left, or one not yet on sale.
  def handle_info({:keys_changed, fleet_id, token_ids}, socket),
    do:
      {:noreply,
       socket
       |> KeysLive.refresh_key(fleet_id, token_ids)
       |> FleetLive.refresh_activity_soon(fleet_id)}

  # A notice that the open fleet's workspace has moved past what the page last
  # read is only a nudge to read it again, once, a moment later: the notices
  # that come in the meantime are answered by that one read.
  def handle_info(
        {:graph_head, fleet_id, run_id, watermark},
        %{assigns: %{workspace: %{fleet_id: fleet_id, seen: seen}}} = socket
      ),
      do: {:noreply, WorkspaceLive.refresh_soon(socket, seen, run_id, watermark)}

  def handle_info({:graph_head, fleet_id, _run_id, _watermark}, socket),
    do: {:noreply, FleetLive.refresh_activity_soon(socket, fleet_id)}

  def handle_info(:refresh_workspace = message, socket),
    do: WorkspaceLive.handle_info(message, socket)

  # A notice that the open fleet's proposal records or balances changed is a
  # nudge to read its page again, once, a moment later, like the workspace's.
  def handle_info(
        {notice, fleet_id},
        %{assigns: %{proposals: %{fleet_id: fleet_id}}} = socket
      )
      when notice in [:proposals_changed, :balances_changed],
      do: {:noreply, ProposalsLive.refresh_soon(socket)}

  # Votes recorded in the fleet move the open key's two vote figures.
  def handle_info(
        {:proposals_changed, fleet_id},
        %{assigns: %{key_profile: %{fleet_id: fleet_id, issued?: true}}} = socket
      ) do
    {:noreply,
     socket
     |> KeyProfileLive.refresh_votes()
     |> FleetLive.refresh_activity_soon(fleet_id)}
  end

  def handle_info({:proposals_changed, fleet_id}, socket),
    do: {:noreply, FleetLive.refresh_activity_soon(socket, fleet_id)}

  # A new reading of the fleet's balances, every minute, may carry
  # income, so the open key's rewards are read again with it.
  def handle_info(
        {:balances_changed, fleet_id},
        %{assigns: %{key_profile: %{fleet_id: fleet_id}}} = socket
      ),
      do: {:noreply, KeyProfileLive.refresh_rewards(socket)}

  def handle_info({:balances_changed, _fleet_id}, socket), do: {:noreply, socket}

  def handle_info(:refresh_proposals = message, socket),
    do: ProposalsLive.handle_info(message, socket)

  # Time has passed on an open fleet page: its agents' statuses are read
  # again, and the page waits for the next minute. A page that has left the
  # fleet stops.
  def handle_info(:refresh_check_ins, %{assigns: %{fleet: %{agents: _}}} = socket) do
    # "Who's here", the key list and the open key's agent, as the agents'
    # check-ins say now.
    {:noreply,
     socket
     |> assign(:check_ins_timer, nil)
     |> FleetLive.refresh_agents()
     |> FleetLive.reread_listed()
     |> KeyProfileLive.refresh_key_shards()
     |> FleetLive.watch_check_ins()}
  end

  def handle_info(:refresh_check_ins, socket),
    do: {:noreply, assign(socket, :check_ins_timer, nil)}

  def handle_info({:refresh_activity, _fleet_id} = message, socket),
    do: FleetLive.handle_info(message, socket)

  @impl true
  def handle_async({Read, _name, _generation} = name, result, socket) do
    {:noreply, socket |> Read.settle(name, result) |> report_connection_outcome()}
  end

  def handle_async(:rewards, result, socket),
    do: KeyProfileLive.handle_async(:rewards, result, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      route_spec={@route_spec}
      account_control={@account_control}
      shell_instance={@shell_instance}
    >
      <:content>
        <AccountLive.page
          :if={@route_spec.route_id == :account}
          account={current_account(@access_context)}
          account_control={@account_control}
          verified_connections={@verified_connections}
          verified_connections_notice={@verified_connections_notice}
          held_keys={@held_keys}
        />

        <FleetLive.page
          :if={@route_spec.route_id == :fleet}
          fleet={@fleet}
          actor={actor(@access_context)}
          params={@fleet_params}
          keys={@streams.fleet_keys}
          profile={@key_profile}
          thread={@streams.key_thread}
          activity={@streams.activity}
          now={FleetLive.now_shown(@activity)}
          send_agent_open={@send_agent_open}
        />

        <KeysLive.page
          :if={@route_spec.route_id == :keys}
          key={@key}
          actor={actor(@access_context)}
        />

        <RoomsLive.page
          :if={@route_spec.route_id == :rooms}
          room={@room}
          posts={@streams.posts}
          post_form={@post_form}
          naming_form={@naming_form}
          notice={@room_notice}
        />

        <WorkspaceLive.board
          :if={@route_spec.route_id == :workspace}
          board={@workspace}
          notebooks_notice={@notebooks_notice}
        />
        <WorkspaceLive.item :if={@route_spec.route_id == :workspace_item} item={@workspace} />
        <ProposalsLive.list
          :if={@route_spec.route_id == :proposals}
          page={@proposals}
          actor={actor(@access_context)}
        />
        <ProposalsLive.detail
          :if={@route_spec.route_id == :proposal}
          page={@proposals}
          actor={actor(@access_context)}
        />
      </:content>
    </.shell>
    """
  end

  defp current_account(%{principal: {:human, account}}), do: account
  defp current_account(_access_context), do: nil

  # The page starts listening for changed keys before it reads, so a change
  # that lands while it loads still reaches it. The map is told when the key
  # chosen changes under it: back or forward, or another fleet's page.
  defp load_fleet(socket, %{route_id: :fleet}, %{"fleet_id" => fleet_id} = params) do
    shown = socket.assigns.fleet

    socket
    |> listen_to(fleet_id)
    |> follow_workspace(fleet_id)
    |> follow_proposals(fleet_id)
    |> FleetLive.read_fleet(params)
    |> FleetLive.tell_map_chosen(shown)
    |> FleetLive.watch_check_ins()
  end

  defp load_fleet(socket, _route_spec, _params),
    do:
      socket
      |> assign(fleet: nil, fleet_params: nil, activity: nil, activity_refresh: nil)
      |> stream(:fleet_keys, [], reset: true)
      |> stream(:activity, [], reset: true)

  # The fleet whose keys the page on show follows: the fleet's own page, or
  # one of its keys' pages.
  defp keys_fleet(%{route_id: route_id}, %{"fleet_id" => fleet_id})
       when route_id in [:fleet, :keys],
       do: fleet_id

  defp keys_fleet(_route_spec, _params), do: nil

  # A person signed in hears when their own mutes change, on any of their
  # pages, for as long as the page is open.
  defp follow_mutes(socket) do
    muter = Muter.of(human_actor(socket))
    if connected?(socket) and muter != nil, do: start_listening(Muter.topic(muter))
    socket
  end

  # One subscription to the keys of the fleet on show, dropped on the way out.
  defp follow_keys(socket, fleet_id) do
    topic = fleet_id && Keys.topic(fleet_id)

    if connected?(socket) and topic != socket.assigns.keys_topic do
      stop_listening(socket.assigns.keys_topic)
      start_listening(topic)
      assign(socket, :keys_topic, topic)
    else
      socket
    end
  end

  # The key named in the address opens over its fleet's page. The fleet's page
  # has already started listening to the fleet's rooms and votes, so a message
  # that lands while the key loads still reaches it.
  defp load_key_profile(%{assigns: %{fleet: %{chosen_key: token_id} = fleet}} = socket, before)
       when is_integer(token_id),
       do: KeyProfileLive.read_key_profile(socket, fleet, token_id, before)

  defp load_key_profile(socket, _before),
    do: socket |> assign(:key_profile, nil) |> stream(:key_thread, [], reset: true)

  defp load_key(socket, %{route_id: :keys}, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    assign(socket, :key, KeysLive.key_view(socket, fleet_id, String.to_integer(token_id)))
  end

  defp load_key(socket, _route_spec, _params), do: assign(socket, :key, nil)

  # The page starts listening before it reads, so a post that lands while it
  # loads still reaches it; a notice for a post it already read is passed over.
  defp load_room(socket, %{route_id: :rooms}, %{"fleet_id" => fleet_id, "slug" => slug}) do
    socket
    |> listen_to(fleet_id)
    |> RoomsLive.read_room(fleet_id, slug)
  end

  # A fleet's page keeps listening to the fleet's rooms.
  defp load_room(socket, _route_spec, _params) do
    socket
    |> listen_to(fleet_on_show(socket))
    |> assign(room: nil, room_notice: nil, post_form: nil, naming_form: nil)
  end

  defp fleet_on_show(%{assigns: %{fleet: %{fleet_id: fleet_id}}}), do: fleet_id
  defp fleet_on_show(_socket), do: nil

  # One subscription per fleet, taken up on the way into its rooms and dropped
  # on the way out, so a page only hears about the fleet it is showing.
  defp listen_to(socket, fleet_id) do
    topic = fleet_id && Rooms.fleet_topic(fleet_id)

    if connected?(socket) and topic != socket.assigns.room_topic do
      stop_listening(socket.assigns.room_topic)
      start_listening(topic)
      assign(socket, :room_topic, topic)
    else
      socket
    end
  end

  defp stop_listening(nil), do: :ok
  defp stop_listening(topic), do: Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, topic)

  defp start_listening(nil), do: :ok
  defp start_listening(topic), do: Phoenix.PubSub.subscribe(Keyfleet.PubSub, topic)

  # The page starts listening before it reads, so a change that lands while it
  # loads still reaches it. Each visit, reconnection included, reads afresh.
  defp load_workspace(socket, %{route_id: route_id}, %{"fleet_id" => fleet_id} = params)
       when route_id in [:workspace, :workspace_item] do
    socket
    |> follow_workspace(fleet_id)
    |> assign(workspace_params: params, notebooks_notice: nil)
    |> WorkspaceLive.read_workspace()
  end

  # A fleet's page keeps hearing about the fleet's workspace.
  defp load_workspace(socket, _route_spec, _params) do
    socket
    |> follow_workspace(fleet_on_show(socket))
    |> assign(workspace: nil, workspace_params: nil)
  end

  defp follow_workspace(socket, fleet_id) do
    topic = fleet_id && Graph.head_topic(fleet_id)

    if connected?(socket) and topic != socket.assigns.workspace_topic do
      stop_listening(socket.assigns.workspace_topic)
      start_listening(topic)
      assign(socket, :workspace_topic, topic)
    else
      socket
    end
  end

  # The page starts listening before it reads, so votes recorded while it
  # loads still reach it. Each visit, reconnection included, reads afresh.
  defp load_proposals(socket, %{route_id: route_id}, %{"fleet_id" => fleet_id} = params)
       when route_id in [:proposals, :proposal] do
    socket
    |> follow_proposals(fleet_id)
    |> assign(:proposals_params, params)
    |> ProposalsLive.read_proposals()
  end

  # A fleet's page keeps hearing about the fleet's votes.
  defp load_proposals(socket, _route_spec, _params) do
    socket
    |> follow_proposals(fleet_on_show(socket))
    |> assign(proposals: nil, proposals_params: nil)
  end

  defp follow_proposals(socket, fleet_id) do
    topic = fleet_id && Proposals.topic(fleet_id)

    if connected?(socket) and topic != socket.assigns.proposals_topic do
      stop_listening(socket.assigns.proposals_topic)
      start_listening(topic)
      assign(socket, :proposals_topic, topic)
    else
      socket
    end
  end

  defp load_verified_connections(socket, %{route_id: :account}),
    do: read_verified_connections(socket)

  defp load_verified_connections(socket, _route_spec) do
    socket
    |> Read.clear(:verified_connections)
    |> assign(verified_connections_notice: nil, connection_outcome: nil)
  end

  # The account's own record is the only thing a connection is read from, so
  # nothing the browser reports can name a connection the record does not hold.
  defp read_verified_connections(socket) do
    case human_actor(socket) do
      %Human{} = actor ->
        Read.start(socket, :verified_connections, actor.human_account_id, fn ->
          Accounts.list_my_linked_identities(actor: actor)
        end)

      nil ->
        Read.clear(socket, :verified_connections)
    end
  end

  defp report_connection_outcome(%{assigns: %{connection_outcome: nil}} = socket), do: socket

  defp report_connection_outcome(
         %{assigns: %{verified_connections: %Read{state: :loading}}} = socket
       ),
       do: socket

  defp report_connection_outcome(%{assigns: assigns} = socket) do
    params = assigns.connection_outcome

    notice =
      with %Read{state: state, value: identities} when state in [:ready, :empty] <-
             assigns.verified_connections,
           {:ok, provider} <- Providers.parse(params["provider"]),
           {:ok, action} <- identity_action(params["action"]) do
        connection_outcome(params["error"], action, provider, identities)
      else
        _unknown_outcome -> connection_outcome(params["error"])
      end

    assign(socket, verified_connections_notice: notice, connection_outcome: nil)
  end

  defp load_held_keys(socket, %{route_id: :account}),
    do: assign(socket, :held_keys, AccountLive.held_keys(human_actor(socket)))

  defp load_held_keys(socket, _route_spec), do: assign(socket, :held_keys, [])

  defp identity_request("link", provider, _identities) do
    {:ok, %{action: :link, provider: provider}}
  end

  defp identity_request("unlink", provider, identities) when is_list(identities) do
    case Enum.find(identities, &(&1.provider == provider)) do
      nil -> {:error, :not_connected}
      identity -> {:ok, %{action: :unlink, provider: provider, subject: identity.subject}}
    end
  end

  defp identity_request(_action, _provider, _identities), do: {:error, :invalid_action}

  defp identity_action("link"), do: {:ok, :link}
  defp identity_action("unlink"), do: {:ok, :unlink}
  defp identity_action(_action), do: {:error, :invalid_action}

  # X and GitHub take the whole tab to their own approval page and bring it
  # back; Farcaster asks for a scan here.
  defp connection_started(%{action: :link, provider: :farcaster}),
    do: "Scan the code with Farcaster to approve the connection."

  defp connection_started(%{action: :link, provider: provider}),
    do: "Taking you to #{Providers.label(provider)} to approve the connection."

  defp connection_started(%{action: :unlink, provider: provider}),
    do: "Disconnecting #{Providers.label(provider)}…"

  defp connection_outcome("already-connected"),
    do: %{tone: :error, message: "That account is already connected to another account here."}

  defp connection_outcome(error) when is_binary(error) and error != "",
    do: %{tone: :error, message: "That connection couldn’t be verified. Try again."}

  defp connection_outcome(_none), do: nil

  defp connection_outcome(error, _action, _provider, _identities)
       when is_binary(error) and error != "",
       do: connection_outcome(error)

  defp connection_outcome(_none, action, provider, identities) do
    label = Providers.label(provider)

    case {action, Enum.any?(identities, &(&1.provider == provider))} do
      {:link, true} ->
        %{tone: :success, message: "#{label} connected."}

      {:link, false} ->
        %{tone: :error, message: "#{label} didn’t come back connected. Try again."}

      {:unlink, false} ->
        %{tone: :success, message: "#{label} disconnected."}

      {:unlink, true} ->
        %{tone: :error, message: "#{label} is still connected. Try again."}
    end
  end

  @doc "The signed-in person the page acts for, or nil; the area pages act as them too."
  def human_actor(%{assigns: %{access_context: access_context}}), do: actor(access_context)
  def human_actor(_socket), do: nil

  defp actor(%{principal: {:human, account}}), do: Human.for_account(account)
  defp actor(_access_context), do: nil
end

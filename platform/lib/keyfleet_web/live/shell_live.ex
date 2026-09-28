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
  alias Keyfleet.Chain
  alias Keyfleet.Chain.RewardsWaiting
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Profile
  alias Keyfleet.Proposals
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Checks.RoomPoster
  alias Keyfleet.Rooms.Errors.RenameTooSoonError

  alias KeyfleetWeb.{
    AccountLive,
    FleetLive,
    KeyLinks,
    KeyMap,
    KeysLive,
    ProposalsLive,
    ProposalsPage,
    Read,
    RoomsLive,
    WorkspaceLive,
    WorkspacePage
  }

  alias KeyfleetWeb.RouteCatalog

  @identity_providers %{"x" => :x, "github" => :github, "farcaster" => :farcaster}
  @naming_failed "That room couldn’t be named. Try again."
  @thread_page 100
  # A page left open keeps the latest two hundred posts.
  @thread_kept 200
  # A key's profile keeps the latest hundred messages written to it.
  @key_thread_kept 100
  # How long a workspace page waits after a notice of changes before it reads
  # them, so a burst of writes is read once.
  @workspace_refresh_after 1_000
  # The same for a proposals page after a notice that the fleet's proposal
  # records or balances changed.
  @proposals_refresh_after 1_000
  @fleet_events ~w(open_send_agent close_send_agent activity_earlier keymap_ready select_key)
  @key_events ~w(approve_pairing set_limits decline_pairing detach_operator)

  @impl true
  def mount(params, session, socket) do
    {:ok,
     socket
     |> stream_configure(:posts, dom_id: &"post-#{&1.id}")
     |> stream(:posts, [])
     |> stream_configure(:fleet_keys, dom_id: &"fleet-key-#{&1.token_id}")
     |> stream(:fleet_keys, [])
     |> stream_configure(:key_thread, dom_id: &"key-message-#{&1.id}")
     |> stream(:key_thread, [])
     |> stream_configure(:activity, dom_id: &FleetLive.activity_dom_id/1)
     |> stream(:activity, [])
     |> assign(
       theme: session["theme"],
       route_spec: RouteCatalog.fetch!(socket.assigns.live_action, params),
       shell_instance: System.unique_integer([:positive, :monotonic]),
       verified_connections: %Read{},
       verified_connections_notice: nil,
       connection_outcome: nil,
       held_keys: [],
       fleet: nil,
       fleet_params: nil,
       keys_topic: nil,
       activity: nil,
       activity_refresh: nil,
       key_profile: nil,
       key: nil,
       key_notice: nil,
       key_drafts: %{},
       room: nil,
       room_notice: nil,
       room_topic: nil,
       send_key: nil,
       workspace: nil,
       workspace_params: nil,
       workspace_topic: nil,
       workspace_refresh?: false,
       proposals: nil,
       proposals_params: nil,
       proposals_topic: nil,
       proposals_refresh?: false,
       launch_plans: nil,
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
       |> load_verified_connections(route_spec)
       |> load_held_keys(route_spec)
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
         {:ok, provider} <- linked_identity_provider(provider),
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

  def handle_event(event, params, socket) when event in @key_events,
    do: KeysLive.handle_event(event, params, socket)

  def handle_event("send_message", %{"post" => %{"body" => body}}, socket) do
    {:noreply, post(socket, body)}
  end

  def handle_event("post_to_key", %{"post" => %{"body" => body}}, socket) do
    {:noreply, post_to_key(socket, body)}
  end

  # A key the visitor arrived on closes by taking it out of the address in
  # place, so closing adds no step to go back through.
  def handle_event(
        "close_key",
        _params,
        %{assigns: %{key_profile: %{fleet_id: fleet_id}}} = socket
      ) do
    {:noreply,
     push_patch(socket,
       to: KeyLinks.closed_path(fleet_id, socket.assigns.fleet_params),
       replace: true
     )}
  end

  def handle_event("close_key", _params, socket), do: {:noreply, socket}

  def handle_event(event, params, socket) when event in @fleet_events,
    do: FleetLive.handle_event(event, params, socket)

  def handle_event("name_room", %{"room" => %{"topic" => topic}}, socket)
      when is_binary(topic) do
    {:noreply, name_room(socket, topic)}
  end

  def handle_event("name_room", _params, socket),
    do: {:noreply, refuse_naming(socket, @naming_failed)}

  # The outcome is judged against the connections read after the provider came
  # back, so it waits for that read to land.
  def handle_event("refresh_verified_connections", params, socket) do
    {:noreply,
     socket
     |> assign(connection_outcome: params, verified_connections_notice: nil)
     |> read_verified_connections()}
  end

  # A notice that the open room has taken a post it is not showing yet is only a
  # nudge to look again. The new posts are read back from the room itself.
  @impl true
  def handle_info(
        {:room_head, room_id, seq},
        %{assigns: %{room: %{room_id: room_id, last_seq: last_seq}}} = socket
      )
      when seq > last_seq,
      do: {:noreply, show_new_posts(socket)}

  # The page only hears about the rooms of the fleet it shows.
  def handle_info({:room_head, _room_id, _seq}, socket),
    do: {:noreply, FleetLive.refresh_activity_soon(socket, fleet_on_show(socket))}

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
      |> refresh_key_profile(token_ids)
      |> FleetLive.refresh_activity_soon(fleet_id)

    progress = socket.assigns.fleet.progress

    case KeyMap.change(fleet_id, progress, token_ids, human_actor(socket)) do
      :reset -> {:noreply, push_event(socket, "keymap:reset", %{})}
      {:patch, patch} -> {:noreply, push_event(socket, "keymap:patch", patch)}
    end
  end

  # A notice for a fleet the page has since left, or one not yet on sale.
  def handle_info({:keys_changed, fleet_id, _token_ids}, socket),
    do: {:noreply, FleetLive.refresh_activity_soon(socket, fleet_id)}

  # Something written as, or to, the open key or another of its holder's keys:
  # the key's new messages are read from its thread, and its posts again.
  def handle_info(
        {:key_activity, fleet_id, token_id},
        %{assigns: %{key_profile: %{fleet_id: fleet_id, issued?: true} = profile}} = socket
      ) do
    if token_id == profile.token_id or token_id in profile.holder_keys,
      do: {:noreply, show_key_activity(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:key_activity, _fleet_id, _token_id}, socket), do: {:noreply, socket}

  # A room created or named in the fleet on show changes its list of rooms, and
  # the room on show when it is the one named.
  def handle_info({:rooms_changed, fleet_id}, %{assigns: %{room: %{fleet_id: fleet_id}}} = socket) do
    rooms = Rooms.list_rooms!(fleet_id, actor: human_actor(socket), load: [:fleet])
    {:noreply, update(socket, :room, &show_rooms(&1, rooms))}
  end

  def handle_info({:rooms_changed, _fleet_id}, socket), do: {:noreply, socket}

  # A notice that the open fleet's workspace has moved past what the page last
  # read is only a nudge to read it again, once, a moment later: the notices
  # that come in the meantime are answered by that one read.
  def handle_info(
        {:graph_head, fleet_id, run_id, watermark},
        %{assigns: %{workspace: %{fleet_id: fleet_id, seen: seen}}} = socket
      ) do
    if moved?(seen, run_id, watermark) and not socket.assigns.workspace_refresh? do
      Process.send_after(self(), :refresh_workspace, @workspace_refresh_after)
      {:noreply, assign(socket, :workspace_refresh?, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:graph_head, fleet_id, _run_id, _watermark}, socket),
    do: {:noreply, FleetLive.refresh_activity_soon(socket, fleet_id)}

  def handle_info(:refresh_workspace, %{assigns: %{workspace: %{}}} = socket),
    do: {:noreply, socket |> assign(:workspace_refresh?, false) |> read_workspace()}

  def handle_info(:refresh_workspace, socket),
    do: {:noreply, assign(socket, :workspace_refresh?, false)}

  # A notice that the open fleet's proposal records or balances changed is a
  # nudge to read its page again, once, a moment later, like the workspace's.
  def handle_info(
        {notice, fleet_id},
        %{assigns: %{proposals: %{fleet_id: fleet_id}}} = socket
      )
      when notice in [:proposals_changed, :balances_changed] do
    if socket.assigns.proposals_refresh? do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh_proposals, @proposals_refresh_after)
      {:noreply, assign(socket, :proposals_refresh?, true)}
    end
  end

  # Votes recorded in the fleet move the open key's two vote figures.
  def handle_info(
        {:proposals_changed, fleet_id},
        %{assigns: %{key_profile: %{fleet_id: fleet_id, issued?: true} = profile}} = socket
      ) do
    votes = Profile.votes(fleet_id, profile.token_id, profile.holder)

    {:noreply,
     socket
     |> assign(:key_profile, Map.merge(profile, votes))
     |> FleetLive.refresh_activity_soon(fleet_id)}
  end

  def handle_info({:proposals_changed, fleet_id}, socket),
    do: {:noreply, FleetLive.refresh_activity_soon(socket, fleet_id)}

  def handle_info({:balances_changed, _fleet_id}, socket), do: {:noreply, socket}

  def handle_info(:refresh_proposals, %{assigns: %{proposals: %{}}} = socket),
    do: {:noreply, socket |> assign(:proposals_refresh?, false) |> read_proposals()}

  def handle_info(:refresh_proposals, socket),
    do: {:noreply, assign(socket, :proposals_refresh?, false)}

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
     |> refresh_key_operator()
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

  # A read for a key no longer open is dropped.
  def handle_async(:rewards, result, %{assigns: %{key_profile: %{issued?: true}}} = socket),
    do: {:noreply, update(socket, :key_profile, &%{&1 | rewards: rewards_shown(result)})}

  def handle_async(:rewards, _result, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      route_spec={@route_spec}
      account_control={@account_control}
      shell_instance={@shell_instance}
      theme={@theme}
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
          notice={@key_notice}
          drafts={@key_drafts}
        />

        <RoomsLive.page
          :if={@route_spec.route_id == :rooms}
          room={@room}
          posts={@streams.posts}
          notice={@room_notice}
        />

        <WorkspaceLive.board :if={@route_spec.route_id == :workspace} board={@workspace} />
        <WorkspaceLive.item :if={@route_spec.route_id == :workspace_item} item={@workspace} />
        <ProposalsLive.list
          :if={@route_spec.route_id == :proposals}
          page={@proposals}
          actor={actor(@access_context)}
          launch_plans={@launch_plans}
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
    |> follow_keys(fleet_id)
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
      |> follow_keys(nil)
      |> assign(fleet: nil, fleet_params: nil, activity: nil, activity_refresh: nil)
      |> stream(:fleet_keys, [], reset: true)
      |> stream(:activity, [], reset: true)

  defp refresh_key_operator(%{assigns: %{key_profile: %{issued?: true} = shown}} = socket),
    do:
      assign(socket, :key_profile, %{
        shown
        | operator: Profile.operator(shown.fleet_id, shown.token_id)
      })

  defp refresh_key_operator(socket), do: socket

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

  # The key named in the address opens over its fleet's page. The page starts
  # listening to the fleet's rooms and votes before it reads, so a message
  # that lands while it loads still reaches it.
  defp load_key_profile(%{assigns: %{fleet: %{chosen_key: token_id} = fleet}} = socket, before)
       when is_integer(token_id) do
    socket = socket |> listen_to(fleet.fleet_id) |> follow_proposals(fleet.fleet_id)
    profile = Profile.read(fleet.fleet_id, token_id, human_actor(socket))

    socket
    |> assign(
      :key_profile,
      profile
      |> Map.delete(:thread)
      |> Map.merge(%{
        close: closing(before, fleet.fleet_id),
        news: nil,
        notice: nil,
        draft: "",
        send_key: Ash.UUID.generate()
      })
    )
    |> read_rewards(before)
    |> stream(:key_thread, key_thread(profile), reset: true, limit: -@key_thread_kept)
  end

  defp load_key_profile(socket, _before),
    do: socket |> assign(:key_profile, nil) |> stream(:key_thread, [], reset: true)

  # What an issued key has waiting is read from the chain once the window is
  # open, so the window never waits for the chain. The same key shown again
  # keeps the figure it has.
  defp read_rewards(
         %{assigns: %{key_profile: %{fleet_id: fleet_id, token_id: token_id}}} = socket,
         %{
           key_profile: %{fleet_id: fleet_id, token_id: token_id, rewards: {:ok, _amount} = shown}
         }
       ),
       do: update(socket, :key_profile, &Map.put(&1, :rewards, shown))

  defp read_rewards(
         %{assigns: %{fleet: fleet, key_profile: %{issued?: true, token_id: token_id}}} = socket,
         _before
       ) do
    rewards = Map.take(fleet, [:fleet_id, :rewards_address, :usdc_address])
    client = Chain.Client.configured()

    socket
    |> update(:key_profile, &Map.put(&1, :rewards, :reading))
    |> start_async(:rewards, fn -> RewardsWaiting.read(rewards, token_id, client) end)
  end

  defp read_rewards(socket, _before), do: socket

  defp rewards_shown({:ok, {:ok, amount}}), do: {:ok, amount}
  defp rewards_shown(_failed), do: :failed

  # The messages written to a key; the next key on sale has none yet.
  defp key_thread(%{issued?: true, thread: thread}), do: thread
  defp key_thread(%{issued?: false}), do: []

  # How the profile closes: by going back when the fleet's page opened it, so
  # Close and Back agree; in place when the visitor arrived with the key in
  # the address. Another key opened while a profile is open takes its place in
  # the address rather than adding a step, so it closes as the first one did.
  defp closing(%{fleet: %{fleet_id: fleet_id, chosen_key: nil}}, fleet_id), do: "back"
  defp closing(%{key_profile: %{fleet_id: fleet_id, close: close}}, fleet_id), do: close
  defp closing(_before, _fleet_id), do: "replace"

  # The open key is read again when it was sold, or when it or another key
  # changed hands to or from its holder. What the visitor was writing stays,
  # and the thread keeps its messages. Otherwise only who may write is checked
  # again: the visitor may have bought their first key, or the fleet's key
  # ownership become fresh.
  defp refresh_key_profile(%{assigns: %{key_profile: %{} = shown}} = socket, token_ids) do
    if holder_moved?(shown, token_ids) do
      profile = Profile.read(shown.fleet_id, shown.token_id, human_actor(socket))

      socket
      |> assign(
        :key_profile,
        profile
        |> Map.delete(:thread)
        |> Map.merge(Map.take(shown, [:close, :news, :notice, :draft, :send_key]))
      )
      |> read_rewards(%{key_profile: shown})
      |> stream(:key_thread, key_thread(profile), limit: -@key_thread_kept)
    else
      recheck_composer(socket)
    end
  end

  defp refresh_key_profile(socket, _token_ids), do: socket

  defp holder_moved?(%{issued?: false, token_id: token_id}, token_ids), do: token_id in token_ids

  defp holder_moved?(%{issued?: true, fleet_id: fleet_id, holder: holder}, token_ids),
    do: Profile.held_any?(fleet_id, holder, token_ids)

  # The next key on sale has no thread, so no one writes to it yet. A notice
  # about the last message sent goes once what the profile says about writing
  # has changed, which explains it.
  defp recheck_composer(%{assigns: %{key_profile: %{issued?: true} = profile}} = socket) do
    case Profile.composer(human_actor(socket), profile.fleet_id) do
      composer when composer == profile.composer -> socket
      composer -> assign(socket, :key_profile, %{profile | composer: composer, notice: nil})
    end
  end

  defp recheck_composer(socket), do: socket

  # Only the messages after the last one on show are read and added.
  defp show_key_activity(%{assigns: %{key_profile: profile}} = socket) do
    %{fleet_id: fleet_id, token_id: token_id} = profile
    messages = Profile.thread_after(fleet_id, token_id, profile.last_seq)

    socket
    |> assign(
      :key_profile,
      profile
      |> Map.merge(Profile.activity(fleet_id, token_id, profile.holder))
      |> Map.merge(%{
        last_seq: Profile.last_seq(messages, profile.last_seq),
        news: if(messages != [], do: "New message to Key #{Rules.grouped(token_id)}.")
      })
    )
    |> stream(:key_thread, messages, limit: -@key_thread_kept)
  end

  # The message is written straight to the key's thread, and the profile then
  # reads back what the thread holds after the last message it was showing.
  defp post_to_key(%{assigns: %{key_profile: %{issued?: true} = profile}} = socket, body) do
    %{fleet_id: fleet_id, token_id: token_id} = profile

    case Rooms.send_to_key(
           %{
             fleet_id: fleet_id,
             token_id: token_id,
             body: body,
             idempotency_key: profile.send_key
           },
           actor: human_actor(socket)
         ) do
      {:ok, _message} ->
        socket
        |> update(:key_profile, &%{&1 | draft: "", notice: nil, send_key: Ash.UUID.generate()})
        |> show_key_activity()
        |> update(:key_profile, &%{&1 | news: nil})

      {:error, refusal} ->
        socket
        |> update(:key_profile, &%{&1 | draft: body, notice: post_refusal(refusal, fleet_id)})
        |> recheck_composer()
    end
  end

  defp post_to_key(socket, _body), do: socket

  defp load_key(socket, %{route_id: :keys}, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    assign(socket,
      key: KeysLive.key_view(socket, fleet_id, String.to_integer(token_id)),
      key_notice: nil,
      key_drafts: %{}
    )
  end

  defp load_key(socket, _route_spec, _params),
    do: assign(socket, key: nil, key_notice: nil, key_drafts: %{})

  # The page starts listening before it reads, so a post that lands while it
  # loads still reaches it; a notice for a post it already read is passed over.
  defp load_room(socket, %{route_id: :rooms}, %{"fleet_id" => fleet_id, "slug" => slug}) do
    socket = listen_to(socket, fleet_id)
    actor = human_actor(socket)
    # A fleet outside the catalog has no rooms, and the page says it doesn't exist.
    rooms =
      case Rooms.list_rooms(fleet_id, actor: actor, load: [:fleet]) do
        {:ok, rooms} -> rooms
        {:error, %Ash.Error.Invalid{errors: [%UnknownFleetError{}]}} -> []
      end

    room = Enum.find(rooms, &(&1.slug == slug))
    posts = latest_posts(room, actor)

    socket
    |> assign(
      room:
        show_rooms(
          %{
            fleet_id: fleet_id,
            slug: slug,
            fleet_name: fleet_name(rooms),
            last_seq: last_seq(posts, 0),
            can_post?: room != nil and RoomPoster.may_post?(actor, fleet_id),
            naming: "",
            refreshing?: posting_paused?(actor, rooms, fleet_id),
            draft: ""
          },
          rooms
        ),
      room_notice: nil,
      send_key: Ash.UUID.generate()
    )
    |> stream(:posts, posts, reset: true, limit: -@thread_kept)
  end

  # A fleet's page keeps listening to the fleet's rooms.
  defp load_room(socket, _route_spec, _params) do
    socket
    |> listen_to(fleet_on_show(socket))
    |> assign(room: nil, room_notice: nil, send_key: nil)
  end

  defp fleet_on_show(%{assigns: %{fleet: %{fleet_id: fleet_id}}}), do: fleet_id
  defp fleet_on_show(_socket), do: nil

  # The fleet's rooms, and what the page shows of the one it is on.
  defp show_rooms(%{slug: slug} = shown, rooms) do
    room = Enum.find(rooms, &(&1.slug == slug))

    Map.merge(shown, %{
      rooms: rooms,
      room_id: room && room.id,
      kind: room && room.kind,
      name: room && RoomsLive.room_label(room),
      topic: room && room.topic,
      topic_set_by: room && room.topic_set_by,
      topic_set_at: room && room.topic_set_at
    })
  end

  # Every fleet opens with its rooms, so a fleet with none is one there is not.
  defp fleet_name([room | _rooms]), do: room.fleet.name
  defp fleet_name([]), do: nil

  # Only someone signed in to a live fleet is told that posting waits on key
  # ownership being refreshed; everyone else is told who can post.
  defp posting_paused?(%Human{}, [room | _rooms], fleet_id),
    do: room.fleet.contract_address != nil and not Chain.fresh?(fleet_id)

  defp posting_paused?(_actor, _rooms, _fleet_id), do: false

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

  # Places in a room's order run unbroken, so the newest hundred posts start one
  # hundred places back from where the room has got to.
  defp latest_posts(nil, _actor), do: []

  defp latest_posts(room, actor),
    do: posts_after(room.fleet_id, room.slug, max(room.head_seq - @thread_page, 0), actor)

  # Only the posts after the last one on the page are read and added to it.
  defp show_new_posts(%{assigns: %{room: room}} = socket) do
    posts = posts_after(room.fleet_id, room.slug, room.last_seq, human_actor(socket))

    socket
    |> assign(:room, %{room | last_seq: last_seq(posts, room.last_seq)})
    |> stream(:posts, posts, limit: -@thread_kept)
  end

  defp posts_after(fleet_id, slug, after_seq, actor) do
    Rooms.read_messages!(fleet_id, slug, %{after_seq: after_seq, limit: @thread_page},
      actor: actor,
      load: [:reply_to_seq]
    )
  end

  defp last_seq([], shown), do: shown
  defp last_seq(posts, _shown), do: List.last(posts).seq

  # The post is written straight to the room, and the page then reads back what
  # the room holds after the last post it was showing.
  defp post(%{assigns: %{room: %{fleet_id: fleet_id, slug: slug}}} = socket, body) do
    actor = human_actor(socket)

    case Rooms.send_message(
           %{
             fleet_id: fleet_id,
             slug: slug,
             body: body,
             idempotency_key: socket.assigns.send_key
           },
           actor: actor
         ) do
      {:ok, _message} ->
        socket
        |> assign(send_key: Ash.UUID.generate(), room_notice: nil)
        |> update(:room, &%{&1 | draft: ""})
        |> show_new_posts()

      {:error, refusal} ->
        socket
        |> assign(:room_notice, %{tone: :error, message: post_refusal(refusal, fleet_id)})
        |> update(
          :room,
          &%{
            &1
            | draft: body,
              can_post?: &1.can_post? and RoomPoster.may_post?(actor, fleet_id),
              refreshing?: posting_paused?(actor, &1.rooms, fleet_id)
          }
        )
    end
  end

  defp post(socket, _body), do: socket

  # The room is named straight away, and the page then reads back the room and
  # the line the naming added to it.
  defp name_room(%{assigns: %{room: %{fleet_id: fleet_id, slug: slug}}} = socket, topic) do
    actor = human_actor(socket)

    case Rooms.name_open_room(fleet_id, slug, topic, actor: actor) do
      {:ok, _room} ->
        rooms = Rooms.list_rooms!(fleet_id, actor: actor, load: [:fleet])

        socket
        |> assign(:room_notice, nil)
        |> update(:room, &(&1 |> show_rooms(rooms) |> Map.put(:naming, "")))
        |> show_new_posts()

      {:error, refusal} ->
        socket
        |> refuse_naming(naming_refusal(refusal, fleet_id))
        |> update(
          :room,
          &%{
            &1
            | naming: topic,
              can_post?: &1.can_post? and RoomPoster.may_post?(actor, fleet_id),
              refreshing?: posting_paused?(actor, &1.rooms, fleet_id)
          }
        )
    end
  end

  defp name_room(socket, _topic), do: socket

  defp refuse_naming(%{assigns: %{room: %{}}} = socket, refusal),
    do: assign(socket, :room_notice, %{tone: :error, message: refusal})

  defp refuse_naming(socket, _refusal), do: socket

  defp naming_refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Chain.fresh?(fleet_id),
      do: "Only the people holding this fleet’s keys can name a room.",
      else: KeysLive.refreshing()
  end

  defp naming_refusal(%Ash.Error.Invalid{errors: errors} = refusal, _fleet_id) do
    cond do
      Rooms.taken?(refusal, :name) ->
        "That name is already another room’s name in this fleet."

      Enum.any?(errors, &match?(%RenameTooSoonError{}, &1)) ->
        "This room was renamed a moment ago. Try again in a minute."

      Enum.any?(errors, &match?(%{field: :topic}, &1)) ->
        "Choose a name of up to 80 characters, on one line, using only visible characters."

      true ->
        @naming_failed
    end
  end

  defp naming_refusal(_refusal, _fleet_id), do: @naming_failed

  defp post_refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Chain.fresh?(fleet_id),
      do:
        "Only the people holding this fleet’s keys, and the agents they have attached, can post here.",
      else: KeysLive.refreshing()
  end

  defp post_refusal(_refusal, _fleet_id), do: "That post didn’t go through. Try again."

  # The page starts listening before it reads, so a change that lands while it
  # loads still reaches it. Each visit, reconnection included, reads afresh.
  defp load_workspace(socket, %{route_id: route_id}, %{"fleet_id" => fleet_id} = params)
       when route_id in [:workspace, :workspace_item] do
    socket
    |> follow_workspace(fleet_id)
    |> assign(:workspace_params, params)
    |> read_workspace()
  end

  # A fleet's page keeps hearing about the fleet's workspace.
  defp load_workspace(socket, _route_spec, _params) do
    socket
    |> follow_workspace(fleet_on_show(socket))
    |> assign(workspace: nil, workspace_params: nil)
  end

  defp read_workspace(%{assigns: %{route_spec: %{route_id: :workspace}}} = socket) do
    params = socket.assigns.workspace_params

    assign(
      socket,
      :workspace,
      WorkspacePage.board(params["fleet_id"], params, human_actor(socket))
    )
  end

  defp read_workspace(%{assigns: %{route_spec: %{route_id: :workspace_item}}} = socket) do
    params = socket.assigns.workspace_params

    assign(
      socket,
      :workspace,
      WorkspacePage.item(params["fleet_id"], params["object_id"], params, human_actor(socket))
    )
  end

  # A copy of another log, or a place further on in the same one.
  defp moved?({run_id, seen_seq}, run_id, watermark), do: watermark > seen_seq
  defp moved?(_seen, _run_id, _watermark), do: true

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
  # loads still reach it. Each visit, reconnection included, reads afresh;
  # the launch plans the launch form offers are read only then, since the
  # form keeps what it first showed.
  defp load_proposals(socket, %{route_id: route_id}, %{"fleet_id" => fleet_id} = params)
       when route_id in [:proposals, :proposal] do
    socket
    |> follow_proposals(fleet_id)
    |> assign(:proposals_params, params)
    |> assign(:launch_plans, if(route_id == :proposals, do: ProposalsPage.launch_plans(fleet_id)))
    |> read_proposals()
  end

  # A fleet's page keeps hearing about the fleet's votes.
  defp load_proposals(socket, _route_spec, _params) do
    socket
    |> follow_proposals(fleet_on_show(socket))
    |> assign(proposals: nil, proposals_params: nil, launch_plans: nil)
  end

  defp read_proposals(socket) do
    params = socket.assigns.proposals_params

    page =
      case socket.assigns.route_spec.route_id do
        :proposals -> ProposalsPage.list(params["fleet_id"], params)
        :proposal -> ProposalsPage.detail(params["fleet_id"], params["number"], params)
      end

    assign(socket, proposals: page)
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
           {:ok, provider} <- linked_identity_provider(params["provider"]),
           {:ok, action} <- identity_action(params["action"]) do
        connection_outcome(params["error"], action, provider, identities)
      else
        _unknown_outcome -> connection_outcome(params["error"])
      end

    assign(socket, verified_connections_notice: notice, connection_outcome: nil)
  end

  defp load_held_keys(socket, %{route_id: :account}),
    do: assign(socket, :held_keys, held_keys(human_actor(socket)))

  defp load_held_keys(socket, _route_spec), do: assign(socket, :held_keys, [])

  # Every key the signed-in person's wallets hold, fleet by fleet in catalog
  # order, leaving out fleets where they hold none.
  defp held_keys(nil), do: []

  defp held_keys(%Human{wallet_addresses: wallets} = actor) do
    for %{id: fleet_id, name: name} <- Fleets.catalog(),
        keys = Keys.keys_held_in_fleet!(fleet_id, wallets, actor: actor),
        keys != [],
        do: %{fleet_id: fleet_id, name: name, token_ids: Enum.map(keys, & &1.token_id)}
  end

  defp linked_identity_provider(provider) do
    case Map.fetch(@identity_providers, provider) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :invalid_provider}
    end
  end

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

  defp actor(%{principal: {:human, account}}),
    do: %Human{human_account_id: account.id, wallet_addresses: account_wallets(account)}

  defp actor(_access_context), do: nil

  defp account_wallets(account) do
    [account.wallet_address | List.wrap(account.wallet_addresses)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end

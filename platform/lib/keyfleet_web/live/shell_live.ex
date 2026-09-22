defmodule KeyFleetWeb.ShellLive do
  @moduledoc """
  One LiveView holds the header, sidebar and account control across every in-app
  route and patches between them, so the frame never remounts on navigation.
  """

  use KeyFleetWeb, :live_view

  import KeyFleetWeb.Components.Shell

  alias KeyFleet.Accounts
  alias KeyFleet.Accounts.LinkedIdentity.Providers
  alias KeyFleet.Actors.Human
  alias KeyFleet.Chain
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Rooms
  alias KeyFleet.Rooms.Checks.FleetMember
  alias KeyFleetWeb.{AccountLive, FleetLive, KeysLive, NotFoundError, OverviewLive, RoomsLive}
  alias KeyFleetWeb.RouteCatalog

  @identity_providers %{"x" => :x, "github" => :github, "farcaster" => :farcaster}
  @refused "That didn’t go through."
  @refreshing "Key ownership is being refreshed; try again in a moment."
  @thread_page 100
  # A page left open keeps the latest two hundred posts.
  @thread_kept 200

  @impl true
  def mount(params, session, socket) do
    {:ok,
     socket
     |> stream_configure(:posts, dom_id: &"post-#{&1.id}")
     |> stream(:posts, [])
     |> stream_configure(:fleet_keys, dom_id: &"fleet-key-#{&1.token_id}")
     |> stream(:fleet_keys, [])
     |> assign(
       theme: session["theme"],
       route_spec: RouteCatalog.fetch!(socket.assigns.live_action, params),
       shell_instance: System.unique_integer([:positive, :monotonic]),
       verified_connections: [],
       verified_connections_notice: nil,
       fleet: nil,
       key: nil,
       key_notice: nil,
       room: nil,
       room_notice: nil,
       room_topic: nil,
       send_key: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    route_spec = RouteCatalog.fetch!(socket.assigns.live_action, params)

    {:noreply,
     socket
     |> assign(:route_spec, route_spec)
     |> load_verified_connections(route_spec)
     |> load_fleet(route_spec, params)
     |> load_key(route_spec, params)
     |> load_room(route_spec, params)}
  end

  @impl true
  def handle_event(
        "request_verified_connection",
        %{"action" => action, "provider" => provider},
        socket
      ) do
    with %Human{} <- human_actor(socket),
         {:ok, provider} <- linked_identity_provider(provider),
         {:ok, request} <- identity_request(action, provider, socket.assigns.verified_connections) do
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

  def handle_event("approve_pairing", %{"id" => id}, socket),
    do: {:noreply, decide(socket, id, &Keys.approve_pairing/3, "That agent now runs this key.")}

  def handle_event("decline_pairing", %{"id" => id}, socket),
    do: {:noreply, decide(socket, id, &Keys.decline_pairing/3, "Request turned down.")}

  def handle_event("detach_operator", %{"id" => id}, socket),
    do: {:noreply, decide(socket, id, &Keys.detach_operator/3, "Operator detached.")}

  def handle_event("send_message", %{"post" => %{"body" => body}}, socket) do
    {:noreply, post(socket, body)}
  end

  def handle_event("refresh_verified_connections", params, socket) do
    socket = reload_verified_connections(socket)

    notice =
      with {:ok, provider} <- linked_identity_provider(params["provider"]),
           {:ok, action} <- identity_action(params["action"]) do
        connection_outcome(params["error"], action, provider, socket.assigns.verified_connections)
      else
        _unknown_outcome -> connection_outcome(params["error"])
      end

    {:noreply, assign(socket, verified_connections_notice: notice)}
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

  def handle_info({:room_head, _room_id, _seq}, socket), do: {:noreply, socket}

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
        <OverviewLive.page
          :if={@route_spec.route_id == :app}
          account_control={@account_control}
          account={current_account(@access_context)}
        />

        <AccountLive.page
          :if={@route_spec.route_id == :account}
          account={current_account(@access_context)}
          account_control={@account_control}
          verified_connections={@verified_connections}
          verified_connections_notice={@verified_connections_notice}
        />

        <FleetLive.page
          :if={@route_spec.route_id == :fleet}
          fleet={@fleet}
          keys={@streams.fleet_keys}
        />

        <KeysLive.page :if={@route_spec.route_id == :keys} key={@key} notice={@key_notice} />

        <RoomsLive.page
          :if={@route_spec.route_id == :rooms}
          room={@room}
          posts={@streams.posts}
          notice={@room_notice}
        />
      </:content>
    </.shell>
    """
  end

  defp current_account(%{principal: {:human, account}}), do: account
  defp current_account(_access_context), do: nil

  defp load_fleet(socket, %{route_id: :fleet}, %{"fleet_id" => fleet_id} = params) do
    actor = human_actor(socket)

    case Fleets.get_fleet!(fleet_id, actor: actor) do
      nil ->
        socket
        |> assign(:fleet, %{fleet_id: fleet_id, name: nil})
        |> stream(:fleet_keys, [], reset: true)

      fleet ->
        page = key_page!(fleet_id, params, actor)
        deployed? = fleet.contract_address != nil
        current? = deployed? and Chain.fresh?(fleet_id)

        socket
        |> assign(:fleet, %{
          fleet_id: fleet_id,
          name: fleet.name,
          contract_address: fleet.contract_address,
          deployed?: deployed?,
          current?: current?,
          progress: if(current?, do: Chain.progress(fleet_id)),
          rooms: Rooms.list_rooms!(fleet_id, actor: actor),
          no_keys?: page.results == [] and not paged?(params),
          pages: page_links(fleet_id, page, params)
        })
        |> stream(:fleet_keys, fleet_keys(fleet_id, page.results, actor), reset: true)
    end
  end

  defp load_fleet(socket, _route_spec, _params),
    do: socket |> assign(:fleet, nil) |> stream(:fleet_keys, [], reset: true)

  # A page is named by the key it follows or precedes; a name that isn't one
  # is a page that doesn't exist.
  defp key_page!(fleet_id, params, actor) do
    case Keys.keys_in_fleet(fleet_id, page: key_position(params), actor: actor) do
      {:ok, page} -> page
      {:error, %Ash.Error.Invalid{}} -> raise NotFoundError
    end
  end

  defp key_position(%{"after" => keyset}) when is_binary(keyset), do: [after: keyset]
  defp key_position(%{"before" => keyset}) when is_binary(keyset), do: [before: keyset]
  defp key_position(params), do: if(paged?(params), do: raise(NotFoundError), else: [])

  defp paged?(params), do: Map.has_key?(params, "after") or Map.has_key?(params, "before")

  # A page reached by going forward always has one before it, and one reached by
  # going back always has one after it.
  defp page_links(_fleet_id, %Ash.Page.Keyset{results: []}, _params),
    do: %{previous: nil, next: nil}

  defp page_links(fleet_id, %Ash.Page.Keyset{results: keys, more?: more?}, params) do
    {previous?, next?} =
      case params do
        %{"after" => _keyset} -> {true, more?}
        %{"before" => _keyset} -> {more?, true}
        _first_page -> {false, more?}
      end

    %{
      previous:
        if(previous?, do: fleet_page_path(fleet_id, before: hd(keys).__metadata__.keyset)),
      next: if(next?, do: fleet_page_path(fleet_id, after: List.last(keys).__metadata__.keyset))
    }
  end

  defp fleet_page_path(fleet_id, position),
    do: "/app/fleets/#{fleet_id}?#{URI.encode_query(position)}"

  defp fleet_keys(fleet_id, keys, actor) do
    operators =
      Map.new(
        Keys.fleet_operators!(fleet_id, Enum.map(keys, & &1.token_id), actor: actor),
        &{&1.token_id, &1.agent_profile.name}
      )

    for key <- keys do
      %{
        token_id: key.token_id,
        owner_wallet: key.owner_wallet,
        operator_name: operators[key.token_id]
      }
    end
  end

  defp load_key(socket, %{route_id: :keys}, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    assign(socket,
      key: key_view(socket, fleet_id, String.to_integer(token_id)),
      key_notice: nil
    )
  end

  defp load_key(socket, _route_spec, _params), do: assign(socket, key: nil, key_notice: nil)

  defp key_view(socket, fleet_id, token_id) do
    actor = human_actor(socket)
    key = Keys.current_key!(fleet_id, token_id, actor: actor, load: [:fleet])

    %{
      fleet_id: fleet_id,
      token_id: token_id,
      fleet_name: key && key.fleet.name,
      owner_wallet: key && key.owner_wallet,
      current_epoch: key && key.ownership_epoch,
      owner?: owns_key?(actor, key),
      refreshing?: not Chain.fresh?(fleet_id),
      operator: Keys.current_operator!(fleet_id, token_id, actor: actor),
      requests: Keys.list_pairing_requests!(fleet_id, token_id, actor: actor),
      history: Keys.pairing_history!(fleet_id, token_id, actor: actor)
    }
  end

  defp owns_key?(%Human{wallet_addresses: wallets}, %{owner_wallet: owner}),
    do: owner in wallets

  defp owns_key?(_actor, _key), do: false

  # The buttons act on what the page is showing; the key itself decides whether
  # the decision still applies, and the page is redrawn from the answer either
  # way, so a page left open on a key that has moved on catches up.
  defp decide(socket, id, decision, message) do
    with %Human{} = actor <- human_actor(socket),
         %{} = pairing <- Enum.find(shown_pairings(socket), &(&1.id == id)),
         {:ok, _decided} <- decision.(pairing, %{}, actor: actor) do
      redraw_key(socket, %{tone: :success, message: message})
    else
      refusal -> redraw_key(socket, %{tone: :error, message: refusal_message(refusal, socket)})
    end
  end

  defp refusal_message({:error, %Ash.Error.Forbidden{}}, %{assigns: %{key: %{fleet_id: fleet_id}}}) do
    if Chain.fresh?(fleet_id), do: @refused, else: @refreshing
  end

  defp refusal_message({:error, %Ash.Error.Invalid{errors: errors}}, _socket) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
      do: "This request was already answered.",
      else: @refused
  end

  defp refusal_message(_refusal, _socket), do: @refused

  defp redraw_key(%{assigns: %{key: %{fleet_id: fleet_id, token_id: token_id}}} = socket, notice) do
    socket
    |> assign(:key, key_view(socket, fleet_id, token_id))
    |> assign(:key_notice, notice)
  end

  defp redraw_key(socket, notice), do: assign(socket, :key_notice, notice)

  defp shown_pairings(%{assigns: %{key: %{operator: operator, requests: requests}}}),
    do: [operator | requests] |> Enum.reject(&is_nil/1)

  defp shown_pairings(_socket), do: []

  # The page starts listening before it reads, so a post that lands while it
  # loads still reaches it; a notice for a post it already read is passed over.
  defp load_room(socket, %{route_id: :rooms}, %{"fleet_id" => fleet_id, "slug" => slug}) do
    socket = listen_to(socket, fleet_id)
    actor = human_actor(socket)
    rooms = Rooms.list_rooms!(fleet_id, actor: actor, load: [:fleet])
    room = Enum.find(rooms, &(&1.slug == slug))
    posts = latest_posts(room, actor)

    socket
    |> assign(
      room: %{
        fleet_id: fleet_id,
        slug: slug,
        room_id: room && room.id,
        name: room && room.name,
        fleet_name: fleet_name(rooms),
        rooms: rooms,
        last_seq: last_seq(posts, 0),
        can_post?: room != nil and FleetMember.member?(actor, fleet_id),
        refreshing?: posting_paused?(actor, rooms, fleet_id),
        draft: ""
      },
      room_notice: nil,
      send_key: Ash.UUID.generate()
    )
    |> stream(:posts, posts, reset: true, limit: -@thread_kept)
  end

  defp load_room(socket, _route_spec, _params) do
    socket
    |> listen_to(nil)
    |> assign(room: nil, room_notice: nil, send_key: nil)
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
  defp stop_listening(topic), do: Phoenix.PubSub.unsubscribe(KeyFleet.PubSub, topic)

  defp start_listening(nil), do: :ok
  defp start_listening(topic), do: Phoenix.PubSub.subscribe(KeyFleet.PubSub, topic)

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
              can_post?: &1.can_post? and FleetMember.member?(actor, fleet_id),
              refreshing?: posting_paused?(actor, &1.rooms, fleet_id)
          }
        )
    end
  end

  defp post(socket, _body), do: socket

  defp post_refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Chain.fresh?(fleet_id),
      do:
        "Only the people holding this fleet’s keys, and the agents they have attached, can post here.",
      else: @refreshing
  end

  defp post_refusal(_refusal, _fleet_id), do: "That post didn’t go through. Try again."

  defp load_verified_connections(socket, %{route_id: :account}),
    do: reload_verified_connections(socket)

  defp load_verified_connections(socket, _route_spec),
    do: assign(socket, verified_connections: [], verified_connections_notice: nil)

  # The account's own record is the only thing a connection is read from, so
  # nothing the browser reports can name a connection the record does not hold.
  defp reload_verified_connections(socket) do
    case human_actor(socket) do
      %Human{} = actor ->
        case Accounts.list_my_linked_identities(actor: actor) do
          {:ok, identities} -> assign(socket, verified_connections: identities)
          {:error, _error} -> assign(socket, verified_connections: [])
        end

      nil ->
        assign(socket, verified_connections: [])
    end
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

  defp identity_request("unlink", provider, identities) do
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

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, account}}}}),
    do: %Human{human_account_id: account.id, wallet_addresses: account_wallets(account)}

  defp human_actor(_socket), do: nil

  defp account_wallets(account) do
    [account.wallet_address | List.wrap(account.wallet_addresses)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end

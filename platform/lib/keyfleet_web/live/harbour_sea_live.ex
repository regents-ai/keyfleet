defmodule KeyfleetWeb.HarbourSeaLive do
  @moduledoc """
  The sea behind the product's pages: Classic #1's harbour on every page and
  for every visitor (`KeyfleetWeb.Components.Shell.get_key_fleet/0`), one ship
  for each of its most recently active Keys, sailing to the island of the
  Key's last action and circling it (`KeyfleetWeb.HarbourCrew`). The visitor's
  own Keys come first, then the most recent, sixteen at most.

  Each of the three buildings opens its part of the fleet: the inn its General
  room, the forge its workspace and the castle its proposals. While the fleet
  is coming soon, those open its own page, which says so. Wherever the sea
  shows between the page's parts, a mouse over a building names it and lifts
  it, and pressing it opens it. The sea takes no other press until its button
  lifts the page away; then pressing a ship opens its card: the Key's last few
  actions and a link to its profile.

  The root layout renders it beside the page's own LiveView
  (`KeyfleetWeb.Router` marks the pages that have it), so it keeps running
  while the visitor moves between pages; the page tells it where it is with
  "show_page". It takes the shell's own sign-in check and shows nothing the
  page itself would not.

  A fleet's ships are drawn from what every visitor who isn't a member sees
  alike, `KeyfleetWeb.FleetNow`, read once for every open page. Only a
  member's ships are read as the visitor, since a member sees more (rooms
  other than General, every item's title). Which ships are the visitor's own
  is read as the visitor, when the fleet comes on show and when its Keys
  change hands.
  """

  use KeyfleetWeb, :live_view

  alias Keyfleet.Access
  alias Keyfleet.Activity
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Room
  alias Keyfleet.SharedReading

  alias KeyfleetWeb.{
    ActivityLines,
    FleetNow,
    HarbourCrew,
    KeyLinks,
    PageRead,
    Read,
    Router,
    ShellLive
  }

  alias KeyfleetWeb.Components.Shell

  alias KeyfleetWeb.Live.Session
  alias KeyfleetWeb.Plugs.LaunchGate
  alias Phoenix.Socket.Broadcast

  # Notices about what the visitor reads as themselves are answered by one
  # read a moment later, and each visitor's moment is spread over two seconds
  # more, so the open pages of a fleet's members don't all read in the same
  # instant. It only delays a read of the visitor's own view.
  @reread_after 1_000
  @spread 2_000

  @doc """
  The sea, as the root layout places it on the page `conn` draws. The page's
  live session is the page's own: its hooks watch navigation, which LiveView
  refuses for a LiveView the router did not mount, so it is left out here and
  this LiveView takes the shell's sign-in check itself (`mount/3`).
  """
  def sea(conn) do
    outside = %{conn | private: Map.delete(conn.private, :phoenix_live_view)}

    live_render(outside, __MODULE__,
      container: {:div, class: "harbour-sea"},
      session: Session.render_context(conn)
    )
  end

  # `fleets` are the fleets on show, each with the visitor's class in it, and
  # `own` the visitor's Keys in each, under the account they were read for.
  # `public` holds each fleet's ships as anyone who isn't a member sees them,
  # `crew` the ships of the fleets the visitor is a member of, read as them.
  # `due` is what the next read for the visitor must read again.
  @impl true
  def mount(params, session, socket) do
    case admit(params, session, socket) do
      {:cont, socket} ->
        {:ok,
         assign(socket,
           path: nil,
           shown: nil,
           fleets: [],
           own: {nil, %{}},
           public: %{},
           crew: %Read{},
           topics: [],
           watched: [],
           due: MapSet.new(),
           agent: nil,
           now: nil
         ), layout: false}

      {:halt, socket} ->
        {:ok, socket}
    end
  end

  # The launch gate and the shell's sign-in (`KeyfleetWeb.Live.Session`): a
  # connection is refused as the shell's is, and every event, notice and read
  # after it checks the sign-in again first. Both hooks also watch navigation,
  # which this LiveView never has and LiveView refuses to a LiveView the router
  # did not mount, so the sign-in is taken as if routed and the watch on
  # navigation is taken off again.
  defp admit(params, session, socket) do
    if connected?(socket) and not LaunchGate.app_surfaces_enabled?() do
      {:halt, redirect(socket, to: ~p"/early")}
    else
      case Session.on_mount(:load_human, params, session, %{socket | router: Router}) do
        {:cont, socket} ->
          {:cont, %{detach_hook(socket, :session_authority_params, :handle_params) | router: nil}}

        {:halt, socket} ->
          {:halt, %{socket | router: nil}}
      end
    end
  end

  # The page on show, by its address. A new address closes the card; the
  # first brings Classic #1's ships.
  @impl true
  def handle_event("show_page", %{"path" => path}, socket) when is_binary(path) do
    socket =
      if path == socket.assigns.path, do: socket, else: assign(socket, path: path, agent: nil)

    {:noreply, kept(socket, fn -> show(socket, Shell.get_key_fleet()) end)}
  end

  def handle_event("show_agent", %{"id" => id}, socket) when is_binary(id) do
    if ship(on_sea(socket.assigns), id),
      do: {:noreply, assign(socket, agent: id, now: DateTime.utc_now())},
      else: {:noreply, socket}
  end

  def handle_event("close_agent", _params, socket), do: {:noreply, assign(socket, :agent, nil)}

  # A page or ship sent without its address or name.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A new reading of a fleet the visitor isn't a member of redraws its ships.
  # One that has gone leaves the sea as it is drawn.
  @impl true
  def handle_info({:shared_reading, {:fleet_now, fleet_id} = key}, socket) do
    if key in socket.assigns.watched,
      do: {:noreply, socket |> draw([fleet_id]) |> close_sailed()},
      else: {:noreply, socket}
  end

  # Anything new in a fleet the visitor is a member of is a nudge to read its
  # ships again, once for a burst; Keys changing hands, to read again which
  # are the visitor's and whether they are a member. Nothing else a fleet says
  # moves a ship: a new reading of a treasury's balances, every minute, least
  # of all.
  def handle_info({:reread, shown}, %{assigns: %{shown: shown, due: due}} = socket) do
    socket = assign(socket, :due, MapSet.new())
    {:noreply, kept(socket, fn -> reread(socket, due) end)}
  end

  def handle_info({:reread, _left}, socket), do: {:noreply, socket}
  def handle_info(%Broadcast{}, socket), do: {:noreply, crew_soon(socket)}
  def handle_info({:graph_head, _fleet, _run, _mark}, socket), do: {:noreply, crew_soon(socket)}
  def handle_info({:graph_notable, _fleet}, socket), do: {:noreply, crew_soon(socket)}
  def handle_info({:proposals_changed, _fleet}, socket), do: {:noreply, crew_soon(socket)}

  def handle_info({:keys_changed, fleet_id, _keys}, socket) do
    if List.keymember?(socket.assigns.fleets, fleet_id, 0),
      do: {:noreply, reread_soon(socket, {:keys, fleet_id})},
      else: {:noreply, socket}
  end

  def handle_info(_notice, socket), do: {:noreply, socket}

  @impl true
  def handle_async({Read, _name, _generation} = name, result, socket),
    do: {:noreply, socket |> Read.settle(name, result) |> close_sailed()}

  # The card of a Key that has sailed off the sea closes with it.
  defp close_sailed(%{assigns: %{agent: nil}} = socket), do: socket

  defp close_sailed(socket) do
    if ship(on_sea(socket.assigns), socket.assigns.agent),
      do: socket,
      else: assign(socket, :agent, nil)
  end

  defp show(%{assigns: %{shown: shown}} = socket, shown), do: socket

  # The visitor's class and Keys in the fleet are read before anything is
  # heard, so a read that fails leaves the sea, and what it hears, as it was.
  defp show(socket, shown) do
    actor = ShellLive.human_actor(socket)
    fleets = [{shown, Access.class(actor, shown)}]
    own = Map.new(fleets, fn {fleet_id, _class} -> {fleet_id, owned(actor, fleet_id)} end)

    socket
    |> assign(
      shown: shown,
      fleets: fleets,
      own: {reader(socket.assigns.access_context), own},
      due: MapSet.new()
    )
    |> follow(actor)
    |> draw(for {fleet_id, class} <- fleets, class != :member, do: fleet_id)
    |> read_crew()
  end

  # What a reread names, read again: the class and Keys of each fleet whose
  # Keys changed hands, and the ships of the fleets the visitor is a member
  # of when anything in them changed. A fleet the visitor left is drawn from
  # its shared reading again; one they joined is read as them.
  defp reread(socket, due) do
    actor = ShellLive.human_actor(socket)
    reader = reader(socket.assigns.access_context)
    rechecked = for {:keys, fleet_id} <- due, do: fleet_id
    {owner, own} = socket.assigns.own
    own = if owner == reader, do: own, else: %{}

    fleets =
      for {fleet_id, class} <- socket.assigns.fleets do
        {fleet_id, if(fleet_id in rechecked, do: Access.class(actor, fleet_id), else: class)}
      end

    own = Map.merge(own, Map.new(rechecked, &{&1, owned(actor, &1)}))

    redrawn =
      for {fleet_id, class} <- fleets, class != :member, fleet_id in rechecked, do: fleet_id

    crew? = :crew in due or Enum.any?(rechecked, &({&1, :member} in fleets))

    socket =
      socket |> assign(fleets: fleets, own: {reader, own}) |> follow(actor) |> draw(redrawn)

    if crew?, do: read_crew(socket), else: socket
  end

  # The sea stays as it is when the visitor's part can't be read; the next
  # page, or the next notice about the fleets it shows, reads it again.
  defp kept(socket, read) do
    case PageRead.run("harbour", read) do
      {:ok, read_socket} -> read_socket
      {:error, _failure} -> socket
    end
  end

  defp crew_soon(socket), do: reread_soon(socket, :crew)

  # The first notice of a burst sets the moment; the rest join it.
  defp reread_soon(socket, reason) do
    %{due: due, shown: shown} = socket.assigns

    if MapSet.size(due) == 0 do
      wait = @reread_after + :rand.uniform(@spread + 1) - 1
      Process.send_after(self(), {:reread, shown}, wait)
    end

    assign(socket, :due, MapSet.put(due, reason))
  end

  # What the visitor hears of each fleet on show. A member hears what the
  # shell hears for their class: its rooms, its workspace and its votes. Anyone
  # else hears its shared reading, which hears those for everyone. A signed-in
  # visitor also hears its Keys, which change which ships are theirs and
  # whether they are a member; a signed-out one holds none.
  defp follow(socket, actor) do
    %{fleets: fleets, topics: topics_was, watched: watched_was} = socket.assigns
    topics = Enum.flat_map(fleets, fn {fleet_id, class} -> topics(fleet_id, class, actor) end)
    watched = for {fleet_id, class} <- fleets, class != :member, do: FleetNow.key(fleet_id)

    Enum.each(topics_was -- topics, &Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, &1))
    Enum.each(topics -- topics_was, &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))
    Enum.each(watched_was -- watched, &SharedReading.unsubscribe/1)
    Enum.each(watched -- watched_was, &SharedReading.subscribe/1)
    assign(socket, topics: topics, watched: watched)
  end

  defp topics(fleet_id, :member, _actor),
    do: [
      Rooms.topic(fleet_id, :member),
      Graph.topic(fleet_id, :member),
      Proposals.topic(fleet_id),
      Keys.topic(fleet_id)
    ]

  defp topics(_fleet_id, _class, nil), do: []
  defp topics(fleet_id, _class, _actor), do: [Keys.topic(fleet_id)]

  # The ships of `fleet_ids` from their shared readings, heard first. A fleet
  # whose reading is absent keeps the ships it has; a fleet gone from the sea
  # takes its ships with it.
  defp draw(socket, fleet_ids) do
    %{fleets: fleets, public: public} = socket.assigns

    public =
      Enum.reduce(
        fleet_ids,
        Map.take(public, Enum.map(fleets, &elem(&1, 0))),
        fn fleet_id, public ->
          case FleetNow.fetch(fleet_id) do
            {%{coming_soon?: false, feed: %{items: items}}, _degraded?} ->
              Map.put(public, fleet_id, HarbourCrew.ships(fleet_id, items))

            {%{coming_soon?: true}, _degraded?} ->
              Map.put(public, fleet_id, [])

            nil ->
              public
          end
        end
      )

    assign(socket, :public, public)
  end

  # The ships of the fleets the visitor is a member of are read beside the
  # page, as the visitor, after listening to those fleets, so a change that
  # lands while they load still reaches them.
  defp read_crew(socket) do
    actor = ShellLive.human_actor(socket)

    case for({fleet_id, :member} <- socket.assigns.fleets, do: fleet_id) do
      [] ->
        socket

      fleet_ids ->
        Read.start(socket, :crew, reader(socket.assigns.access_context), fn ->
          {:ok,
           Map.new(fleet_ids, fn fleet_id ->
             %{items: items} = Activity.page(fleet_id, nil, actor: actor)
             {fleet_id, HarbourCrew.ships(fleet_id, items)}
           end)}
        end)
    end
  end

  # The Keys the visitor holds in a fleet; a signed-out visitor holds none.
  defp owned(actor, fleet_id), do: MapSet.new(Keys.held_keys(actor, fleet_id), & &1.token_id)

  # The ships on the sea: each fleet's, as the visitor's class there sees it,
  # the visitor's own Keys first, then the most recently active. What was read
  # for the visitor shows only while they are signed in as they were then: a
  # sign-in that ends while the page is open takes it away with it. A fleet
  # the visitor has just joined shows as anyone sees it until their own read
  # of it lands; one they have left shows only as anyone sees it.
  defp drawn(fleets, public, crew, {owner, own}, access_context) do
    reader = reader(access_context)
    read = if crew.owner == reader, do: crew.value || %{}, else: %{}
    own = if owner == reader, do: own, else: %{}

    fleets
    |> Enum.flat_map(fn {fleet_id, class} ->
      mine = Map.get(own, fleet_id, MapSet.new())

      ships =
        if class == :member,
          do: read[fleet_id] || public[fleet_id],
          else: public[fleet_id]

      for ship <- ships || [], do: Map.put(ship, :own?, MapSet.member?(mine, ship.token_id))
    end)
    |> HarbourCrew.sea()
  end

  # The three buildings as the hook reads them, in `data-harbour-places`: the
  # name each shows under the mouse and the part of Classic #1 it opens.
  defp places do
    fleet = Fleets.path(Shell.get_key_fleet())

    Jason.encode!(%{
      inn: %{name: "General chat", href: "#{fleet}/rooms/#{Room.public_slug()}"},
      forge: %{name: "Workspace", href: "#{fleet}/workspace"},
      castle: %{name: "Proposals", href: "#{fleet}/proposals"}
    })
  end

  defp on_sea(assigns),
    do: drawn(assigns.fleets, assigns.public, assigns.crew, assigns.own, assigns.access_context)

  defp ship(ships, id), do: Enum.find(ships, &(&1.id == id))

  defp reader(%{principal: {:human, account}}), do: account.id
  defp reader(_access_context), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="harbour"
      class="harbour-sea__harbour"
      phx-hook="HarbourSea"
      phx-mounted={JS.ignore_attributes(["data-harbour-ready"])}
      data-harbour-layout="sea"
      data-harbour-crew={HarbourCrew.on_sea(drawn(@fleets, @public, @crew, @own, @access_context))}
      data-harbour-places={places()}
      aria-hidden="true"
    >
      <div id="harbour-stage" class="harbour-sea__stage" phx-update="ignore" data-harbour-stage>
        <canvas id="harbour-canvas" data-harbour-canvas></canvas>
        <span class="harbour-sea__tag" data-harbour-tag hidden></span>
      </div>
    </div>
    <button
      id="sea-lift"
      type="button"
      class="harbour-sea__lift"
      aria-controls="app-shell"
      aria-pressed="false"
      aria-label="Show the sea"
      title="Show the sea"
      phx-click={
        JS.toggle_class("sea-lifted", to: "body")
        |> JS.toggle_attribute({"aria-pressed", "true", "false"})
        |> JS.toggle_attribute({"aria-label", "Bring the page back", "Show the sea"})
        |> JS.toggle_attribute({"title", "Bring the page back", "Show the sea"})
      }
    >
      <svg viewBox="0 0 20 20" aria-hidden="true">
        <path d="M4 12l6-6 6 6M4 16h12" fill="none" stroke="currentColor" stroke-width="1.5" />
      </svg>
    </button>
    <.agent_card
      :if={ship = @agent && ship(drawn(@fleets, @public, @crew, @own, @access_context), @agent)}
      ship={ship}
      now={@now}
    />
    """
  end

  attr :ship, :map, required: true
  attr :now, DateTime, required: true

  # A Key's card: its name, its last actions and a link to its profile. It
  # opens as it is rendered and closes with its X, Escape or a new page.
  defp agent_card(assigns) do
    ~H"""
    <dialog
      id="harbour-agent"
      class="harbour-card"
      phx-hook="ModalDialog"
      phx-mounted={JS.ignore_attributes(["open", "style"])}
      data-close-event="close_agent"
      data-shown={@ship.id}
      aria-labelledby="harbour-agent-title"
    >
      <header class="harbour-card__head">
        <span class="harbour-card__sail" style={"--sail: #{@ship.color}"}></span>
        <div>
          <h2 id="harbour-agent-title" tabindex="-1" data-modal-title>{@ship.name}</h2>
          <p>{@ship.key}</p>
        </div>
        <form method="dialog">
          <button type="submit" class="harbour-card__close" aria-label="Close">
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path
                d="M3 3l10 10M13 3L3 13"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
              />
            </svg>
          </button>
        </form>
      </header>
      <ol class="harbour-card__actions" aria-label="Recent actions">
        <li :for={action <- @ship.actions}>
          <span>{action.text}</span>
          <time datetime={DateTime.to_iso8601(action.at)}>
            {KeyfleetWeb.Time.moment(action.at, @now)}
          </time>
        </li>
      </ol>
      <.link class="harbour-card__key" patch={KeyLinks.key_path(@ship.fleet_id, @ship.token_id)}>
        Open {ActivityLines.key_name(@ship.token_id, nil)}
      </.link>
    </dialog>
    """
  end
end

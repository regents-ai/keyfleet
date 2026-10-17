defmodule KeyfleetWeb.HarbourSeaLive do
  @moduledoc """
  The sea behind the product's pages: one ship for each of the most recently
  active Keys, sailing to the island of the Key's last action and circling it.
  The inn is a chat, the forge is work in the workspace and the castle is a
  proposal or a vote. Sales, transfers and shards move no ship.

  On a fleet's pages the ships are that fleet's Keys; anywhere else they are
  the latest Keys of every open fleet. The visitor's own Keys come first, then
  the most recent, sixteen at most. The sea takes no presses until its button
  lifts the page away; then pressing a ship opens its card: the Key's last few
  actions and a link to its profile.

  The root layout renders it beside the page's own LiveView
  (`KeyfleetWeb.Router` marks the pages that have it), so it keeps running
  while the visitor moves between pages; the page tells it where it is with
  "show_page". It reads as the visitor, under the shell's own sign-in check,
  and shows nothing the page itself would not.
  """

  use KeyfleetWeb, :live_view

  alias Keyfleet.Access
  alias Keyfleet.Activity
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Rooms

  alias KeyfleetWeb.{
    ActivityLines,
    DirectoryMD,
    Endpoint,
    KeyLinks,
    Read,
    RouteCatalog,
    Router,
    ShellLive
  }

  alias KeyfleetWeb.Live.Session
  alias KeyfleetWeb.Plugs.LaunchGate
  alias Phoenix.Socket.Broadcast

  # The island each kind of activity sends a ship to.
  @places %{
    post: "inn",
    posts: "inn",
    room_named: "inn",
    created: "forge",
    claimed: "forge",
    unclaimed: "forge",
    progress: "forge",
    status: "forge",
    revised: "forge",
    archived: "forge",
    linked: "forge",
    proposed: "castle",
    votes: "castle"
  }

  # The kinds whose facts name the key that did them as `by`.
  @by_kinds ~w(post room_named created claimed unclaimed progress status revised archived linked)a

  # The sails' inks; a Key keeps its ink on every page.
  @inks {"#e4572e", "#17bebb", "#f2c14e", "#7b61ff", "#4caf50", "#2e86de"}

  # The sea holds sixteen ships, and a card lists a Key's last four actions.
  @ships 16
  @kept 4

  # Notices about the fleets on show are answered by one read a moment later.
  @reread_after 1_000

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

  @impl true
  def mount(params, session, socket) do
    case admit(params, session, socket) do
      {:cont, socket} ->
        {:ok,
         assign(socket,
           path: nil,
           shown: nil,
           topics: [],
           reread_due?: false,
           crew: %Read{},
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

  # The page on show, by its address. A new address closes the card; a new
  # fleet brings its ships.
  @impl true
  def handle_event("show_page", %{"path" => path}, socket) when is_binary(path) do
    socket =
      if path == socket.assigns.path, do: socket, else: assign(socket, path: path, agent: nil)

    shown = shown(path)

    if shown == socket.assigns.shown,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(shown: shown, reread_due?: false) |> read_crew()}
  end

  def handle_event("show_agent", %{"id" => id}, socket) when is_binary(id) do
    if ship(socket.assigns.crew, socket.assigns.access_context, id),
      do: {:noreply, assign(socket, agent: id, now: DateTime.utc_now())},
      else: {:noreply, socket}
  end

  def handle_event("close_agent", _params, socket), do: {:noreply, assign(socket, :agent, nil)}

  # Anything new in the fleets on show is a nudge to read their ships again,
  # once for a burst. Nothing else they say moves a ship: a new reading of a
  # treasury's balances, every minute, least of all.
  @impl true
  def handle_info({:reread, shown}, %{assigns: %{shown: shown}} = socket),
    do: {:noreply, socket |> assign(:reread_due?, false) |> read_crew()}

  def handle_info({:reread, _left}, socket), do: {:noreply, socket}
  def handle_info(%Broadcast{}, socket), do: {:noreply, reread_soon(socket)}
  def handle_info({:graph_head, _fleet, _run, _mark}, socket), do: {:noreply, reread_soon(socket)}
  def handle_info({:graph_notable, _fleet}, socket), do: {:noreply, reread_soon(socket)}
  def handle_info({:proposals_changed, _fleet}, socket), do: {:noreply, reread_soon(socket)}
  def handle_info({:keys_changed, _fleet, _keys}, socket), do: {:noreply, reread_soon(socket)}
  def handle_info(_notice, socket), do: {:noreply, socket}

  # The card of a Key that has sailed off the sea closes with it.
  @impl true
  def handle_async({Read, _name, _generation} = name, result, socket) do
    %{assigns: %{agent: agent, crew: crew, access_context: context}} =
      socket = Read.settle(socket, name, result)

    if agent != nil and ship(crew, context, agent) == nil,
      do: {:noreply, assign(socket, :agent, nil)},
      else: {:noreply, socket}
  end

  defp reread_soon(%{assigns: %{reread_due?: true}} = socket), do: socket

  defp reread_soon(socket) do
    Process.send_after(self(), {:reread, socket.assigns.shown}, @reread_after)
    assign(socket, :reread_due?, true)
  end

  # The fleet whose page is at `path`, when the shell shows that fleet: one
  # that is open. Anywhere else, every open fleet (`:public`).
  defp shown(path) do
    with %{route: route} <- Phoenix.Router.route_info(Router, "GET", path, Endpoint.host()),
         %{fleet_id: fleet_id} when is_binary(fleet_id) <-
           Enum.find(RouteCatalog.entries(), &(&1.path_pattern == route)),
         true <- fleet_id in Fleets.open_fleet_ids() do
      fleet_id
    else
      _elsewhere -> :public
    end
  end

  defp fleets(:public), do: Fleets.open_fleet_ids()
  defp fleets(fleet_id), do: [fleet_id]

  # The ships are read beside the page, as the visitor, after listening to
  # their fleets, so a change that lands while they load still reaches them.
  defp read_crew(socket) do
    actor = ShellLive.human_actor(socket)
    fleet_ids = fleets(socket.assigns.shown)
    reader = actor && actor.human_account_id

    socket
    |> follow(fleet_ids, actor)
    |> Read.start(:crew, reader, fn -> {:ok, crew(fleet_ids, actor)} end)
  end

  # What the visitor's class hears of each fleet, as the shell hears it: its
  # rooms, its workspace, its votes and its Keys, which can change the class.
  defp follow(socket, fleet_ids, actor) do
    topics =
      Enum.flat_map(fleet_ids, fn fleet_id ->
        class = Access.class(actor, fleet_id)

        [
          Rooms.topic(fleet_id, class),
          Graph.topic(fleet_id, class),
          Proposals.topic(fleet_id),
          Keys.topic(fleet_id)
        ]
      end)

    was = socket.assigns.topics
    Enum.each(was -- topics, &Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, &1))
    Enum.each(topics -- was, &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))
    assign(socket, :topics, topics)
  end

  # The visitor's own Keys first, then the most recently active.
  defp crew(fleet_ids, actor) do
    fleet_ids
    |> Enum.flat_map(&fleet_ships(&1, actor))
    |> Enum.sort_by(&{not &1.own?, -DateTime.to_unix(&1.at, :microsecond)})
    |> Enum.take(@ships)
  end

  # Each Key that did something at an island in the first page of the fleet's
  # activity, at the island of its newest action.
  defp fleet_ships(fleet_id, actor) do
    %{items: items} = Activity.page(fleet_id, nil, actor: actor)
    own = MapSet.new(Keys.held_keys(actor, fleet_id), & &1.token_id)
    %{name: fleet} = Enum.find(Fleets.catalog(), &(&1.id == fleet_id))

    items
    |> Enum.flat_map(fn item -> for key <- acting(item), do: {key, item} end)
    |> Enum.group_by(fn {key, _item} -> key.token_id end)
    |> Enum.map(fn {token_id, [{_key, newest} | _] = done} ->
      key = ActivityLines.key_name(token_id, nil)

      %{
        id: "#{fleet_id}:#{token_id}",
        fleet_id: fleet_id,
        token_id: token_id,
        name: name(done) || key,
        key: "#{key} of #{fleet}",
        place: Map.fetch!(@places, newest.kind),
        color: elem(@inks, rem(token_id, tuple_size(@inks))),
        at: newest.at,
        own?: MapSet.member?(own, token_id),
        actions:
          done
          |> Enum.map(&elem(&1, 1))
          |> Enum.uniq_by(& &1.id)
          |> Enum.take(@kept)
          |> Enum.map(&%{text: ActivityLines.text(&1), at: &1.at})
      }
    end)
  end

  # The Keys an item says acted, for the kinds that send a ship somewhere.
  defp acting(%{kind: kind, facts: %{by: %{token_id: _} = by}}) when kind in @by_kinds, do: [by]
  defp acting(%{kind: :posts, facts: %{keys: keys}}), do: keys

  defp acting(%{kind: :proposed, facts: %{proposer: %{token_id: token_id}}})
       when is_integer(token_id),
       do: [%{token_id: token_id, agent: nil}]

  defp acting(%{kind: :votes, facts: facts}) do
    for side <- [:yes, :no, :abstain],
        token_id <- facts[side].token_ids,
        uniq: true,
        do: %{token_id: token_id, agent: nil}
  end

  defp acting(_item), do: []

  # The name of the Key's agent, from its newest action that names one.
  defp name(done) do
    Enum.find_value(done, fn {%{agent: agent}, _item} ->
      if is_binary(agent) and DirectoryMD.visible(agent) != "", do: DirectoryMD.visible(agent)
    end)
  end

  # The ships read for the visitor as they are signed in now. A sign-in that
  # ends while the page is open takes them away with it.
  defp ships(%Read{owner: owner, value: value}, access_context) do
    if owner == reader(access_context), do: value || [], else: []
  end

  defp ship(crew, access_context, id), do: Enum.find(ships(crew, access_context), &(&1.id == id))

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
      data-harbour-crew={
        Jason.encode!(
          Enum.map(ships(@crew, @access_context), &Map.take(&1, [:id, :name, :place, :color]))
        )
      }
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
      :if={ship = @agent && ship(@crew, @access_context, @agent)}
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

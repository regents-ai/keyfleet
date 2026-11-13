defmodule KeyfleetWeb.WorldlineLive do
  @moduledoc """
  A fleet's Worldline, at `/worldline` under the fleet's address, drawn inside
  the fleet's page under its bar (`KeyfleetWeb.FleetLive`): everything the
  reader may read of the fleet along one line, from its oldest event on the
  left to now on the right (`KeyfleetWeb.WorldlinePage`).

  The picture is drawn in the browser (`assets/js/hooks/worldline.ts`). Its
  workspace, code and notebooks are three wide trails around the line, each
  room a thin one with a pixel for each post, and proposals and polls bright
  points on the line itself. The page sends it the newest events once it is
  live, older ones as the reader pans back to them, and new ones a moment
  after they happen. `?show=list` shows the same events as links, newest
  first, with "Older" for the page before. Every event links to the page it
  happened on.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]

  import Phoenix.LiveView,
    only: [connected?: 1, push_event: 3, stream: 3, stream: 4, stream_insert: 4]

  alias Keyfleet.Fleets
  alias KeyfleetWeb.{PageRead, PollsLive, ShellLive, WorldlinePage}

  # How many of each source's events a read takes: the picture's, the
  # list's, and a read of what was just heard.
  @picture_read 100
  @list_read 20
  @heard_read 20

  # Each source the reader reads gives the legend its trail.
  @legend [
    posts: {"chat", "Chat"},
    changes: {"workspace", "Workspace"},
    pushes: {"code", "Code"},
    notebooks: {"notebooks", "Notebooks"},
    opened: {"opened", "Proposals"},
    polls: {"polls", "Polls"}
  ]

  @doc "The fleet's Worldline, as the picture or as the list."
  def worldline_path(fleet_id, show \\ :picture)
  def worldline_path(fleet_id, :picture), do: "#{Fleets.path(fleet_id)}/worldline"

  def worldline_path(fleet_id, :list),
    do: "#{Fleets.path(fleet_id)}/worldline?" <> URI.encode_query(show: "list")

  @doc "The id of an event's line in the list."
  def dom_id(%{id: id}), do: "worldline-" <> String.replace(id, ":", "-")

  @doc """
  The Worldline named in the address, read newest first as the reader. The
  picture is read once the page is live, as only the browser draws it.
  Leaving the Worldline clears it.
  """
  def read(socket, :worldline, %{"fleet_id" => fleet_id} = params) do
    show = if params["show"] == "list", do: :list, else: :picture
    read_as = ShellLive.reads_as(socket, fleet_id)

    worldline = %{
      fleet_id: fleet_id,
      show: show,
      state: :read,
      cursor: nil,
      empty?: false,
      heard: [],
      legend:
        for(
          {source, trail} <- @legend,
          source in WorldlinePage.sources(fleet_id, read_as),
          do: trail
        )
    }

    socket = stream(socket, :worldline, [], reset: true)

    if show == :picture and not connected?(socket),
      do: assign(socket, :worldline, worldline),
      else: read_newest(socket, worldline, read_as)
  end

  def read(%{assigns: %{worldline: nil}} = socket, _route_id, _params), do: socket

  def read(socket, _route_id, _params),
    do: socket |> assign(:worldline, nil) |> stream(:worldline, [], reset: true)

  defp read_newest(socket, %{fleet_id: fleet_id, show: show} = worldline, read_as) do
    case PageRead.run("worldline", fn ->
           WorldlinePage.page(fleet_id, nil, [limit: limit(show)] ++ read_as)
         end) do
      {:ok, %{events: events, cursor: cursor}} ->
        socket
        |> assign(:worldline, %{worldline | cursor: cursor, empty?: events == []})
        |> show_newest(show, events, cursor)

      {:error, _failure} ->
        assign(socket, :worldline, %{worldline | state: :unreadable})
    end
  end

  defp limit(:picture), do: @picture_read
  defp limit(:list), do: @list_read

  # The picture takes the time it was read by, so it draws now where the
  # events have it, whatever the reader's own clock says.
  defp show_newest(socket, :picture, events, cursor) do
    push_event(socket, "worldline:page", %{
      events: Enum.map(events, &payload/1),
      older: cursor != nil,
      now: System.system_time(:millisecond)
    })
  end

  defp show_newest(socket, :list, events, _cursor),
    do: stream(socket, :worldline, Enum.reverse(events), reset: true)

  @doc """
  The page before the oldest on show: the picture asks for it as the reader
  pans back to it and takes it as the reply; the list's "Older" adds it under
  the events on show.
  """
  def handle_event(
        "worldline_older",
        _params,
        %{assigns: %{worldline: %{cursor: cursor} = worldline}} = socket
      )
      when cursor != nil do
    %{events: events, cursor: next} =
      WorldlinePage.page(
        worldline.fleet_id,
        cursor,
        [limit: limit(worldline.show)] ++ ShellLive.reads_as(socket, worldline.fleet_id)
      )

    socket = assign(socket, :worldline, %{worldline | cursor: next})

    case worldline.show do
      :picture -> {:reply, %{events: Enum.map(events, &payload/1), older: next != nil}, socket}
      :list -> {:noreply, stream(socket, :worldline, Enum.reverse(events))}
    end
  end

  def handle_event("worldline_older", _params, socket), do: {:noreply, socket}

  @doc """
  Something happened in one of the Worldline's sources: `:posts`,
  `:changes`, `:pushes`, `:polls` or `:proposals`. A burst is read once, a
  moment later, as the fleet's hall reads its feed.
  """
  def heard(%{assigns: %{worldline: %{state: :read, heard: heard} = worldline}} = socket, source) do
    if heard == [] do
      Process.send_after(
        self(),
        :refresh_worldline,
        Application.fetch_env!(:keyfleet, :fleet_feed_wait_ms)
      )
    end

    sources = if source == :proposals, do: [:opened, :closed], else: [source]
    assign(socket, :worldline, %{worldline | heard: Enum.uniq(heard ++ sources)})
  end

  def heard(socket, _source), do: socket

  @doc "The newest events of the sources heard, added to what is on show."
  def handle_info(
        :refresh_worldline,
        %{assigns: %{worldline: %{heard: [_ | _] = heard} = worldline}} = socket
      ) do
    %{events: events} =
      WorldlinePage.page(
        worldline.fleet_id,
        nil,
        [limit: @heard_read, only: heard] ++ ShellLive.reads_as(socket, worldline.fleet_id)
      )

    socket =
      assign(socket, :worldline, %{
        worldline
        | heard: [],
          empty?: worldline.empty? and events == []
      })

    case worldline.show do
      :picture ->
        {:noreply, push_event(socket, "worldline:heard", %{events: Enum.map(events, &payload/1)})}

      :list ->
        {:noreply, Enum.reduce(events, socket, &stream_insert(&2, :worldline, &1, at: 0))}
    end
  end

  def handle_info(:refresh_worldline, socket), do: {:noreply, socket}

  @doc """
  The reader's class in the fleet changed: the Worldline is read again as it
  now reads, and hears the polls only if it now reads them.
  """
  def class_changed(
        %{assigns: %{worldline: %{fleet_id: fleet_id, show: show}}} = socket,
        fleet_id
      ) do
    params = %{"fleet_id" => fleet_id, "show" => Atom.to_string(show)}
    socket |> PollsLive.read_polls(:worldline, params) |> read(:worldline, params)
  end

  def class_changed(socket, _fleet_id), do: socket

  # An event as the picture takes it: its time in milliseconds and who did it
  # in words.
  defp payload(event) do
    %{
      id: event.id,
      at: DateTime.to_unix(event.at, :millisecond),
      trail: event.trail,
      kind: event.kind,
      who: event.key && "Key #{grouped(event.key)}",
      what: event.what,
      title: event.title,
      path: event.path,
      live: event.live?
    }
  end

  attr :worldline, :map, required: true, doc: "the Worldline as `read/3` reads it"
  attr :events, :any, required: true, doc: "the list's events, as a stream"

  def page(assigns) do
    ~H"""
    <article id="worldline-page" class="worldline-page">
      <section class="worldline-panel" aria-labelledby="worldline-title">
        <header class="worldline-head">
          <h2 id="worldline-title">Worldline</h2>
          <nav id="worldline-show" class="fleet-keys-switch" aria-label="Show the Worldline as">
            <.link
              id="worldline-show-picture"
              patch={worldline_path(@worldline.fleet_id)}
              aria-current={if @worldline.show == :picture, do: "page"}
            >
              Picture
            </.link>
            <.link
              id="worldline-show-list"
              patch={worldline_path(@worldline.fleet_id, :list)}
              aria-current={if @worldline.show == :list, do: "page"}
            >
              List
            </.link>
          </nav>
        </header>

        <ul id="worldline-legend" class="worldline-legend" aria-label="Trails">
          <li :for={{trail, name} <- @worldline.legend} data-trail={trail}>{name}</li>
        </ul>

        <Regent.Primitives.empty_state
          :if={@worldline.state == :unreadable}
          id="worldline-unreadable"
          class="kf-empty"
          title="The Worldline couldn’t be loaded. Refresh the page to try again."
        />

        <.picture
          :if={@worldline.show == :picture and @worldline.state == :read}
          worldline={@worldline}
        />

        <Regent.Primitives.empty_state
          :if={@worldline.state == :read and @worldline.empty?}
          id="worldline-empty"
          class="kf-empty"
          title="Nothing has happened in this fleet yet."
        />

        <ol
          :if={@worldline.show == :list and @worldline.state == :read}
          id="worldline-events"
          class="worldline-events"
          phx-update="stream"
        >
          <li :for={{dom_id, event} <- @events} id={dom_id} data-trail={trail(event)}>
            <.link {to(event)} class="worldline-event">
              <span class="worldline-event__head">
                <span class="worldline-event__what">{event.what}</span>
                <span :if={event.key} class="worldline-event__who">Key {grouped(event.key)}</span>
                <KeyfleetWeb.Time.local
                  id={dom_id <> "-at"}
                  at={event.at}
                  as={:moment}
                  class="worldline-event__at"
                />
              </span>
              <span class="worldline-event__title">{event.title}</span>
            </.link>
          </li>
        </ol>

        <Regent.Primitives.button
          :if={@worldline.show == :list and @worldline.cursor != nil}
          id="worldline-older"
          type="button"
          variant="secondary"
          arrow={false}
          phx-click="worldline_older"
        >
          Older
        </Regent.Primitives.button>
      </section>
    </article>
    """
  end

  attr :worldline, :map, required: true

  # The picture the browser draws, and what stands until it does: the line
  # and its head. One link follows the event pointed at, so it opens as any
  # link does, in a new tab too.
  defp picture(assigns) do
    ~H"""
    <div
      id="worldline-stage"
      class="worldline-stage"
      phx-hook="Worldline"
      phx-update="ignore"
      phx-mounted={
        JS.ignore_attributes(["data-worldline-ready", "data-worldline-still", "data-dragging"])
      }
      tabindex="0"
      role="group"
      aria-labelledby="worldline-title"
      aria-describedby="worldline-help"
    >
      <canvas class="worldline-stage__canvas" data-worldline-canvas aria-hidden="true"></canvas>
      <span class="worldline-stage__line" aria-hidden="true"></span>
      <span class="worldline-stage__head" aria-hidden="true"></span>
      <p class="worldline-stage__still">
        Your browser can’t draw this picture.
        <.link patch={worldline_path(@worldline.fleet_id, :list)}>List</.link>
        has every event.
      </p>
      <a class="worldline-focus" data-worldline-focus draggable="false" hidden>
        <span class="worldline-focus__card" data-focus-card>
          <span class="worldline-focus__what" data-focus-what></span>
          <span class="worldline-focus__title" data-focus-title></span>
          <span class="worldline-focus__meta" data-focus-meta></span>
        </span>
      </a>
    </div>
    <p id="worldline-help" class="worldline-help">
      Drag to move through time. Scroll or pinch to zoom.
      <span class="visually-hidden">
        Arrow keys move through time, plus and minus zoom, and Enter opens the event shown.
      </span>
    </p>
    """
  end

  defp to(%{live?: true, path: path}), do: %{patch: path}
  defp to(%{live?: false, path: path}), do: %{href: path}

  # The colour an event's mark takes, as its legend shows it.
  defp trail(%{trail: "room:" <> _slug}), do: "chat"
  defp trail(%{kind: :poll}), do: "polls"
  defp trail(%{kind: :proposal_opened}), do: "opened"
  defp trail(%{kind: :proposal_closed}), do: "closed"
  defp trail(%{trail: trail}), do: trail
end

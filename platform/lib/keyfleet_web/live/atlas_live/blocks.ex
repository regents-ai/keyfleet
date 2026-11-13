defmodule KeyfleetWeb.AtlasLive.Blocks do
  @moduledoc """
  The Atlas as blocks (`?view=blocks`): a treemap of the window shown, where
  each project is a block as big as the work it holds in the window and
  coloured by how recently it was worked on, with a corner on a block changed
  today. Choosing a block, or zooming into it, opens it in place: a block for
  each kind of work, then a block for each thing, as big as its changes, the
  quieter ones gathered into one more block that opens the same way, then
  the thing itself, linking to its page. A path above the picture goes back
  up. The browser draws it (`assets/js/hooks/atlas_blocks.ts` and
  `assets/js/atlas/blocks/`) and asks for the window's counts and each kind's
  things as the reader opens them (`handle_event/3`); the strip beside it
  lists the most active things of the window, and choosing one opens the
  blocks down to it.
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Atlas.{Source, Span}
  alias KeyfleetWeb.{AtlasLive, AtlasPage, ShellLive, WorkspacePage}

  @thing_read 100

  @doc "The kinds of work, each with its name."
  def kinds do
    for kind <- WorkspacePage.types() ++ [Source.notebook_kind()] do
      if kind == Source.notebook_kind(),
        do: [kind, "Notebooks"],
        else: [kind, elem(WorkspacePage.type_name(kind), 1)]
    end
  end

  attr :atlas, :map, required: true, doc: "the Atlas as `KeyfleetWeb.AtlasLive.read/3` reads it"

  def picture(assigns) do
    {start, finish} = AtlasPage.window(assigns.atlas.window, assigns.atlas.at)
    assigns = assign(assigns, start: start, finish: finish)

    ~H"""
    <Regent.Primitives.empty_state
      :if={@atlas.active != nil and @atlas.rows == []}
      id="atlas-empty"
      class="kf-empty"
      title="Nothing has been worked on in this fleet yet."
    />
    <div :if={@atlas.active == nil or @atlas.rows != []} class="atlas-blocks-layout">
      <div
        id="atlas-blocks"
        class="atlas-blocks"
        phx-hook="AtlasBlocks"
        data-rows={Jason.encode!(for row <- @atlas.rows, do: [row.project, row.title])}
        data-kinds={Jason.encode!(kinds())}
        data-window={@atlas.window}
        data-from={DateTime.to_unix(@start)}
        data-to={DateTime.to_unix(@finish)}
        data-kind={@atlas.source || "all"}
      >
        <nav class="atlas-list__window" aria-label="Move through time">
          <.link
            id="atlas-blocks-earlier"
            patch={
              AtlasLive.moved(@atlas, at: @start |> DateTime.add(-1, :day) |> DateTime.to_date())
            }
          >
            Earlier
          </.link>
          <h3 id="atlas-blocks-window">{AtlasLive.window_label(@atlas.window, @start)}</h3>
          <.link
            id="atlas-blocks-later"
            patch={AtlasLive.moved(@atlas, at: DateTime.to_date(@finish))}
          >
            Later
          </.link>
        </nav>
        <div
          id="atlas-blocks-stage"
          class="atlas-blocks__stage"
          phx-update="ignore"
          tabindex="0"
          role="group"
          aria-labelledby="atlas-title"
          aria-describedby="atlas-help"
          data-blocks-stage
        >
          <nav class="atlas-blocks__trail" aria-label="Path">
            <ol data-blocks-trail></ol>
          </nav>
          <div class="atlas-blocks__surface" data-blocks-surface>
            <canvas class="atlas-blocks__canvas" data-blocks-canvas aria-hidden="true"></canvas>
            <div class="atlas-blocks__names" data-blocks-names></div>
            <p class="atlas-blocks__note" data-blocks-empty hidden>
              Nothing changed in this window.
            </p>
            <p class="atlas-blocks__note atlas-blocks__still">
              Your browser can’t draw this picture.
              <.link patch={AtlasLive.moved(@atlas, show: :list)}>List</.link>
              has all of it.
            </p>
            <p class="atlas-blocks__tip" data-blocks-tip aria-hidden="true" hidden></p>
          </div>
          <div class="atlas-blocks__zoom" role="group" aria-label="Zoom">
            <button type="button" aria-label="Zoom out" data-blocks-zoom="out">−</button>
            <output aria-label="Showing" data-blocks-level></output>
            <button type="button" aria-label="Zoom in" data-blocks-zoom="in">+</button>
          </div>
          <p class="visually-hidden" role="status" data-blocks-said></p>
        </div>
      </div>

      <aside
        :if={@atlas.active}
        id="atlas-active"
        class="atlas-active"
        aria-labelledby="atlas-active-title"
      >
        <header class="atlas-active__head">
          <h3 id="atlas-active-title">Active</h3>
          <p id="atlas-active-window">
            {AtlasLive.window_label(@atlas.active.span, @atlas.active.start)}
          </p>
        </header>
        <ol :if={@atlas.active.things != []} id="atlas-active-things" class="atlas-active__things">
          <li :for={thing <- @atlas.active.things} id={"atlas-active-" <> AtlasLive.dom_id(thing)}>
            <button
              type="button"
              class="atlas-active__thing"
              phx-click={
                JS.dispatch("atlas:focus",
                  to: "#atlas-blocks",
                  detail: %{id: thing.id, project: thing.project, kind: thing.kind}
                )
              }
            >
              <span class="atlas-active__title">{thing.title}</span>
              <span class="atlas-active__meta">
                <span data-kind={thing.kind}>{thing.what}</span>
                · {AtlasLive.changes(thing.changes)}<span :if={thing.actors > 1}> · {thing.actors} Keys</span>
              </span>
            </button>
          </li>
        </ol>
        <p :if={@atlas.active.things == []} class="atlas-active__none">
          Nothing changed in this window.
        </p>
      </aside>
    </div>

    <div :if={@atlas.active == nil or @atlas.rows != []} class="atlas-blocks-foot">
      <p id="atlas-help" class="atlas-help">
        Scroll or pinch to zoom from the whole fleet down to single items, drag to move, and choose a block to open it.
        <span class="visually-hidden">
          Arrow keys move between blocks, Enter opens the block chosen, Escape goes back up, and plus and minus zoom.
        </span>
      </p>
      <p class="atlas-legend">
        <span>Older</span>
        <span class="atlas-blocks__ramp" aria-hidden="true"></span>
        <span>Newer</span>
        <span class="atlas-blocks__key" data-key="today" aria-hidden="true"></span>
        <span>Today</span>
        <span class="atlas-blocks__key" data-key="more" aria-hidden="true"></span>
        <span>More</span>
        <span class="atlas-legend__zone">Times in UTC</span>
      </p>
    </div>
    """
  end

  @doc """
  What the blocks ask for, answered as their reply: `atlas_blocks_fleet`, the
  window's changes, things and Keys for each project's kinds of work, with
  when each kind was last worked on (the start of the latest bucket of
  `AtlasPage.bucket/1` with work in it), whether it was today, and each
  project's Keys; and `atlas_blocks_things`, a page of one project's things
  of one kind, the most active first, with `after` for the page that
  follows, nil after the last.
  """
  def handle_event(
        "atlas_blocks_fleet",
        _params,
        %{assigns: %{atlas: %{state: :read, show: :picture, view: :blocks} = atlas}} = socket
      ) do
    read_as = ShellLive.reads_as(socket, atlas.fleet_id)
    {from, to} = AtlasPage.window(atlas.window, atlas.at)
    bucket = AtlasPage.bucket(atlas.window)
    now = DateTime.utc_now()
    filter = %{source: atlas.source, by: [:project, :kind]}
    swarm = &AtlasPage.swarm(atlas.fleet_id, &1, &2, &3, &4, read_as)
    # Read before when each was last worked on, so work counted between the
    # two reads is never a kind with no latest bucket.
    cells = swarm.(atlas.window, from, to, filter)
    keys = swarm.(atlas.window, from, to, %{filter | by: [:project]})

    latest =
      bucket
      |> swarm.(Span.start(bucket, from), to, filter)
      |> Enum.group_by(&{&1.project, &1.kind}, & &1.at)
      |> Map.new(fn {pair, starts} -> {pair, Enum.max(starts, DateTime)} end)

    today =
      if DateTime.compare(now, from) != :lt and DateTime.compare(now, to) == :lt do
        {day, next} = AtlasPage.window(:day, now)
        :day |> swarm.(day, next, filter) |> MapSet.new(&{&1.project, &1.kind})
      else
        MapSet.new()
      end

    kinds =
      for cell <- cells do
        pair = {cell.project, cell.kind}

        [
          cell.project,
          cell.kind,
          cell.changes,
          cell.things,
          cell.actors,
          DateTime.to_unix(latest[pair]),
          MapSet.member?(today, pair)
        ]
      end

    {:reply,
     %{
       now: DateTime.to_unix(now),
       bucket: bucket,
       kinds: kinds,
       keys: Enum.map(keys, &[&1.project, &1.actors])
     }, socket}
  end

  def handle_event(
        "atlas_blocks_things",
        %{"project" => project, "kind" => kind, "after" => cursor},
        %{assigns: %{atlas: %{state: :read, show: :picture, view: :blocks} = atlas}} = socket
      )
      when is_binary(project) and is_binary(kind) and (is_binary(cursor) or is_nil(cursor)) do
    %{things: things, after: next} =
      AtlasPage.most_active(
        atlas.fleet_id,
        atlas.window,
        atlas.at,
        [limit: @thing_read, source: atlas.source, project: project, kind: kind, after: cursor] ++
          ShellLive.reads_as(socket, atlas.fleet_id)
      )

    {:reply, %{things: Enum.map(things, &thing/1), after: next}, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp thing(thing) do
    %{
      id: thing.id,
      title: thing.title,
      what: thing.what,
      who: thing.who,
      at: DateTime.to_unix(thing.at, :millisecond),
      changes: thing.changes,
      actors: thing.actors,
      path: thing.path,
      live: thing.live?
    }
  end
end

defmodule KeyfleetWeb.AtlasLive.Field do
  @moduledoc """
  The Atlas as a field (`?view=field`): one endless canvas where each project
  is a cluster, the busiest in the middle, and inside each cluster a patch for
  each kind of work, where the window's hours wind outward from its first
  hour in the middle to its newest on the outside. Zooming moves from the
  whole fleet glowing with its work, to a project's hours by kind, to the
  things of each hour as points and then cards linking to their pages. The
  browser draws it (`assets/js/hooks/atlas_field.ts` and
  `assets/js/atlas/field/`) and asks for the counts and things on screen as
  the reader moves (`handle_event/3`); the strip beside it lists the most
  active things of the window, and choosing one brings the field to it.
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Atlas.Source
  alias KeyfleetWeb.{AtlasLive, AtlasPage, ShellLive, WorkspacePage}

  @spans ~w(hour day week month year)
  @thing_read 200

  @doc "The kinds of work, in the order their patches fill a cluster, each with its name."
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
    <div :if={@atlas.active == nil or @atlas.rows != []} class="atlas-field-layout">
      <div
        id="atlas-field"
        class="atlas-field"
        phx-hook="AtlasField"
        data-rows={Jason.encode!(for row <- @atlas.rows, do: [row.project, row.title, row.changes])}
        data-kinds={Jason.encode!(kinds())}
        data-window={@atlas.window}
        data-from={DateTime.to_unix(@start)}
        data-to={DateTime.to_unix(@finish)}
        data-kind={@atlas.source || "all"}
      >
        <nav class="atlas-list__window" aria-label="Move through time">
          <.link
            id="atlas-field-earlier"
            patch={
              AtlasLive.moved(@atlas, at: @start |> DateTime.add(-1, :day) |> DateTime.to_date())
            }
          >
            Earlier
          </.link>
          <h3 id="atlas-field-window">{AtlasLive.window_label(@atlas.window, @start)}</h3>
          <.link id="atlas-field-later" patch={AtlasLive.moved(@atlas, at: DateTime.to_date(@finish))}>
            Later
          </.link>
        </nav>
        <div
          id="atlas-field-stage"
          class="atlas-field__stage"
          phx-update="ignore"
          tabindex="0"
          role="group"
          aria-labelledby="atlas-title"
          aria-describedby="atlas-help"
          data-field-stage
        >
          <div class="atlas-field__surface" data-field-surface>
            <canvas class="atlas-field__canvas" data-field-canvas aria-hidden="true"></canvas>
            <div class="atlas-field__names" data-field-names aria-hidden="true"></div>
            <div class="atlas-field__cards" data-field-cards></div>
            <p class="atlas-field__context" data-field-context aria-hidden="true" hidden></p>
            <p class="atlas-field__still">
              Your browser can’t draw this picture.
              <.link patch={AtlasLive.moved(@atlas, show: :list)}>List</.link>
              has all of it.
            </p>
            <p class="atlas-field__tip" data-field-tip aria-hidden="true" hidden></p>
          </div>
          <div class="atlas-field__zoom" role="group" aria-label="Zoom">
            <button type="button" aria-label="Zoom out" data-field-zoom="out">−</button>
            <output aria-label="Showing" data-field-level></output>
            <button type="button" aria-label="Zoom in" data-field-zoom="in">+</button>
          </div>
          <p class="visually-hidden" role="status" data-field-said></p>
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
                  to: "#atlas-field",
                  detail: %{
                    id: thing.id,
                    project: thing.project,
                    kind: thing.kind,
                    at: DateTime.to_unix(thing.at, :millisecond)
                  }
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

    <div :if={@atlas.active == nil or @atlas.rows != []} class="atlas-field-foot">
      <p id="atlas-help" class="atlas-help">
        Scroll or pinch to zoom from the whole fleet down to single items, drag to move, and choose a cluster or an hour to look closer.
        <span class="visually-hidden">
          Arrow keys move between projects, or between hours inside one, plus and minus zoom, and Enter looks closer or opens the card chosen.
        </span>
      </p>
      <p class="atlas-legend">
        <span>Fewer</span>
        <span class="atlas-legend__ramp" aria-hidden="true"></span>
        <span>More changes</span>
        <span class="atlas-field__key" aria-hidden="true"></span>
        <span>Item</span>
        <span class="atlas-field__key" data-shape="round" aria-hidden="true"></span>
        <span>Notebook</span>
        <span class="atlas-field__key" data-shape="ring" aria-hidden="true"></span>
        <span>Last hour</span>
        <span class="atlas-legend__zone">Times in UTC</span>
      </p>
    </div>
    """
  end

  @doc """
  What the field asks for as the reader moves, answered as its reply:
  `atlas_field_cells`, each project's counts by kind in each bucket of a span
  over a stretch, for one project or all; and `atlas_field_things`, the
  things of one project changed in one hour, newest first.
  """
  def handle_event(
        "atlas_field_cells",
        %{"span" => span, "from" => from, "to" => to, "project" => project},
        %{assigns: %{atlas: %{state: :read, show: :picture, view: :field} = atlas}} = socket
      )
      when span in @spans and is_integer(from) and is_integer(to) and
             (is_binary(project) or is_nil(project)) do
    cells =
      AtlasPage.swarm(
        atlas.fleet_id,
        String.to_existing_atom(span),
        DateTime.from_unix!(from),
        DateTime.from_unix!(to),
        %{source: atlas.source, project: project, by: [:project, :kind]},
        ShellLive.reads_as(socket, atlas.fleet_id)
      )

    {:reply, %{cells: Enum.map(cells, &cell/1)}, socket}
  end

  def handle_event(
        "atlas_field_things",
        %{"project" => project, "at" => at},
        %{assigns: %{atlas: %{state: :read, show: :picture, view: :field} = atlas}} = socket
      )
      when is_binary(project) and is_integer(at) do
    %{things: things} =
      AtlasPage.newest(
        atlas.fleet_id,
        :hour,
        DateTime.from_unix!(at),
        [limit: @thing_read, source: atlas.source, project: project] ++
          ShellLive.reads_as(socket, atlas.fleet_id)
      )

    {:reply, %{things: Enum.map(things, &card/1)}, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A project's counts of one kind in one bucket, as the field takes them:
  # the bucket's start in seconds, the project, the kind, its changes and things.
  defp cell(cell),
    do: [DateTime.to_unix(cell.at), cell.project, cell.kind, cell.changes, cell.things]

  defp card(thing) do
    %{
      id: thing.id,
      kind: thing.kind,
      what: thing.what,
      project: thing.project,
      title: thing.title,
      who: thing.who,
      at: DateTime.to_unix(thing.at, :millisecond),
      changes: thing.changes,
      path: thing.path,
      live: thing.live?
    }
  end
end

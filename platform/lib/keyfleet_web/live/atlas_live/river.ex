defmodule KeyfleetWeb.AtlasLive.River do
  @moduledoc """
  The Atlas as a river (`?view=river`): time runs left to right and each
  project is a band as thick as its work, stacked into one stream with the
  busiest in the middle, the dozen busiest on their own and the rest run
  together in one band that opens. Inside a band its notebooks are striped
  and the rest of its work solid. Zooming moves from a year of weeks to a
  month of days and a day of hours; there the band under the pointer takes
  the height and opens into a lane for each kind of work, the lanes into a
  mark for each thing changed, and the marks into cards linking to each
  thing's page. The browser draws it (`assets/js/hooks/atlas_river.ts` and
  `assets/js/atlas/river/`), asking for what it shows through `answer/3`;
  the strip beside it lists the most active things of the window in view,
  and choosing one brings the picture to it.
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Atlas.Source
  alias KeyfleetWeb.{AtlasLive, AtlasPage, WorkspacePage}

  @spans ~w(week day hour)
  @item_read 200

  @doc """
  What the river asks for as the reader moves (`atlas_river`), as its reply,
  or nil for a question it does not ask:

    * `cells`: each project's changes, things changed, Keys at work and
      changes to its notebooks in each bucket of a span over a stretch, as
      `[start in seconds, project, changes, things, Keys, notebooks]`.
    * `lanes`: one project's counts by kind of work in each hour of a
      stretch, as `[start in seconds, kind, changes, things, Keys]`, with
      each kind's name as its lane shows it.
    * `items`: the things one project changed in one hour, newest first.
  """
  def answer(
        %{"read" => "cells", "span" => span, "from" => from, "to" => to},
        atlas,
        read_as
      )
      when span in @spans and is_integer(from) and is_integer(to) do
    span = String.to_existing_atom(span)
    swarm = &swarm(atlas, span, from, to, %{source: &1, by: [:project]}, read_as)
    cells = swarm.(atlas.source)

    notebooks =
      case atlas.source do
        nil -> swarm.(:notebook)
        :notebook -> cells
        :graph -> []
      end
      |> Map.new(&{{&1.at, &1.project}, &1.changes})

    %{
      cells:
        for cell <- cells do
          [
            DateTime.to_unix(cell.at),
            cell.project,
            cell.changes,
            cell.things,
            cell.actors,
            Map.get(notebooks, {cell.at, cell.project}, 0)
          ]
        end
    }
  end

  def answer(
        %{"read" => "lanes", "from" => from, "to" => to, "project" => project},
        atlas,
        read_as
      )
      when is_integer(from) and is_integer(to) and is_binary(project) do
    cells =
      swarm(
        atlas,
        :hour,
        from,
        to,
        %{source: atlas.source, project: project, by: [:kind]},
        read_as
      )

    %{
      cells:
        for(
          cell <- cells,
          do: [DateTime.to_unix(cell.at), cell.kind, cell.changes, cell.things, cell.actors]
        ),
      names: cells |> Enum.map(& &1.kind) |> Enum.uniq() |> Map.new(&{&1, lane_name(&1)})
    }
  end

  def answer(%{"read" => "items", "at" => at, "project" => project}, atlas, read_as)
      when is_integer(at) and is_binary(project) do
    %{things: things} =
      AtlasPage.newest(
        atlas.fleet_id,
        :hour,
        DateTime.from_unix!(at),
        [limit: @item_read, source: atlas.source, project: project] ++ read_as
      )

    %{things: Enum.map(things, &item/1)}
  end

  def answer(_params, _atlas, _read_as), do: nil

  defp swarm(atlas, span, from, to, filter, read_as),
    do:
      AtlasPage.swarm(
        atlas.fleet_id,
        span,
        DateTime.from_unix!(from),
        DateTime.from_unix!(to),
        filter,
        read_as
      )

  # A kind of work as its lane is named: several of it.
  defp lane_name(kind) do
    if kind == Source.notebook_kind(),
      do: "Notebooks",
      else: kind |> WorkspacePage.type_name() |> elem(1)
  end

  defp item(thing) do
    %{
      id: thing.id,
      kind: thing.kind,
      what: thing.what,
      title: thing.title,
      who: thing.who,
      at: DateTime.to_unix(thing.at, :millisecond),
      changes: thing.changes,
      path: thing.path,
      live: thing.live?
    }
  end

  attr :atlas, :map, required: true, doc: "the Atlas as `KeyfleetWeb.AtlasLive.read/3` reads it"

  def picture(assigns) do
    ~H"""
    <Regent.Primitives.empty_state
      :if={@atlas.active != nil and @atlas.rows == []}
      id="atlas-empty"
      class="kf-empty"
      title="Nothing has been worked on in this fleet yet."
    />
    <div :if={@atlas.active == nil or @atlas.rows != []} class="atlas-river-layout">
      <div
        id="atlas-river"
        class="atlas-river"
        phx-hook="AtlasRiver"
        data-rows={rows(@atlas.rows)}
        data-window={@atlas.window}
        data-at={DateTime.to_unix(@atlas.at, :millisecond)}
        data-kind={@atlas.source || "all"}
      >
        <div
          id="atlas-river-stage"
          class="atlas-river__stage"
          phx-update="ignore"
          tabindex="0"
          role="group"
          aria-labelledby="atlas-title"
          aria-describedby="atlas-help"
          data-atlas-stage
        >
          <div class="atlas-river__surface" data-atlas-surface>
            <canvas class="atlas-river__canvas" data-atlas-canvas aria-hidden="true"></canvas>
            <div class="atlas-river__names" data-atlas-names aria-hidden="true"></div>
            <div class="atlas-river__axis" data-atlas-axis aria-hidden="true"></div>
            <div class="atlas-river__cards" data-atlas-cards hidden></div>
            <div class="atlas-river__ring" data-atlas-ring aria-hidden="true" hidden></div>
            <p class="atlas-river__still">
              Your browser can’t draw this picture.
              <.link patch={AtlasLive.moved(@atlas, show: :list)}>List</.link>
              has all of it.
            </p>
            <p class="atlas-river__tip" data-atlas-tip aria-hidden="true" hidden></p>
          </div>
          <div class="atlas-river__bar">
            <button type="button" aria-expanded="false" data-atlas-more hidden>More</button>
            <div class="atlas-river__zoom" role="group" aria-label="Zoom">
              <button type="button" aria-label="Zoom out" data-atlas-zoom="out">−</button>
              <output aria-label="Showing" data-atlas-level></output>
              <button type="button" aria-label="Zoom in" data-atlas-zoom="in">+</button>
            </div>
          </div>
          <p class="visually-hidden" role="status" data-atlas-said></p>
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
                  to: "#atlas-river",
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

    <div :if={@atlas.active == nil or @atlas.rows != []} class="atlas-river-foot">
      <p id="atlas-help" class="atlas-help">
        Scroll or pinch to zoom from a year down to single items, drag to move, and choose a project to give it room. Hold Shift and scroll to open the one under the pointer.
        <span class="visually-hidden">
          Arrow keys move between projects and times, plus and minus zoom, Enter gives the project chosen room and then looks closer, and Escape lets it go.
        </span>
      </p>
      <p class="atlas-legend">
        <span class="atlas-river__key" aria-hidden="true"></span>
        <span>Graph</span>
        <span class="atlas-river__key atlas-river__key--notebooks" aria-hidden="true"></span>
        <span>Notebooks</span>
        <span class="atlas-legend__zone">Times in UTC</span>
      </p>
    </div>
    """
  end

  # The rows the picture draws, busiest first: each project's name, title and
  # changes counted.
  defp rows(rows), do: Jason.encode!(for row <- rows, do: [row.project, row.title, row.changes])
end

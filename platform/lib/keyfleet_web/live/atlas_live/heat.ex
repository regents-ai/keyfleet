defmodule KeyfleetWeb.AtlasLive.Heat do
  @moduledoc """
  The Atlas as heat (`?view=heat`): time runs left to right and each project
  is a row, busiest first, the dozen busiest on their own and the rest folded
  into one row that opens. Each square is a bucket of time, as dark or as
  light as the work in it. Zooming moves from a year of weeks to a month of
  days, a day of hours, and inside an hour the things changed in it, each a
  card linking to its page. The browser draws it (`assets/js/hooks/atlas_heat.ts`
  and `assets/js/atlas/heat/`); the strip beside it lists the most active
  things of the window in view, and choosing one brings the picture to it.
  """
  use KeyfleetWeb, :html

  alias KeyfleetWeb.AtlasLive

  attr :atlas, :map, required: true, doc: "the Atlas as `KeyfleetWeb.AtlasLive.read/3` reads it"

  def picture(assigns) do
    ~H"""
    <Regent.Primitives.empty_state
      :if={@atlas.active != nil and @atlas.rows == []}
      id="atlas-empty"
      class="kf-empty"
      title="Nothing has been worked on in this fleet yet."
    />
    <div :if={@atlas.active == nil or @atlas.rows != []} class="atlas-heat-layout">
      <div
        id="atlas-heat"
        class="atlas-heat"
        phx-hook="AtlasHeat"
        data-rows={rows(@atlas.rows)}
        data-window={@atlas.window}
        data-at={DateTime.to_unix(@atlas.at, :millisecond)}
        data-kind={@atlas.source || "all"}
      >
        <div
          id="atlas-heat-stage"
          class="atlas-heat__stage"
          phx-update="ignore"
          tabindex="0"
          role="group"
          aria-labelledby="atlas-title"
          aria-describedby="atlas-help"
          data-atlas-stage
        >
          <div class="atlas-heat__rows" data-atlas-rows></div>
          <div class="atlas-heat__surface" data-atlas-surface>
            <canvas class="atlas-heat__canvas" data-atlas-canvas aria-hidden="true"></canvas>
            <div class="atlas-heat__axis" data-atlas-axis aria-hidden="true"></div>
            <div class="atlas-heat__cards" data-atlas-cards></div>
            <p class="atlas-heat__still">
              Your browser can’t draw this picture.
              <.link patch={AtlasLive.moved(@atlas, show: :list)}>List</.link>
              has all of it.
            </p>
            <p class="atlas-heat__tip" data-atlas-tip aria-hidden="true" hidden></p>
          </div>
          <div class="atlas-heat__zoom" role="group" aria-label="Zoom">
            <button type="button" aria-label="Zoom out" data-atlas-zoom="out">−</button>
            <output aria-label="Showing" data-atlas-level></output>
            <button type="button" aria-label="Zoom in" data-atlas-zoom="in">+</button>
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
                  to: "#atlas-heat",
                  detail: %{
                    id: thing.id,
                    project: thing.project,
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

    <div :if={@atlas.active == nil or @atlas.rows != []} class="atlas-heat-foot">
      <p id="atlas-help" class="atlas-help">
        Scroll or pinch to zoom from a year down to single items, drag to move, and choose a square to look closer.
        <span class="visually-hidden">
          Arrow keys move between squares, plus and minus zoom, and Enter looks closer or opens the card chosen.
        </span>
      </p>
      <p class="atlas-legend">
        <span>Fewer</span>
        <span class="atlas-legend__ramp" aria-hidden="true"></span>
        <span>More changes</span>
        <span class="atlas-legend__zone">Times in UTC</span>
      </p>
    </div>
    """
  end

  # The rows the picture draws, busiest first: each project's name, title and
  # changes counted.
  defp rows(rows), do: Jason.encode!(for row <- rows, do: [row.project, row.title, row.changes])
end

defmodule KeyfleetWeb.SeasonsLive do
  @moduledoc """
  A fleet's record of settled seasons, at `/seasons` under the fleet's
  address, drawn inside the fleet's page under its bar
  (`KeyfleetWeb.FleetLive`), for anyone: twenty at a time, newest first,
  with "More" for older ones, each with its holding, captain, the holding's
  result and how many Keys picked. Above them, "24h": what the holding came
  to over the last eight seasons settled, a day of them, or over as many as
  have settled (`Keyfleet.Seasons.Rules.compounded/1`). A season's row opens
  to its picks, a hundred at a time.

  The record is read as the page opens and as each "More" asks; a season
  settled meanwhile shows when the page is opened again.
  """

  use KeyfleetWeb, :html

  alias Keyfleet.Fleets
  alias Keyfleet.Seasons
  alias Keyfleet.Seasons.Rules
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.SeasonPanel

  # Picks a season's row opens to, and each "More" under them adds.
  @picks 100

  # How many settled seasons "24h" compounds: a day of three-hour seasons.
  @day 8

  @doc "The address of the fleet's record of settled seasons."
  def seasons_path(fleet_id), do: "#{Fleets.path(fleet_id)}/seasons"

  @doc """
  The record named in the address, its newest page read for anyone, or
  nothing for any other page. A record that can't be read says so.
  """
  def read(socket, :seasons, %{"fleet_id" => fleet_id}) do
    case PageRead.run("seasons", fn -> Seasons.settled_page(fleet_id, nil) end) do
      {:ok, {seasons, more?}} ->
        day = Enum.take(seasons, @day)

        assign(socket, :seasons, %{
          fleet_id: fleet_id,
          state: :read,
          rows: Enum.map(seasons, &row/1),
          more?: more?,
          day: %{result: Rules.compounded(day), count: length(day)},
          open: nil
        })

      {:error, _failure} ->
        assign(socket, :seasons, %{fleet_id: fleet_id, state: :unreadable})
    end
  end

  def read(socket, _route_id, _params), do: assign(socket, :seasons, nil)

  @doc """
  "More" adds the page of seasons settled before the oldest on show; a
  season's row opens to its first picks, or closes when it is open; and
  "More" under them adds the next picks.
  """
  def handle_event(
        "seasons_more",
        _params,
        %{assigns: %{seasons: %{state: :read, more?: true, rows: rows} = record}} = socket
      ) do
    {seasons, more?} = Seasons.settled_page(record.fleet_id, List.last(rows).number)

    {:noreply,
     assign(socket, :seasons, %{record | rows: rows ++ Enum.map(seasons, &row/1), more?: more?})}
  end

  def handle_event(
        "seasons_open",
        %{"number" => number},
        %{assigns: %{seasons: %{state: :read} = record}} = socket
      ) do
    open =
      case Enum.find(record.rows, &(Integer.to_string(&1.number) == number)) do
        nil ->
          record.open

        row ->
          if open?(record, row), do: nil, else: read_picks(record.fleet_id, row.number, nil, [])
      end

    {:noreply, assign(socket, :seasons, %{record | open: open})}
  end

  def handle_event(
        "seasons_picks_more",
        _params,
        %{assigns: %{seasons: %{open: %{more: place} = open} = record}} = socket
      )
      when is_integer(place) do
    open = read_picks(record.fleet_id, open.number, place, open.picks)
    {:noreply, assign(socket, :seasons, %{record | open: open})}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  attr :seasons, :map, required: true, doc: "the record as `read/3` reads it"

  @doc "The record page."
  def page(assigns) do
    ~H"""
    <article id="seasons-page" class="seasons-page">
      <section class="seasons-panel" aria-labelledby="seasons-title">
        <h2 id="seasons-title">Seasons</h2>

        <Regent.Primitives.empty_state
          :if={@seasons.state == :unreadable}
          id="seasons-unreadable"
          class="kf-empty"
          title="The seasons couldn’t be loaded. Refresh the page to try again."
        />

        <Regent.Primitives.empty_state
          :if={@seasons.state == :read and @seasons.rows == []}
          id="seasons-empty"
          class="kf-empty"
          title="No season has ended yet."
        />

        <dl :if={@seasons.state == :read and @seasons.rows != []} class="seasons-day">
          <div>
            <dt>24h</dt>
            <dd id="seasons-day">
              <span class="seasons-day__figure">{SeasonPanel.percent(@seasons.day.result)}</span>
              <span class="seasons-minor">{seasons_counted(@seasons.day.count)}</span>
            </dd>
          </div>
        </dl>

        <div
          :if={@seasons.state == :read and @seasons.rows != []}
          class="seasons-table-frame"
          role="region"
          tabindex="0"
          aria-labelledby="seasons-title"
        >
          <table id="seasons-table" class="seasons-table">
            <thead>
              <tr>
                <th scope="col">Season</th>
                <th scope="col">Holding</th>
                <th scope="col">Captain</th>
                <th scope="col" class="seasons-table__figure">Result</th>
                <th scope="col" class="seasons-table__figure">Picks</th>
              </tr>
            </thead>
            <tbody :for={row <- @seasons.rows} id={"seasons-#{row.number}"}>
              <tr>
                <th scope="row">
                  <button
                    type="button"
                    class="seasons-table__open"
                    phx-click="seasons_open"
                    phx-value-number={row.number}
                    aria-expanded={to_string(open?(@seasons, row))}
                    aria-controls={"seasons-#{row.number}-picks"}
                  >
                    <span>Season {row.number}</span>
                    <KeyfleetWeb.Time.local
                      id={"seasons-#{row.number}-at"}
                      at={row.starts_at}
                      as={:stamp}
                      class="seasons-minor"
                    />
                  </button>
                </th>
                <td>{row.holding}</td>
                <td>{SeasonPanel.captain(row.captain_key)}</td>
                <td class="seasons-table__figure">{SeasonPanel.percent(row.result)}</td>
                <td class="seasons-table__figure">{row.pick_count}</td>
              </tr>
              <tr :if={open?(@seasons, row)} id={"seasons-#{row.number}-picks"}>
                <td colspan="5">
                  <.picks open={@seasons.open} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <Regent.Primitives.button
          :if={@seasons.state == :read and @seasons.more?}
          id="seasons-more"
          type="button"
          variant="secondary"
          arrow={false}
          phx-click="seasons_more"
        >
          More
        </Regent.Primitives.button>

        <SeasonPanel.terms />
      </section>
    </article>
    """
  end

  attr :open, :map, required: true

  # One settled season's picks, in the order they were locked.
  defp picks(%{open: %{picks: []}} = assigns),
    do: ~H|<p class="fleet-detail">No Key picked this season.</p>|

  defp picks(assigns) do
    ~H"""
    <ol id="seasons-picks" class="seasons-picks">
      <li :for={pick <- @open.picks} id={"seasons-pick-#{pick.key}"}>
        <span class="seasons-minor">Key {pick.key}</span>
        <span>{pick.product}</span>
        <span class="seasons-table__figure">{SeasonPanel.percent(pick.result)}</span>
        <q :if={pick.reason} class="seasons-picks__reason">{pick.reason}</q>
      </li>
    </ol>
    <Regent.Primitives.button
      :if={@open.more}
      id="seasons-picks-more"
      type="button"
      variant="secondary"
      arrow={false}
      phx-click="seasons_picks_more"
    >
      More
    </Regent.Primitives.button>
    """
  end

  defp open?(%{open: %{number: number}}, %{number: number}), do: true
  defp open?(_record, _row), do: false

  defp seasons_counted(1), do: "1 season"
  defp seasons_counted(count), do: "#{count} seasons"

  defp row(season),
    do: %{
      number: season.number,
      starts_at: season.starts_at,
      holding: season.holding,
      captain_key: season.captain_key,
      result: season.holding_result,
      pick_count: season.keys_locked
    }

  # The page of the season's picks after `place`, under those on show.
  defp read_picks(fleet_id, number, place, shown) do
    {picks, _more?} = page = Seasons.settled_picks_page(fleet_id, number, place, @picks)

    %{
      number: number,
      picks: shown ++ Enum.map(picks, &pick/1),
      more: Seasons.next_after(page)
    }
  end

  defp pick(pick),
    do: %{key: pick.token_id, product: pick.product, result: pick.result, reason: pick.reason}
end

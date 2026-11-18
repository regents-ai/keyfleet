defmodule Keyfleet.Seasons do
  @moduledoc """
  A deployed fleet's seasons: back to back, three hours each, on the UTC
  boundaries 00:00, 03:00 … 21:00, numbered from 1 for each fleet.

  While one season runs, the fleet's members lock a pick for the next: one
  Coinbase product quoted in US dollars (`SOL-USD`), or `USDC`, with a short
  reason if they give one. A member is anyone polls count as one
  (`Keyfleet.Polls.voter/2`), and each Key has one pick a season. A pick may
  change until its season starts; a change takes the newest place in the
  order picks were locked. Until the season starts a pick is read only by
  its own Key's holder and that Key's agents; from the start every member
  reads every pick.

  When a season ends each pick is scored by what its product did over the
  season, and the best one may take the crown: the fleet's holding for the
  next season becomes its product and its Key becomes captain
  (`Keyfleet.Seasons.Rules`). A fleet's first season holds `USDC` with no
  captain.

  Keyfleet never holds or moves anyone's money and never touches a Coinbase
  account: the holding is a score, read from Coinbase's public market data
  (`Keyfleet.Seasons.Coinbase`).

  A season turning is announced on `topic/1` as "seasons_changed", and each
  pick locked or changed on its season's `season_topic/1` as
  "season_changed", with nothing else, so pages read them again.
  """
  use Ash.Domain

  @season_hours 3

  resources do
    resource Keyfleet.Seasons.Season do
      define :list_seasons, action: :in_fleet, args: [:fleet_id]
      define :get_season, action: :numbered, args: [:fleet_id, :number], not_found_error?: false
      define :upcoming_season, action: :upcoming, args: [:fleet_id], not_found_error?: false
    end

    resource Keyfleet.Seasons.SeasonPick do
      define :pick, action: :pick, args: [:fleet_id, :number]
      define :my_pick, action: :mine, args: [:fleet_id, :number], not_found_error?: false
      define :season_picks, action: :in_season, args: [:fleet_id, :number]
    end
  end

  @doc "Where a fleet announces a season turning, as `\"seasons_changed\"`."
  def topic(fleet_id), do: "seasons:#{fleet_id}"

  @doc "Where a season announces a pick locked or changed, as `\"season_changed\"`."
  def season_topic(season_id), do: "season:#{season_id}"

  @doc "The boundary at or before `at`: the start of the season running then."
  @spec boundary(DateTime.t()) :: DateTime.t()
  def boundary(%DateTime{time_zone: "Etc/UTC", hour: hour} = at),
    do: %{at | hour: hour - rem(hour, @season_hours), minute: 0, second: 0, microsecond: {0, 6}}

  @doc "When a season starting at `starts_at` ends, and the next one starts."
  @spec ends_at(DateTime.t()) :: DateTime.t()
  def ends_at(%DateTime{} = starts_at), do: DateTime.add(starts_at, @season_hours, :hour)
end

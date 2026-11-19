defmodule KeyfleetWeb.SeasonJSON do
  @moduledoc """
  A fleet's seasons as the agent API and the public record answer them
  (`KeyfleetWeb.AgentTools.Seasons.Answer`). Keys are named by number, never
  by wallet, and prices and results are decimal strings, as Coinbase sent
  the prices. No answer carries more than a page of picks: a season's picks
  are read on their own (`picks/3`).
  """

  alias Keyfleet.Seasons
  alias Keyfleet.Seasons.{Coinbase, Rules}

  @doc """
  The fleet's seasons as a member reads them now: the season under way with
  how many Keys picked and the first page of its picks, the season taking
  picks with the caller's own pick and how many Keys have locked one, the
  season settled last, and the rules.
  """
  def show(fleet_id, running, running_picks, taking_picks, my_pick, settled) do
    %{
      fleet_id: fleet_id,
      running: running && running(running, running_picks),
      taking_picks: taking_picks && taking_picks(taking_picks, my_pick),
      last_settled: settled && last_settled(settled, running),
      rules: %{
        season_hours: Seasons.season_hours(),
        switching_margin: decimal(Rules.switching_margin()),
        volume_floor_usd: decimal(Coinbase.volume_floor())
      }
    }
  end

  @doc "A page of the fleet's settled seasons, its public record."
  def record(fleet_id, seasons, more?) do
    %{
      fleet_id: fleet_id,
      seasons: Enum.map(seasons, &settled/1),
      next_before: if(more?, do: Integer.to_string(List.last(seasons).number)),
      has_more: more?
    }
  end

  @doc """
  A page of one season's picks, in the order they were locked: a season
  under way's have no close price or result yet.
  """
  def picks(fleet_id, number, {picks, more?} = page) do
    %{
      fleet_id: fleet_id,
      season: number,
      picks:
        Enum.map(
          picks,
          &Map.merge(running_pick(&1), %{
            close_price: decimal(&1.close_price),
            result: decimal(&1.result)
          })
        ),
      next_after: next_after(page),
      has_more: more?
    }
  end

  @doc "A Key's own pick for a season taking picks."
  def pick(pick, number) do
    %{
      season: number,
      key: pick.token_id,
      product: pick.product,
      reason: pick.reason,
      picked_at: pick.picked_at
    }
  end

  defp running(season, {picks, _more?} = page) do
    %{
      number: season.number,
      starts_at: season.starts_at,
      ends_at: season.ends_at,
      holding: season.holding,
      captain_key: season.captain_key,
      holding_open_price: decimal(season.holding_open_price),
      pick_count: season.keys_locked,
      picks: Enum.map(picks, &running_pick/1),
      next_after: next_after(page)
    }
  end

  defp running_pick(pick) do
    %{
      key: pick.token_id,
      product: pick.product,
      reason: pick.reason,
      open_price: decimal(pick.open_price),
      void: pick.void
    }
  end

  defp taking_picks(season, my_pick) do
    %{
      number: season.number,
      starts_at: season.starts_at,
      my_pick: my_pick && pick(my_pick, season.number),
      keys_locked: season.keys_locked
    }
  end

  # The season after the one settled last is the one under way: a turn
  # settles one and locks the next together.
  defp last_settled(settled, running) do
    %{
      number: settled.number,
      holding: settled.holding,
      holding_result: decimal(settled.holding_result),
      best_pick: best_pick(settled.best_pick),
      crown_changed: running.holding != settled.holding
    }
  end

  defp settled(season) do
    %{
      number: season.number,
      starts_at: season.starts_at,
      ends_at: season.ends_at,
      holding: season.holding,
      captain_key: season.captain_key,
      holding_open_price: decimal(season.holding_open_price),
      holding_close_price: decimal(season.holding_close_price),
      holding_result: decimal(season.holding_result),
      pick_count: season.keys_locked,
      best_pick: best_pick(season.best_pick)
    }
  end

  defp best_pick(nil), do: nil

  defp best_pick(pick),
    do: %{key: pick.token_id, product: pick.product, result: decimal(pick.result)}

  defp next_after(page) do
    case Seasons.next_after(page) do
      nil -> nil
      after_order -> Integer.to_string(after_order)
    end
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: Decimal.to_string(value, :normal)
end

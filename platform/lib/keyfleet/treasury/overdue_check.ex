defmodule Keyfleet.Treasury.OverdueCheck do
  @moduledoc """
  Every hour (`config :keyfleet, Oban, cron:`): looks at each deployed
  fleet's latest money reading (`Keyfleet.Treasury.Reading`) and, by the
  chain's clock at that reading, saves with the site's errors
  (`Keyfleet.Treasury.OverdueError`) each kind of money nobody has moved in time:

    * the Daily Treasury Slice to Keys, due for more than 6 hours while the
      treasury holds at least what it splits from of some asset (0.05 ETH, or
      100 of a token); below that a run shares nothing, so nothing is late;
    * the protocol share, owed to REGENT staking for more than 24 hours;
    * USDC from Key sales, waiting more than 3 hours with no piece of it
      turned into REGENT (`Keyfleet.Treasury.last_piece_turned_at/1`).

  The last two are only read as waiting while there is some of them, so an
  empty treasury is never overdue.

  Each kind is one error naming every fleet it holds for, saved again every
  hour until someone moves the money. Anyone may move each of them, from the
  fleet's Treasury tab or as an agent. A fleet is looked at from the first
  reading after it is recorded on the site, and not before.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Keyfleet.Treasury
  alias Keyfleet.Treasury.OverdueError

  @split_late 6 * 3600
  @owed_late 24 * 3600
  @waiting_late 3 * 3600

  # The least ETH the treasury splits from, as the treasury fixes it.
  @eth_floor 50_000_000_000_000_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    readings =
      for fleet <- Keyfleet.Fleets.list_deployed_fleets!(),
          reading = Treasury.get_reading!(fleet.id),
          reading != nil,
          do: {fleet, reading}

    with [_ | _] = late <-
           late(readings, &split_due/1, @split_late) do
      OverdueError.report(
        "The Daily Treasury Slice to Keys is more than 6 hours overdue: #{named(late)}. " <>
          "Anyone may run it from the fleet's Treasury tab."
      )
    end

    with [_ | _] = late <-
           late(
             readings,
             fn {_fleet, reading} -> reading.protocol_share_owed_since end,
             @owed_late
           ) do
      OverdueError.report(
        "The protocol share has been owed to REGENT staking for more than a day: " <>
          "#{named(late)}. Anyone may send it from the fleet's Treasury tab."
      )
    end

    with [_ | _] = late <- late(readings, &waiting_since/1, @waiting_late) do
      OverdueError.report(
        "USDC from Key sales has waited more than 3 hours with no piece turned into REGENT: " <>
          "#{named(late)}. Anyone may press Buy REGENT on the fleet's Treasury tab; " <>
          "if every press fails, the price is moving too much for the buyer."
      )
    end

    :ok
  end

  defp split_due({_fleet, %{next_run_at: nil}}), do: nil

  defp split_due({fleet, reading}),
    do: if(splits_any?(fleet, reading), do: reading.next_run_at)

  # Whether the treasury holds at least what it splits from of some asset. A
  # token that has not said its decimals has no floor known here.
  defp splits_any?(fleet, reading) do
    %{details: details} = Treasury.assets(fleet)

    Enum.any?(reading.assets, fn %{asset: asset, held: held} ->
      floor = split_floor(asset, details)
      floor != nil and held >= floor
    end)
  end

  defp split_floor(asset, details) do
    case {asset == Treasury.native(), details[asset]} do
      {true, _eth} -> @eth_floor
      {false, {_symbol, decimals}} when is_integer(decimals) -> 100 * 10 ** decimals
      {false, _unknown} -> nil
    end
  end

  # USDC has waited since it was first read waiting, or since a piece of it
  # last turned into REGENT, whichever is later.
  defp waiting_since({_fleet, %{conversion_waiting_since: nil}}), do: nil

  defp waiting_since({fleet, reading}) do
    case Treasury.last_piece_turned_at(fleet.id) do
      nil -> reading.conversion_waiting_since
      turned_at -> Enum.max([reading.conversion_waiting_since, turned_at], DateTime)
    end
  end

  # The fleets whose `since_of` time is more than `late` seconds before their
  # reading's block, with that time.
  defp late(readings, since_of, late) do
    for {fleet, reading} = read <- readings,
        since = since_of.(read),
        since != nil and DateTime.diff(reading.block_time, since) > late,
        do: {fleet.name, since}
  end

  defp named(late),
    do:
      Enum.map_join(late, ", ", fn {name, since} ->
        "#{name} (since #{Calendar.strftime(since, "%-d %b %H:%M UTC")})"
      end)
end

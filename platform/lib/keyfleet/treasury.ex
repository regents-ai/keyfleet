defmodule Keyfleet.Treasury do
  @moduledoc """
  A fleet's money as its contracts report it: every money event of its fleet
  contract, treasury and reward ledger and of the REGENT buyer for it, the latest reading of its balances,
  and the symbol and decimals of each token they name. Recorded from the
  fleet's contracts by the chain reader and by nothing else. The chain is the
  authority; these records only mirror it.
  """
  use Ash.Domain

  require Ash.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.Treasury.Event

  @latest 20
  # How the contracts name ETH wherever they name an asset.
  @native "0x0000000000000000000000000000000000000000"
  # The fleet's USDC, which its contract refuses to be deployed with unless
  # it has six decimals.
  @usdc_decimals 6
  @regent_decimals 18
  # What the history shows: money into the treasury, out of it, shared with
  # the keys by the daily split, and REGENT bought with USDC from Key sales.
  @history_kinds [
    :forwarded,
    :protocol_share_sent,
    :paid,
    :advanced,
    :split_allocated,
    :regent_bought
  ]

  resources do
    resource Keyfleet.Treasury.Reading do
      define :record_reading, action: :record
      define :get_reading, action: :read, get_by: [:fleet_id], not_found_error?: false
    end

    resource Keyfleet.Treasury.AssetDetails do
      define :record_asset_details, action: :record
      define :asset_details, action: :of_fleet, args: [:fleet_id]
    end

    resource Keyfleet.Treasury.Event do
      define :record_event, action: :record

      define :events_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :latest_events, action: :latest_of_kinds, args: [:fleet_id, :kinds, :limit]

      define :events_recorded_before,
        action: :of_kinds_before,
        args: [:fleet_id, :kinds, :before_seq, :limit]
    end
  end

  @doc "How the fleet's contracts name ETH."
  def native, do: @native

  @doc """
  Every money event recorded from blocks `from..to` of the fleet, so a
  second reading of them can be checked against the record.
  """
  def recorded_in_blocks!(fleet_id, from, to),
    do: events_recorded_in_blocks!(fleet_id, from, to, actor: %System{})

  @doc """
  The assets the fleet's deployment names, and so knows by address: ETH, its
  USDC and REGENT, with their symbols and decimals.
  """
  def known_assets(fleet),
    do: %{
      @native => {"ETH", 18},
      fleet.usdc_address => {"USDC", @usdc_decimals},
      fleet.regent_address => {"REGENT", @regent_decimals}
    }

  @doc """
  What an amount of the fleet's assets is shown with: `%{known: addresses,
  details: %{asset => {symbol, decimals}}}`, the assets the deployment names
  (`known_assets/1`) and each asset's symbol and decimals: those of the known
  ones, and every other token's as it reported them, either nil when the
  token has not said.
  """
  def assets(fleet) do
    known = known_assets(fleet)

    details =
      fleet.id
      |> asset_details!()
      |> Map.new(&{&1.asset, {&1.symbol, &1.decimals}})
      |> Map.merge(known)

    %{known: Map.keys(known), details: details}
  end

  @doc """
  The assets the treasury holds and splits, in the order the latest reading
  lists them, or just ETH, REGENT and USDC before the first reading. Each is
  `%{address: address, symbol: symbol, decimals: decimals, usdc?: usdc?,
  known?: known?}`, symbol and decimals nil when the token has not said,
  `usdc?` true only for the fleet's own USDC and `known?` only for the assets
  the deployment names, so a token calling itself USDC or REGENT is never
  taken for it.
  """
  def payable_assets(fleet) do
    %{known: known, details: details} = assets(fleet)

    listed =
      case get_reading!(fleet.id) do
        nil -> [@native, fleet.regent_address, fleet.usdc_address]
        reading -> Enum.map(reading.assets, & &1.asset)
      end

    Enum.map(listed, fn asset ->
      {symbol, decimals} = Map.get(details, asset, {nil, nil})

      %{
        address: asset,
        symbol: symbol,
        decimals: decimals,
        usdc?: asset == fleet.usdc_address,
        known?: asset in known
      }
    end)
  end

  @doc """
  The fleet's latest #{@latest} money events in and out of its treasury and
  of its daily split, newest first, and whether earlier ones were recorded.
  """
  def latest(fleet_id) do
    {shown, earlier} =
      fleet_id
      |> latest_events!(@history_kinds, @latest + 1)
      |> Enum.split(@latest)

    %{shown: shown, earlier?: earlier != []}
  end

  @doc """
  When the fleet's latest piece of USDC from Key sales turned into REGENT was
  recorded, or nil when none has.
  """
  def last_piece_turned_at(fleet_id) do
    case latest_events!(fleet_id, [:regent_bought], 1) do
      [bought] -> bought.observed_at
      [] -> nil
    end
  end

  @doc """
  Each advance an approved proposal made that has not all come back, oldest
  first, as `%{advance_id: id, operator: address, asset: address, amount:
  amount, outstanding: amount, purpose_hash: hash}`.
  """
  def open_advances(fleet_id) do
    events =
      Event
      |> Ash.Query.filter(fleet_id == ^fleet_id and kind in [:advanced, :advance_returned])
      |> Ash.Query.sort(record_seq: :asc)
      |> Ash.read!()

    events
    |> Enum.reduce(%{}, fn
      %{kind: :advanced} = advance, open ->
        Map.put(open, advance.advance_id, %{
          advance_id: advance.advance_id,
          operator: advance.account,
          asset: advance.asset,
          amount: advance.amount,
          outstanding: advance.amount,
          purpose_hash: advance.purpose_hash,
          record_seq: advance.record_seq
        })

      %{kind: :advance_returned} = returned, open ->
        Map.update!(open, returned.advance_id, &%{&1 | outstanding: returned.outstanding})
    end)
    |> Map.values()
    |> Enum.reject(&Decimal.eq?(&1.outstanding, 0))
    |> Enum.sort_by(& &1.record_seq)
    |> Enum.map(&Map.delete(&1, :record_seq))
  end
end

defmodule Keyfleet.Treasury do
  @moduledoc """
  A fleet's money as its contracts report it: every money event of its fleet
  contract, treasury and reward ledger and of the REGENT buyer for it, the latest reading of its balances,
  and the symbol and decimals of each token they name. Recorded from the
  fleet's contracts by the chain reader and by nothing else. The chain is the
  authority; these records only mirror it.

  The upkeep presses the Treasury buttons anyone may press, from its own
  account (`Keyfleet.Treasury.Upkeep`), and keeps a line of what it did with
  each (`Keyfleet.Treasury.UpkeepLine`); an admin pauses and resumes it
  (`Keyfleet.Treasury.UpkeepSwitch`).
  """
  use Ash.Domain

  require Ash.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.Treasury.Event
  alias Keyfleet.Treasury.Upkeep.Send
  alias Keyfleet.Treasury.UpkeepLine

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
  # The order a run's lines are shown in: each step as the run presses it,
  # then what concerns the whole run.
  @upkeep_order %{run_split: 0, send_share: 1, carry_out: 2, convert: 3, nil: 4}
  @upkeep_recent 5

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
    end

    resource Keyfleet.Treasury.UpkeepLine do
      define :record_upkeep_line, action: :record
      define :settle_upkeep_line, action: :settle, args: [:outcome, :reason]
      define :unsettled_upkeep_lines, action: :unsettled
    end

    resource Keyfleet.Treasury.UpkeepSwitch do
      define :upkeep_switch, action: :the_switch
      define :switch_upkeep, action: :switch, args: [:paused, :changed_by]
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

  @doc """
  What the upkeep has done for the fleet, or nil when no upkeep key is set:
  `%{paused?: paused?, checked_at: at, lines: lines, recent: recent}`.
  `lines` are what its newest run did with the fleet's steps and with those
  of every fleet, in the order it presses them, then what concerns the whole
  run; `checked_at` is when that run did it, nil before the first. `recent`
  are its #{@upkeep_recent} newest transactions that landed for the fleet or
  for every fleet, newest first. Each line is `%{step: step, proposal: number,
  outcome: outcome, reason: reason, opens_at: at, amount: amount,
  transaction_hash: hash, at: at}` (`Keyfleet.Treasury.UpkeepLine`).
  """
  def upkeep(fleet_id) do
    if upkeep_operator() do
      newest =
        UpkeepLine
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one!()

      %{
        paused?: upkeep_paused?(),
        checked_at: newest && newest.inserted_at,
        lines: if(newest, do: run_lines(newest.run_id, fleet_id), else: []),
        recent:
          UpkeepLine
          |> Ash.Query.filter(outcome == :done and (fleet_id == ^fleet_id or is_nil(fleet_id)))
          |> Ash.Query.sort(inserted_at: :desc)
          |> Ash.Query.limit(@upkeep_recent)
          |> Ash.read!()
          |> Enum.map(&upkeep_line/1)
      }
    end
  end

  defp run_lines(run_id, fleet_id) do
    UpkeepLine
    |> Ash.Query.filter(run_id == ^run_id and (fleet_id == ^fleet_id or is_nil(fleet_id)))
    |> Ash.read!()
    |> Enum.sort_by(&{Map.fetch!(@upkeep_order, &1.step), &1.proposal || 0})
    |> Enum.map(&upkeep_line/1)
  end

  defp upkeep_line(line) do
    line
    |> Map.take([:step, :proposal, :outcome, :reason, :opens_at, :amount, :transaction_hash])
    |> Map.put(:at, line.inserted_at)
  end

  @doc "The upkeep account's lowercase address, or nil when no upkeep key is set."
  def upkeep_operator, do: Send.operator()

  @doc "Whether an admin has paused the upkeep. It starts paused."
  def upkeep_paused?, do: upkeep_switch!().paused

  @doc "Pauses the upkeep, as the admin whose account is `account_id`."
  def pause_upkeep!(account_id),
    do: switch_upkeep!(upkeep_switch!(), true, account_id, actor: %System{})

  @doc "Resumes the upkeep, as the admin whose account is `account_id`."
  def resume_upkeep!(account_id),
    do: switch_upkeep!(upkeep_switch!(), false, account_id, actor: %System{})

  @doc """
  Clears what the upkeep no longer keeps once its run `run_id` has finished:
  earlier runs' skipped lines, and every line older than 30 days.
  """
  def forget_upkeep_lines!(run_id) do
    UpkeepLine
    |> Ash.Query.for_read(:forgettable, %{latest_run_id: run_id}, actor: %System{})
    |> Ash.bulk_destroy!(:forget, %{}, actor: %System{}, strategy: :atomic, notify?: false)
  end
end

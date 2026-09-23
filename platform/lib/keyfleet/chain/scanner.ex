defmodule KeyFleet.Chain.Scanner do
  @moduledoc """
  One pass over a deployed fleet's key history.

  Each pass reads the head, reads again the last 30 blocks it already
  recorded, then records the ownership changes after them up to the head, and
  only then moves the fleet's cursor on. Recording is safe to repeat: an
  ownership change seen twice is recorded once. Nothing above the head this
  pass read is asked for, so a node that is behind reads as a shorter pass,
  never as missing history.

  The second reading is how a change in the chain's history shows up. If it
  finds an ownership change that disagrees with the record, or a block whose
  hash is no longer the one recorded, the fleet is stopped at that block and
  the error is logged. Nothing recorded is rewritten; an operator corrects the
  record by hand and then clears the stop, as `docs/chain-reader.md` describes.
  A recorded change missing from a block whose hash still matches is the node
  answering inconsistently, so the pass fails and is retried instead.

  Once a pass has moved the cursor on, the room of every Fibonacci level that
  has sold a key is opened if it is not open yet. Opening a room never holds
  up the record: if it fails, the failure is logged and the next pass tries
  again.
  """

  require Logger

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain
  alias KeyFleet.Chain.OwnershipLog
  alias KeyFleet.Fleets.Fleet
  alias KeyFleet.Keys
  alias KeyFleet.Rooms

  @rescan_blocks 30
  @max_range 10_000
  @system %System{}

  @doc """
  Runs one pass with `client`.

  Returns `:ok` once the cursor has moved on, `{:stopped, block}` while the
  fleet is stopped at a disagreement, and `{:error, reason}` when the chain
  could not be read, in which case nothing moved. A stopped fleet is not
  written to.
  """
  def step(%Fleet{} = fleet, client) do
    with :ok <- pass(fleet, client), do: open_level_rooms(fleet)
  end

  defp pass(fleet, client) do
    case Chain.get_cursor!(fleet.id) do
      nil ->
        %{fleet_id: fleet.id, next_block: fleet.deployed_block}
        |> Chain.open_cursor!(actor: @system)
        |> then(&scan(fleet, &1, client))

      %{rescan_from: nil} = cursor ->
        scan(fleet, cursor, client)

      %{rescan_from: block} ->
        {:stopped, block}
    end
  end

  defp scan(fleet, cursor, client) do
    with {:ok, head} <- client.head(),
         :ok <- reread(fleet, cursor.next_block, head.number, client),
         {:ok, next_block} <- read_forward(fleet, cursor.next_block, head.number, client) do
      Chain.advance_cursor!(
        cursor,
        %{
          next_block: next_block,
          head_block: head.number,
          head_block_hash: head.hash,
          observed_at: DateTime.utc_now()
        },
        actor: @system
      )

      :ok
    else
      {:diverged, block} -> stop(fleet, cursor, block)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reread(fleet, next_block, head, client) do
    from = max(fleet.deployed_block, next_block - @rescan_blocks)
    to = min(next_block - 1, head)

    if to < from do
      :ok
    else
      with {:ok, epochs} <- read(fleet, from, to, client),
           :ok <- record(epochs),
           do: still_on_chain(fleet, epochs, from, to, client)
    end
  end

  defp read_forward(_fleet, next_block, head, _client) when head < next_block,
    do: {:ok, next_block}

  defp read_forward(fleet, next_block, head, client) do
    to = min(head, next_block + @max_range - 1)

    with {:ok, epochs} <- read(fleet, next_block, to, client),
         :ok <- record(epochs),
         do: {:ok, to + 1}
  end

  defp read(fleet, from, to, client) do
    with {:ok, logs} <- client.get_logs(fleet.contract_address, OwnershipLog.topic(), from, to) do
      decode_all(logs, fleet, from, to)
    end
  end

  defp decode_all(logs, fleet, from, to) do
    decoded = Enum.map(logs, &OwnershipLog.decode(&1, fleet.id, fleet.contract_address))

    if Enum.all?(decoded, &match?({:ok, %{block_number: block}} when block in from..to//1, &1)),
      do:
        {:ok, decoded |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(&{&1.block_number, &1.log_index})},
      else: {:error, :invalid_log}
  end

  # An ownership change that conflicts with one already recorded means the
  # chain no longer agrees with the record.
  defp record(epochs) do
    Enum.reduce_while(epochs, :ok, fn epoch, :ok ->
      case Keys.record_epoch(epoch, actor: @system) do
        {:ok, _recorded} -> {:cont, :ok}
        {:error, %Ash.Error.Invalid{}} -> {:halt, {:diverged, epoch.block_number}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # A recorded change the second reading no longer finds means the same only
  # when its block is no longer the block that was recorded.
  defp still_on_chain(fleet, epochs, from, to, client) do
    seen = MapSet.new(epochs, &{&1.transaction_hash, &1.log_index})

    fleet.id
    |> Keys.recorded_in_blocks!(from, to, actor: @system)
    |> Enum.reject(&MapSet.member?(seen, {&1.transaction_hash, &1.log_index}))
    |> Enum.map(&{&1.block_number, &1.block_hash})
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {block, recorded_hash}, :ok ->
      case client.get_block_hash(block) do
        {:ok, ^recorded_hash} -> {:halt, {:error, {:log_missing_from_block, block}}}
        {:ok, _other_hash} -> {:halt, {:diverged, block}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp open_level_rooms(fleet) do
    with {:error, reason} <- Rooms.ensure_level_rooms(fleet.id) do
      Logger.warning(
        "Fleet #{fleet.id}: level rooms not opened this pass, trying again next pass: " <>
          Exception.format_banner(:error, reason)
      )
    end

    :ok
  end

  defp stop(fleet, cursor, block) do
    Chain.flag_divergence!(cursor, %{rescan_from: block}, actor: @system)

    Logger.error(
      "Fleet #{fleet.id} stopped: the chain disagrees with the recorded key ownership at block #{block}. " <>
        "Correct the record as docs/chain-reader.md describes, then run bin/clear-fleet-stop #{fleet.id}."
    )

    {:stopped, block}
  end
end

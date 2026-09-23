defmodule KeyFleet.Chain.Scanner do
  @moduledoc """
  One pass over a deployed fleet's history: who holds each key, from the
  fleet contract, and its proposals, votes and executions, from its vote
  contract.

  Each pass reads the head, reads again the last 30 blocks it already
  recorded, then records what happened after them up to the head. Each
  stretch of blocks is one request for both contracts, and its records are
  made in the order the chain made them. A stretch the node will not answer
  whole, such as one whose logs are more than it sends at once, is asked for
  again in halves, down to single blocks, and each answered piece is recorded
  before the next is asked for, so a pass holds one answer at most.

  A piece read for the first time is recorded in one transaction with the
  fleet's cursor moved past it, so the cursor always stands just after the
  last piece recorded. Every piece, in the second reading too, is recorded
  only while the cursor still stands where the pass left it and the fleet is
  not stopped; if an operator's correction or another pass has moved it, the
  piece is rolled back and the pass ends quietly, leaving the cursor where it
  now stands. The first piece that cannot be read ends the pass with
  the cursor there, and the next pass carries on from it: a single block the
  node will not answer, which is named in the error, or a piece with a
  malformed or unknown log, a proposal without its payload, a proposal number
  skipped, or a vote or execution for a proposal not recorded yet. That piece
  records nothing. Recording is safe to repeat: a record read twice is made
  once and keeps its number. Nothing above the head this pass read is asked
  for, so a node that is behind reads as a shorter pass, never as missing
  history.

  The second reading is how a change in the chain's history shows up. It
  checks each piece, in chain order, before recording anything new in it:
  every record made from those blocks must still be there. If it finds a
  record that disagrees with one already made, or a block whose hash is no
  longer the one recorded, the fleet is stopped at that block and the error
  is logged; pieces before it keep what they recorded. Nothing recorded is
  rewritten; an operator corrects the record by hand and then clears the
  stop, as `docs/chain-reader.md` describes. A recorded event missing from a
  block whose hash still matches is the node answering inconsistently, so the
  pass fails and is retried instead.

  A pass that reaches the head also notes the head's time, which is how far
  votes are known to be counted. A pass that made a new proposal record says
  so on `KeyFleet.Proposals.topic/1`, even if it then failed or stopped the
  fleet; that is only a hint to read again.

  Once a pass has moved the cursor on, the room of every Fibonacci level that
  has sold a key is opened if it is not open yet. Opening a room never holds
  up the record: if it fails, the failure is logged and the next pass tries
  again.
  """

  require Logger

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain
  alias KeyFleet.Chain.Logs
  alias KeyFleet.Fleets.Fleet
  alias KeyFleet.Keys
  alias KeyFleet.Proposals
  alias KeyFleet.Rooms

  @rescan_blocks 30
  @max_range 10_000
  @system %System{}

  @doc """
  Runs one pass with `client`.

  Returns `:ok` once the cursor has reached the end of the pass,
  `{:stopped, block}` while the fleet is stopped at a disagreement, naming
  the earliest one found, `:moved`
  when someone else moved the cursor or stopped the fleet during the pass,
  and
  `{:error, reason}` when the chain could not be read, in which case the
  cursor stands just after the last piece recorded. A stopped fleet is not
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
    result =
      with {:ok, head} <- client.head(),
           {:ok, cursor} <- reread(fleet, cursor, head, client),
           {:ok, _cursor} <- read_forward(fleet, cursor, head, client) do
        :ok
      else
        {:diverged, block} -> stop(fleet, cursor, block)
        {:moved, from_block} -> moved(fleet, from_block)
        {:error, reason} -> {:error, reason}
      end

    announce_proposals(cursor)
    result
  end

  # Only a pass that reached the head knows the votes are counted up to its time.
  defp advance(next_block, head) do
    moved = %{
      next_block: next_block,
      head_block: head.number,
      head_block_hash: head.hash,
      observed_at: DateTime.utc_now()
    }

    if next_block == head.number + 1,
      do: Map.put(moved, :read_through_at, head.timestamp),
      else: moved
  end

  # Each piece is checked against what is recorded before anything new in it
  # is recorded.
  defp reread(fleet, cursor, head, client) do
    from = max(fleet.deployed_block, cursor.next_block - @rescan_blocks)
    to = min(cursor.next_block - 1, head.number)

    each_piece(fleet, from, to, client, cursor, &check_and_record(fleet, client, &1, &2, &3, &4))
  end

  defp check_and_record(fleet, client, from, to, records, cursor) do
    with :ok <- still_on_chain(fleet, records, from, to, client),
         do: write_piece(fleet, records, cursor, &Chain.hold_cursor/1)
  end

  # Each piece moves the cursor past itself as it is recorded.
  defp read_forward(fleet, cursor, head, client) do
    from = cursor.next_block
    to = min(head.number, from + @max_range - 1)

    if to < from do
      write_piece(fleet, [], cursor, &Chain.advance_cursor(&1, advance(from, head)))
    else
      each_piece(fleet, from, to, client, cursor, &record_and_move(fleet, head, &1, &2, &3, &4))
    end
  end

  defp record_and_move(fleet, head, _from, to, records, cursor) do
    write_piece(fleet, records, cursor, &Chain.advance_cursor(&1, advance(to + 1, head)))
  end

  # Reads `from..to` in chain order. A stretch the node will not answer whole
  # is asked for again in halves, and each answered piece goes to `handle`
  # before the next is asked for, so a pass holds one answer at most. The
  # first piece that fails ends the reading.
  defp each_piece(_fleet, from, to, _client, acc, _handle) when to < from, do: {:ok, acc}

  defp each_piece(fleet, from, to, client, acc, handle) do
    addresses = [fleet.contract_address, fleet.votes_address]

    case client.get_logs(addresses, Logs.topics(), from, to) do
      {:ok, logs} ->
        with {:ok, records} <- Logs.decode(logs, fleet, from, to),
             do: handle.(from, to, records, acc)

      {:error, _reason} when from < to ->
        middle = div(from + to, 2)

        with {:ok, acc} <- each_piece(fleet, from, middle, client, acc, handle),
             do: each_piece(fleet, middle + 1, to, client, acc, handle)

      {:error, reason} ->
        {:error, {:block_unanswered, from, reason}}
    end
  end

  # A piece's records and what `to_cursor` does after them, holding or moving
  # the cursor, are made together or not at all. It is refused, and the piece
  # rolled back, once the cursor no longer stands where this pass left it or
  # the fleet has been stopped. A record the database refuses ends the
  # transaction there and comes back as its changeset.
  defp write_piece(fleet, records, cursor, to_cursor) do
    KeyFleet.Repo.transact(fn ->
      case record(fleet, records) do
        :ok -> write_cursor(cursor, to_cursor)
        failure -> {:error, failure}
      end
    end)
    |> case do
      {:ok, cursor} ->
        {:ok, cursor}

      {:error, %Ash.Changeset{} = refused} ->
        refused.errors
        |> Ash.Error.to_error_class()
        |> failure(Ash.Changeset.get_attribute(refused, :block_number))

      {:error, failure} ->
        failure
    end
  end

  # `to_cursor` writes from the cursor as this pass last left it.
  defp write_cursor(cursor, to_cursor) do
    case to_cursor.(cursor) do
      {:ok, cursor} -> {:ok, cursor}
      {:error, :moved} -> {:error, {:moved, cursor.next_block}}
      {:error, error} -> {:error, {:error, error}}
    end
  end

  # A record that conflicts with one already made means the chain no longer
  # agrees with the record.
  defp record(fleet, records) do
    with :ok <- Logs.in_sequence(records, Proposals.highest_number!(fleet.id)),
         do: Enum.reduce_while(records, :ok, &record_one/2)
  end

  defp record_one({_type, fields} = record, :ok) do
    case make_record(record) do
      {:ok, _recorded} -> {:cont, :ok}
      {:error, error} -> {:halt, failure(error, fields.block_number)}
    end
  end

  defp failure(%Ash.Error.Invalid{}, block), do: {:diverged, block}
  defp failure(error, _block), do: {:error, error}

  # A refused record is returned rather than rolling back the piece's
  # transaction, which `write_piece/4` undoes as a whole.
  @record_opts [actor: @system, rollback_on_error?: false]

  defp make_record({:ownership, epoch}), do: Keys.record_epoch(epoch, @record_opts)
  defp make_record({:proposal, proposal}), do: Proposals.record_proposal(proposal, @record_opts)
  defp make_record({:vote, vote}), do: Proposals.record_vote(vote, @record_opts)

  defp make_record({:execution, execution}),
    do: Proposals.record_execution(execution, @record_opts)

  # A recorded event the second reading no longer finds means the same only
  # when its block is no longer the block that was recorded.
  defp still_on_chain(fleet, records, from, to, client) do
    seen =
      MapSet.new(records, fn {_type, fields} -> {fields.transaction_hash, fields.log_index} end)

    fleet.id
    |> Keys.recorded_in_blocks!(from, to, actor: @system)
    |> Enum.concat(Proposals.recorded_in_blocks!(fleet.id, from, to))
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

  # The cursor as the pass found it; the records it made moved proposal_seq on.
  defp announce_proposals(%{fleet_id: fleet_id, proposal_seq: before}) do
    if Chain.get_cursor!(fleet_id).proposal_seq > before do
      Phoenix.PubSub.broadcast(
        KeyFleet.PubSub,
        Proposals.topic(fleet_id),
        {:proposals_changed, fleet_id}
      )
    end
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

  # Someone else moved the cursor or stopped the fleet during the pass: an
  # operator's correction, or another pass. The pass leaves the cursor as it
  # is, and the next pass reads on from wherever it then stands.
  defp moved(fleet, from_block) do
    Logger.info(
      "Fleet #{fleet.id}: the cursor moved underneath a pass that left it at block " <>
        "#{from_block}, or the fleet was stopped; the pass ended and wrote nothing more."
    )

    :moved
  end

  # A fleet already stopped at an earlier block stays stopped there.
  defp stop(fleet, cursor, block) do
    %{rescan_from: stopped_at} =
      Chain.flag_divergence!(cursor, %{block: block}, actor: @system)

    Logger.error(
      "Fleet #{fleet.id} stopped: the chain disagrees with the record at block #{block}. " <>
        "It is stopped at block #{stopped_at}. " <>
        "Correct the record as docs/chain-reader.md describes, then run bin/clear-fleet-stop #{fleet.id}."
    )

    {:stopped, stopped_at}
  end
end

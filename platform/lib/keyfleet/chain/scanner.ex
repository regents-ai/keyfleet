defmodule Keyfleet.Chain.Scanner do
  @moduledoc """
  One pass over a deployed fleet's history: who holds each of its Keys and
  each Key's reveal, from the Key collection every fleet shares; what it
  forwarded to its treasury or sent as the protocol share, from its manager;
  its proposals, votes, cancellations and executions, which Keys' workspace
  edits a proposal restricted, and each Key's presence, from its vote
  contract; the shards its Keys' owners issued and ended and whether those
  shards may vote, from the shard record every fleet shares; what its
  treasury paid, advanced, got back and split, from its treasury; rewards
  settled and paid out, from its reward ledger; and its USDC from Key sales
  turned into REGENT, from the REGENT buyer every fleet shares, the one its
  manager names at the head the pass reads.

  Each pass reads the head and the buyer the manager names there, and a pass
  that cannot read the buyer reads nothing and fails. It then reads again the
  last 30 blocks it already
  recorded (about a minute of Base), then records what
  happened after them up to the head. Each stretch of blocks is one request
  for all seven contracts, and its records are made in the order the chain made
  them. A stretch the node will not answer
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
  malformed or unknown log, a proposal without its author key's renewal, a
  proposal number skipped, or a vote, cancellation or execution for a
  proposal not recorded yet. That piece
  records nothing. Recording is safe to repeat: a record read twice is made
  once and keeps its number. Nothing above the head this pass read is asked
  for, so a node that is behind reads as a shorter pass, never as missing
  history.

  The second reading is how a change in the chain's history shows up. It
  checks each piece, in chain order, before recording anything new in it:
  every record made from those blocks must still be there. If it finds a
  record that disagrees with one already made, or a block whose hash is no
  longer the one recorded, the fleet is stopped at that block and the error
  is logged; pieces before it keep what they recorded. A record read again
  that disagrees with the one already made stops the fleet at the earlier of
  the block it was read from and the block it was recorded from. A key's
  reveal is its seed wherever it is read: the same seed read from another
  block is the same reveal, and a reveal missing from its block is not a
  disagreement, but a different seed or request for a revealed key is.
  Nothing recorded is rewritten; an operator corrects the record by hand and
  then clears the stop, as `docs/chain-reader.md` describes. A recorded event
  missing from a block whose hash still matches is the node answering
  inconsistently, so the pass fails and is retried instead.

  A pass that made a new proposal or money record says so on
  `Keyfleet.Proposals.topic/1`. One that recorded keys revealed, sold,
  changing hands, issuing or ending shards, turning their agent voting on or
  off, or having their edits restricted or allowed names them all in one
  notice on `Keyfleet.Keys.topic/1`, wherever in the pass it recorded them. Each is said
  even if the pass then failed or stopped the fleet, and each is only a hint
  to read again.
  """

  require Logger

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain
  alias Keyfleet.Chain.Logs
  alias Keyfleet.Chain.ReadingStoppedError
  alias Keyfleet.Fleets.Fleet
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Treasury
  alias RegentChain.Abi
  alias RegentChain.Call

  @rescan_blocks 30
  @regent_buyer Call.encode("REGENT_BUYER()", [])
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
           {:ok, buyer} <- regent_buyer(fleet, head, client),
           contracts = {fleet, buyer},
           {:ok, cursor} <- reread(contracts, cursor, head, client),
           {:ok, _cursor} <- read_forward(contracts, cursor, head, client) do
        :ok
      else
        {:diverged, block} -> stop(fleet, cursor, block)
        {:moved, from_block} -> moved(fleet, from_block)
        {:error, reason} -> {:error, reason}
      end

    announce(cursor)
    result
  end

  defp advance(next_block, head) do
    %{
      next_block: next_block,
      head_block: head.number,
      head_block_hash: head.hash,
      observed_at: DateTime.utc_now()
    }
  end

  # The REGENT buyer the fleet's manager names, which never changes.
  defp regent_buyer(fleet, head, client) do
    with {:ok, returned} <- client.call(fleet.manager_address, @regent_buyer, head.hash),
         {:ok, [buyer]} <- Abi.decode(returned, [:address]) do
      {:ok, buyer}
    else
      {:error, reason} -> {:error, {:regent_buyer_unread, reason}}
      :error -> {:error, {:regent_buyer_unread, :unreadable_answer}}
    end
  end

  # Each piece is checked against what is recorded before anything new in it
  # is recorded.
  defp reread({fleet, _buyer} = contracts, cursor, head, client) do
    from = max(fleet.deployed_block, cursor.next_block - @rescan_blocks)
    to = min(cursor.next_block - 1, head.number)

    each_piece(
      contracts,
      from,
      to,
      client,
      cursor,
      &check_and_record(fleet, client, &1, &2, &3, &4)
    )
  end

  defp check_and_record(fleet, client, from, to, records, cursor) do
    with :ok <- still_on_chain(fleet, records, from, to, client),
         do: write_piece(fleet, records, cursor, &Chain.hold_cursor/1)
  end

  # Each piece moves the cursor past itself as it is recorded.
  defp read_forward({fleet, _buyer} = contracts, cursor, head, client) do
    from = cursor.next_block
    to = min(head.number, from + @max_range - 1)

    if to < from do
      write_piece(fleet, [], cursor, &Chain.advance_cursor(&1, advance(from, head)))
    else
      each_piece(
        contracts,
        from,
        to,
        client,
        cursor,
        &record_and_move(fleet, head, &1, &2, &3, &4)
      )
    end
  end

  defp record_and_move(fleet, head, _from, to, records, cursor) do
    write_piece(fleet, records, cursor, &Chain.advance_cursor(&1, advance(to + 1, head)))
  end

  # Reads `from..to` in chain order. A stretch the node will not answer whole
  # is asked for again in halves, and each answered piece goes to `handle`
  # before the next is asked for, so a pass holds one answer at most. The
  # first piece that fails ends the reading, and so does a node asking for
  # fewer requests (HTTP 429): halves would only ask it more.
  defp each_piece(_contracts, from, to, _client, acc, _handle) when to < from, do: {:ok, acc}

  defp each_piece({fleet, buyer} = contracts, from, to, client, acc, handle) do
    case client.get_logs(Logs.addresses(fleet, buyer), Logs.topics(), from, to) do
      {:ok, logs} ->
        with {:ok, records} <- Logs.decode(logs, fleet, buyer, from, to),
             do: handle.(from, to, records, acc)

      {:error, :chain_busy} ->
        {:error, {:block_unanswered, from, :chain_busy}}

      {:error, _reason} when from < to ->
        middle = div(from + to, 2)

        with {:ok, acc} <- each_piece(contracts, from, middle, client, acc, handle),
             do: each_piece(contracts, middle + 1, to, client, acc, handle)

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
    Keyfleet.Repo.transact(fn ->
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

  # A record read again that disagrees with the one already made stops the
  # fleet at the earlier of the two blocks: the recorded one's block changed.
  defp failure(%Ash.Error.Invalid{errors: errors}, block) do
    recorded =
      for %{vars: vars} <- errors,
          Keyword.has_key?(vars, :recorded_block),
          do: vars[:recorded_block]

    {:diverged, Enum.min([block | recorded])}
  end

  defp failure(error, _block), do: {:error, error}

  # A refused record is returned rather than rolling back the piece's
  # transaction, which `write_piece/4` undoes as a whole.
  @record_opts [actor: @system, rollback_on_error?: false]

  defp make_record({:ownership, epoch}), do: Keys.record_epoch(epoch, @record_opts)
  defp make_record({:reveal, reveal}), do: Keys.record_reveal(reveal, @record_opts)

  defp make_record({:proposal, proposal}), do: Proposals.record_proposal(proposal, @record_opts)
  defp make_record({:ballot, vote}), do: Proposals.record_vote(vote, @record_opts)

  defp make_record({:cancellation, cancellation}),
    do: Proposals.record_cancellation(cancellation, @record_opts)

  defp make_record({:execution, execution}),
    do: Proposals.record_execution(execution, @record_opts)

  defp make_record({:edits_restriction, restriction}),
    do: Keys.record_edits_restriction(restriction, @record_opts)

  defp make_record({:shard, event}), do: Keys.record_shard_event(event, @record_opts)
  defp make_record({:agent_voting, setting}), do: Keys.record_agent_voting(setting, @record_opts)
  defp make_record({:presence, presence}), do: Keys.record_presence(presence, @record_opts)
  defp make_record({:treasury_event, event}), do: Treasury.record_event(event, @record_opts)

  # A recorded event the second reading no longer finds means the same only
  # when its block is no longer the block that was recorded.
  defp still_on_chain(fleet, records, from, to, client) do
    seen =
      MapSet.new(records, fn {_type, fields} -> {fields.transaction_hash, fields.log_index} end)

    fleet.id
    |> Keys.recorded_in_blocks!(from, to, actor: @system)
    |> Enum.concat(Keys.shard_events_in_blocks!(fleet.id, from, to, actor: @system))
    |> Enum.concat(Keys.edits_restrictions_in_blocks!(fleet.id, from, to, actor: @system))
    |> Enum.concat(Keys.agent_voting_in_blocks!(fleet.id, from, to, actor: @system))
    |> Enum.concat(Keys.presences_in_blocks!(fleet.id, from, to, actor: @system))
    |> Enum.concat(Proposals.recorded_in_blocks!(fleet.id, from, to))
    |> Enum.concat(Treasury.recorded_in_blocks!(fleet.id, from, to))
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

  # The cursor as the pass found it; the records it made moved its numbers on.
  # Every key revealed, sold, changing hands, issuing or ending a shard,
  # turning its agent voting on or off, or having its edits restricted or
  # allowed in the pass is named once.
  defp announce(%{fleet_id: fleet_id} = before) do
    now = Chain.get_cursor!(fleet_id)

    revealed =
      if now.reveal_seq > before.reveal_seq,
        do: Keys.reveals_recorded_since!(fleet_id, before.reveal_seq, actor: @system),
        else: []

    owned =
      if now.ownership_seq > before.ownership_seq,
        do: Keys.epochs_recorded_since!(fleet_id, before.ownership_seq, actor: @system),
        else: []

    sharded =
      if now.shard_seq > before.shard_seq,
        do:
          Keys.shard_events_recorded_since!(fleet_id, before.shard_seq, actor: @system) ++
            Keys.agent_voting_recorded_since!(fleet_id, before.shard_seq, actor: @system),
        else: []

    restricted =
      if now.proposal_seq > before.proposal_seq,
        do:
          Keys.edits_restrictions_recorded_since!(fleet_id, before.proposal_seq, actor: @system),
        else: []

    if now.proposal_seq > before.proposal_seq do
      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Proposals.topic(fleet_id),
        {:proposals_changed, fleet_id}
      )
    end

    case Enum.uniq_by(revealed ++ owned ++ sharded ++ restricted, & &1.token_id) do
      [] ->
        :ok

      records ->
        # Whoever was let into the fleet's code or notebooks is checked afresh.
        Keyfleet.Code.end_access(fleet_id)
        Keyfleet.Notebooks.end_access(fleet_id)

        Phoenix.PubSub.broadcast(
          Keyfleet.PubSub,
          Keys.topic(fleet_id),
          {:keys_changed, fleet_id, Enum.map(records, & &1.token_id)}
        )
    end
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

    message =
      "Fleet #{fleet.id} stopped: the chain disagrees with the record at block #{block}. " <>
        "It is stopped at block #{stopped_at}. " <>
        "Correct the record as docs/chain-reader.md describes, then run bin/clear-fleet-stop #{fleet.id}."

    Logger.error(message)
    ReadingStoppedError.report(message)
    {:stopped, stopped_at}
  end
end

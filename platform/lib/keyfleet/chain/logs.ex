defmodule KeyFleet.Chain.Logs do
  @moduledoc """
  Turns the raw logs of one stretch of a fleet's blocks into the records the
  reader makes, in the order the chain made them.

  Each log is sent, by its contract and topic0, to `KeyFleet.Chain.OwnershipLog`
  or `KeyFleet.Chain.VotesLog`, and carries its fleet and its place on the
  chain. A launch proposal is joined with the payload log that follows it in
  the same transaction. A log the node lists twice is read once.
  One log that cannot be read, two different logs in one place, or a proposal
  and payload that do not pair up refuses the whole stretch, and the reason
  names the log.
  """

  alias KeyFleet.Chain.Abi
  alias KeyFleet.Chain.OwnershipLog
  alias KeyFleet.Chain.VotesLog

  @doc "The topic0 of every event the reader asks for."
  def topics, do: [OwnershipLog.topic() | VotesLog.topics()]

  @doc """
  The records in `logs`, read from blocks `from..to` of `fleet`, in (block,
  log index) order. Otherwise `{:error, reason}`, where the reason names the
  transaction hash and log index of the log refused:

    * `{:unreadable_log, transaction_hash, log_index}`: the log is outside
      that stretch, is not from the fleet's contracts, or is not exactly as
      they emit it.
    * `{:conflicting_logs, transaction_hash, log_index}`: two different logs
      claim the same place.
    * `{:payload_missing, transaction_hash, log_index}`: a launch
      proposal is not followed by its payload.
    * `{:payload_without_proposal, transaction_hash, log_index}`: a payload
      does not follow its proposal.
  """
  def decode(logs, fleet, from, to) do
    with {:ok, records} <- decode_each(logs, fleet, from..to//1, []),
         {:ok, records} <- distinct(records),
         do: records |> Enum.sort_by(&position/1) |> join([])
  end

  @doc """
  Whether `records` can be made after the fleet's highest recorded proposal
  number, `highest`: each new proposal must be the next number, and each vote
  and execution must name a proposal recorded by then. A proposal at or below
  the highest is one read again, which recording compares with the record.
  """
  def in_sequence(records, highest) do
    Enum.reduce_while(records, highest, fn
      {:proposal, %{number: number}}, top when number <= top ->
        {:cont, top}

      {:proposal, %{number: number}}, top when number == top + 1 ->
        {:cont, number}

      {:proposal, proposal}, _top ->
        {:halt, {:error, {:proposal_number_skipped, proposal.block_number}}}

      {_type, %{proposal_number: number}}, top when number <= top ->
        {:cont, top}

      {_type, %{proposal_number: _number} = record}, _top ->
        {:halt, {:error, {:proposal_not_recorded, record.block_number}}}

      {:ownership, _epoch}, top ->
        {:cont, top}
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      _highest -> :ok
    end
  end

  defp decode_each([], _fleet, _blocks, records), do: {:ok, Enum.reverse(records)}

  defp decode_each([log | logs], fleet, blocks, records) do
    case decode_one(log, fleet, blocks) do
      {:ok, record} ->
        decode_each(logs, fleet, blocks, [record | records])

      :error ->
        {:error, {:unreadable_log, as_given(log, "transactionHash"), as_given(log, "logIndex")}}
    end
  end

  defp as_given(%{} = log, field), do: log[field]
  defp as_given(_log, _field), do: nil

  defp decode_one(
         %{
           "address" => address,
           "topics" => [topic0 | topics],
           "data" => data,
           "blockNumber" => block_number,
           "blockHash" => block_hash,
           "transactionHash" => transaction_hash,
           "logIndex" => log_index
         },
         fleet,
         blocks
       )
       when is_binary(address) and is_binary(topic0) do
    with {:ok, block_number} <- Abi.quantity(block_number),
         true <- block_number in blocks,
         {:ok, block_hash} <- Abi.hash(block_hash),
         {:ok, transaction_hash} <- Abi.hash(transaction_hash),
         {:ok, log_index} <- Abi.quantity(log_index),
         {:ok, words} <- words(topics, []),
         {:ok, data} <- Abi.bytes(data),
         {:ok, {type, fields}} <-
           route(fleet, String.downcase(address), String.downcase(topic0), words, data) do
      {:ok,
       {type,
        Map.merge(fields, %{
          fleet_id: fleet.id,
          block_number: block_number,
          block_hash: block_hash,
          transaction_hash: transaction_hash,
          log_index: log_index
        })}}
    else
      _malformed -> :error
    end
  end

  defp decode_one(_log, _fleet, _blocks), do: :error

  defp route(%{contract_address: address}, address, topic0, words, data),
    do: OwnershipLog.decode(topic0, words, data)

  defp route(%{votes_address: address}, address, topic0, words, data),
    do: VotesLog.decode(topic0, words, data)

  defp route(_fleet, _address, _topic0, _words, _data), do: :error

  defp words([], words), do: {:ok, Enum.reverse(words)}

  defp words([topic | topics], words) do
    case Abi.bytes(topic) do
      {:ok, <<word::binary-size(32)>>} -> words(topics, [word | words])
      _malformed -> :error
    end
  end

  defp position({_type, record}), do: {record.block_number, record.log_index}
  defp event({_type, record}), do: {record.transaction_hash, record.log_index}

  # The same log listed twice is read once. Two different logs in one block at
  # one index, or with one transaction hash and index, are not one chain.
  defp distinct(records) do
    records = Enum.uniq(records)

    with :ok <- one_each(records, &position/1),
         :ok <- one_each(records, &event/1),
         do: {:ok, records}
  end

  defp one_each(records, place) do
    records
    |> Enum.group_by(place)
    |> Enum.find_value(:ok, fn
      {_place, [{_type, record}, _other | _rest]} ->
        {:error, {:conflicting_logs, record.transaction_hash, record.log_index}}

      {_place, [_one]} ->
        nil
    end)
  end

  # A launch proposal takes its payload from the next log, which
  # must be that payload, for the same proposal, in the same transaction.
  defp join([], records), do: {:ok, Enum.reverse(records)}

  defp join([{:proposal, %{kind: :decision}} = proposal | rest], records),
    do: join(rest, [proposal | records])

  defp join(
         [
           {:proposal, %{kind: kind, number: number, transaction_hash: transaction} = proposal},
           {kind, %{number: number, transaction_hash: transaction, payload: payload}} | rest
         ],
         records
       ),
       do: join(rest, [{:proposal, Map.merge(proposal, payload)} | records])

  defp join([{:proposal, proposal} | _rest], _records),
    do: {:error, {:payload_missing, proposal.transaction_hash, proposal.log_index}}

  defp join([{:autolaunch, payload} | _rest], _records),
    do: {:error, {:payload_without_proposal, payload.transaction_hash, payload.log_index}}

  defp join([record | rest], records), do: join(rest, [record | records])
end

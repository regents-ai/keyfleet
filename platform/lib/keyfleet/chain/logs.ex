defmodule Keyfleet.Chain.Logs do
  @moduledoc """
  Turns the raw logs of one stretch of a fleet's blocks into the records the
  reader makes, in the order the chain made them.

  Each log is sent, by its contract and topic0, to
  `Keyfleet.Chain.OwnershipLog`, `Keyfleet.Chain.RevealLog` or
  `Keyfleet.Chain.MoneyLog`, for the fleet contract,
  `Keyfleet.Chain.VotesLog`, for its vote contract,
  `Keyfleet.Chain.ShardsLog`, for its shard record, or
  `Keyfleet.Chain.MoneyLog`, for its treasury and reward ledger, and carries
  its fleet and its place on the chain. A proposal takes the time it opened
  from the renewal of its author key logged just before it, in the same
  transaction. A log the node lists twice is read once. One log that cannot
  be read, two different logs in one place, or a proposal without its
  author's renewal refuses the whole stretch, and the reason names the log.
  """

  alias Keyfleet.Chain.MoneyLog
  alias Keyfleet.Chain.OwnershipLog
  alias Keyfleet.Chain.RevealLog
  alias Keyfleet.Chain.ShardsLog
  alias Keyfleet.Chain.VotesLog
  alias RegentChain.Abi

  @doc "The topic0 of every event the reader asks for."
  def topics,
    do:
      Enum.concat([
        [OwnershipLog.topic(), RevealLog.topic()],
        MoneyLog.fleet_topics(),
        VotesLog.topics(),
        ShardsLog.topics(),
        MoneyLog.treasury_topics(),
        MoneyLog.rewards_topics()
      ])

  @doc """
  The records in `logs`, read from blocks `from..to` of `fleet`, in (block,
  log index) order. Otherwise `{:error, reason}`, where the reason names the
  transaction hash and log index of the log refused:

    * `{:unreadable_log, transaction_hash, log_index}`: the log is outside
      that stretch, is not from the fleet's contracts, or is not exactly as
      they emit it.
    * `{:conflicting_logs, transaction_hash, log_index}`: two different logs
      claim the same place.
    * `{:opening_missing, transaction_hash, log_index}`: a proposal does not
      follow its author key's renewal in the same transaction.
  """
  def decode(logs, fleet, from, to) do
    with {:ok, records} <- decode_each(logs, fleet, from..to//1, []),
         {:ok, records} <- distinct(records),
         do: records |> Enum.sort_by(&position/1) |> join([])
  end

  @doc """
  Whether `records` can be made after the fleet's highest recorded proposal
  number, `highest`: each new proposal must be the next number, and each vote
  ballot, cancellation and execution must name a proposal recorded by then. A
  proposal at or below the highest is one read again, which recording
  compares with the record. Every other record names no proposal.
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

      {_type, _record}, top ->
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

  defp route(%{contract_address: address}, address, topic0, words, data) do
    with :error <- OwnershipLog.decode(topic0, words, data),
         :error <- RevealLog.decode(topic0, words, data),
         do: MoneyLog.decode(:fleet, topic0, words, data)
  end

  defp route(%{votes_address: address}, address, topic0, words, data),
    do: VotesLog.decode(topic0, words, data)

  defp route(%{shards_address: address}, address, topic0, words, data),
    do: ShardsLog.decode(topic0, words, data)

  defp route(%{treasury_address: address}, address, topic0, words, data),
    do: MoneyLog.decode(:treasury, topic0, words, data)

  defp route(%{rewards_address: address}, address, topic0, words, data),
    do: MoneyLog.decode(:rewards, topic0, words, data)

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

  # A proposal opens at the time its author key is renewed, which the
  # contract logs just before the proposal, in the same transaction.
  defp join([], records), do: {:ok, Enum.reverse(records)}

  defp join(
         [
           {:presence, %{kind: :present, token_id: key, at: at, transaction_hash: transaction}} =
             renewal,
           {:proposal, %{author_key: key, transaction_hash: transaction} = proposal} | rest
         ],
         records
       ),
       do: join(rest, [{:proposal, Map.put(proposal, :opened_at, at)}, renewal | records])

  defp join([{:proposal, proposal} | _rest], _records),
    do: {:error, {:opening_missing, proposal.transaction_hash, proposal.log_index}}

  defp join([record | rest], records), do: join(rest, [record | records])
end

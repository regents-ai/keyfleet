defmodule Keyfleet.Chain.VotesLog do
  @moduledoc """
  Reads the proposal, vote and execution logs of a fleet's `KeyfleetVotes`
  contract into the fields `Keyfleet.Proposals` records.

  A launch or payment proposal is two logs: `ProposalCreated` and, right after
  it in the same transaction, `AutolaunchProposed` or `PayProposed`. Each is
  read here on its own, as `{:proposal, fields}` and `{:autolaunch, %{number:
  n, payload: fields}}` or `{:pay, %{number: n, payload: fields}}`;
  `Keyfleet.Chain.Logs` joins them.

  Every key is one vote, so a vote carries its keys and nothing else. A key
  may vote again, and its latest vote is the one that counts. A
  `VoteWithdrawn` log is read as a vote whose `support` is nil: the keys it
  names count for neither side until they vote again.

  A Decision's or payment's text is kept up to its first 64 KiB, as raw bytes
  that need not be valid text, beside its full length and its SHA-256. A
  launch's text is always empty and is not kept.
  """

  alias RegentChain.Abi
  alias RegentChain.Event

  @created Event.topic0("ProposalCreated(uint256,uint8,address,uint64,bytes32,string)")
  @autolaunch Event.topic0("AutolaunchProposed(uint256,bytes32)")
  @pay Event.topic0("PayProposed(uint256,address,uint256,address)")
  @vote Event.topic0("VoteCast(uint256,address,bool,uint256[])")
  @withdrawn Event.topic0("VoteWithdrawn(uint256,address,uint256[])")
  @executed Event.topic0("ProposalExecuted(uint256,address)")

  @text_cap 65_536
  @zero_digest "0x" <> String.duplicate("0", 64)
  # The contract's `Kind` numbers, pinned in contracts/test/KeyfleetVotesTopics.t.sol.
  @kinds %{0 => :decision, 1 => :autolaunch, 2 => :pay}

  @doc "The topic0 of every event read here."
  def topics, do: [@created, @autolaunch, @pay, @vote, @withdrawn, @executed]

  @doc """
  A log's indexed topics after topic0, as 32-byte words, and its data, as one
  record; `:error` for any other log or a malformed one.
  """
  def decode(@created, [id, kind, proposer], data) do
    with {:ok, number} <- number(id),
         {:ok, kind} <- kind(kind),
         {:ok, proposer} <- Abi.word(proposer, :address),
         {:ok, [opened_block, digest, text]} <-
           Abi.decode(data, [{:uint, 63}, :bytes32, :bytes]) do
      {:ok,
       {:proposal,
        Map.merge(
          %{
            number: number,
            kind: kind,
            proposer: proposer,
            opened_block: opened_block,
            digest: if(digest != @zero_digest, do: digest)
          },
          text(kind, text)
        )}}
    else
      _malformed -> :error
    end
  end

  def decode(@autolaunch, [id], data) do
    with {:ok, number} <- number(id),
         {:ok, [envelope_hash]} <- Abi.decode(data, [:bytes32]) do
      {:ok, {:autolaunch, %{number: number, payload: %{envelope_hash: envelope_hash}}}}
    else
      _malformed -> :error
    end
  end

  def decode(@pay, [id, asset, recipient], data) do
    with {:ok, number} <- number(id),
         {:ok, asset} <- Abi.word(asset, :address),
         {:ok, recipient} <- Abi.word(recipient, :address),
         {:ok, [amount]} <- Abi.decode(data, [{:uint, 256}]) do
      {:ok,
       {:pay,
        %{
          number: number,
          payload: %{asset: asset, amount: Decimal.new(amount), recipient: recipient}
        }}}
    else
      _malformed -> :error
    end
  end

  def decode(@vote, [id, voter], data) do
    with {:ok, [support, token_ids]} <- Abi.decode(data, [:bool, {:array, {:uint, 63}}]),
         do: vote(id, voter, support, token_ids)
  end

  def decode(@withdrawn, [id, voter], data) do
    with {:ok, [token_ids]} <- Abi.decode(data, [{:array, {:uint, 63}}]),
         do: vote(id, voter, nil, token_ids)
  end

  def decode(@executed, [id, executor], data) do
    with {:ok, number} <- number(id),
         {:ok, executor} <- Abi.word(executor, :address),
         {:ok, []} <- Abi.decode(data, []) do
      {:ok, {:execution, %{proposal_number: number, executor: executor}}}
    else
      _malformed -> :error
    end
  end

  def decode(_topic0, _topics, _data), do: :error

  defp vote(id, voter, support, token_ids) do
    with {:ok, number} <- number(id),
         {:ok, voter} <- Abi.word(voter, :address),
         [_ | _] <- token_ids,
         true <- Enum.all?(token_ids, &(&1 > 0)) do
      {:ok,
       {:vote,
        %{
          proposal_number: number,
          voter: voter,
          support: support,
          token_ids: token_ids
        }}}
    else
      _malformed -> :error
    end
  end

  defp number(topic) do
    case Abi.word(topic, {:uint, 63}) do
      {:ok, number} when number > 0 -> {:ok, number}
      _malformed -> :error
    end
  end

  defp kind(topic) do
    with {:ok, value} <- Abi.word(topic, {:uint, 8}), do: Map.fetch(@kinds, value)
  end

  defp text(:autolaunch, _text), do: %{text: nil, text_bytes: nil, text_sha256: nil}

  defp text(_kind, text) do
    %{
      text: binary_part(text, 0, min(byte_size(text), @text_cap)),
      text_bytes: byte_size(text),
      text_sha256: "0x" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    }
  end
end

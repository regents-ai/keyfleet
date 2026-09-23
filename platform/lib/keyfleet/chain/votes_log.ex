defmodule KeyFleet.Chain.VotesLog do
  @moduledoc """
  Reads the proposal, vote and execution logs of a fleet's `KeyfleetVotes`
  contract into the fields `KeyFleet.Proposals` records.

  A launch or payment proposal is two logs: `ProposalCreated` and, right after
  it in the same transaction, `AutolaunchProposed` or `PayProposed`. Each is
  read here on its own, as `{:proposal, fields}` and `{:autolaunch, %{number:
  n, payload: fields}}` or `{:pay, %{number: n, payload: fields}}`;
  `KeyFleet.Chain.Logs` joins them.

  Every key is one vote, so a vote carries its keys and nothing else.

  A Decision's or payment's text is kept up to its first 64 KiB, as raw bytes
  that need not be valid text, beside its full length and its SHA-256. A
  launch's text is always empty and is not kept.
  """

  alias KeyFleet.Chain.Abi

  # cast keccak "ProposalCreated(uint256,uint8,address,uint64,uint256,bytes32,string)"
  @created "0x3981631dc33adabae5ab9de3f23bf01207ffc383d894a4f777ee115e75dee3a9"
  # cast keccak "AutolaunchProposed(uint256,bytes32,uint64)"
  @autolaunch "0xa395caec5e719dd09aa72025608546598e2f07d131ae8ca46b82bbaacfbe2846"
  # cast keccak "PayProposed(uint256,address,uint256,address,uint64)"
  @pay "0xdf6e4791f55c0c086cb1d3527b5f4f92e4b3d3142e3899a7b5a4af3e75b7cd85"
  # cast keccak "VoteCast(uint256,address,bool,uint256[])"
  @vote "0x707650471b3fbad25e3f07d77bd835851846b71eb8c47598be05f07de77aed53"
  # cast keccak "ProposalExecuted(uint256,address)"
  @executed "0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24"

  @text_cap 65_536
  @zero_digest "0x" <> String.duplicate("0", 64)
  # The contract's `Kind` numbers, pinned in contracts/test/KeyfleetVotesTopics.t.sol.
  @kinds %{0 => :decision, 1 => :autolaunch, 2 => :pay}

  @doc "The topic0 of every event read here."
  def topics, do: [@created, @autolaunch, @pay, @vote, @executed]

  @doc """
  A log's indexed topics after topic0, as 32-byte words, and its data, as one
  record; `:error` for any other log or a malformed one.
  """
  def decode(@created, [id, kind, proposer], data) do
    with {:ok, number} <- number(id),
         {:ok, kind} <- kind(kind),
         {:ok, proposer} <- Abi.word(proposer, :address),
         {:ok, [closes_at, eligible_keys, digest, text]} <-
           Abi.decode(data, [{:uint, 64}, {:uint, 63}, :bytes32, :bytes]),
         {:ok, closes_at} <- DateTime.from_unix(closes_at) do
      {:ok,
       {:proposal,
        Map.merge(
          %{
            number: number,
            kind: kind,
            proposer: proposer,
            closes_at: closes_at,
            eligible_keys: eligible_keys,
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
         {:ok, [envelope_hash, execution_expiry]} <- Abi.decode(data, [:bytes32, {:uint, 64}]) do
      {:ok,
       {:autolaunch,
        %{
          number: number,
          payload: %{
            envelope_hash: envelope_hash,
            execution_expiry: Decimal.new(execution_expiry)
          }
        }}}
    else
      _malformed -> :error
    end
  end

  def decode(@pay, [id, asset, recipient], data) do
    with {:ok, number} <- number(id),
         {:ok, asset} <- Abi.word(asset, :address),
         {:ok, recipient} <- Abi.word(recipient, :address),
         {:ok, [amount, execution_expiry]} <- Abi.decode(data, [{:uint, 256}, {:uint, 64}]) do
      {:ok,
       {:pay,
        %{
          number: number,
          payload: %{
            asset: asset,
            amount: Decimal.new(amount),
            recipient: recipient,
            execution_expiry: Decimal.new(execution_expiry)
          }
        }}}
    else
      _malformed -> :error
    end
  end

  def decode(@vote, [id, voter], data) do
    with {:ok, number} <- number(id),
         {:ok, voter} <- Abi.word(voter, :address),
         {:ok, [support, [_ | _] = token_ids]} <-
           Abi.decode(data, [:bool, {:array, {:uint, 63}}]),
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

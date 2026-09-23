defmodule KeyFleet.ProposalHelpers do
  @moduledoc """
  Records proposals, votes, executions and launches as the chain reader
  would, without a chain. Each record gets a chain event of its own. The
  fleet needs a cursor first, as `KeyFleet.ChainHelpers.seed_cursor!/2` makes.
  """

  alias KeyFleet.Actors.System
  alias KeyFleet.Proposals

  @system %System{}
  @block_hash "0x" <> String.duplicate("b", 64)

  @doc """
  Proposal `number` of the fleet: a decision closing in an hour that seven
  keys may vote on, unless `attrs` says otherwise. A payment and a launch
  get the fields their kind carries.
  """
  def proposal!(fleet_id, number, attrs \\ %{}) do
    attrs = Map.new(attrs)
    kind = Map.get(attrs, :kind, :decision)

    %{
      fleet_id: fleet_id,
      number: number,
      kind: kind,
      proposer: wallet("f"),
      closes_at: DateTime.add(DateTime.utc_now(), 3600),
      eligible_keys: 7,
      digest: "0x" <> String.duplicate("d", 64)
    }
    |> Map.merge(kind_fields(kind, number))
    |> Map.merge(event())
    |> Map.merge(attrs)
    |> Proposals.record_proposal!(actor: @system)
  end

  @doc "A vote on proposal `number` by `voter` with `token_ids`, one vote per key."
  def vote!(fleet_id, number, voter, support, token_ids) do
    %{
      fleet_id: fleet_id,
      proposal_number: number,
      voter: voter,
      support: support,
      token_ids: token_ids
    }
    |> Map.merge(event())
    |> Proposals.record_vote!(actor: @system)
  end

  @doc "Proposal `number` carried out by `executor`."
  def execution!(fleet_id, number, executor) do
    %{fleet_id: fleet_id, proposal_number: number, executor: executor}
    |> Map.merge(event())
    |> Proposals.record_execution!(actor: @system)
  end

  @doc "The launch a launch proposal approves, read."
  def launch_envelope!(proposal, attrs \\ %{}) do
    %{
      fleet_id: proposal.fleet_id,
      proposal_id: proposal.id,
      name: "Cascade Research",
      symbol: "CSR",
      description: "Research the fleet funds",
      website: "https://example.test",
      image: "ipfs://cascade",
      required_regent_raised: Decimal.new("250000000000000000000000")
    }
    |> Map.merge(Map.new(attrs))
    |> Proposals.record_launch_envelope!(actor: @system)
  end

  def wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp kind_fields(:autolaunch, _number) do
    %{
      envelope_hash: "0x" <> String.duplicate("a1", 32),
      execution_expiry: Decimal.new(DateTime.to_unix(DateTime.utc_now()) + 86_400 * 7)
    }
  end

  defp kind_fields(kind, number) do
    text = "Proposal #{number}"

    text_fields = %{
      text: text,
      text_bytes: byte_size(text),
      text_sha256: "0x" <> Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    }

    if kind == :pay do
      Map.merge(text_fields, %{
        asset: wallet("a"),
        amount: Decimal.new(5_000_000),
        recipient: wallet("b"),
        execution_expiry: Decimal.new(DateTime.to_unix(DateTime.utc_now()) + 3600 + 2_592_000)
      })
    else
      text_fields
    end
  end

  # A chain event no other record has.
  defp event do
    id = :erlang.unique_integer([:positive])

    %{
      block_number: id,
      block_hash: @block_hash,
      transaction_hash: "0x" <> Base.encode16(<<id::256>>, case: :lower),
      log_index: 0
    }
  end
end

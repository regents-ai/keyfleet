defmodule Keyfleet.ProposalHelpers do
  @moduledoc """
  Records key sales, proposals, votes, executions, launches, budget receipts,
  launch income, budget payments, balance readings and asset details as the
  chain reader would, without a chain. Each record gets a chain event of its own. The
  fleet needs a cursor first, as `Keyfleet.ChainHelpers.seed_cursor!/2` makes.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Treasury

  @system %System{}
  @block_hash "0x" <> String.duplicate("b", 64)

  @doc """
  Proposal `number` of the fleet: a decision, unless `attrs` says otherwise.
  A payment and a launch get the fields their kind carries.
  """
  def proposal!(fleet_id, number, attrs \\ %{}) do
    attrs = Map.new(attrs)
    kind = Map.get(attrs, :kind, :decision)

    %{
      fleet_id: fleet_id,
      number: number,
      kind: kind,
      proposer: wallet("f"),
      opened_block: 1,
      digest: "0x" <> String.duplicate("d", 64)
    }
    |> Map.merge(kind_fields(kind, number))
    |> Map.merge(event())
    |> Map.merge(attrs)
    |> Proposals.record_proposal!(actor: @system)
  end

  @doc "Keys `token_ids` of the fleet sold, each to `owner`."
  def keys_sold!(fleet_id, token_ids, owner \\ wallet("1")) do
    for token_id <- token_ids do
      %{fleet_id: fleet_id, token_id: token_id, ownership_epoch: 1, owner_wallet: owner}
      |> Map.merge(event())
      |> Keys.record_epoch!(actor: @system)
    end
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
      floor_price_q96: Decimal.new("79228162514264337593500"),
      minimum_regent_raised: Decimal.new(0)
    }
    |> Map.merge(Map.new(attrs))
    |> Proposals.record_launch_envelope!(actor: @system)
  end

  @doc "10 USDC-sized units of a token recognized into the budget, unless `attrs` says otherwise."
  def budget_receipt!(fleet_id, attrs \\ %{}) do
    %{fleet_id: fleet_id, kind: :recognized, asset: wallet("a"), amount: Decimal.new(10_000_000)}
    |> Map.merge(event())
    |> Map.merge(Map.new(attrs))
    |> Treasury.record_budget_receipt!(actor: @system)
  end

  @doc "The symbol and decimals of `asset`, as its token reported them."
  def asset_details!(fleet_id, asset, symbol, decimals) do
    Treasury.record_asset_details!(
      %{fleet_id: fleet_id, asset: asset, symbol: symbol, decimals: decimals},
      actor: @system
    )
  end

  @doc "Income of 10 USDC-sized units paid to the keys, unless `attrs` says otherwise."
  def income_receipt!(fleet_id, attrs \\ %{}) do
    %{
      fleet_id: fleet_id,
      asset: wallet("a"),
      caller: wallet("f"),
      amount: Decimal.new(10_000_000)
    }
    |> Map.merge(event())
    |> Map.merge(Map.new(attrs))
    |> Treasury.record_income_receipt!(actor: @system)
  end

  @doc "A payment of 5 USDC-sized units from the budget, unless `attrs` says otherwise."
  def budget_payment!(fleet_id, attrs \\ %{}) do
    %{
      fleet_id: fleet_id,
      asset: wallet("a"),
      recipient: wallet("b"),
      amount: Decimal.new(5_000_000),
      share: Decimal.new(0),
      matched: Decimal.new(0)
    }
    |> Map.merge(event())
    |> Map.merge(Map.new(attrs))
    |> Treasury.record_budget_payment!(actor: @system)
  end

  @doc "A reading of the fleet's balances with `assets`, taken at `block_time`."
  def treasury_reading!(fleet_id, assets, attrs \\ %{}) do
    %{
      fleet_id: fleet_id,
      # Later than every reading before it, so it replaces the one kept.
      block_number: :erlang.unique_integer([:positive, :monotonic]),
      block_hash: @block_hash,
      block_time: DateTime.utc_now(),
      cascade_reserve: Decimal.new(0),
      protocol_share_owed: Decimal.new(0),
      assets: assets
    }
    |> Map.merge(Map.new(attrs))
    |> Treasury.record_reading!(actor: @system)
  end

  def wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp kind_fields(:autolaunch, _number) do
    %{envelope_hash: "0x" <> String.duplicate("a1", 32)}
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
        recipient: wallet("b")
      })
    else
      text_fields
    end
  end

  # A chain event no other record has.
  defp event do
    id = :erlang.unique_integer([:positive, :monotonic])

    %{
      block_number: id,
      block_hash: @block_hash,
      transaction_hash: "0x" <> Base.encode16(<<id::256>>, case: :lower),
      log_index: 0
    }
  end
end

defmodule Keyfleet.ProposalHelpers do
  @moduledoc """
  Records key sales, proposals, votes, cancellations, executions, money
  events, treasury readings and asset details as the chain reader would,
  without a chain. Each record gets a chain event of its own. The fleet needs
  a cursor first, as `Keyfleet.ChainHelpers.seed_cursor!/2` makes.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain.MoneyLog
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Treasury

  @system %System{}
  @block_hash "0x" <> String.duplicate("b", 64)

  @doc """
  Proposal `number` of the fleet, open for a day from a minute ago with no
  calls and nobody active when it opened, unless `attrs` says otherwise.
  """
  def proposal!(fleet_id, number, attrs \\ %{}) do
    opened_at = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
    closes_at = DateTime.add(opened_at, 86_400)

    %{
      fleet_id: fleet_id,
      number: number,
      author_key: 1,
      proposer: wallet("f"),
      proposal_hash: hash(number),
      content_hash: "0x" <> String.duplicate("d", 64),
      opened_at: opened_at,
      closes_at: closes_at,
      execution_expiry: DateTime.add(closes_at, 86_400),
      opening_count: 0,
      open_revision: 1,
      calls: []
    }
    |> Map.merge(event())
    |> Map.merge(Map.new(attrs))
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

  @doc "A vote of `choice` on proposal `number` by `voter` with `token_ids`, one vote per key."
  def vote!(fleet_id, number, voter, choice, token_ids) do
    %{
      fleet_id: fleet_id,
      proposal_number: number,
      voter: voter,
      choice: choice,
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

  @doc "Proposal `number` cancelled by `by`."
  def cancellation!(fleet_id, number, by) do
    %{fleet_id: fleet_id, proposal_number: number, cancelled_by: by}
    |> Map.merge(event())
    |> Proposals.record_cancellation!(actor: @system)
  end

  @doc """
  Key `token_id` present from `at`, as its renewal records it, or no longer
  present, as its change of hands records it, for `at` nil.
  """
  def presence!(fleet_id, token_id, at) do
    %{fleet_id: fleet_id, token_id: token_id}
    |> Map.merge(
      if(at,
        do: %{kind: :present, at: at, ownership_epoch: 1},
        else: %{kind: :cleared, at: nil, ownership_epoch: nil}
      )
    )
    |> Map.merge(event())
    |> Keys.record_presence!(actor: @system)
  end

  @doc "A newly sold key's automatic presence, starting at `at`."
  def scheduled!(fleet_id, token_id, at) do
    %{fleet_id: fleet_id, token_id: token_id, kind: :scheduled, at: at, ownership_epoch: nil}
    |> Map.merge(event())
    |> Keys.record_presence!(actor: @system)
  end

  @doc "A money event of `kind` with `fields`, every other field empty."
  def money_event!(fleet_id, kind, fields) do
    MoneyLog.fields()
    |> Map.new(&{&1, nil})
    |> Map.merge(%{fleet_id: fleet_id, kind: kind})
    |> Map.merge(Map.new(fields))
    |> Map.merge(event())
    |> Treasury.record_event!(actor: @system)
  end

  @doc "The symbol and decimals of `asset`, as its token reported them."
  def asset_details!(fleet_id, asset, symbol, decimals) do
    Treasury.record_asset_details!(
      %{fleet_id: fleet_id, asset: asset, symbol: symbol, decimals: decimals},
      actor: @system
    )
  end

  @doc "A reading of the fleet's treasury with `assets`, taken now."
  def treasury_reading!(fleet_id, assets, attrs \\ %{}) do
    %{
      fleet_id: fleet_id,
      # Later than every reading before it, so it replaces the one kept.
      block_number: :erlang.unique_integer([:positive, :monotonic]),
      block_hash: @block_hash,
      block_time: DateTime.utc_now(),
      cascade_reserve: Decimal.new(0),
      protocol_share_owed: Decimal.new(0),
      daily_split_bps: 100,
      assets: assets
    }
    |> Map.merge(Map.new(attrs))
    |> Treasury.record_reading!(actor: @system)
  end

  def wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp hash(number), do: "0x" <> Base.encode16(<<number::256>>, case: :lower)

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

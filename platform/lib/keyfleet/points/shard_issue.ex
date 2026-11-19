defmodule Keyfleet.Points.ShardIssue do
  @moduledoc """
  Regent Points' check of a Key's holder authorizing their agent: a shard of
  the Key issued to a wallet (`Keyfleet.Keys.ShardEvent`), keyed by its id. Only
  the chain reader records one, and only the Key's owner in the ownership
  epoch it names can issue it, so it earns for the account whose wallets held
  that epoch's wallet then (`Keyfleet.Points.Holder`), and only when the wallet
  given the shard was then that person's paired agent.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Keys
  alias Keyfleet.Points.Holder

  # Only an issue is offered (`Keyfleet.Keys.ShardEvent` `:record`).
  def verify(%{"source_event_key" => id}) do
    case Keys.get_shard_event(id, actor: %System{}) do
      {:ok, %{} = shard} -> issued(id, shard)
      {:ok, nil} -> {:error, :shard_event_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp issued(id, shard) do
    at = shard.observed_at

    with {:ok, epoch} <- Holder.epoch(shard.fleet_id, shard.token_id, shard.ownership_epoch),
         {:ok, holder} <- Holder.holder(epoch, at),
         {:ok, {:agent, pairing}} <- Holder.actor(holder, {:agent_wallet, shard.wallet}, at) do
      Holder.facts("shard_issue", id, holder, :human, at, %{
        "agent_pairing_id" => pairing.id,
        "transaction_hash" => shard.transaction_hash
      })
    end
  end
end

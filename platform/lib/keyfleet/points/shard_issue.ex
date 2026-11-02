defmodule Keyfleet.Points.ShardIssue do
  @moduledoc """
  Regent Points' check of a person's first agent authorized on Keyfleet
  (`keyfleet.first_authorized_agent`): a shard of their Key issued to the
  wallet of an agent paired with them when the chain recorded it. A shard
  given to any other wallet authorizes no agent of theirs.
  """

  alias Keyfleet.Keys.ShardEvent
  alias Keyfleet.Points.Holder
  alias Keyfleet.Repo

  def verify(%{"source_event_key" => id}) do
    # No person is asking: Points' check reads the committed row as it was saved,
    # straight from the table, since the record offers no read without one.
    case Repo.get(ShardEvent, id) do
      %{kind: :issued} = shard ->
        at = shard.observed_at

        with {:ok, holder} <-
               Holder.of_epoch(shard.fleet_id, shard.token_id, shard.ownership_epoch, at),
             {:ok, pairing} <- Holder.agent_wallet(holder, shard.wallet, at) do
          evidence = %{
            "agent_pairing_id" => pairing.id,
            "transaction_hash" => shard.transaction_hash
          }

          {:ok, Holder.facts("shard_issue", id, holder, :human, at, evidence)}
        end

      %{} ->
        {:error, :shard_not_issued}

      nil ->
        {:error, :shard_not_found}
    end
  end
end

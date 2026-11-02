defmodule Keyfleet.Points.KeyEpoch do
  @moduledoc """
  Regent Points' check of a Key's ownership epoch: a person's first Key in
  any fleet (`keyfleet.first_membership`) and each Key they bought
  (`keyfleet.key_bought`). It reads the saved epoch and answers with the
  person whose wallets held it when it was recorded. Only a Key's first
  epoch, its sale, is bought; a Key given or moved to another wallet is not.
  """

  alias Keyfleet.Keys.KeyAttachment
  alias Keyfleet.Points.Holder
  alias Keyfleet.Repo

  def verify(%{"rule_id" => rule, "source_event_key" => id}) do
    # No person is asking: Points' check reads the committed row as it was saved,
    # straight from the table, since the record offers no read without one.
    case Repo.get(KeyAttachment, id) do
      nil ->
        {:error, :key_epoch_not_found}

      %{ownership_epoch: epoch} when rule == "keyfleet.key_bought" and epoch != 1 ->
        {:error, :key_not_sold}

      key ->
        with {:ok, holder} <-
               Holder.of_epoch(key.fleet_id, key.token_id, key.ownership_epoch, key.observed_at) do
          evidence = %{"transaction_hash" => key.transaction_hash}
          {:ok, Holder.facts("key_epoch", id, holder, :human, key.observed_at, evidence)}
        end
    end
  end
end

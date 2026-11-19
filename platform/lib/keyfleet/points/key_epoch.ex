defmodule Keyfleet.Points.KeyEpoch do
  @moduledoc """
  Regent Points' check of a wallet coming to hold a Key: one ownership epoch
  the chain reader recorded (`Keyfleet.Keys.KeyAttachment`), keyed
  `"fleet:token:epoch"`. It earns for the account whose wallets held that
  wallet when it was recorded (`Keyfleet.Points.Holder`).

  `keyfleet.first_membership` is any epoch; `keyfleet.key_bought` only a Key's
  epoch 1, its sale.
  """

  alias Keyfleet.Points.Holder

  def verify(%{"rule_id" => rule_id, "source_event_key" => key}) do
    [fleet_id, token_id, ownership_epoch] =
      Regex.run(~r/\A(.+):(\d+):(\d+)\z/, key, capture: :all_but_first)

    with :ok <- sold(rule_id, ownership_epoch),
         {:ok, epoch} <-
           Holder.epoch(fleet_id, String.to_integer(token_id), String.to_integer(ownership_epoch)),
         {:ok, holder} <- Holder.holder(epoch, epoch.observed_at) do
      Holder.facts("key_epoch", key, holder, :human, epoch.observed_at, %{
        "transaction_hash" => epoch.transaction_hash
      })
    end
  end

  defp sold("keyfleet.key_bought", "1"), do: :ok
  defp sold("keyfleet.key_bought", _epoch), do: {:error, :key_not_sold}
  defp sold("keyfleet.first_membership", _epoch), do: :ok
end

defmodule Keyfleet.Keys.Signals do
  @moduledoc """
  What Keys tell the rest of the site, as Ash signals. Each is emitted in the
  chain scanner's own save, so a listener with the default delivery commits or
  rolls back with it. Points offers both to Regent Points
  (`Keyfleet.Points.Award`).

    * `:key_epoch_recorded`: a wallet came to hold a Key, its ownership epoch
      `ownership_epoch`; epoch 1 is the Key's sale.
    * `:shard_issued`: a Key's holder lent a shard of it to a wallet, for the
      Key's ownership epoch `ownership_epoch`. A shard read again emits
      nothing.
  """

  use Ash.Signals

  signals do
    signal :key_epoch_recorded do
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false
      argument :ownership_epoch, :integer, allow_nil?: false
    end

    signal :shard_issued do
      argument :shard_event_id, :uuid, allow_nil?: false
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false
      argument :ownership_epoch, :integer, allow_nil?: false
    end
  end
end

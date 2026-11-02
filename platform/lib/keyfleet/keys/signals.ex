defmodule Keyfleet.Keys.Signals do
  @moduledoc """
  What the chain reader's Key records tell the rest of the site, as Ash
  signals, each emitted in the transaction that first saves the record
  (`Keyfleet.Points.Changes.Announce`). Regent Points hears them
  (`Keyfleet.Points.Award`).

    * `:key_held`: a Key changed hands, or was sold: `key_epoch_id` names the
      ownership epoch, whose first is the sale.
    * `:key_revealed`: a Key was revealed; `key_reveal_id` names the reveal.
    * `:shard_recorded`: a Key's owner gave a wallet a shard of it, or a shard
      ended; `shard_event_id` names the record and `kind` which it is.
  """

  use Ash.Signals

  signals do
    signal :key_held do
      argument :key_epoch_id, :uuid, allow_nil?: false
      argument :ownership_epoch, :integer, allow_nil?: false
    end

    signal :key_revealed do
      argument :key_reveal_id, :uuid, allow_nil?: false
    end

    signal :shard_recorded do
      argument :shard_event_id, :uuid, allow_nil?: false
      argument :kind, :atom, allow_nil?: false
    end
  end
end

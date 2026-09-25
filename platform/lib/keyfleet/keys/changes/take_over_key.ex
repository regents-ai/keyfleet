defmodule Keyfleet.Keys.Changes.TakeOverKey do
  @moduledoc """
  Hands a key to the operator the owner just approved.

  Whoever was attached steps down as replaced, and the other requests waiting on
  the same key are turned down.
  """
  use Ash.Resource.Change

  alias Keyfleet.Keys.PairingLedger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      %{fleet_id: fleet_id, token_id: token_id, ownership_epoch: epoch, id: id} = changeset.data
      PairingLedger.lock_key!(fleet_id, token_id)
      PairingLedger.replace_active!(fleet_id, token_id, id)
      PairingLedger.decline_open_requests!(fleet_id, token_id, epoch, id)
      changeset
    end)
  end
end

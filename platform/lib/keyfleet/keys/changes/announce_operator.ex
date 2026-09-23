defmodule KeyFleet.Keys.Changes.AnnounceOperator do
  @moduledoc """
  Tells everyone watching a fleet's keys that a key has gained or lost the
  agent running it, once the change is committed.

  A pairing left waiting for the owner changes nothing anyone sees, so only a
  pairing that ends up running or ended is announced. Best effort: a page that
  misses the notice reads the key afresh when it reconnects.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_transaction(changeset, &announce/2)

  defp announce(_changeset, {:ok, %{status: status} = pairing} = result)
       when status in [:active, :ended] do
    Phoenix.PubSub.broadcast(
      KeyFleet.PubSub,
      KeyFleet.Keys.topic(pairing.fleet_id),
      {:keys_changed, pairing.fleet_id, [pairing.token_id]}
    )

    result
  end

  defp announce(_changeset, result), do: result
end

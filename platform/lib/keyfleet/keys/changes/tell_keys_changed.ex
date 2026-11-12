defmodule Keyfleet.Keys.Changes.TellKeysChanged do
  @moduledoc """
  Once a change to which Key an agent is on is saved, the fleet's pages and
  readings hear which Keys it changed, as the chain's changes are heard
  (`Keyfleet.Keys.topic/1`'s `{:keys_changed, fleet_id, token_ids}`): the Key
  the agent is on or came off, and the Key it left when it moved
  (`:left_token_id` in the change's context, from
  `Keyfleet.Keys.Changes.PutAgent`). A change that wasn't saved tells nobody.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      with {:ok, %{fleet_id: fleet_id, token_id: token_id}} <- saved(changeset, result) do
        token_ids = Enum.uniq([token_id | List.wrap(changeset.context[:left_token_id])])

        Phoenix.PubSub.broadcast(
          Keyfleet.PubSub,
          Keyfleet.Keys.topic(fleet_id),
          {:keys_changed, fleet_id, token_ids}
        )
      end

      result
    end)
  end

  # A put answers the row it saved; a release, the row it took away.
  defp saved(_changeset, {:ok, %{} = row}), do: {:ok, row}
  defp saved(%{action_type: :destroy, data: row}, :ok), do: {:ok, row}
  defp saved(_changeset, error), do: error
end

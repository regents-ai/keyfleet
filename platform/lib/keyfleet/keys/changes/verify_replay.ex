defmodule KeyFleet.Keys.Changes.VerifyReplay do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # The database serializes conflicting inserts. A skipped upsert returns the
    # existing immutable row; only an exact authoritative replay is successful.
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      # Two unique indexes can otherwise race even for identical inserts. Lock
      # the epoch until commit before asking Postgres to reconcile the replay.
      identity =
        Enum.map(
          [:fleet_id, :token_id, :ownership_epoch],
          &Ash.Changeset.get_attribute(changeset, &1)
        )

      KeyFleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        Jason.encode!(identity)
      ])

      changeset
    end)
    |> Ash.Changeset.after_action(fn changeset, row ->
      fields = changeset.action.accept

      if Enum.all?(fields, &(Map.fetch!(row, &1) == Ash.Changeset.get_attribute(changeset, &1))) do
        {:ok, row}
      else
        {:error,
         Ash.Error.Changes.InvalidChanges.exception(
           fields: fields,
           message: "ownership epoch conflicts with a previously recorded observation"
         )}
      end
    end)
  end
end

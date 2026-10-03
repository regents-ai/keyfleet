defmodule Keyfleet.Notebooks.Changes.UpdateRoster do
  @moduledoc """
  A key changing hands, or a shard of one issued or ended, queues the job that
  brings the fleet's notebook hub in step (`Keyfleet.Notebooks.Roster`), in
  the same transaction as the record: a record rolled back queues nothing,
  and every one kept has its job. A record read again from the chain, already
  made, queues nothing.
  """
  use Ash.Resource.Change

  alias Keyfleet.Notebooks

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      if Notebooks.hub?(record.fleet_id) and
           Ash.Resource.get_metadata(record, :upsert_skipped) != true,
         do: Oban.insert!(Notebooks.Roster.new(%{fleet_id: record.fleet_id}))

      {:ok, record}
    end)
  end
end

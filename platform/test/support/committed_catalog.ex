defmodule Keyfleet.CommittedCatalog do
  @moduledoc """
  The fleet catalog for a test whose callers each run on a connection of their
  own, and so see only what is committed.

  `commit!/0` commits the catalog fleets the database does not hold yet and
  returns their ids; `remove!/1` deletes exactly those once the test's other
  records are gone, so the database is left as the test found it. Both run
  outside the sandbox, inside `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`.
  """

  import Ecto.Query

  alias Keyfleet.Fleets
  alias Keyfleet.Repo

  def commit! do
    held = Enum.map(Fleets.list_fleets!(), & &1.id)
    Fleets.bootstrap_catalog!()
    Fleets.catalog_ids() -- held
  end

  # Fleets have no destroy action: the site never removes one, so this teardown
  # deletes the rows it committed directly.
  def remove!(fleet_ids),
    do: Repo.delete_all(from(fleet in "fleets", where: fleet.id in ^fleet_ids))
end

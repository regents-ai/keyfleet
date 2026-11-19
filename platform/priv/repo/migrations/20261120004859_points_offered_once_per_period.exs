defmodule Keyfleet.Repo.Migrations.PointsOfferedOncePerPeriod do
  @moduledoc """
  Each Key ownership epoch keeps the one-time Regent Points rules already offered
  for it (`Keyfleet.Keys.KeyAttachment` `points_offered`), empty at first and never
  null. Its default is a constant, so PostgreSQL records it in the catalog and
  rewrites no row: every existing epoch reads it as empty. No row changes. The
  table's guard on epochs (`protect_key_epoch`) names the columns that never change,
  and this one is not among them.

  Locks: adding the column takes `ACCESS EXCLUSIVE` on `key_attachments` in
  Keyfleet's own schema, held until commit, which follows at once. While it waits
  for the lock, and while it holds it, the table's reads and writes wait behind
  it: the chain reader's ownership records and every read of who holds a Key. The
  lock is waited for at most 5 seconds; past that the release command fails and
  nothing changes.

  Generated with `mix ash.codegen points_offered_once_per_period`.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:key_attachments) do
      add(:points_offered, {:array, :text}, null: false, default: [])
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:key_attachments) do
      remove(:points_offered)
    end
  end
end

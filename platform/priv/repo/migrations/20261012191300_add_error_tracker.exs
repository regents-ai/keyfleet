defmodule Keyfleet.Repo.Migrations.AddErrorTracker do
  use Ecto.Migration

  # ErrorTracker's own tables, in the schema the site's own tables use.
  def up, do: ErrorTracker.Migration.up(prefix: "keyfleet_app", create_schema: false)
  def down, do: ErrorTracker.Migration.down(prefix: "keyfleet_app", version: 1)
end

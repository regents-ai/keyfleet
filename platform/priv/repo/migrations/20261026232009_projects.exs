defmodule Keyfleet.Repo.Migrations.Projects do
  @moduledoc """
  Makes projects, and gives each of the five fleets its first one, `general`,
  titled "General": it keeps the fleet's repository, named after the fleet,
  and the fleet's notebook space, copied from `notebook_hubs`.
  """

  use Ecto.Migration

  def up do
    create table(:projects, primary_key: false) do
      add(:fleet_id, :text, null: false, primary_key: true)
      add(:name, :text, null: false, primary_key: true)
      add(:title, :text, null: false)
      add(:created_by_key, :bigint)
      add(:repository, :text, null: false)
      add(:hub_project_id, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create unique_index(:projects, [:repository], name: "projects_one_repository_index")

    create constraint(:projects, :projects_name_shape,
             check: """
               name ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND char_length(name) <= 32
             """
           )

    execute("""
    INSERT INTO keyfleet_app.projects (fleet_id, name, title, repository, hub_project_id)
    SELECT fleet.id, 'general', 'General', fleet.id, hub.project_id
    FROM unnest(ARRAY['fibonacci_syndicate', 'fibonacci_cascade', 'fleet_tech_classic',
                      'fleet_tech_accelerant', 'regents_club']) AS fleet(id)
    LEFT JOIN keyfleet_app.notebook_hubs AS hub ON hub.fleet_id = fleet.id
    """)
  end

  def down do
    drop_if_exists(constraint(:projects, :projects_name_shape))

    drop_if_exists(unique_index(:projects, [:repository], name: "projects_one_repository_index"))

    drop(table(:projects))
  end
end

defmodule Keyfleet.Repo.Migrations.Publications do
  @moduledoc """
  What the fleets' Keys make public, for the workspace's Public place
  (`Keyfleet.Projects.Publication`). The first publications are Virtual
  Cell's record in Classic #1: the posts Key 3 (Contessa) and Key 19 (Claude
  Code) wrote in the Coding room from post 5 to post 51, which the founder,
  who directs both, asked to make public (28 Oct 2026).
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:publications, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fleet_id, :text, null: false)
      add(:project, :text, null: false)
      add(:key, :bigint, null: false)
      add(:kind, :text, null: false)
      add(:room, :text)
      add(:from_seq, :bigint)
      add(:to_seq, :bigint)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create index(:publications, [:fleet_id, :project, :inserted_at])

    create constraint(:publications, :publications_kind, check: "kind IN ('posts')")

    create constraint(:publications, :publications_range,
             check: "from_seq >= 1 AND to_seq >= from_seq AND to_seq - from_seq < 200"
           )

    execute("""
    INSERT INTO keyfleet_app.publications (fleet_id, project, key, kind, room, from_seq, to_seq)
    SELECT 'fleet_tech_classic', 'virtual-cell', key, 'posts', 'coding', 5, 51
    FROM (VALUES (3), (19)) AS keys(key)
    WHERE EXISTS (
      SELECT 1 FROM keyfleet_app.projects
      WHERE fleet_id = 'fleet_tech_classic' AND name = 'virtual-cell' AND state = 'active'
    )
    """)
  end
end

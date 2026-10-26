defmodule Keyfleet.Repo.Migrations.ProjectsInGraph do
  @moduledoc """
  Gives every workspace object the project it belongs to. Every object made
  before projects belongs to its fleet's first project, `general`.
  """

  use Ecto.Migration

  def up do
    alter table(:graph_objects) do
      add(:project, :text, null: false, default: "general")
    end

    alter table(:graph_objects) do
      modify(:project, :text, default: nil)
    end

    create index(:graph_objects, [:fleet_id, :project, :type, :changed_seq, :id],
             name: "graph_objects_project_changed_index"
           )
  end

  def down do
    drop_if_exists(
      index(:graph_objects, [:fleet_id, :project, :type, :changed_seq, :id],
        name: "graph_objects_project_changed_index"
      )
    )

    alter table(:graph_objects) do
      remove(:project)
    end
  end
end

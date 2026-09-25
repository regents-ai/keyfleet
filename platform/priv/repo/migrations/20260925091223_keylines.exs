defmodule Keyfleet.Repo.Migrations.Keylines do
  @moduledoc """
  Marks every line in a key's thread as one, so the fleet's room lines are
  indexed and read without their rooms.

  Generated with `mix ash.codegen keylines`, then edited: lines already
  written are marked from their room's kind before the mark is required. Lines
  are never edited, so their guard is lifted for the one update.
  """

  use Ecto.Migration

  def up do
    alter table(:messages) do
      add(:in_key_thread, :boolean)
    end

    execute("ALTER TABLE keyfleet_app.messages DISABLE TRIGGER immutable_messages")

    execute("""
    UPDATE keyfleet_app.messages AS line
    SET in_key_thread = (room.kind = 'key')
    FROM keyfleet_app.rooms AS room
    WHERE room.id = line.room_id
    """)

    execute("ALTER TABLE keyfleet_app.messages ENABLE TRIGGER immutable_messages")

    alter table(:messages) do
      modify(:in_key_thread, :boolean, null: false)
    end

    drop_if_exists(
      index(:messages, ["fleet_id", "as_key", "inserted_at DESC"],
        name: "messages_posts_as_key_index"
      )
    )

    create index(:messages, ["fleet_id", "as_key", "inserted_at DESC"],
             name: "messages_posts_as_key_index",
             where: "kind = 'post' AND NOT in_key_thread"
           )

    drop_if_exists(
      index(:messages, ["fleet_id", "inserted_at DESC", "id"], name: "messages_fleet_lines_index")
    )

    create index(:messages, ["fleet_id", "inserted_at DESC", "id"],
             name: "messages_fleet_lines_index",
             where: "NOT in_key_thread"
           )
  end

  def down do
    drop_if_exists(
      index(:messages, ["fleet_id", "inserted_at DESC", "id"], name: "messages_fleet_lines_index")
    )

    create index(:messages, ["fleet_id", "inserted_at DESC", "id"],
             name: "messages_fleet_lines_index",
             where: "kind IN ('post', 'room_named')"
           )

    drop_if_exists(
      index(:messages, ["fleet_id", "as_key", "inserted_at DESC"],
        name: "messages_posts_as_key_index"
      )
    )

    create index(:messages, ["fleet_id", "as_key", "inserted_at DESC"],
             name: "messages_posts_as_key_index",
             where: "kind = 'post'"
           )

    alter table(:messages) do
      remove(:in_key_thread)
    end
  end
end

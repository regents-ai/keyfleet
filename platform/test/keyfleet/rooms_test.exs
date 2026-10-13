defmodule Keyfleet.RoomsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.{Fleets, Repo, Rooms}
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Rooms.Room

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "bootstrap repairs partial and stale rooms without replacing their identities" do
    Fleets.bootstrap_catalog!()

    existing =
      Ash.create!(
        Room,
        %{fleet_id: "fibonacci_syndicate", slug: "general", name: "Stale", kind: :fixed},
        action: :bootstrap,
        actor: %Keyfleet.Actors.System{}
      )

    assert length(Rooms.bootstrap_rooms!(Fleets.catalog_ids())) == 50
    first = persisted_rooms()
    assert length(first) == 50
    assert Enum.any?(first, &(&1 == {existing.id, existing.fleet_id, "general", "General"}))

    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    assert persisted_rooms() == first

    for fleet <- Fleets.list_fleets!() do
      rooms = Rooms.list_rooms!(fleet.id)

      assert Enum.map(rooms, &{&1.slug, &1.name, &1.kind, &1.topic}) == [
               {"welcome", "Welcome and intros", :fixed, nil},
               {"general", "General", :fixed, nil},
               {"business", "Business", :fixed, nil},
               {"voting", "Voting", :fixed, nil},
               {"coding", "Coding", :fixed, nil},
               {"open-1", "Open room 1", :open, nil},
               {"open-2", "Open room 2", :open, nil},
               {"open-3", "Open room 3", :open, nil},
               {"open-4", "Open room 4", :open, nil},
               {"open-5", "Open room 5", :open, nil}
             ]

      assert Enum.all?(rooms, &(&1.fleet_id == fleet.id))
    end

    assert {:error, %Ash.Error.Invalid{errors: [%UnknownFleetError{}]}} =
             Rooms.list_rooms("unknown_fleet")

    assert {:error, %Ash.Error.Invalid{}} = Rooms.list_rooms(nil)

    assert {:error, %Ash.Error.Invalid{}} =
             Room |> Ash.Query.for_read(:for_fleet, %{}) |> Ash.read()
  end

  test "running bootstrap again keeps what members named the open rooms" do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    Repo.query!(
      "UPDATE keyfleet_app.rooms SET topic = 'Hull survey', topic_set_by = $1, " <>
        "topic_set_at = now() WHERE fleet_id = 'fibonacci_syndicate' AND slug = 'open-2'",
      ["0x" <> String.duplicate("a", 40)]
    )

    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    assert %{topic: "Hull survey", topic_set_by: "0x" <> _} =
             Rooms.get_room!("fibonacci_syndicate", "open-2")
  end

  test "ordinary actors cannot write rooms and leave persisted state unchanged" do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    before = persisted_rooms()

    for actor <- [nil, %Keyfleet.Actors.Human{human_account_id: 1}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(
                 Room,
                 %{
                   fleet_id: "fibonacci_syndicate",
                   slug: "general",
                   name: "Changed",
                   kind: :fixed
                 },
                 action: :bootstrap,
                 actor: actor
               )
    end

    assert persisted_rooms() == before
  end

  test "database rejects duplicate fleet slugs and orphan rooms" do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    before = persisted_rooms()

    for {fleet_id, slug, code} <- [
          {"fibonacci_syndicate", "general", :unique_violation},
          {"missing_fleet", "general", :foreign_key_violation}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
               Repo.query(
                 "INSERT INTO keyfleet_app.rooms (id, fleet_id, slug, name, kind) " <>
                   "VALUES ($1, $2, $3, $4, 'fixed')",
                 [Ecto.UUID.dump!(Ash.UUID.generate()), fleet_id, slug, "Unwanted"],
                 mode: :savepoint
               )
    end

    assert persisted_rooms() == before
  end

  test "bootstrap opens rooms only for the fleets it is given" do
    Fleets.bootstrap_catalog!()

    assert length(Rooms.bootstrap_rooms!(["fleet_tech_classic"])) == 10
    assert persisted_rooms() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == ["fleet_tech_classic"]
  end

  test "failure on a later room rolls back all earlier room writes" do
    Fleets.bootstrap_catalog!()

    Repo.query!(
      "ALTER TABLE keyfleet_app.rooms ADD CONSTRAINT reject_coding CHECK (slug <> 'coding')"
    )

    assert_raise Ash.Error.Unknown, fn -> Rooms.bootstrap_rooms!(Fleets.catalog_ids()) end

    assert persisted_rooms() == []
  end

  describe "mutes" do
    @fleet "fibonacci_syndicate"

    setup do
      Fleets.bootstrap_catalog!()
      :ok
    end

    test "nobody signed in keeps no mutes" do
      # A mute is only ever its muter's own, and nobody signed in is no muter.
      assert {:error, %Ash.Error.Forbidden{}} = Rooms.mute_key(@fleet, 3, actor: nil)
      assert Rooms.muted_keys!(@fleet, nil) == MapSet.new()
      assert Repo.aggregate(Keyfleet.Rooms.Mute, :count) == 0
    end
  end

  defp persisted_rooms do
    Repo.query!(
      "SELECT id::text, fleet_id, slug, name FROM keyfleet_app.rooms ORDER BY fleet_id, slug"
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end
end

defmodule KeyFleet.RoomsTest do
  use ExUnit.Case, async: false

  alias KeyFleet.{Fleets, Repo, Rooms}
  alias KeyFleet.Graph.Errors.UnknownFleetError
  alias KeyFleet.Rooms.Room

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "bootstrap repairs partial and stale rooms without replacing their identities" do
    Fleets.bootstrap_catalog!()

    existing =
      Ash.create!(Room, %{fleet_id: "fibonacci_syndicate", slug: "general", name: "Stale"},
        action: :bootstrap,
        actor: %KeyFleet.Actors.System{}
      )

    assert length(Rooms.bootstrap_core_rooms!()) == 12
    first = persisted_rooms()
    assert length(first) == 12
    assert Enum.any?(first, &(&1 == {existing.id, existing.fleet_id, "general", "General"}))

    Rooms.bootstrap_core_rooms!()
    assert persisted_rooms() == first

    for fleet <- Fleets.list_fleets!() do
      rooms = Rooms.list_rooms!(fleet.id)

      assert Enum.map(rooms, &{&1.slug, &1.name}) ==
               [{"general", "General"}, {"planning", "Planning"}, {"work", "Work"}]

      assert Enum.all?(rooms, &(&1.fleet_id == fleet.id))
    end

    assert {:error, %Ash.Error.Invalid{errors: [%UnknownFleetError{}]}} =
             Rooms.list_rooms("unknown_fleet")

    assert {:error, %Ash.Error.Invalid{}} = Rooms.list_rooms(nil)

    assert {:error, %Ash.Error.Invalid{}} =
             Room |> Ash.Query.for_read(:for_fleet, %{}) |> Ash.read()
  end

  test "ordinary and forged actors cannot write rooms and leave persisted state unchanged" do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_core_rooms!()
    before = persisted_rooms()

    for actor <- [nil, %KeyFleet.Actors.Human{human_account_id: 1}, %{role: :system}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(
                 Room,
                 %{fleet_id: "fibonacci_syndicate", slug: "general", name: "Changed"},
                 action: :bootstrap,
                 actor: actor
               )
    end

    assert persisted_rooms() == before
  end

  test "database rejects duplicate fleet slugs and orphan rooms" do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_core_rooms!()
    before = persisted_rooms()

    for {fleet_id, slug, code} <- [
          {"fibonacci_syndicate", "general", :unique_violation},
          {"missing_fleet", "general", :foreign_key_violation}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
               Repo.query(
                 "INSERT INTO keyfleet_app.rooms (id, fleet_id, slug, name) VALUES ($1, $2, $3, $4)",
                 [Ecto.UUID.dump!(Ash.UUID.generate()), fleet_id, slug, "Unwanted"],
                 mode: :savepoint
               )
    end

    assert persisted_rooms() == before
  end

  test "bootstrap refuses an incomplete fleet catalog before writing any rooms" do
    Fleets.bootstrap_catalog!()
    Repo.query!("DELETE FROM keyfleet_app.fleets WHERE id = 'fleet_tech_classic'")

    assert_raise RuntimeError, ~r/complete fixed fleet catalog/, fn ->
      Rooms.bootstrap_core_rooms!()
    end

    assert persisted_rooms() == []
  end

  test "failure on a later room rolls back all earlier room writes" do
    Fleets.bootstrap_catalog!()

    Repo.query!(
      "ALTER TABLE keyfleet_app.rooms ADD CONSTRAINT reject_work CHECK (slug <> 'work')"
    )

    assert_raise Ash.Error.Unknown, fn -> Rooms.bootstrap_core_rooms!() end

    assert persisted_rooms() == []
  end

  defp persisted_rooms do
    Repo.query!(
      "SELECT id::text, fleet_id, slug, name FROM keyfleet_app.rooms ORDER BY fleet_id, slug"
    ).rows
    |> Enum.map(&List.to_tuple/1)
  end
end

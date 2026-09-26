defmodule Keyfleet.CreatedRoomRaceTest do
  use ExUnit.Case, async: false

  alias Keyfleet.CommittedCatalog
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  # Each creation runs on a connection of its own and commits, so the rooms
  # and any fleets committed here are removed when it ends.
  @fleet "fleet_tech_classic"

  setup do
    added_fleets = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &CommittedCatalog.commit!/0)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM keyfleet_app.rooms WHERE fleet_id = $1 AND kind = 'created'", [
          @fleet
        ])

        CommittedCatalog.remove!(added_fleets)
      end)
    end)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      # The first 98 created rooms, written straight to the table: only the
      # last two creations are under test.
      Repo.insert_all(
        "rooms",
        for n <- 1..98 do
          %{
            id: Ecto.UUID.bingenerate(),
            fleet_id: @fleet,
            slug: "made-#{n}",
            name: "Made #{n}",
            kind: "created"
          }
        end
      )
    end)

    :ok
  end

  test "agents creating the last free rooms at the same moment get exactly those rooms" do
    results = race(for n <- 1..6, do: "late-#{n}")

    assert length(for {:ok, _room} <- results, do: :created) == 2

    assert length(
             for {:error, %Ash.Error.Invalid{errors: [%Rooms.Errors.CreatedRoomLimitError{}]}} <-
                   results,
                 do: :refused
           ) == 4

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert Rooms.count_created_rooms!(@fleet) == 100
    end)
  end

  defp race(slugs) do
    parent = self()

    callers =
      for slug <- slugs do
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, self()})

          receive do
            :go ->
              # Who may create a room is shown elsewhere; this race is about the
              # count alone, so it runs without an actor holding a key.
              Rooms.create_room(%{fleet_id: @fleet, slug: slug, name: slug},
                authorize?: false
              )
          after
            10_000 -> raise "creation barrier timed out"
          end
        end)
      end

    for _ <- callers do
      assert_receive {:ready, _}, 10_000
    end

    Enum.each(callers, &send(&1.pid, :go))
    Task.await_many(callers, 15_000)
  end
end

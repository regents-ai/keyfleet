defmodule KeyFleet.FleetsTest do
  use ExUnit.Case, async: false

  alias KeyFleet.{Fleets, Repo}
  alias KeyFleet.Fleets.Fleet

  @catalog %{
    "fibonacci_syndicate" => "Fibonacci Syndicate",
    "fibonacci_cascade" => "Fibonacci Cascade",
    "fleet_tech_classic" => "Fleet.Tech Classic",
    "fleet_tech_accelerant" => "Fleet.Tech Accelerant"
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "bootstrap converges a partial catalog and reruns preserve exactly four stable identities" do
    Ash.create!(Fleet, %{id: "fibonacci_syndicate", name: "Stale name"},
      action: :bootstrap,
      actor: %KeyFleet.Actors.System{}
    )

    Fleets.bootstrap_catalog!()
    first = Map.new(Fleets.list_fleets!(), &{&1.id, &1.name})
    assert first == @catalog

    Fleets.bootstrap_catalog!()
    assert Map.new(Fleets.list_fleets!(), &{&1.id, &1.name}) == first
  end

  test "ordinary callers cannot change the catalog through the bootstrap action" do
    Fleets.bootstrap_catalog!()

    for actor <- [nil, %KeyFleet.Actors.Human{human_account_id: 1}, %{role: :system}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(Fleet, %{id: "fibonacci_syndicate", name: "Changed"},
                 action: :bootstrap,
                 actor: actor
               )
    end

    assert Map.new(Fleets.list_fleets!(), &{&1.id, &1.name}) == @catalog
  end

  test "database rejects duplicate and noncatalog identities" do
    Fleets.bootstrap_catalog!()

    for {id, code} <- [
          {"fibonacci_syndicate", :unique_violation},
          {"user_created_fleet", :check_violation}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} =
               Repo.query(
                 "INSERT INTO keyfleet_app.fleets (id, name) VALUES ($1, $2)",
                 [id, "Unwanted fleet"],
                 mode: :savepoint
               )
    end

    assert Map.new(Fleets.list_fleets!(), &{&1.id, &1.name}) == @catalog
  end
end

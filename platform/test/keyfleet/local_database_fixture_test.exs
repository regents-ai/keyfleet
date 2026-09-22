defmodule KeyFleet.LocalDatabaseFixtureTest do
  use ExUnit.Case, async: true

  alias KeyFleet.LocalDatabaseFixture

  test "accepts only loopback dev and test database targets" do
    assert :ok =
             LocalDatabaseFixture.validate_target!(:dev,
               hostname: "127.0.0.1",
               database: "keyfleet_dev"
             )

    assert :ok =
             LocalDatabaseFixture.validate_target!(:test,
               hostname: "::1",
               database: "keyfleet_test"
             )

    for {env, host, database} <- [
          {:prod, "127.0.0.1", "keyfleet_dev"},
          {:dev, "db.internal", "keyfleet_dev"},
          {:dev, "localhost", "keyfleet_dev"},
          {:dev, "127.0.0.1", "keyfleet"}
        ] do
      assert_raise RuntimeError, ~r/refused unsafe database target/, fn ->
        LocalDatabaseFixture.validate_target!(env, hostname: host, database: database)
      end
    end
  end
end

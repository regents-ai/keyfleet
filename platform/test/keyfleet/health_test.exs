defmodule Keyfleet.HealthTest do
  # Invariant: the health answer says when a release carries a migration its
  # database has not applied, and still answers 200, so the host keeps serving.
  use KeyfleetWeb.ConnCase, async: true

  defp health(conn) do
    conn = get(conn, "/api/v1/health")
    {conn.status, json_response(conn, conn.status)}
  end

  test "a database with every migration applied says so", %{conn: conn} do
    assert Keyfleet.Health.migrations_applied?()
    assert {200, %{"status" => "ok", "migrations_applied" => true}} = health(conn)
  end

  test "a migration the database has not recorded leaves the answer at 200 and says so",
       %{conn: conn} do
    # Forget the newest applied migration inside this test's own transaction.
    Ecto.Adapters.SQL.query!(
      Keyfleet.Repo,
      "DELETE FROM keyfleet_app.schema_migrations WHERE version = (SELECT max(version) FROM keyfleet_app.schema_migrations)",
      []
    )

    refute Keyfleet.Health.migrations_applied?()
    assert {200, %{"status" => "ok", "migrations_applied" => false}} = health(conn)
    assert response(get(conn, "/healthz"), 200) == "ok"
  end
end

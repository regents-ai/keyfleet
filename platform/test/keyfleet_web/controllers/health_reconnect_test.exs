defmodule KeyfleetWeb.HealthReconnectTest do
  # Costly failure: the health check's connection is lost once, as it is when
  # the database restarts, and the check keeps failing, so Fly restarts a
  # machine that was fine; or a read that can't finish holds the check past
  # Fly's two-second deadline. This module runs alone: it ends the connection
  # the check reads through.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Repo

  @tag :capture_log
  test "after its connection is ended, the next health check answers ok", %{conn: conn} do
    assert get(conn, "/healthz").status == 200

    # The connection ends itself, as the server ends it on a restart.
    assert {:error, %Postgrex.Error{postgres: %{code: :admin_shutdown}}} =
             Repo.query("SELECT pg_terminate_backend(pg_backend_pid())")

    assert get(conn, "/healthz").status == 200
  end

  # The check's timeout ends the connection it waited on, which in a test is
  # the sandbox's own, so the check after it is the case above.
  @tag :capture_log
  test "a check that can't read in time answers 503 inside Fly's two-second deadline",
       %{conn: conn} do
    # Holds the table the check reads, from a connection of its own.
    {:ok, holder} = Postgrex.start_link(Keyword.drop(Repo.config(), [:pool, :pool_size]))
    Postgrex.query!(holder, "BEGIN", [])

    Postgrex.query!(
      holder,
      "LOCK TABLE \"#{Repo.default_prefix()}\".session_authorities",
      []
    )

    {waited, response} = :timer.tc(fn -> get(conn, "/healthz") end, :millisecond)
    assert response.status == 503
    assert waited < 2_000

    Postgrex.query!(holder, "ROLLBACK", [])
    GenServer.stop(holder)
  end
end

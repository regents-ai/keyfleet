defmodule KeyfleetWeb.HealthReconnectTest do
  # Costly failure: the health check's own connection is lost once, as it is
  # when the database restarts or a read outlasts the check, and the check
  # keeps failing, so Fly restarts a machine that was fine. This module runs
  # alone: it breaks the one connection every health check uses.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Repo

  test "after its connection is ended, the next health check answers ok", %{conn: conn} do
    assert get(conn, "/healthz").status == 200

    # The connection ends itself, as the server ends it on a restart.
    assert {:error, %Postgrex.Error{postgres: %{code: :admin_shutdown}}} =
             Postgrex.query(Keyfleet.Health, "SELECT pg_terminate_backend(pg_backend_pid())", [])

    assert get(conn, "/healthz").status == 200
  end

  test "a check that can't read in time fails once, and the next once the table is free answers ok",
       %{conn: conn} do
    test = self()

    # Holds the table the check reads until told to let go.
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("LOCK TABLE \"#{Repo.default_prefix()}\".session_authorities")
          send(test, :locked)

          receive do
            :release -> Repo.rollback(:released)
          end
        end)
      end)

    assert_receive :locked
    assert get(conn, "/healthz").status == 503

    send(holder.pid, :release)
    assert Task.await(holder) == {:error, :released}
    assert get(conn, "/healthz").status == 200
  end
end

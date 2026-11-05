defmodule KeyfleetWeb.ConnCase do
  @moduledoc "Connection and LiveView test support without a database sandbox."

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint KeyfleetWeb.Endpoint

      use KeyfleetWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
      import Phoenix.LiveViewTest
      import KeyfleetWeb.SessionAuthorityHelpers
    end
  end

  setup tags do
    # At repeatable read, so a page's one-snapshot reads (the fleet page's
    # "Recent Work") can run inside the test's transaction.
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: not tags[:async],
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    # Runs first: a page whose read failed saves the failure beside it
    # (`KeyfleetWeb.PageRead`), and the test's connection stays open until
    # every such save has finished writing.
    on_exit(&await_error_saves/0)
    {:ok, conn: KeyfleetWeb.SessionAuthorityHelpers.build_conn()}
  end

  defp await_error_saves do
    for pid <- Task.Supervisor.children(Keyfleet.ErrorSaves) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end
  end
end

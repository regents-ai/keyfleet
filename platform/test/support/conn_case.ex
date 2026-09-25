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
    # "Trying now") can run inside the test's transaction.
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: not tags[:async],
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: KeyfleetWeb.SessionAuthorityHelpers.build_conn()}
  end
end

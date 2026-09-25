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
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: KeyfleetWeb.SessionAuthorityHelpers.build_conn()}
  end
end

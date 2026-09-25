defmodule KeyfleetWeb.PageControllerTest do
  use KeyfleetWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "Keyfleet"
    assert html =~ ~s(<meta name="privy-bridge-src" content="/assets/js/privy_bridge.js")
  end
end

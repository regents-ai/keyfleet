defmodule KeyFleetWeb.PageControllerTest do
  use KeyFleetWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "KeyFleet"
    assert html =~ ~s(<meta name="privy-bridge-src" content="/assets/js/privy_bridge.js")
  end
end

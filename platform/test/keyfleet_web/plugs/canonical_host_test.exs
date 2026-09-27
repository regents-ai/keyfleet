defmodule KeyfleetWeb.Plugs.CanonicalHostTest do
  use KeyfleetWeb.ConnCase, async: true

  alias KeyfleetWeb.Endpoint

  defp on_host(conn, host), do: %{conn | host: host}

  test "a www. visit moves to the same page and query at the site's address", %{conn: conn} do
    conn = conn |> on_host("www." <> Endpoint.host()) |> get("/docs?section=keys&page=2")

    assert conn.status == 301
    assert conn.halted
    assert get_resp_header(conn, "location") == [Endpoint.url() <> "/docs?section=keys&page=2"]
  end

  test "a www. visit with no query moves without one", %{conn: conn} do
    conn = conn |> on_host("www." <> Endpoint.host()) |> post("/auth/privy/session")

    assert conn.status == 301
    assert get_resp_header(conn, "location") == [Endpoint.url() <> "/auth/privy/session"]
  end

  test "the site's own address and other www. names are left alone", %{conn: conn} do
    assert conn |> on_host(Endpoint.host()) |> get("/healthz") |> response(200) == "ok"
    assert conn |> on_host("www.example.com") |> get("/healthz") |> response(200) == "ok"
  end
end

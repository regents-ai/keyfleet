defmodule KeyfleetWeb.Plugs.ParsersTest do
  use KeyfleetWeb.ConnCase, async: true

  # A page asks for HTML, so only the /api path decides the answer's format.
  defp malformed(conn, path) do
    fn ->
      conn
      |> put_req_header("accept", "text/html")
      |> put_req_header("content-type", "application/json")
      |> post(path, "{\"unclosed\": ")
    end
  end

  defp content_type(headers), do: headers |> List.keyfind!("content-type", 0) |> elem(1)

  test "an API caller's malformed body gets a JSON 400", %{conn: conn} do
    {400, headers, body} = assert_error_sent(400, malformed(conn, "/api/v1/fleets"))

    assert content_type(headers) =~ "application/json"
    assert %{"errors" => %{"detail" => "Bad Request"}} = Jason.decode!(body)
  end

  test "a page's malformed body still gets the HTML 400", %{conn: conn} do
    {400, headers, _body} = assert_error_sent(400, malformed(conn, "/auth/privy/session"))

    assert content_type(headers) =~ "text/html"
  end
end

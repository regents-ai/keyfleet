defmodule KeyfleetWeb.Plugs.ParsersTest do
  use KeyfleetWeb.ConnCase, async: true

  # The endpoint decodes the query string after it chose JSON for an /api
  # path. Refused for the request as it entered the endpoint, which asks for
  # HTML, the answer would be the site's HTML error page.
  test "an API caller's query string that isn't UTF-8 gets a JSON 400", %{conn: conn} do
    {400, headers, body} =
      assert_error_sent(400, fn ->
        conn |> put_req_header("accept", "text/html") |> get("/api/v1/fleets?x=%FF")
      end)

    assert {"content-type", "application/json" <> _} = List.keyfind(headers, "content-type", 0)
    assert %{"error" => %{"code" => "bad_request"}} = Jason.decode!(body)
  end
end

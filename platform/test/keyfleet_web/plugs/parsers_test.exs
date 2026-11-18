defmodule KeyfleetWeb.Plugs.ParsersTest do
  use KeyfleetWeb.ConnCase, async: true

  # The endpoint decodes every query string, and a route that reads a body
  # decodes it in its own pipeline; `%FF` is not UTF-8, so neither decodes.
  defp malformed(conn, accept, path, body \\ nil) do
    conn = put_req_header(conn, "accept", accept)

    fn ->
      case body do
        nil -> get(conn, path)
        {type, body} -> conn |> put_req_header("content-type", type) |> post(path, body)
      end
    end
  end

  defp content_type(headers), do: headers |> List.keyfind!("content-type", 0) |> elem(1)

  # A query string is decoded before the router, so only the /api path decides
  # the answer's format; an API route's pipeline takes JSON callers only.
  test "an API caller's malformed query string or body gets a JSON 400", %{conn: conn} do
    for request <- [
          malformed(conn, "text/html", "/api/v1/fleets?x=%FF"),
          malformed(conn, "application/json", "/api/agents/v1/pair", {
            "application/json",
            "{\"unclosed\": "
          })
        ] do
      {400, headers, body} = assert_error_sent(400, request)

      assert content_type(headers) =~ "application/json"

      assert %{"error" => %{"code" => "bad_request", "message" => "Bad Request"}} =
               Jason.decode!(body)
    end
  end

  test "a page's malformed query string or body still gets the HTML 400", %{conn: conn} do
    for request <- [
          malformed(conn, "text/html", "/?x=%FF"),
          malformed(conn, "text/html", "/oauth/authorize", {
            "application/x-www-form-urlencoded",
            "decision=%FF"
          })
        ] do
      {400, headers, _body} = assert_error_sent(400, request)

      assert content_type(headers) =~ "text/html"
    end
  end
end

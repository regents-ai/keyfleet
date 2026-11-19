defmodule KeyfleetWeb.RateLimitTest do
  use KeyfleetWeb.ConnCase, async: false

  # The release budget, and a client address of each test's own, sent as Fly's
  # proxy sends it, so no other case has spent any of it.
  setup %{conn: conn} do
    for {name, release} <- [
          api_rate_limit: [limit: 120, window_seconds: 60],
          connector_rate_limit: [limit: 6_000, window_seconds: 60]
        ] do
      budget = Application.fetch_env!(:keyfleet, name)
      Application.put_env(:keyfleet, name, release)
      on_exit(fn -> Application.put_env(:keyfleet, name, budget) end)
    end

    client = "203.0.113.#{System.unique_integer([:positive]) |> rem(250) |> Kernel.+(1)}"
    %{conn: put_req_header(conn, "fly-client-ip", client)}
  end

  test "the health check and every /api answer say what is left of the budget", %{conn: conn} do
    for path <- ~w(/healthz /api/v1/fleets /api/no-such-route /api/v1/agent/shards) do
      response = get(conn, path)

      assert get_resp_header(response, "ratelimit-policy") == [~s("default";q=120;w=60)], path
      assert [remaining] = get_resp_header(response, "ratelimit"), path
      assert remaining =~ ~r/\A"default";r=\d+;t=\d+\z/, path
    end

    page = get(conn, "/")
    assert page.status == 200
    assert get_resp_header(page, "ratelimit-policy") == []
  end

  test "past the budget the answer is 429 with Retry-After, and pages still open",
       %{conn: conn} do
    refused =
      Enum.reduce_while(1..250, nil, fn _n, _last ->
        response = get(conn, "/healthz")
        if response.status == 429, do: {:halt, response}, else: {:cont, nil}
      end)

    assert %Plug.Conn{status: 429} = refused
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) in 1..60
    assert [~s("default";r=0;t=) <> _reset] = get_resp_header(refused, "ratelimit")

    assert json_response(refused, 429) == %{
             "error" => %{
               "code" => "too_many_requests",
               "message" => "Too Many Requests",
               "hint" => "Wait the number of seconds in Retry-After, then send the request again."
             }
           }

    assert get(conn, "/api/v1/fleets").status == 429
    assert get(conn, "/").status == 200
    assert get(conn, "/docs").status == 200
  end

  # Every Claude user's requests come from Claude's own servers. Once that
  # address has spent the /api budget, a request carrying a token still
  # reaches the connector, which counts it against its account; one without a
  # token is refused with the rest of the address's requests.
  test "a connector request with a token spends its own ceiling, not the /api budget",
       %{conn: conn} do
    with_token = put_req_header(conn, "authorization", "Bearer made-up")

    for path <- ~w(/mcp /mcp/more) do
      response = post(with_token, path, %{})
      assert response.status != 429, path

      assert get_resp_header(response, "ratelimit-policy") == [~s("connector";q=6000;w=60)],
             path

      response = post(conn, path, %{})
      assert get_resp_header(response, "ratelimit-policy") == [~s("default";q=120;w=60)], path
    end

    for _n <- 1..120, do: get(conn, "/healthz")

    assert post(conn, "/mcp", %{}).status == 429
    assert post(conn, "/mcp/more", %{}).status == 429
    assert post(with_token, "/mcp", %{}).status != 429
  end

  test "a first part with a percent escape is not found and spends nothing; a later one spends",
       %{conn: conn} do
    budget = [~s("default";q=120;w=60)]

    for {method, plain, escaped, plain_status, plain_budget} <- [
          {:get, "/healthz", "/%68ealthz", 200, budget},
          {:get, "/api/v1/fleets", "/%61pi/v1/fleets", 200, budget},
          {:get, "/share/nothing.png", "/%73hare/nothing.png", 404, budget},
          {:get, "/oauth/authorize", "/%6Fauth/authorize", 404, []},
          {:post, "/mcp", "/%6Dcp", 404, budget}
        ] do
      for accept <- ["text/html", "application/json", "text/markdown"] do
        asking = put_req_header(conn, "accept", accept)
        unknown = dispatch(asking, @endpoint, method, "/no-such-address")
        answer = dispatch(asking, @endpoint, method, escaped)

        assert answer.status == 404, escaped
        assert get_resp_header(answer, "ratelimit-policy") == [], escaped
        assert get_resp_header(answer, "content-type") == get_resp_header(unknown, "content-type")
        assert answer.resp_body == unknown.resp_body, escaped
      end

      answer = dispatch(conn, @endpoint, method, plain)
      assert answer.status == plain_status, plain
      assert get_resp_header(answer, "ratelimit-policy") == plain_budget, plain
    end

    answer = get(conn, "/api/v1/%66leets")
    assert answer.status == 200
    assert get_resp_header(answer, "ratelimit-policy") == budget
  end
end

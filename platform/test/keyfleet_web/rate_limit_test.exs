defmodule KeyfleetWeb.RateLimitTest do
  use KeyfleetWeb.ConnCase, async: false

  # The release budget, and a client address of each test's own, sent as Fly's
  # proxy sends it, so no other case has spent any of it.
  setup %{conn: conn} do
    budget = Application.fetch_env!(:keyfleet, :api_rate_limit)
    Application.put_env(:keyfleet, :api_rate_limit, limit: 120, window_seconds: 60)
    on_exit(fn -> Application.put_env(:keyfleet, :api_rate_limit, budget) end)

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
end

defmodule KeyfleetWeb.LaunchStepsControllerTest do
  use KeyfleetWeb.ConnCase, async: false

  @events [
    [:keyfleet, :launch, :step],
    [:keyfleet, :launch, :setup_copied],
    [:keyfleet, :launch, :refused]
  ]

  setup %{conn: conn} do
    ref = :telemetry_test.attach_event_handlers(self(), @events)
    on_exit(fn -> :telemetry.detach(ref) end)

    # Each test its own address, so one test's reports never spend another's budget.
    address = {10, 77, :rand.uniform(250), :rand.uniform(250)}
    %{conn: %{conn | remote_ip: address}, ref: ref}
  end

  defp report(conn, body) do
    conn |> put_req_header("content-type", "text/plain;charset=UTF-8") |> post(~p"/steps", body)
  end

  test "counts each way in by its name", %{conn: conn, ref: ref} do
    for step <- ~w(home watch connect) do
      assert report(conn, ~s({"step":"#{step}"})).status == 204
      assert_received {[:keyfleet, :launch, :step], ^ref, %{count: 1}, %{step: ^step}}
    end
  end

  test "counts a copied setup line by the agent it is for", %{conn: conn, ref: ref} do
    [{agent, _name} | _] = KeyfleetWeb.AgentGuides.runtimes()

    for agent <- ["any", agent] do
      assert report(conn, ~s({"step":"copy","agent":"#{agent}"})).status == 204
      assert_received {[:keyfleet, :launch, :setup_copied], ^ref, %{count: 1}, %{agent: ^agent}}
    end
  end

  test "refuses anything but a step it knows, and counts nothing for it", %{
    conn: conn,
    ref: ref
  } do
    for body <- [
          ~s({"step":"buy"}),
          ~s({"step":"home","who":"0xabc"}),
          ~s({"step":"copy","agent":"not-an-agent"}),
          ~s({"step":"copy"}),
          ~s(["home"]),
          "home"
        ] do
      assert report(conn, body).status == 400
      assert_received {[:keyfleet, :launch, :refused], ^ref, _, %{reason: :invalid}}
    end

    refute_received {[:keyfleet, :launch, :step], ^ref, _, _}
    refute_received {[:keyfleet, :launch, :setup_copied], ^ref, _, _}
  end

  test "refuses a body larger than a report", %{conn: conn, ref: ref} do
    assert report(conn, String.duplicate("x", 300)).status == 413
    assert_received {[:keyfleet, :launch, :refused], ^ref, _, %{reason: :too_large}}
  end

  test "drops reports past an address's budget for the minute", %{conn: conn, ref: ref} do
    for _ <- 1..60, do: assert(report(conn, ~s({"step":"home"})).status == 204)

    refused = report(conn, ~s({"step":"home"}))
    assert refused.status == 429
    assert [_seconds] = get_resp_header(refused, "retry-after")
    assert_received {[:keyfleet, :launch, :refused], ^ref, _, %{reason: :rate_limited}}
  end
end

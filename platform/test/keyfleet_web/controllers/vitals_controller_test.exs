defmodule KeyfleetWeb.VitalsControllerTest do
  # Visitors' page timings come in unsigned from anyone, so each test names
  # what a made-up or flooding sender must not be able to do. Every request
  # comes from an address of its test's own, so no other case has spent its
  # budget.
  use KeyfleetWeb.ConnCase, async: false

  @report %{
    "route" => "/",
    "device" => "phone",
    "connection" => "4g",
    "metrics" => %{"LCP" => 1_200, "CLS" => 0.02}
  }

  setup %{conn: conn} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:keyfleet, :vitals, :lcp]])
    on_exit(fn -> :telemetry.detach(ref) end)

    address = {203, 0, 113, System.unique_integer([:positive]) |> rem(250) |> Kernel.+(1)}
    %{conn: %{conn | remote_ip: address} |> put_req_header("content-type", "text/plain")}
  end

  # Costly failure: a sender posts a large body and the site reads all of it.
  test "a body past a kilobyte is refused with 413 and counts nothing", %{conn: conn} do
    padded = Map.put(@report, "pad", "")
    filler = 1_025 - byte_size(Jason.encode!(padded))
    body = Jason.encode!(Map.put(padded, "pad", String.duplicate("x", filler)))
    assert byte_size(body) == 1_025

    assert post(conn, "/vitals", body).status == 413
    refute_received {[:keyfleet, :vitals, :lcp], _ref, _measurements, _metadata}

    assert post(conn, "/vitals", Jason.encode!(@report)).status == 204
    assert_received {[:keyfleet, :vitals, :lcp], _ref, %{value: 1.2}, %{route: "/"}}
  end

  # Costly failure: one sender floods the timings and skews every figure.
  test "the 61st report from one address in a minute is refused with 429", %{conn: conn} do
    for _report <- 1..60,
        do: assert(post(conn, "/vitals", Jason.encode!(@report)).status == 204)

    refused = post(conn, "/vitals", Jason.encode!(@report))
    assert refused.status == 429
    assert [seconds] = get_resp_header(refused, "retry-after")
    assert String.to_integer(seconds) in 1..60
  end

  # Costly failure: a made-up page name becomes a new label on every timing
  # figure, without end.
  test "a report for a page that is not one of the site's is refused with 400 and counts nothing",
       %{conn: conn} do
    for route <- ["/no-such-page", "/classic/1/rooms/general", "/admin/errors"] do
      refused = post(conn, "/vitals", Jason.encode!(%{@report | "route" => route}))
      assert refused.status == 400, route
    end

    refute_received {[:keyfleet, :vitals, :lcp], _ref, _measurements, _metadata}
  end
end

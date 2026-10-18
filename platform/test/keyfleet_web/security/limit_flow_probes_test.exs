defmodule KeyfleetWeb.Security.LimitFlowProbesTest do
  @moduledoc """
  Authorized red-team regression probes for limit and flow bypass: the server
  must refuse agent work independently of the UI — when the site is closed,
  when a fleet is coming soon, when an unpaired stranger signs correctly, when
  a body carries an undocumented field, and when a body is over its cap.

  These lock in the server-side gates so a future change that moves a money
  endpoint out from behind a gate is caught. The true parallel credit
  double-spend proof is out of this repo (debit lives in RegentCredits) and is
  tagged `:dynamic` for the Mac's non-sandboxed / fork run.

  See `priv/security/redteam_checks.yml` and
  `docs/security/redteam-2026-10-17.md`.
  """
  use ExUnit.Case, async: false

  import KeyfleetWeb.RedTeamHelpers

  @join %{"name" => "Probe", "declared_harness" => "local"}

  setup do
    ctx = start_app!()
    signer = paired_signer!()
    record_owner!(1, signer.address)
    ctx = Map.put(ctx, :signer, signer)
    send_signed(ctx, signer, "POST", "/api/v1/agent/join/status", @join)
    {:ok, ctx}
  end

  describe "closed site refuses the agent API at the endpoint (RT-GATE-CLOSED)" do
    # Toggle to break: leave `:app_surfaces` true. With it false, LaunchGate (in
    # the endpoint, before SignedAgent) must 503 every signed agent request.
    test "a fully-signed agent request is 503 not_open_yet when surfaces are off", ctx do
      prev = Application.get_env(:keyfleet, :app_surfaces)
      Application.put_env(:keyfleet, :app_surfaces, false)
      on_exit(fn -> Application.put_env(:keyfleet, :app_surfaces, prev) end)

      resp = send_signed(ctx, ctx.signer, "POST", "/api/v1/agent/join/status", @join)
      assert_refused(resp, 503, "not_open_yet")
    end
  end

  describe "coming-soon fleet refuses every money endpoint (RT-GATE-COMING-SOON)" do
    # Toggle to break: remove `plug KeyfleetWeb.Plugs.FleetComingSoon` from the
    # `:agent` pipeline; the calls then reach AgentChainController
    # (fleet_not_on_chain / other) instead of the 404 gate. (Prove locally; do
    # not ship any pipeline change.)
    #
    # fleet_tech_accelerant is catalog coming-soon and is NOT deployed in setup,
    # so coming_soon?/2 is true for it.
    @soon "fleet_tech_accelerant"

    for {method, suffix, body} <- [
          {"POST", "presence", %{}},
          {"POST", "split", %{}},
          {"POST", "treasury/send_share", %{}},
          {"POST", "treasury/convert", %{"inputs" => %{"amount" => "1"}}},
          {"POST", "proposals/create", %{"kind" => "text", "key" => "1", "text" => "hi"}},
          {"POST", "proposals/vote", %{"number" => 1, "choice" => "yes"}},
          {"POST", "proposals/cancel", %{"number" => 1}},
          {"POST", "proposals/carry_out", %{"number" => 1}},
          {"POST", "keys/1/claim", %{}}
        ] do
      test "coming-soon fleet refuses #{suffix}", ctx do
        resp =
          send_signed(
            ctx,
            ctx.signer,
            unquote(method),
            "/api/v1/agent/fleets/#{@soon}/#{unquote(suffix)}",
            unquote(Macro.escape(body))
          )

        assert_refused(resp, 404, "fleet_coming_soon")
      end
    end
  end

  describe "an unpaired stranger is refused even with a valid signature (RT-PAIRING)" do
    # Toggle to break: in signed_agent.ex `admit/2`, return `{:ok, ...}` without
    # requiring `with_pairing`.
    test "a correctly signed but unpaired wallet cannot send a DM", ctx do
      stranger = unpaired_signer!()

      resp =
        send_signed(
          ctx,
          stranger,
          "POST",
          "/api/v1/agent/fleets/#{fleet()}/keys/1/dms/2/send",
          %{"body" => "hi", "idempotency_key" => Ecto.UUID.generate()}
        )

      assert_refused(resp, 403, "agent_not_paired")
    end
  end

  describe "input bounds the plug enforces before any action (RT-INPUT-BOUNDS)" do
    # Toggle to break: loosen `check_body/2` in signed_agent.ex (accept extra
    # keys), or raise a route's body cap.
    test "a body with an undocumented field is refused", ctx do
      resp =
        send_signed(
          ctx,
          ctx.signer,
          "POST",
          "/api/v1/agent/fleets/#{fleet()}/rooms/general/topic",
          %{
            "topic" => "ok",
            "role" => "admin"
          }
        )

      assert resp.status == 422
      assert refusal_code(resp) == "invalid_request"
    end

    test "a body over the route's cap is refused before it is parsed", ctx do
      oversized = %{"topic" => String.duplicate("a", 8_000)}

      resp =
        send_signed(
          ctx,
          ctx.signer,
          "POST",
          "/api/v1/agent/fleets/#{fleet()}/rooms/general/topic",
          oversized
        )

      assert resp.status == 413
    end
  end

  describe "concurrency — identical sends collapse to one message (RT-IDEMPOTENCY)" do
    # Toggle to break: drop `upsert_identity :unique_send_key` from the room
    # :send_message action; two concurrent identical sends then make two rows.
    #
    # NOTE: under the test sandbox all callers share one connection and
    # serialize, so this proves the unique index/upsert decides one winner, not
    # true parallel timing. The genuine parallel credit double-spend proof needs
    # a non-sandboxed DB and the RegentCredits debit action — Mac / fork only.
    @tag :dynamic
    test "two identical sends yield one message id", ctx do
      body = %{"body" => "same", "idempotency_key" => "dup-1"}
      path = "/api/v1/agent/fleets/#{fleet()}/rooms/general/messages/send"

      a = send_signed(ctx, ctx.signer, "POST", path, body)
      b = send_signed(ctx, ctx.signer, "POST", path, body)

      assert Enum.sort([a.status, b.status]) == [200, 201],
             "expected one created + one handed back, got #{a.status}/#{b.status}"

      assert a.body["message"]["id"] == b.body["message"]["id"]
    end
  end

  describe "an agent's posts as a Key spend its wallet's allowance (RT-QUOTA-POSTS)" do
    # Toggle to break: remove `change Keyfleet.Rooms.Changes.LimitPosts` from
    # :send_message in rooms/message.ex; the second post is then written.
    test "a post past the allowance is 429 post_limit_reached, and a repeat is handed back",
         ctx do
      allow!(:agent_posts, 1)
      path = "/api/v1/agent/fleets/#{fleet()}/rooms/general/messages/send"
      first = %{"body" => "First", "idempotency_key" => "k-1"}

      assert %{status: 201} = send_signed(ctx, ctx.signer, "POST", path, first)

      resp =
        send_signed(ctx, ctx.signer, "POST", path, %{
          "body" => "One more",
          "idempotency_key" => "k-2"
        })

      assert_refused(resp, 429, "post_limit_reached")
      assert [_seconds] = Req.Response.get_header(resp, "retry-after")
      assert %{status: 200} = send_signed(ctx, ctx.signer, "POST", path, first)
    end
  end

  describe "workspace writes spend each wallet's allowance (RT-QUOTA-WRITES)" do
    # Toggle to break: drop the `Limits.admit(:graph_writes, ...)` step from
    # `write/4` in agent_graph_controller.ex; the second write then reaches the
    # workspace's own checks.
    test "a write past the allowance is 429 workspace_limit_reached", ctx do
      allow!(:graph_writes, 1)

      write = fn ->
        send_signed(
          ctx,
          ctx.signer,
          "POST",
          "/api/v1/agent/fleets/#{fleet()}/graph/create",
          %{
            "as_key" => 2,
            "command_id" => Ecto.UUID.generate(),
            "type" => "note",
            "scope" => "fleet",
            "data" => %{"title" => "x"}
          }
        )
      end

      assert_refused(write.(), 403, "not_a_key_holder")
      limited = assert_refused(write.(), 429, "workspace_limit_reached")
      assert [_seconds] = Req.Response.get_header(limited, "retry-after")
    end
  end

  # Gives `name` an allowance of `limit` for this test alone.
  defp allow!(name, limit) do
    limits = Application.fetch_env!(:keyfleet, :limits)
    window = limits |> Keyword.fetch!(name) |> Keyword.fetch!(:window_seconds)
    allowance = [limit: limit, window_seconds: window]
    Application.put_env(:keyfleet, :limits, Keyword.put(limits, name, allowance))
    on_exit(fn -> Application.put_env(:keyfleet, :limits, limits) end)
  end
end

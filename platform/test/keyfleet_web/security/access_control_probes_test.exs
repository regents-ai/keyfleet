defmodule KeyfleetWeb.Security.AccessControlProbesTest do
  @moduledoc """
  Authorized red-team regression probes for access control and tenancy: an
  agent must never act as a Key it does not hold (IDOR), never set a protected
  field (mass-assignment), and never read another fleet it is not a member of.

  The signer's agent holds Key 1; a foreign wallet holds Key 2. Each probe
  drives a signed request that tries to act as Key 2 (or a foreign fleet) and
  asserts the refusal. Flipping the holder gate off locally makes the attack
  reach the action — the probe then fails, which is the recorded proof.

  See `priv/security/redteam_checks.yml` and
  `docs/security/redteam-2026-10-17.md` for the per-check disable toggle.
  """
  use ExUnit.Case, async: false

  import KeyfleetWeb.RedTeamHelpers

  @foreign "0x" <> String.duplicate("b", 40)

  defp idem, do: Ecto.UUID.generate()

  setup do
    ctx = start_app!()
    signer = paired_signer!()
    # The signer's own wallet holds Key 1; a stranger holds Key 2.
    record_owner!(1, signer.address)
    record_owner!(2, @foreign)
    ctx = Map.put(ctx, :signer, signer)
    # Give the agent a profile, the way a real agent joins before acting.
    send_signed(ctx, signer, "POST", "/api/v1/agent/join/status", %{
      "name" => "Probe",
      "declared_harness" => "local"
    })

    {:ok, ctx}
  end

  describe "IDOR — an agent cannot act as a Key it does not hold (RT-IDOR-DM / RT-IDOR-GRAPH)" do
    # Toggle to break: in dms/message.ex / dms/conversation.ex, drop the
    # `KeyHolder` check (`keys: [...]`) from the action's policy; the request
    # then acts as the foreign Key.
    test "cannot send a DM as a Key held by someone else", ctx do
      resp =
        send_signed(
          ctx,
          ctx.signer,
          "POST",
          "/api/v1/agent/fleets/#{fleet()}/keys/2/dms/1/send",
          %{"body" => "hi", "idempotency_key" => idem()}
        )

      assert_refused(resp, 403, "not_your_key")
    end

    test "cannot read another Key's DM inbox", ctx do
      resp =
        send_signed(ctx, ctx.signer, "GET", "/api/v1/agent/fleets/#{fleet()}/keys/2/dms")

      assert_refused(resp, 403, "not_your_key")
    end

    test "cannot block another Key's correspondents as that Key", ctx do
      resp =
        send_signed(
          ctx,
          ctx.signer,
          "POST",
          "/api/v1/agent/fleets/#{fleet()}/keys/2/dms/1/block",
          %{}
        )

      assert_refused(resp, 403, "not_your_key")
    end

    # Toggle to break: in graph/workspace.ex, drop the `KeyActor` check keyed on
    # `as_key` from the create/patch policy.
    test "cannot write the workspace as a Key it does not hold (as_key IDOR)", ctx do
      resp =
        send_signed(
          ctx,
          ctx.signer,
          "POST",
          "/api/v1/agent/fleets/#{fleet()}/graph/create",
          %{
            "as_key" => 2,
            "command_id" => idem(),
            "project" => "general",
            "type" => "note",
            "data" => %{"title" => "x"}
          }
        )

      assert_refused(resp, 403, "not_a_key_holder")
    end
  end

  describe "mass-assignment — a profile update takes only its editable fields (RT-MASS-ASSIGN)" do
    # Toggle to break: add a field (e.g. "role") to `@editable` in
    # signed_agent.ex, or to the agent_profile `:update` accept list.
    for field <- ["role", "human_account_id", "pairing_id", "admin", "standing"] do
      test "rejects a profile update naming #{field}", ctx do
        resp =
          send_signed(ctx, ctx.signer, "POST", "/api/v1/agent/profile/update", %{
            unquote(field) => "1"
          })

        assert resp.status == 422,
               "an update naming #{unquote(field)} was accepted: #{inspect(resp.body)}"

        assert refusal_code(resp) == "invalid_request"
      end
    end
  end

  describe "cross-tenant — an agent cannot read a fleet it is not a member of (RT-TENANT)" do
    # Toggle to break: in access/check.ex, resolve the class against a fixed
    # fleet instead of the path `fleet_id`, or make `member?/2` ignore the fleet.
    setup ctx do
      # A second fleet the signer is NOT a member of, open (deployed) so the
      # refusal is the membership gate, not the coming-soon gate.
      Keyfleet.ChainHelpers.deploy!("fibonacci_cascade")
      Keyfleet.ChainHelpers.seed_cursor!("fibonacci_cascade")
      Keyfleet.ChainViews.share!()
      {:ok, ctx}
    end

    test "the member-only workspace of a foreign fleet refuses", ctx do
      resp =
        send_signed(
          ctx,
          ctx.signer,
          "POST",
          "/api/v1/agent/fleets/fibonacci_cascade/graph/changes",
          %{"after_seq" => 0}
        )

      # 403 forbidden when ownership is fresh; 503 only if it cannot be read.
      assert resp.status in [403, 503],
             "foreign-fleet workspace read was allowed: #{inspect(resp.body)}"
    end
  end
end

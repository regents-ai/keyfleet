defmodule KeyfleetWeb.SharedAgentPairingTest do
  use KeyfleetWeb.ConnCase, async: false

  import KeyfleetWeb.RefusalHelpers

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System

  @owner "did:privy:keyfleet-pairing-owner"
  @wallet "0x2222222222222222222222222222222222222222"

  setup do
    Accounts.register_verified!(@owner, nil, [], actor: %System{})

    # Ash is bypassed on purpose: a person names themselves through the shared
    # profile API, whose rows only a signed proof writes.
    Keyfleet.Repo.insert_all(
      "profiles",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          app_id: "keyfleet-test",
          privy_user_id: @owner,
          display_name: "Sol's owner",
          wallet_addresses: [],
          proof_issued_at: 0,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: "regent_identity"
    )

    :ok
  end

  # The SIWA sign-in server verifies each request for audience keyfleet and
  # names the key that signed it; the test hears what it was asked to verify.
  defp siwa_verifies do
    test = self()

    Req.Test.stub(RegentAgents.Broker, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:verified, Plug.Conn.get_req_header(conn, "x-siwa-audience"), Jason.decode!(body)}
      )

      Req.Test.json(conn, %{
        "code" => "http_envelope_valid",
        "data" => %{
          "verified" => true,
          "agentRegistration" => nil,
          "agentBook" => nil,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => @wallet,
            "chain_id" => 8453,
            "audience" => "keyfleet"
          }
        }
      })
    end)
  end

  defp code! do
    RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: @owner}).code
  end

  test "an agent pairs with a code from regents.sh and checks in, signed for Keyfleet",
       %{conn: conn} do
    siwa_verifies()
    # Spaced as no JSON encoder writes it, so only the bytes as sent can match.
    raw = ~s({ "code" : "#{code!()}",  "name":"Sol", "harness" : "codex" })

    paired =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/agents/v1/pair", raw)

    assert %{"data" => %{"name" => "Sol", "harness" => "codex", "wallet" => @wallet}} =
             json_response(paired, 201)

    assert_received {:verified, ["keyfleet"], envelope}
    assert %{"method" => "POST", "path" => "/api/agents/v1/pair", "body" => ^raw} = envelope

    checked_in = get(build_conn(), "/api/agents/v1/me")

    assert %{"data" => %{"wallet" => @wallet, "account" => %{"display_name" => "Sol's owner"}}} =
             json_response(checked_in, 200)

    assert_received {:verified, ["keyfleet"], %{"method" => "GET", "path" => "/api/agents/v1/me"}}
  end

  test "while the site is closed, both requests answer not_open_yet", %{conn: conn} do
    Application.put_env(:keyfleet, :app_surfaces, false)
    on_exit(fn -> Application.put_env(:keyfleet, :app_surfaces, true) end)

    assert json_response(post(conn, "/api/agents/v1/pair", %{}), 503) == refused("not_open_yet")
    assert json_response(get(build_conn(), "/api/agents/v1/me"), 503) == refused("not_open_yet")
    refute_received {:verified, _audience, _envelope}
  end

  test "both requests spend the /api budget, and past it nothing is verified", %{conn: conn} do
    budget = Application.fetch_env!(:keyfleet, :api_rate_limit)
    Application.put_env(:keyfleet, :api_rate_limit, limit: 1, window_seconds: 60)
    on_exit(fn -> Application.put_env(:keyfleet, :api_rate_limit, budget) end)

    siwa_verifies()
    conn = put_req_header(conn, "fly-client-ip", "203.0.113.251")

    first = get(conn, "/api/agents/v1/me")
    assert json_response(first, 404)["error"]["code"] == "not_paired"
    assert get_resp_header(first, "ratelimit-policy") == [~s("default";q=1;w=60)]
    assert_received {:verified, ["keyfleet"], _envelope}

    for refused <- [post(conn, "/api/agents/v1/pair", %{}), get(conn, "/api/agents/v1/me")] do
      assert json_response(refused, 429)["error"]["code"] == "too_many_requests"
    end

    refute_received {:verified, _audience, _envelope}
  end
end

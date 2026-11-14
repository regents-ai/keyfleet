defmodule KeyfleetWeb.AgentFundingsTest do
  # An agent prices and starts funding its fleet's treasury with NEAR through
  # its own signed requests, then reads how the funding stands. The NEAR
  # exchange service is the test's stub (`Keyfleet.Fundings.StubClient`).
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, ContractSchema, Fleets, Keys, PairingHelpers}
  alias Keyfleet.Fundings.StubClient
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @api "/api/v1/agent/fleets/#{@fleet}/fundings"
  @ask %{"usdc_amount" => 5_000_000, "refund_to" => "agent.near"}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    member = paired_signer()
    record_owner!(1, member.address)

    %{
      secret: secret,
      member: member,
      stranger: paired_signer(),
      treasury: Fleets.get_fleet!(@fleet).treasury_address
    }
  end

  test "a quote answers the service's price and the fleet's treasury, and records nothing", c do
    price = c |> post!(c.member, "/quote", @ask) |> json_response(200)

    assert ContractSchema.response_errors(price, "POST", "#{tmpl()}/quote", 200) == []

    assert %{
             "near_in_formatted" => "1.651313840569386417635746",
             "time_estimate_s" => 24,
             "recipient" => recipient,
             "usdc_amount" => 5_000_000
           } = price["quote"]

    assert recipient == c.treasury
    assert [%{recipient: ^recipient, dry: true}] = StubClient.quotes()
    assert {:ok, []} = Keyfleet.Fundings.list_fundings(@fleet, actor: %System{})
  end

  test "a start answers where to send the NEAR, landing at the fleet's treasury", c do
    started = c |> post!(c.member, "/start", @ask) |> json_response(201)

    assert ContractSchema.response_errors(started, "POST", "#{tmpl()}/start", 201) == []

    assert %{
             "state" => "pending_deposit",
             "status" => "Waiting",
             "deposit_address" => "deposit-stub-1",
             "recipient" => recipient,
             "receipt" => nil
           } = started["funding"]

    assert recipient == c.treasury
    assert [%{recipient: ^recipient, dry: false}] = StubClient.quotes()
  end

  test "a body naming any other recipient is refused, and nothing is asked or recorded", c do
    body = Map.put(@ask, "recipient", "0x" <> String.duplicate("b", 40))
    refused = c |> post!(c.member, "/start", body) |> json_response(422)

    assert refused["error"]["code"] == "invalid_request"
    assert StubClient.quotes() == []
    assert {:ok, []} = Keyfleet.Fundings.list_fundings(@fleet, actor: %System{})
  end

  test "an agent that isn't one of the fleet's members is refused", c do
    for op <- ["/quote", "/start"] do
      refused = c |> post!(c.stranger, op, @ask) |> json_response(403)
      assert refused["error"]["code"] == "funding_needs_key", op
    end

    assert StubClient.quotes() == []
  end

  test "an amount past 1,000 USDC or a refund account that isn't NEAR's is refused", c do
    for body <- [
          %{@ask | "usdc_amount" => 1_000_000_001},
          %{@ask | "usdc_amount" => 0},
          %{@ask | "refund_to" => "Not An Account!"}
        ] do
      refused = c |> post!(c.member, "/start", body) |> json_response(422)
      assert refused["error"]["code"] == "invalid_funding", inspect(body)
    end
  end

  test "a failing exchange service is told apart, and nothing is recorded", c do
    StubClient.put_quote({:error, %{reason: :http, message: "down"}})
    refused = c |> post!(c.member, "/start", @ask) |> json_response(502)

    assert refused["error"]["code"] == "funding_service_failed"
    assert {:ok, []} = Keyfleet.Fundings.list_fundings(@fleet, actor: %System{})
  end

  test "reading a funding records its latest state, with a receipt once it has arrived", c do
    id = start!(c)

    StubClient.put_status(
      {:ok, %{state: :success, origin_tx: "near-tx-1", destination_tx: "0xbase1", raw: %{}}}
    )

    shown = c |> get!(c.member, "/#{id}") |> json_response(200)
    assert ContractSchema.response_errors(shown, "GET", "#{tmpl()}/{funding_id}", 200) == []

    assert %{
             "state" => "success",
             "status" => "Arrived",
             "origin_tx_url" => "https://nearblocks.io/txns/near-tx-1",
             "destination_tx_url" => "https://basescan.org/tx/0xbase1",
             "receipt" => %{
               "usdc" => "5.000000",
               "recipient" => recipient,
               "origin_tx" => "near-tx-1",
               "destination_tx" => "0xbase1",
               "signature" => "not_checked"
             }
           } = shown["funding"]

    assert recipient == c.treasury

    assert {:ok, %{state: :success}} =
             Keyfleet.Fundings.get_funding(@fleet, id, actor: %System{})
  end

  test "a refunded or failed funding is recorded as such, with no receipt", c do
    for state <- [:refunded, :failed] do
      id = start!(c)

      StubClient.put_status(
        {:ok, %{state: state, origin_tx: "near-tx-2", destination_tx: nil, raw: %{}}}
      )

      shown = c |> get!(c.member, "/#{id}") |> json_response(200)
      assert %{"state" => recorded, "receipt" => nil} = shown["funding"]
      assert recorded == Atom.to_string(state)
      assert {:ok, %{state: ^state}} = Keyfleet.Fundings.get_funding(@fleet, id, actor: %System{})
    end
  end

  test "a funding the fleet doesn't have answers funding_unknown", c do
    refused = c |> get!(c.member, "/#{Ecto.UUID.generate()}") |> json_response(404)
    assert refused["error"]["code"] == "funding_unknown"
  end

  defp start!(c) do
    c |> post!(c.member, "/start", @ask) |> json_response(201) |> get_in(["funding", "id"])
  end

  defp tmpl, do: "/api/v1/agent/fleets/{fleet_id}/fundings"

  defp post!(c, signer, op, body) do
    path = @api <> op
    raw = Jason.encode!(body)
    request = SignedAgentHelpers.sign(signer, c.secret, "www.example.com", "POST", path, raw)
    request.headers |> signed_conn() |> dispatch(@endpoint, :post, path, raw)
  end

  defp get!(c, signer, op) do
    path = @api <> op
    request = SignedAgentHelpers.sign(signer, c.secret, "www.example.com", "GET", path, nil)
    request.headers |> signed_conn() |> get(path)
  end

  defp signed_conn(headers) do
    Enum.reduce(headers, %{build_conn() | remote_ip: {198, 51, 100, 153}}, fn {name, value},
                                                                              conn ->
      put_req_header(conn, name, value)
    end)
  end

  defp paired_signer do
    {:ok, signer} = Siwa.LocalSigner.new()
    PairingHelpers.pair_wallet!(String.downcase(signer.address))
    signer
  end

  defp record_owner!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: String.downcase(wallet),
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )
  end
end

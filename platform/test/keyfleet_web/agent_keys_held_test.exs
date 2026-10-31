defmodule KeyfleetWeb.AgentKeysHeldTest do
  # An agent finds the Keys a wallet holds in a fleet through its own signed
  # request, as the Key map's search on the page finds them.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.System
  alias Keyfleet.{ChainHelpers, ContractSchema, Fleets, Keys, PairingHelpers}
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @api "/api/v1/agent/fleets/#{@fleet}/keys/held"
  @holder "0x00000000000000000000000000000000000000ab"
  @holder_mixed_case "0x00000000000000000000000000000000000000AB"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    {:ok, signer} = Siwa.LocalSigner.new()
    PairingHelpers.pair_wallet!(String.downcase(signer.address))
    %{secret: secret, signer: signer}
  end

  test "answers the Keys a wallet holds now, lowest first, in whatever case it is written", c do
    record!(9, @holder, 1)
    record!(3, @holder, 1)
    # Key 5 was the holder's and has changed hands since.
    record!(5, @holder, 1)
    record!(5, "0x00000000000000000000000000000000000000cd", 2)

    held = c |> post!(@api, %{"wallet" => @holder_mixed_case}) |> json_response(200)

    assert ContractSchema.errors(held, "KeysHeldEnvelope") == []

    assert held == %{
             "held" => %{"fleet_id" => @fleet, "wallet" => @holder, "token_ids" => [3, 9]}
           }

    assert Enum.map(Keys.keys_held_in_fleet!(@fleet, [@holder]), & &1.token_id) == [3, 9]
  end

  test "a wallet that holds none answers an empty list", c do
    held = c |> post!(@api, %{"wallet" => @holder}) |> json_response(200)
    assert held["held"]["token_ids"] == []
  end

  test "a body that names anything but one wallet is refused", c do
    for body <- [
          %{},
          %{"wallet" => "0xab"},
          %{"wallet" => "ab" <> String.duplicate("0", 40)},
          %{"wallet" => 7},
          %{"wallet" => @holder, "token_id" => 1}
        ] do
      assert post!(c, @api, body).status == 422, inspect(body)
    end
  end

  test "a fleet that doesn't exist answers fleet_unknown", c do
    answer = post!(c, "/api/v1/agent/fleets/no_such_fleet/keys/held", %{"wallet" => @holder})
    assert json_response(answer, 404)["error"]["code"] == "fleet_unknown"
  end

  defp post!(c, path, body) do
    raw = Jason.encode!(body)
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", "POST", path, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 151}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :post, path, raw)
  end

  defp record!(token_id, wallet, epoch) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: wallet,
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}-#{epoch}"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )
  end
end

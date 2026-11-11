defmodule KeyfleetWeb.AgentSearchTest do
  # An agent searches a fleet through its own signed request, and finds what
  # it may read there with the page each match is on.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.{ChainHelpers, ContractSchema, Dms, Fleets, Keys, PairingHelpers, Rooms}
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint
  @fleet "fibonacci_syndicate"
  @api "/api/v1/agent/fleets/#{@fleet}/search"
  @person "0x" <> String.duplicate("a", 40)
  @other "0x" <> String.duplicate("b", 40)

  setup do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    Workspace.open_log(@fleet)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)

    # The agent's person holds Key 1; someone else holds Key 2.
    {:ok, signer} = Siwa.LocalSigner.new()
    PairingHelpers.pair_wallet!(String.downcase(signer.address), @person)
    record!(1, @person)
    record!(2, @other)
    %{secret: secret, signer: signer}
  end

  test "finds posts, messages and items with their pages, and reads on from its cursor", c do
    other = human(@other)
    writer = PairingHelpers.agent_for!(other)
    post!(writer, "coding", "The probe deploy failed twice")
    Dms.send_dm!(dm(2, 1, "Can you redo the deploy?"), actor: other)
    task = Workspace.create(@fleet, "task", %{"title" => "Deploy the probe again"})

    first = c |> post!(%{"query" => "deploy", "limit" => 2}) |> json_response(200)
    assert ContractSchema.errors(first, "SearchPage") == []
    assert %{"has_more" => true, "cursor" => cursor, "matches" => [_, _]} = first

    rest = c |> post!(%{"query" => "deploy", "cursor" => cursor}) |> json_response(200)
    assert %{"has_more" => false, "cursor" => nil, "matches" => [_]} = rest

    matches = Map.new(first["matches"] ++ rest["matches"], &{&1["kind"], &1})

    assert %{"room" => %{"slug" => "coding"}, "seq" => 1, "url" => post_url} = matches["post"]
    assert post_url =~ "?room=coding"
    assert %{"key" => 1, "other_key" => 2, "from_key" => 2, "url" => dm_url} = matches["dm"]
    assert dm_url =~ "/keys/1/dms/2"

    assert %{"id" => ^task, "title" => "Deploy the probe again", "url" => item_url} =
             matches["item"]

    assert item_url =~ "/workspace/"
  end

  test "a query with no words, an unknown cursor or a limit out of range is refused", c do
    assert json_response(post!(c, %{"query" => "  "}), 422)["error"]["code"] ==
             "search_query_invalid"

    assert json_response(post!(c, %{"query" => "deploy", "cursor" => "nope"}), 422)["error"][
             "code"
           ] == "search_cursor_unknown"

    assert json_response(post!(c, %{"query" => "deploy", "limit" => 51}), 422)["error"]["code"] ==
             "out_of_range"

    for body <- [%{}, %{"query" => 7}, %{"query" => "deploy", "room" => "general"}] do
      assert json_response(post!(c, body), 422)["error"]["code"] == "invalid_request",
             inspect(body)
    end
  end

  defp post!(c, body) do
    raw = Jason.encode!(body)
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", "POST", @api, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: {198, 51, 100, 151}}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :post, @api, raw)
  end

  defp post!(writer, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: writer
    )
  end

  defp dm(from, to, body),
    do: %{
      fleet_id: @fleet,
      from_token_id: from,
      to_token_id: to,
      body: body,
      idempotency_key: Ash.UUID.generate()
    }

  defp human(wallet), do: %Human{human_account_id: 2, wallet_addresses: [wallet]}

  defp record!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 11,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}-1"), case: :lower),
        log_index: 0
      },
      actor: %System{}
    )
  end
end

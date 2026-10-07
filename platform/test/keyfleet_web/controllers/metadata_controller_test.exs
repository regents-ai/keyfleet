defmodule KeyfleetWeb.MetadataControllerTest do
  use KeyfleetWeb.ConnCase, async: false
  use Oban.Testing, repo: Keyfleet.Repo, prefix: "keyfleet_app"

  import KeyfleetWeb.RefusalHelpers

  alias Keyfleet.Actors.System
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Keys.DrawPicture
  alias Keyfleet.Keys.KeyArt
  alias Keyfleet.Lighthouse
  alias Keyfleet.Traits

  @path "/metadata/{slot}/{token_id}"
  # keccak256 of the fixture table in test/support/fixtures/trait_tables.
  @table_hash "0x1249d615f793a311bcb27def92766224fb544df85aa74359a785a6349df18610"

  setup do
    Fleets.bootstrap_catalog!()

    for {fleet_id, character} <- [{"fibonacci_cascade", "3"}, {"fleet_tech_accelerant", "4"}] do
      deploy!(fleet_id, character)
      ChainHelpers.seed_cursor!(fleet_id)
    end

    buy!("fibonacci_cascade", 3)
    buy!("fleet_tech_accelerant", 1)
    %{site: KeyfleetWeb.Endpoint.url()}
  end

  test "a key waiting for its traits shows the interim access pass for 30 seconds", %{
    conn: conn,
    site: site
  } do
    cascade = get(conn, "/metadata/cascade/3")

    assert get_resp_header(cascade, "cache-control") == ["max-age=30"]

    assert json_response(cascade, 200) == %{
             "name" => "Keyfleet Cascade #3",
             "description" =>
               "Key 3 of Keyfleet Cascade. Its traits appear here once they are drawn.",
             "image" => "#{site}/images/keys/interim-keyfleet-access-pass.png",
             "attributes" => [
               %{"trait_type" => "Level", "value" => 2},
               %{"trait_type" => "Status", "value" => "Revealing"}
             ]
           }

    accelerant = get(conn, "/metadata/accelerant/1")

    assert json_response(accelerant, 200)["attributes"] == [
             %{"trait_type" => "Status", "value" => "Revealing"}
           ]

    for response <- [cascade, accelerant] do
      assert ContractSchema.response_errors(json_response(response, 200), "GET", @path, 200) == []
    end
  end

  # The traits are the fixture table's golden draw for this seed, the same
  # draw contracts/test/KeyfleetTraitDraw.t.sol pins. A reveal queues its
  # card's drawing; until the card is in the bucket the key keeps the pass.
  test "a revealed key shows its traits, then its card once drawn, kept for an hour", %{
    conn: conn,
    site: site
  } do
    seed = Traits.keccak256("golden-1")
    reveal!("fibonacci_cascade", 3, seed)
    reveal!("fleet_tech_accelerant", 1, seed)

    args = %{reveal_id: Keys.get_reveal!("fibonacci_cascade", 3).id}
    assert_enqueued(worker: DrawPicture, args: args)

    revealed = %{
      "name" => "Keyfleet Cascade #3",
      "description" => "Key 3 of Keyfleet Cascade.",
      "attributes" => [
        %{"trait_type" => "Level", "value" => 2},
        %{"trait_type" => "Hull", "value" => "Steel"},
        %{"trait_type" => "Sky", "value" => "Noon"},
        %{"trait_type" => "Mark", "value" => "Star"}
      ],
      "properties" => %{"seed" => seed, "trait_table_hash" => @table_hash}
    }

    drawing = get(conn, "/metadata/cascade/3")
    assert get_resp_header(drawing, "cache-control") == ["max-age=30"]

    assert json_response(drawing, 200) ==
             Map.put(revealed, "image", "#{site}/images/keys/interim-keyfleet-access-pass.png")

    test = self()
    png = <<0x89, "PNG\r\n", 0x1A, "\n", "card">>

    Req.Test.stub(KeyArt, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:draw, conn.request_path, JSON.decode!(body)})
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, png)
    end)

    # Lighthouse's own answer, not its JavaScript library's (which wraps it in `data`).
    cid = "QmUHDKv3NNL1mrg4NTW4WwJqetzwZbGNitdjr2G6Z5Xe6s"

    Req.Test.stub(Lighthouse, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [auth] = Plug.Conn.get_req_header(conn, "authorization")
      send(test, {:lighthouse, conn.method, conn.request_path, auth, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(%{Name: "cascade-3.png", Hash: cid, Size: "42"}))
    end)

    assert perform_job(DrawPicture, args) == :ok

    assert_received {:draw, "/draw",
                     %{
                       "seed" => ^seed,
                       "top_line" => "CASCADE #1 · NO. 0003",
                       "table" => @table_hash
                     }}

    assert_received {:lighthouse, "POST", "/api/v0/add", "Bearer test-lighthouse-key", body}
    assert body =~ ~s(name="file"; filename="cascade-3.png")
    assert body =~ "content-type: image/png"
    assert body =~ png

    # Drawn once: another run leaves the card as it is.
    assert perform_job(DrawPicture, args) == :ok
    refute_received {:draw, _path, _body}

    cascade = get(conn, "/metadata/cascade/3")

    assert get_resp_header(cascade, "cache-control") == ["public, max-age=3600"]

    assert json_response(cascade, 200) ==
             revealed
             |> Map.put("image", "https://media.regents.sh/ipfs/#{cid}")
             |> put_in(["properties", "card"], "ipfs://#{cid}")

    accelerant = get(conn, "/metadata/accelerant/1")

    assert Enum.map(json_response(accelerant, 200)["attributes"], & &1["trait_type"]) ==
             ["Hull", "Sky", "Mark"]

    for response <- [cascade, accelerant] do
      assert ContractSchema.response_errors(json_response(response, 200), "GET", @path, 200) == []
    end
  end

  # A revealed key's traits need its fleet's table; a key still waiting does
  # not, so it is still served.
  @tag :tmp_dir
  test "a revealed key whose table is missing or not its hash is a server error", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    configured = Application.fetch_env!(:keyfleet, Traits)
    Application.put_env(:keyfleet, Traits, directory: tmp_dir)
    on_exit(fn -> Application.put_env(:keyfleet, Traits, configured) end)
    reveal!("fibonacci_cascade", 3, Traits.keccak256("golden-1"))

    assert_error_sent 500, fn -> get(conn, "/metadata/cascade/3") end
    assert json_response(get(conn, "/metadata/accelerant/1"), 200)

    File.write!(Path.join(tmp_dir, @table_hash <> ".json"), ~s({"traits": []}))

    assert_error_sent 500, fn -> get(conn, "/metadata/cascade/3") end
  end

  test "no such fleet or no such key is not found", %{conn: conn} do
    for path <- [
          "/metadata/fibonacci_cascade/3",
          "/metadata/unknown/3",
          "/metadata/cascade/4",
          "/metadata/syndicate/3",
          "/metadata/cascade/03",
          "/metadata/cascade/0",
          "/metadata/cascade/3.json",
          "/metadata/cascade/-3",
          "/metadata/cascade/1234567890123456789"
        ] do
      response = get(conn, path)
      assert json_response(response, 404) == refused("key_not_found"), path
      assert ContractSchema.response_errors(json_response(response, 404), "GET", @path, 404) == []
    end
  end

  defp deploy!(fleet_id, character) do
    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 1,
        contract_address: "0x" <> String.duplicate(character, 40),
        rewards_address: "0x" <> String.duplicate(character <> "a", 20),
        votes_address: "0x" <> String.duplicate(character <> "b", 20),
        shards_address: "0x" <> String.duplicate(character <> "c", 20),
        usdc_address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        deployed_block: 1,
        trait_table_hash: @table_hash
      },
      actor: %System{}
    )
  end

  defp buy!(fleet_id, token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: "0x" <> String.duplicate("a", 40),
        block_number: 10,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: transaction(fleet_id, token_id, "1"),
        log_index: 0
      },
      actor: %System{}
    )
  end

  defp reveal!(fleet_id, token_id, seed) do
    Keys.record_reveal!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        request_id: 7,
        seed: seed,
        block_number: 12,
        block_hash: "0x" <> String.duplicate("c", 64),
        transaction_hash: transaction(fleet_id, token_id, "2"),
        log_index: 0
      },
      actor: %System{}
    )
  end

  defp transaction(fleet_id, token_id, kind),
    do: Traits.keccak256("#{fleet_id}/#{token_id}/#{kind}")
end

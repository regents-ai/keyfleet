defmodule KeyfleetWeb.MetadataControllerTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Actors.System
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
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

  test "a key waiting for its traits shows its fleet's waiting picture for 30 seconds", %{
    conn: conn,
    site: site
  } do
    cascade = get(conn, "/metadata/cascade/3")

    assert get_resp_header(cascade, "cache-control") == ["max-age=30"]

    assert json_response(cascade, 200) == %{
             "name" => "Keyfleet Cascade #3",
             "description" =>
               "Key 3 of Keyfleet Cascade. Its traits appear here once they are drawn.",
             "image" => "#{site}/art/cascade/revealing.png",
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
  # draw contracts/test/KeyfleetTraitDraw.t.sol pins.
  test "a revealed key shows its drawn traits and may be kept for an hour", %{
    conn: conn,
    site: site
  } do
    seed = Traits.keccak256("golden-1")
    reveal!("fibonacci_cascade", 3, seed)
    reveal!("fleet_tech_accelerant", 1, seed)

    cascade = get(conn, "/metadata/cascade/3")

    assert get_resp_header(cascade, "cache-control") == ["public, max-age=3600"]

    assert json_response(cascade, 200) == %{
             "name" => "Keyfleet Cascade #3",
             "description" => "Key 3 of Keyfleet Cascade.",
             "image" => "#{site}/art/#{@table_hash}/cascade/3.png",
             "attributes" => [
               %{"trait_type" => "Level", "value" => 2},
               %{"trait_type" => "Hull", "value" => "Steel"},
               %{"trait_type" => "Sky", "value" => "Noon"},
               %{"trait_type" => "Mark", "value" => "Star"}
             ],
             "properties" => %{"seed" => seed, "trait_table_hash" => @table_hash}
           }

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
      assert json_response(response, 404) == %{"error" => "key_not_found"}, path
      assert ContractSchema.response_errors(json_response(response, 404), "GET", @path, 404) == []
    end
  end

  defp deploy!(fleet_id, character) do
    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: "0x" <> String.duplicate(character, 40),
        rewards_address: "0x" <> String.duplicate(character <> "a", 20),
        votes_address: "0x" <> String.duplicate(character <> "b", 20),
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
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

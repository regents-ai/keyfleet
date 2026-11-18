defmodule KeyfleetWeb.PublicSeasonsTest do
  use KeyfleetWeb.ConnCase, async: false

  import KeyfleetWeb.RefusalHelpers

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ContractSchema
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.SeasonHelpers
  alias Keyfleet.Seasons

  @fleet "fibonacci_syndicate"
  @path "/api/v1/fleets/{fleet_id}/seasons"
  @first "0x" <> String.duplicate("a", 40)
  @second "0x" <> String.duplicate("b", 40)

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    holds!(1, @first)
    holds!(2, @second)
    :ok
  end

  # Season 1 settled with both Keys' picks, season 2 under way with Key 1's
  # and season 3 taking Key 2's: anyone signed out reads season 1 alone, its
  # Keys by number and nothing of either person.
  test "anyone reads the settled seasons alone, with no wallet, agent or person", %{conn: conn} do
    [b0, b1, b2 | _] = SeasonHelpers.boundaries(2)

    SeasonHelpers.coinbase!(%{
      "SOL-USD" => [{b1, "100"}, {b2, "103"}],
      "ETH-USD" => [{b1, "2000"}, {b2, "1990"}]
    })

    SeasonHelpers.turn!(@fleet, b0)
    Seasons.pick!(@fleet, 1, %{product: "SOL-USD", reason: "Fast chain"}, actor: human(@first))
    Seasons.pick!(@fleet, 1, %{product: "ETH-USD"}, actor: human(@second))
    SeasonHelpers.turn!(@fleet, b1)
    Seasons.pick!(@fleet, 2, %{product: "SOL-USD", reason: "Under way"}, actor: human(@first))
    SeasonHelpers.turn!(@fleet, b2)
    Seasons.pick!(@fleet, 3, %{product: "ETH-USD", reason: "Not yet seen"}, actor: human(@second))

    response = get(conn, "/api/v1/fleets/#{@fleet}/seasons")
    body = json_response(response, 200)

    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert ContractSchema.response_errors(body, "GET", @path, 200) == []

    assert %{
             "fleet_id" => @fleet,
             "seasons" => [season],
             "next_before" => nil,
             "has_more" => false
           } = body

    assert Map.keys(season) ==
             ~w(captain_key ends_at holding holding_close_price holding_open_price holding_result number picks starts_at)

    assert %{
             "number" => 1,
             "holding" => "USDC",
             "captain_key" => nil,
             "holding_open_price" => "1",
             "holding_close_price" => "1",
             "holding_result" => "0"
           } = season

    assert DateTime.compare(at(season["starts_at"]), b1) == :eq
    assert DateTime.compare(at(season["ends_at"]), b2) == :eq

    assert season["picks"] == [
             %{
               "key" => 1,
               "product" => "SOL-USD",
               "reason" => "Fast chain",
               "open_price" => "100",
               "close_price" => "103",
               "result" => "0.03",
               "void" => nil
             },
             %{
               "key" => 2,
               "product" => "ETH-USD",
               "reason" => nil,
               "open_price" => "2000",
               "close_price" => "1990",
               "result" => "-0.005",
               "void" => nil
             }
           ]

    text = response.resp_body
    refute text =~ "Under way"
    refute text =~ "Not yet seen"
    refute text =~ ~r/0x[0-9a-f]{40}/i
  end

  # Twenty-one seasons settled by turns that caught up at once: the newest
  # twenty first, then the oldest by the cursor the page gave.
  test "the record pages newest first by the cursor each page gives", %{conn: conn} do
    boundaries = SeasonHelpers.boundaries(22)
    SeasonHelpers.coinbase!(%{"SOL-USD" => []})
    SeasonHelpers.turn!(@fleet, hd(boundaries))
    SeasonHelpers.turn!(@fleet, List.last(boundaries))

    first = conn |> get("/api/v1/fleets/#{@fleet}/seasons") |> json_response(200)
    assert ContractSchema.response_errors(first, "GET", @path, 200) == []
    assert Enum.map(first["seasons"], & &1["number"]) == Enum.to_list(21..2//-1)
    assert %{"next_before" => "2", "has_more" => true} = first

    older =
      conn |> get("/api/v1/fleets/#{@fleet}/seasons?before=2") |> json_response(200)

    assert ContractSchema.response_errors(older, "GET", @path, 200) == []
    assert Enum.map(older["seasons"], & &1["number"]) == [1]
    assert %{"next_before" => nil, "has_more" => false} = older

    none = conn |> get("/api/v1/fleets/#{@fleet}/seasons?before=1") |> json_response(200)
    assert %{"seasons" => [], "next_before" => nil, "has_more" => false} = none
  end

  test "a cursor that names no season, another query or an unknown fleet is refused",
       %{conn: conn} do
    for query <-
          ["before=0", "before=01", "before=x", "before=9223372036854775808"] ++
            ["after=2", "before=2&after=1"] do
      body = conn |> get("/api/v1/fleets/#{@fleet}/seasons?#{query}") |> json_response(400)
      assert body == refused("invalid_season_cursor"), query
      assert ContractSchema.response_errors(body, "GET", @path, 400) == []
    end

    body = conn |> get("/api/v1/fleets/no_such_fleet/seasons") |> json_response(404)
    assert body == refused("fleet_unknown")
    assert ContractSchema.response_errors(body, "GET", @path, 404) == []
  end

  defp human(@first), do: %Actors.Human{human_account_id: 1, wallet_addresses: [@first]}
  defp human(@second), do: %Actors.Human{human_account_id: 2, wallet_addresses: [@second]}

  defp at(text) do
    {:ok, at, 0} = DateTime.from_iso8601(text)
    at
  end

  defp holds!(token_id, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("b", 64),
        log_index: token_id
      },
      actor: %Actors.System{}
    )
  end
end

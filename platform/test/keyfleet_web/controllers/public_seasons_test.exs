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
  @season "/api/v1/fleets/{fleet_id}/seasons/{number}"
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
             ~w(best_pick captain_key ends_at holding holding_close_price holding_open_price holding_result number pick_count starts_at)

    assert %{
             "number" => 1,
             "holding" => "USDC",
             "captain_key" => nil,
             "holding_open_price" => "1",
             "holding_close_price" => "1",
             "holding_result" => "0",
             "pick_count" => 2,
             "best_pick" => %{"key" => 1, "product" => "SOL-USD", "result" => "0.03"}
           } = season

    assert DateTime.compare(at(season["starts_at"]), b1) == :eq
    assert DateTime.compare(at(season["ends_at"]), b2) == :eq

    # Its picks are read on their own; the season under way and the one
    # taking picks have none to read here.
    picks = get(conn, "/api/v1/fleets/#{@fleet}/seasons/1")
    picks_body = json_response(picks, 200)

    assert get_resp_header(picks, "cache-control") == ["no-store"]
    assert ContractSchema.response_errors(picks_body, "GET", @season, 200) == []

    assert %{"fleet_id" => @fleet, "season" => 1, "next_after" => nil, "has_more" => false} =
             picks_body

    for number <- [2, 3] do
      unread = conn |> get("/api/v1/fleets/#{@fleet}/seasons/#{number}") |> json_response(404)
      assert unread == refused("season_unknown")
      assert ContractSchema.response_errors(unread, "GET", @season, 404) == []
    end

    assert picks_body["picks"] == [
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

    for text <- [response.resp_body, picks.resp_body] do
      refute text =~ "Under way"
      refute text =~ "Not yet seen"
      refute text =~ ~r/0x[0-9a-f]{40}/i
    end
  end

  # A season with more picks than a page holds: the first hundred in lock
  # order, then the rest by the cursor the page gave; the record counts them
  # all and names the best.
  test "a settled season's picks page in lock order by the cursor each page gives",
       %{conn: conn} do
    [b0, b1, b2 | _] = SeasonHelpers.boundaries(2)
    SeasonHelpers.coinbase!(%{"SOL-USD" => [{b1, "100"}, {b2, "103"}]})
    SeasonHelpers.turn!(@fleet, b0)

    for token_id <- 1..101 do
      wallet = wallet(token_id)
      if token_id > 2, do: holds!(token_id, wallet)
      Seasons.pick!(@fleet, 1, %{product: "SOL-USD"}, actor: human(token_id, wallet))
    end

    SeasonHelpers.turn!(@fleet, b1)
    SeasonHelpers.turn!(@fleet, b2)

    first = conn |> get("/api/v1/fleets/#{@fleet}/seasons/1") |> json_response(200)
    assert ContractSchema.response_errors(first, "GET", @season, 200) == []
    assert Enum.map(first["picks"], & &1["key"]) == Enum.to_list(1..100)
    assert %{"next_after" => place, "has_more" => true} = first
    refute place =~ ~r/\A[0-9]+\z/

    rest = conn |> get("/api/v1/fleets/#{@fleet}/seasons/1?after=#{place}") |> json_response(200)
    assert ContractSchema.response_errors(rest, "GET", @season, 200) == []
    assert Enum.map(rest["picks"], & &1["key"]) == [101]
    assert %{"next_after" => nil, "has_more" => false} = rest

    # One season's picks cursor doesn't page the record.
    assert conn |> get("/api/v1/fleets/#{@fleet}/seasons?before=#{place}") |> json_response(400) ==
             refused("invalid_season_cursor")

    assert %{"seasons" => [%{"pick_count" => 101, "best_pick" => %{"key" => 1}}]} =
             conn |> get("/api/v1/fleets/#{@fleet}/seasons") |> json_response(200)
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
    assert %{"next_before" => before, "has_more" => true} = first

    older =
      conn |> get("/api/v1/fleets/#{@fleet}/seasons?before=#{before}") |> json_response(200)

    assert ContractSchema.response_errors(older, "GET", @path, 200) == []
    assert Enum.map(older["seasons"], & &1["number"]) == [1]
    assert %{"next_before" => nil, "has_more" => false} = older
  end

  # A cursor is sealed by the site: it shows no place to order or count by, is
  # new in each answer, and continues only the list it was given for.
  test "a cursor shows no place and continues only the list it was given for", %{conn: conn} do
    boundaries = SeasonHelpers.boundaries(22)
    SeasonHelpers.coinbase!(%{"SOL-USD" => []})
    SeasonHelpers.turn!(@fleet, hd(boundaries))
    SeasonHelpers.turn!(@fleet, List.last(boundaries))

    reads =
      for _read <- 1..2 do
        %{"next_before" => before} =
          conn |> get("/api/v1/fleets/#{@fleet}/seasons") |> json_response(200)

        refute before =~ ~r/\A[0-9]+\z/
        before
      end

    assert [first, second] = reads
    assert first != second

    for before <- reads do
      assert %{"seasons" => [%{"number" => 1}]} =
               conn
               |> get("/api/v1/fleets/#{@fleet}/seasons?before=#{before}")
               |> json_response(200)
    end

    for path <- ["/seasons?before=#{changed(first)}", "/seasons/1?after=#{first}"] do
      body = conn |> get("/api/v1/fleets/#{@fleet}#{path}") |> json_response(400)
      assert body == refused("invalid_season_cursor"), path
    end
  end

  test "a cursor this site didn't give, another query or an unknown fleet is refused",
       %{conn: conn} do
    for query <- ["before=x", "before=", "after=x", "before=x&after=y"] do
      body = conn |> get("/api/v1/fleets/#{@fleet}/seasons?#{query}") |> json_response(400)
      assert body == refused("invalid_season_cursor"), query
      assert ContractSchema.response_errors(body, "GET", @path, 400) == []
    end

    body = conn |> get("/api/v1/fleets/no_such_fleet/seasons") |> json_response(404)
    assert body == refused("fleet_unknown")
    assert ContractSchema.response_errors(body, "GET", @path, 404) == []

    # One season's picks: the cursor is after alone, and a number that names
    # no season names none.
    SeasonHelpers.coinbase!(%{"SOL-USD" => []})
    [b0, b1, b2 | _] = SeasonHelpers.boundaries(2)
    Enum.each([b0, b1, b2], &SeasonHelpers.turn!(@fleet, &1))

    for query <- ["after=x", "after=", "before=x", "after=x&before=y"] do
      body = conn |> get("/api/v1/fleets/#{@fleet}/seasons/1?#{query}") |> json_response(400)
      assert body == refused("invalid_season_cursor"), query
      assert ContractSchema.response_errors(body, "GET", @season, 400) == []
    end

    for number <- ["0", "01", "x", "99", "9223372036854775808"] do
      body = conn |> get("/api/v1/fleets/#{@fleet}/seasons/#{number}") |> json_response(404)
      assert body == refused("season_unknown"), number
      assert ContractSchema.response_errors(body, "GET", @season, 404) == []
    end

    body = conn |> get("/api/v1/fleets/no_such_fleet/seasons/1") |> json_response(404)
    assert body == refused("fleet_unknown")
    assert ContractSchema.response_errors(body, "GET", @season, 404) == []
  end

  # The cursor with one character of its sealed text changed.
  defp changed(cursor) do
    sealed = cursor |> String.split(".") |> Enum.max_by(&byte_size/1)
    <<head::binary-size(4), character, tail::binary>> = sealed
    String.replace(cursor, sealed, head <> if(character == ?A, do: "B", else: "A") <> tail)
  end

  defp human(@first), do: human(1, @first)
  defp human(@second), do: human(2, @second)
  defp human(id, wallet), do: %Actors.Human{human_account_id: id, wallet_addresses: [wallet]}

  defp wallet(1), do: @first
  defp wallet(2), do: @second
  defp wallet(token_id), do: "0x" <> String.pad_leading(Integer.to_string(token_id), 40, "0")

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

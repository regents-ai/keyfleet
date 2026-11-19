defmodule KeyfleetWeb.Live.SeasonPanelTest do
  use KeyfleetWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Actors.Human
  alias Keyfleet.Chain.StubClient
  alias Keyfleet.ChainHelpers
  alias Keyfleet.CoinbaseStub
  alias Keyfleet.Fleets
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Seasons
  alias Keyfleet.Seasons.CoinList
  alias Keyfleet.Seasons.Errors.ReasonError
  alias Keyfleet.Seasons.Season
  alias Keyfleet.SharedReading
  alias KeyfleetWeb.AgentTools.Seasons.Answer
  alias KeyfleetWeb.FleetNow

  @fleet "fibonacci_syndicate"
  @path "/syndicate/1"
  @system %Actors.System{}
  @holder ProposalHelpers.wallet("1")
  @other ProposalHelpers.wallet("2")
  @outsider ProposalHelpers.wallet("f")
  @running_reason "Momentum into the weekend"
  @secret "Nobody may read this before the start"

  setup context do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet, %{manager_address: "0x" <> String.duplicate("7", 40)})
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, [1], @holder)
    ProposalHelpers.keys_sold!(@fleet, [2], @other)

    # The wallet's steps a signed-in page reads ask the chain's head.
    StubClient.put_chain(
      %{
        number: 1_000,
        hash: "0x" <> String.duplicate("f", 64),
        timestamp: DateTime.utc_now(),
        base_fee: 0
      },
      []
    )

    CoinbaseStub.stub(
      [
        CoinbaseStub.product("SOL-USD"),
        CoinbaseStub.product("ETH-USD"),
        CoinbaseStub.product("THIN-USD", %{"approximate_quote_24h_volume" => "10"})
      ],
      %{}
    )

    :ok = CoinList.read()
    SharedReading.delete(FleetNow.key(@fleet))

    on_exit(fn ->
      SharedReading.delete(CoinList.key())
      SharedReading.delete(FleetNow.key(@fleet))
    end)

    # Season 1 settled holding BTC-USD, up 2.5%; season 2 runs holding
    # SOL-USD, its crown passed to Key 2's pick, with a pick from each of the
    # `pickers` more Keys a test asks for; season 3 takes picks.
    boundary = Seasons.boundary(DateTime.utc_now())
    first = season!(1, DateTime.add(boundary, -3, :hour))
    first |> lock!("BTC-USD", "100", nil) |> settle!("102.5", "0.025")

    running = season!(2, DateTime.add(boundary, 3, :hour))
    pick!(@other, 2, "SOL-USD", @running_reason)

    pickers = Enum.take(~w(3 4 5 6 7 8 9 a b c d), Map.get(context, :pickers, 0))

    for {character, key} <- Enum.zip(pickers, 3..13) do
      ProposalHelpers.keys_sold!(@fleet, [key], ProposalHelpers.wallet(character))
      pick!(ProposalHelpers.wallet(character), 2, "ETH-USD", nil)
    end

    running = lock!(running, "SOL-USD", "143.27", 2)

    %{running: running, taking: season!(3, DateTime.add(boundary, 6, :hour))}
  end

  test "a Key holder locks a pick, changes it, and is told why one is refused", %{conn: conn} do
    {:ok, view, _html} = live(signed_in_as(conn, @holder), @path)

    assert has_element?(view, "#fleet-season-holding", "SOL-USD")
    assert has_element?(view, "#fleet-season-holding", "$143.27")
    assert has_element?(view, "#fleet-season-captain", "Key 2")
    assert has_element?(view, "#fleet-season-clock")
    assert has_element?(view, "#fleet-season-last", "+2.50%")
    assert has_element?(view, "#fleet-season-last", "Crown passed")
    assert has_element?(view, "#fleet-season-taking", "Season 3 · 0 Keys locked")
    refute has_element?(view, "#fleet-season-mine")

    view
    |> form("#fleet-season-form", pick: %{product: "ETH-USD", reason: "Cheaper gas"})
    |> render_submit()

    assert has_element?(view, "#fleet-season-note", "Locked.")
    assert has_element?(view, "#fleet-season-mine", "ETH-USD")
    assert has_element?(view, "#fleet-season-mine", "Cheaper gas")
    assert has_element?(view, "#fleet-season-pick", "Changing your pick gives up its place.")
    assert has_element?(view, "#fleet-season-taking", "1 Key locked")
    first = Seasons.my_pick!(@fleet, 3, actor: human(@holder))
    assert %{token_id: 1, product: "ETH-USD", reason: "Cheaper gas"} = first

    view
    |> form("#fleet-season-form", pick: %{product: "SOL-USD", reason: ""})
    |> render_submit()

    assert has_element?(view, "#fleet-season-mine", "SOL-USD")
    changed = Seasons.my_pick!(@fleet, 3, actor: human(@holder))
    assert %{product: "SOL-USD", reason: nil} = changed
    assert changed.lock_order > first.lock_order

    # The same domain function the agent's pick goes through refuses these,
    # and a reason's refusal says the rule it broke; 251 emoji, 502 units as
    # a box counts them, are refused as typed, in the rule's words.
    view
    |> element("#fleet-season-form")
    |> render_submit(%{pick: %{product: "THIN-USD"}})

    assert has_element?(view, "#fleet-season-note[data-refused]", "isn’t open to picks")

    for {reason, rule} <- [
          {"Line one\nline two", :plain},
          {"\u{3164}", :blank},
          {String.duplicate("😀", 251), :too_long}
        ] do
      view
      |> element("#fleet-season-form")
      |> render_submit(%{pick: %{product: "SOL-USD", reason: reason}})

      note = Exception.message(ReasonError.exception(rule: rule))
      assert has_element?(view, "#fleet-season-note[data-refused]", note), inspect(reason)
    end

    # The box keeps what was refused, so the next press sends it again unless
    # it is cleared.
    SharedReading.degraded(CoinList.key())

    view
    |> element("#fleet-season-form")
    |> render_submit(%{pick: %{product: "ETH-USD", reason: ""}})

    assert has_element?(view, "#fleet-season-note", "isn’t read yet")

    assert %{product: "SOL-USD"} = Seasons.my_pick!(@fleet, 3, actor: human(@holder))
  end

  test "a pick sent once its season has started is refused as closed", %{
    conn: conn,
    running: running,
    taking: taking
  } do
    {:ok, view, _html} = live(signed_in_as(conn, @holder), @path)

    # A turn that locks the season but whose notice hasn't reached the page.
    settle!(running, "150", "0.047")
    lock!(taking, "SOL-USD", "150", 2)

    view |> element("#fleet-season-form") |> render_submit(%{pick: %{product: "ETH-USD"}})
    assert has_element?(view, "#fleet-season-note[data-refused]", "Season closed.")
  end

  test "anyone holding no Key sees the season but no form and no pick", %{conn: conn} do
    pick!(@other, 3, "ETH-USD", @secret)
    FleetNow.read(@fleet)

    for reader <- [build_conn(), signed_in_as(conn, @outsider)] do
      {:ok, view, html} = live(reader, @path)

      assert has_element?(view, "#fleet-season-holding", "SOL-USD")
      assert has_element?(view, "#fleet-season-captain", "Key 2")
      assert has_element?(view, "#fleet-season-last", "Crown passed")
      refute has_element?(view, "#fleet-season-form")
      refute has_element?(view, "#fleet-season-pick")
      refute has_element?(view, "#fleet-season-picks")

      for page <- [html, render(view)] do
        refute page =~ @running_reason
        refute page =~ @secret
        refute page =~ "Keys locked"
      end
    end
  end

  test "another Key's pick never reaches a member's page before its season starts", %{conn: conn} do
    pick!(@other, 3, "ETH-USD", @secret)

    {:ok, view, html} = live(signed_in_as(conn, @holder), @path)

    # The season under way's picks are the members' to read.
    assert has_element?(view, "#fleet-season-pick-2", @running_reason)
    assert has_element?(view, "#fleet-season-taking", "1 Key locked")
    refute has_element?(view, "#fleet-season-mine")

    # Nothing sent to the page, nor anything the page holds, carries it.
    refute html =~ @secret
    refute render(view) =~ @secret
    refute view.pid |> :sys.get_state() |> inspect(limit: :infinity) =~ @secret

    pick!(@other, 3, "SOL-USD", @secret <> " again")
    refute render(view) =~ @secret
    refute view.pid |> :sys.get_state() |> inspect(limit: :infinity) =~ @secret
  end

  test "a pick locked by another Key and the fleet's turn reach open pages", %{
    conn: conn,
    running: running,
    taking: taking
  } do
    FleetNow.read(@fleet)
    {:ok, member, _html} = live(signed_in_as(conn, @holder), @path)
    {:ok, visitor, _html} = live(build_conn(), @path)

    assert has_element?(member, "#fleet-season-taking", "0 Keys locked")

    pick!(@other, 3, "ETH-USD", nil)
    assert has_element?(member, "#fleet-season-taking", "1 Key locked")

    # The turn: season 2 settles down 10%, Key 2's ETH-USD pick doesn't take
    # the crown, and season 4 opens for picks.
    settle!(running, "128.943", "-0.1")
    lock!(taking, "SOL-USD", "128.943", 2)
    season!(4, DateTime.add(taking.starts_at, 3, :hour))

    assert has_element?(member, "#fleet-season-holding", "$128.943")
    assert has_element?(member, "#fleet-season-last", "−10.00%")
    assert has_element?(member, "#fleet-season-last", "Crown kept")
    assert has_element?(member, "#fleet-season-taking", "Season 4 · 0 Keys locked")
    assert has_element?(member, "#fleet-season-pick-2", "ETH-USD")

    # A visitor's page draws the fleet's next reading.
    FleetNow.read(@fleet)
    assert has_element?(visitor, "#fleet-season-holding", "$128.943")
    assert has_element?(visitor, "#fleet-season-last", "Crown kept")
  end

  # The clock past season 2's end with its turn not yet run, as after a
  # boundary: neither the agent's answer nor the panel calls it under way,
  # and the panel's clock gives a word, not a count to a time gone, until the
  # turn's notice arrives.
  test "between a season's end and its turn, nothing counts it as under way", %{
    conn: conn,
    running: running,
    taking: taking
  } do
    boundary = Seasons.boundary(DateTime.utc_now())
    hours_ago!(6)
    FleetNow.read(@fleet)

    assert {200, %{running: nil, taking_picks: nil, last_settled: nil}, nil} =
             Answer.answer(:show, %{"fleet_id" => @fleet}, human(@holder), nil)

    {:ok, member, _html} = live(signed_in_as(conn, @holder), @path)
    {:ok, visitor, _html} = live(build_conn(), @path)

    for view <- [member, visitor] do
      assert has_element?(view, "#fleet-season-holding", "SOL-USD")
      assert run_out?(view)
    end

    # The turn: season 2 settles, season 3 is under way and season 4 opens.
    settle!(running, "150", "0.047")
    lock!(taking, "SOL-USD", "150", 2)
    season!(4, DateTime.add(boundary, 3, :hour))

    assert {200, %{running: %{number: 3}, taking_picks: %{number: 4}}, nil} =
             Answer.answer(:show, %{"fleet_id" => @fleet}, human(@holder), nil)

    refute run_out?(member)
    FleetNow.read(@fleet)
    refute run_out?(visitor)
  end

  @tag pickers: 11
  test "the season under way's picks show ten at a time", %{conn: conn} do
    {:ok, view, _html} = live(signed_in_as(conn, @holder), @path)

    assert view |> element("#fleet-season-pick-list") |> render() |> count_rows() == 10
    view |> element("#fleet-season-more") |> render_click()
    assert view |> element("#fleet-season-pick-list") |> render() |> count_rows() == 12
    refute has_element?(view, "#fleet-season-more")
  end

  defp count_rows(html), do: html |> String.split("<li") |> length() |> Kernel.-(1)

  # Whether the season's clock writes its words for a time run out.
  defp run_out?(view) do
    clock = view |> element("#fleet-season-clock") |> render() |> LazyHTML.from_fragment()
    LazyHTML.attribute(clock, "data-done") == [LazyHTML.text(clock)]
  end

  # The fleet's seasons, every one, `hours` earlier, as if the clock had run
  # that far past them.
  defp hours_ago!(hours) do
    Repo.update_all(
      from(season in "seasons",
        where: season.fleet_id == ^@fleet,
        update: [
          set: [
            starts_at: fragment("? - make_interval(hours => ?)", season.starts_at, ^hours),
            ends_at: fragment("? - make_interval(hours => ?)", season.ends_at, ^hours)
          ]
        ]
      ),
      [],
      prefix: "keyfleet_app"
    )
  end

  defp season!(number, starts_at) do
    Season
    |> Ash.Changeset.for_create(:open, %{fleet_id: @fleet, number: number, starts_at: starts_at},
      actor: @system
    )
    |> Ash.create!()
  end

  defp lock!(season, holding, price, captain) do
    season
    |> Ash.Changeset.for_update(
      :lock,
      %{holding: holding, holding_open_price: Decimal.new(price), captain_key: captain},
      actor: @system
    )
    |> Ash.update!()
  end

  defp settle!(season, close, result) do
    season
    |> Ash.Changeset.for_update(
      :settle,
      %{holding_close_price: Decimal.new(close), holding_result: Decimal.new(result)},
      actor: @system
    )
    |> Ash.update!()
  end

  defp pick!(wallet, number, product, reason),
    do: Seasons.pick!(@fleet, number, %{product: product, reason: reason}, actor: human(wallet))

  defp human(wallet), do: %Human{human_account_id: 1, wallet_addresses: [wallet]}

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:seasons:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: @system
      )

    init_test_session(conn, %{human_account_id: account.id})
  end
end

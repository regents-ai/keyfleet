defmodule KeyfleetWeb.Live.SeasonsPageTest do
  # A fleet's record of settled seasons, for anyone: twenty at a time, the
  # day's result over the newest eight, and a season's picks a hundred at a
  # time under its row; the page keeps the last hundred seasons and two
  # hundred picks it was given.
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.SeasonHelpers
  alias Keyfleet.Seasons
  alias Keyfleet.Seasons.Season
  alias Keyfleet.SharedReading
  alias KeyfleetWeb.FleetNow

  @fleet "fibonacci_syndicate"
  @path "/syndicate/1/seasons"
  @system %Actors.System{}

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    SharedReading.delete(FleetNow.key(@fleet))
    on_exit(fn -> SharedReading.delete(FleetNow.key(@fleet)) end)
    :ok
  end

  # Season 1 lost half, seasons 2 to 9 each gained a tenth, season 10 runs
  # and season 11 takes picks: the day is the newest eight, 1.1⁸ less one.
  test "anyone reads the settled seasons alone, newest first, and the day's result",
       %{conn: conn} do
    settled!(1, "100", "50", nil)
    for number <- 2..9, do: settled!(number, "100", "110", 2)
    10 |> open!(10) |> lock!("143.27", 2)
    open!(11, 11)

    {:ok, view, html} = live(conn, @path)

    assert has_element?(view, "#seasons-day", "+114.36%")
    assert has_element?(view, "#seasons-day", "8 seasons")
    assert shown_numbers(html) == Enum.to_list(9..1//-1)
    refute has_element?(view, "#seasons-10")
    refute has_element?(view, "#seasons-11")
    refute has_element?(view, "#seasons-more")

    assert view |> element("#seasons-9") |> render() =~ "SOL-USD"
    assert has_element?(view, "#seasons-9 td", "Key 2")
    assert has_element?(view, "#seasons-9 td", "+10.00%")
    assert has_element?(view, "#seasons-1 td", "−50.00%")
    assert has_element?(view, "#seasons-1 td", "—")
    assert has_element?(view, "#seasons-9 time")
    assert has_element?(view, "#seasons-page a[href*='coinbase-mcp']", "Coinbase")
  end

  test "the hall's Record opens the record", %{conn: conn} do
    settled!(1, "100", "110", nil)
    2 |> open!(2) |> lock!("110", nil)
    FleetNow.read(@fleet)

    {:ok, view, _html} = live(conn, "/syndicate/1")
    view |> element("#fleet-season-record") |> render_click()

    assert_patch(view, @path)
    assert has_element?(view, "#seasons-1")
    refute has_element?(view, "#fleet-season")
  end

  test "with fewer than eight settled the day is those, and with none the page says so",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#seasons-empty", "No season has ended yet.")
    refute has_element?(view, "#seasons-day")
    refute has_element?(view, "#seasons-table")

    settled!(1, "100", "110", nil)
    settled!(2, "100", "110", 2)
    settled!(3, "100", "90", 2)

    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#seasons-day", "+8.90%")
    assert has_element?(view, "#seasons-day", "3 seasons")
  end

  # Coinbase had no price for season 1's holding at its end.
  test "a season with no result shows a dash, and so does the day when no season has one",
       %{conn: conn} do
    1
    |> open!(1)
    |> lock!("100", 1)
    |> Ash.Changeset.for_update(:settle, %{holding_close_price: nil, holding_result: nil},
      actor: @system
    )
    |> Ash.update!()

    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#seasons-1 td", "Key 1")
    assert has_element?(view, "#seasons-1 td.seasons-table__figure", "—")
    assert has_element?(view, "#seasons-day .seasons-day__figure", "—")

    settled!(2, "100", "110", 2)

    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#seasons-day", "+10.00%")
    assert has_element?(view, "#seasons-day", "2 seasons")
  end

  test "the record shows twenty seasons at a time", %{conn: conn} do
    for number <- 1..21, do: settled!(number, "100", "101", nil)

    {:ok, view, html} = live(conn, @path)
    assert shown_numbers(html) == Enum.to_list(21..2//-1)

    view |> element("#seasons-more") |> render_click()
    assert shown_numbers(render(view)) == Enum.to_list(21..1//-1)
    refute has_element?(view, "#seasons-more")
  end

  test "a page pressed past a hundred seasons keeps the last hundred, and one opens at a time",
       %{conn: conn} do
    for number <- 1..101, do: settled!(number, "100", "101", nil)

    {:ok, view, _html} = live(conn, @path)
    for _page <- 1..5, do: view |> element("#seasons-more") |> render_click()

    refute has_element?(view, "#seasons-101")
    assert shown_numbers(render(view)) == Enum.to_list(100..1//-1)
    refute has_element?(view, "#seasons-more")
    assert has_element?(view, "#seasons-day", "8 seasons")

    view |> element("#seasons-1 button") |> render_click()
    assert has_element?(view, "#seasons-1 button[aria-expanded=true]")
    assert has_element?(view, "#seasons-1-picks", "No Key picked this season.")

    view |> element("#seasons-2 button") |> render_click()
    assert has_element?(view, "#seasons-2 button[aria-expanded=true]")
    assert has_element?(view, "#seasons-1 button[aria-expanded=false]")
    assert has_element?(view, "#seasons-1-picks[hidden]")
    refute has_element?(view, "#seasons-2-picks[hidden]")
  end

  # Season 1 played by its turns with a pick from each of 201 Keys.
  test "a season's row opens to its picks, a hundred at a time, keeping the last two hundred",
       %{conn: conn} do
    [b0, b1, b2 | _] = SeasonHelpers.boundaries(2)
    SeasonHelpers.coinbase!(%{"SOL-USD" => [{b1, "100"}, {b2, "103"}]})
    SeasonHelpers.turn!(@fleet, b0)

    for key <- 1..201 do
      wallet = "0x" <> String.pad_leading(Integer.to_string(key), 40, "0")
      holds!(key, wallet)
      reason = if key == 1, do: "Fast chain"
      human = %Actors.Human{human_account_id: key, wallet_addresses: [wallet]}
      Seasons.pick!(@fleet, 1, %{product: "SOL-USD", reason: reason}, actor: human)
    end

    SeasonHelpers.turn!(@fleet, b1)
    SeasonHelpers.turn!(@fleet, b2)

    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#seasons-1 td", "201")
    assert has_element?(view, "#seasons-1 button[aria-expanded=false]")
    assert has_element?(view, "#seasons-1-picks[hidden]")

    view |> element("#seasons-1 button") |> render_click()

    assert has_element?(view, "#seasons-1 button[aria-expanded=true]")
    refute has_element?(view, "#seasons-1-picks[hidden]")
    assert has_element?(view, "#seasons-1-pick-1", "SOL-USD")
    assert has_element?(view, "#seasons-1-pick-1", "+3.00%")
    assert has_element?(view, "#seasons-1-pick-1 q", "Fast chain")
    assert shown_picks(view) == Enum.to_list(1..100)

    view |> element("#seasons-1-picks-more") |> render_click()
    assert shown_picks(view) == Enum.to_list(1..200)

    view |> element("#seasons-1-picks-more") |> render_click()
    assert shown_picks(view) == Enum.to_list(2..201)
    assert has_element?(view, "#seasons-1-pick-201", "Key 201")
    refute has_element?(view, "#seasons-1-picks-more")

    view |> element("#seasons-1 button") |> render_click()
    assert has_element?(view, "#seasons-1 button[aria-expanded=false]")
    assert has_element?(view, "#seasons-1-picks[hidden]")
    refute has_element?(view, "#seasons-1-pick-list")
  end

  # Season 1 with a pick from each of 101 Keys, season 2 with none. A season
  # closed and opened again before the page has answered, as a double click
  # sends it, or by way of another season, keeps its list on the page; the
  # list starts again at its first hundred all the same.
  test "a season opened again before the page answers starts at its first hundred",
       %{conn: conn} do
    [b0, b1, b2, b3 | _] = SeasonHelpers.boundaries(3)
    SeasonHelpers.coinbase!(%{"SOL-USD" => [{b1, "100"}, {b2, "103"}, {b3, "104"}]})
    SeasonHelpers.turn!(@fleet, b0)

    for key <- 1..101 do
      wallet = "0x" <> String.pad_leading(Integer.to_string(key), 40, "0")
      holds!(key, wallet)
      human = %Actors.Human{human_account_id: key, wallet_addresses: [wallet]}
      Seasons.pick!(@fleet, 1, %{product: "SOL-USD"}, actor: human)
    end

    for boundary <- [b1, b2, b3], do: SeasonHelpers.turn!(@fleet, boundary)

    {:ok, view, _html} = live(conn, @path)
    view |> element("#seasons-1 button") |> render_click()
    view |> element("#seasons-1-picks-more") |> render_click()
    assert shown_picks(view) == Enum.to_list(1..101)

    back_to_back(view, ["#seasons-1 button", "#seasons-1 button"])
    assert has_element?(view, "#seasons-1 button[aria-expanded=true]")
    assert shown_picks(view) == Enum.to_list(1..100)

    view |> element("#seasons-1-picks-more") |> render_click()
    assert shown_picks(view) == Enum.to_list(1..101)

    back_to_back(view, ["#seasons-2 button", "#seasons-1 button"])
    assert has_element?(view, "#seasons-2-picks[hidden]")
    assert shown_picks(view) == Enum.to_list(1..100)
  end

  # Presses sent one after another before the page answers any, as a browser
  # sends a double click: the page is held while the first reaches it, and
  # the test client queues the rest behind the first's answer.
  defp back_to_back(view, [first | rest]) do
    {_ref, _topic, client} = view.proxy
    :sys.suspend(view.pid)
    pressed = [Task.async(fn -> view |> element(first) |> render_click() end)]
    queued!(view.pid)

    pressed =
      Enum.reduce(rest, pressed, fn selector, pressed ->
        press = Task.async(fn -> view |> element(selector) |> render_click() end)
        queued!(client)
        [press | pressed]
      end)

    :sys.resume(view.pid)
    pressed |> Enum.reverse() |> Enum.each(&Task.await/1)
  end

  # Waits, a few milliseconds at a time for at most a second, until `pid`
  # has a message waiting.
  defp queued!(pid, tries \\ 500)
  defp queued!(pid, 0), do: flunk("#{inspect(pid)} never had a message waiting")

  defp queued!(pid, tries) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queued} when queued > 0 ->
        :ok

      _none ->
        receive do
        after
          2 -> queued!(pid, tries - 1)
        end
    end
  end

  defp shown_numbers(html) do
    ~r/<tr id="seasons-(\d+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [number] -> String.to_integer(number) end)
  end

  defp shown_picks(view) do
    ~r/<li id="seasons-1-pick-(\d+)"/
    |> Regex.scan(view |> element("#seasons-1-pick-list") |> render(), capture: :all_but_first)
    |> Enum.map(fn [key] -> String.to_integer(key) end)
  end

  # A season opened, locked holding SOL-USD and settled with its holding's
  # prices and result, three hours after the one before.
  defp settled!(number, open, close, captain) do
    number
    |> open!(number)
    |> lock!(open, captain)
    |> Ash.Changeset.for_update(
      :settle,
      %{
        holding_close_price: Decimal.new(close),
        holding_result: close |> Decimal.new() |> Decimal.div(Decimal.new(open)) |> Decimal.sub(1)
      },
      actor: @system
    )
    |> Ash.update!()
  end

  defp open!(number, place) do
    starts_at = DateTime.add(Seasons.boundary(DateTime.utc_now()), 3 * (place - 30), :hour)

    Season
    |> Ash.Changeset.for_create(:open, %{fleet_id: @fleet, number: number, starts_at: starts_at},
      actor: @system
    )
    |> Ash.create!()
  end

  defp lock!(season, open, captain) do
    season
    |> Ash.Changeset.for_update(
      :lock,
      %{holding: "SOL-USD", holding_open_price: Decimal.new(open), captain_key: captain},
      actor: @system
    )
    |> Ash.update!()
  end

  defp holds!(key, wallet) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: key,
        ownership_epoch: 1,
        owner_wallet: wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("b", 64),
        log_index: key
      },
      actor: @system
    )
  end
end

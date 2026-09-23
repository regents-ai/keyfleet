defmodule KeyFleetWeb.Live.ProposalsPageTest do
  use KeyFleetWeb.ConnCase, async: false

  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.ProposalHelpers
  alias KeyFleet.Proposals

  @fleet "fibonacci_syndicate"
  @list "/app/fleets/fibonacci_syndicate/proposals"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @voter ProposalHelpers.wallet("e")
  @rule KeyFleetWeb.ProposalsLive.pass_rule()

  setup do
    Fleets.bootstrap_catalog!()

    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: "0x" <> String.duplicate("7", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: @usdc,
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )

    :ok
  end

  test "anyone can read every proposal and where each one stands, with nothing to sign", %{
    conn: conn
  } do
    now = DateTime.utc_now()
    closed = DateTime.add(now, -3600)
    ChainHelpers.seed_cursor!(@fleet, read_through_at: DateTime.add(now, -60))

    ProposalHelpers.proposal!(@fleet, 1, text: "Hire a designer", text_bytes: 15)
    ProposalHelpers.proposal!(@fleet, 2, closes_at: closed, eligible_keys: 7)
    votes!(2, true: [1, 2, 3, 4])
    ProposalHelpers.proposal!(@fleet, 3, closes_at: closed, eligible_keys: 6)
    votes!(3, true: [1, 2, 3], false: [4])
    ProposalHelpers.proposal!(@fleet, 4, closes_at: DateTime.add(now, -30))
    ProposalHelpers.proposal!(@fleet, 5, kind: :pay, closes_at: closed, eligible_keys: 1)
    votes!(5, true: [1])
    ProposalHelpers.execution!(@fleet, 5, @voter)

    ProposalHelpers.proposal!(@fleet, 6,
      kind: :pay,
      closes_at: closed,
      eligible_keys: 1,
      execution_expiry: Decimal.new(DateTime.to_unix(now) - 1)
    )

    votes!(6, true: [1])
    ProposalHelpers.proposal!(@fleet, 7, kind: :autolaunch, closes_at: closed, eligible_keys: 1)
    votes!(7, true: [1])
    ProposalHelpers.execution!(@fleet, 7, @voter)

    {:ok, view, html} = live(conn, @list)

    assert has_element?(view, ".proposals-rule", @rule)
    refute html =~ "Vote counts are catching up."
    refute has_element?(view, "#proposals-page button")

    assert cards(view) == [
             {"7", "Launch", "Launched"},
             {"6", "Payment from the budget", "Expired"},
             {"5", "Payment from the budget", "Paid"},
             {"4", "Decision", "Counting votes"},
             {"3", "Decision", "Did not pass"},
             {"2", "Decision", "Passed"},
             {"1", "Decision", "Voting open"}
           ]

    assert has_element?(view, ~s([data-proposal="1"]), "Hire a designer")
    assert has_element?(view, ~s([data-proposal="3"]), "3 yes, 1 no, of 6 keys that could vote")

    view |> element(~s([data-proposal="2"] a)) |> render_click()
    assert_redirect(view, "/app/fleets/#{@fleet}/proposals/2")
  end

  test "a proposal's page shows its text, its outcome and every vote, fifty at a time", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.proposal!(@fleet, 1, text: "Hire a designer\nfor the launch", text_bytes: 30)
    for token_id <- 1..51, do: ProposalHelpers.vote!(@fleet, 1, @voter, true, [token_id])

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert has_element?(view, "#proposal-status", "Voting open")
    # Its line breaks are kept as written.
    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#proposal-text")
           |> LazyHTML.text() ==
             "Hire a designer\nfor the launch"

    assert has_element?(view, "#proposal-yes", "51 keys")
    assert has_element?(view, ".proposals-rule", @rule)
    refute has_element?(view, "#proposal-page button")
    assert length(votes(view)) == 50
    assert hd(votes(view)) =~ "with key 1"

    view |> element("#proposal-more-votes") |> render_click()
    assert [only] = votes(view)
    assert only =~ "with key 51"

    view |> element("#proposal-first-votes") |> render_click()
    assert length(votes(view)) == 50
  end

  test "a payment names what it pays, to whom and until when", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    ProposalHelpers.proposal!(@fleet, 1,
      kind: :pay,
      asset: @usdc,
      amount: Decimal.new(12_500_000),
      execution_expiry: Decimal.new(DateTime.to_unix(~U[2026-11-01 09:30:00Z]))
    )

    ProposalHelpers.proposal!(@fleet, 2,
      kind: :pay,
      asset: ProposalHelpers.wallet("c"),
      amount: Decimal.new(1_234)
    )

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert has_element?(view, "#proposal-payment", "12.5 USDC")
    assert has_element?(view, "#proposal-payment", ProposalHelpers.wallet("b"))

    assert has_element?(
             view,
             "#proposal-last-day",
             "Can be paid until 1 November 2026 at 09:30 UTC"
           )

    {:ok, other, _html} = live(conn, "#{@list}/2")

    assert has_element?(
             other,
             "#proposal-payment",
             "1,234 units of #{ProposalHelpers.wallet("c")}"
           )
  end

  test "a launch shows its five fields exactly as proposed, once they have been read", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)

    proposal =
      ProposalHelpers.proposal!(@fleet, 1,
        kind: :autolaunch,
        execution_expiry: Decimal.new(DateTime.to_unix(~U[2026-10-07 18:00:00Z]))
      )

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-launch-pending", "Launch details are still being read.")
    refute has_element?(view, "#proposal-launch")

    ProposalHelpers.launch_envelope!(proposal,
      name: "Cascade  Research",
      description: "Line one\nLine <two>",
      required_regent_raised: Decimal.new("250000500000000000000000")
    )

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert fields(view) == [
             {"Name", "Cascade  Research"},
             {"Symbol", "CSR"},
             {"Description", "Line one\nLine <two>"},
             {"Website", "https://example.test"},
             {"Image", "ipfs://cascade"},
             {"REGENT to raise", "250,000.5 REGENT"}
           ]

    assert has_element?(
             view,
             "#proposal-last-day",
             "Can be launched until 7 October 2026 at 18:00 UTC"
           )
  end

  test "while votes are still being read the page says so", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
    ProposalHelpers.proposal!(@fleet, 1)

    for path <- [@list, "#{@list}/1"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#proposals-catching-up", "Vote counts are catching up.")
    end
  end

  test "a fleet or proposal that isn't there says so, and a name that can't be one is not found",
       %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, _view, html} = live(conn, "/app/fleets/hull_survey/proposals")
    assert html =~ "This fleet doesn’t exist."

    {:ok, _view, html} = live(conn, "/app/fleets/hull_survey/proposals/1")
    assert html =~ "This fleet doesn’t exist."

    {:ok, view, html} = live(conn, "#{@list}/9")
    assert html =~ "There is no proposal 9 in this fleet yet."
    assert has_element?(view, "#proposal-missing a[href='#{@list}']")

    {:ok, _view, html} = live(conn, @list)
    assert html =~ "No proposals have been made yet."

    for path <- [
          "#{@list}/0",
          "#{@list}/01",
          "#{@list}/one",
          "#{@list}/#{String.duplicate("9", 19)}",
          "#{@list}?before=0",
          "#{@list}?before=x",
          "#{@list}/1?votes_after=-1"
        ] do
      assert_raise KeyFleetWeb.NotFoundError, fn -> live(conn, path) end
    end
  end

  test "proposals are listed twenty at a time, newest first", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    for number <- 1..21, do: ProposalHelpers.proposal!(@fleet, number)

    {:ok, view, _html} = live(conn, @list)
    assert Enum.map(cards(view), &elem(&1, 0)) == Enum.map(21..2//-1, &to_string/1)
    refute has_element?(view, "#proposals-newest")

    view |> element("#proposals-older") |> render_click()
    assert Enum.map(cards(view), &elem(&1, 0)) == ["1"]
    refute has_element?(view, "#proposals-older")

    view |> element("#proposals-newest") |> render_click()
    assert length(cards(view)) == 20
  end

  test "a notice that votes were recorded has an open page read them again", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.proposal!(@fleet, 1)

    {:ok, view, _html} = live(conn, "#{@list}/1")
    {:ok, list, _html} = live(conn, @list)
    assert has_element?(view, "#proposal-yes", "0 keys")

    ProposalHelpers.vote!(@fleet, 1, @voter, true, [1, 2])
    assert has_element?(view, "#proposal-yes", "0 keys")

    Phoenix.PubSub.broadcast(
      KeyFleet.PubSub,
      Proposals.topic(@fleet),
      {:proposals_changed, @fleet}
    )

    assert shows?(fn -> has_element?(view, "#proposal-yes", "2 keys") end)
    assert shows?(fn -> has_element?(list, ~s([data-proposal="1"]), "2 yes, 0 no") end)
  end

  test "a proposal on show that closes is shown being counted without anything new recorded",
       %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.proposal!(@fleet, 1, closes_at: DateTime.add(DateTime.utc_now(), 1))

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-status", "Voting open")

    assert shows?(fn -> has_element?(view, "#proposal-status", "Counting votes") end, 80)
  end

  test "the fleet's page leads to its proposals", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/fleets/#{@fleet}")
    assert has_element?(view, "#fleet-proposals-link[href='#{@list}']", "See the proposals")
  end

  defp votes!(number, sides) do
    for {support, token_ids} <- sides,
        do: ProposalHelpers.vote!(@fleet, number, @voter, support, token_ids)
  end

  defp cards(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-proposal]")
    |> Enum.map(fn card ->
      [kind, status] =
        card |> LazyHTML.query(".proposals-kind span") |> Enum.map(&text/1)

      {card |> LazyHTML.attribute("data-proposal") |> hd(), kind, status}
    end)
  end

  defp votes(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#proposal-votes li")
    |> Enum.map(&text/1)
  end

  defp fields(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#proposal-launch div")
    |> Enum.map(fn field ->
      {field |> LazyHTML.query("dt") |> LazyHTML.text(),
       field |> LazyHTML.query("dd") |> LazyHTML.text()}
    end)
  end

  defp text(node), do: node |> LazyHTML.text() |> String.trim()

  # Polls every tenth of a second, `tries` times.
  defp shows?(check, tries \\ 30) do
    Enum.any?(1..tries, fn _try ->
      check.() or
        (
          Process.sleep(100)
          false
        )
    end)
  end
end

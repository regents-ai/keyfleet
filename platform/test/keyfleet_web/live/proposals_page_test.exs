defmodule KeyfleetWeb.Live.ProposalsPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.WorkspaceFixtures

  @fleet "fibonacci_syndicate"
  @list "/app/fleets/fibonacci_syndicate/proposals"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @voter ProposalHelpers.wallet("e")
  @holder ProposalHelpers.wallet("1")
  @votes "0x" <> String.duplicate("9", 40)
  @fleet_contract "0x" <> String.duplicate("7", 40)
  @rule KeyfleetWeb.ProposalsLive.pass_rule()

  setup do
    Fleets.bootstrap_catalog!()

    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: @fleet_contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: @votes,
        usdc_address: @usdc,
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )

    :ok
  end

  test "anyone can read every proposal and where each one stands", %{conn: conn} do
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
    assert length(votes(view)) == 50
    assert hd(votes(view)) =~ "with key 1"

    view |> element("#proposal-more-votes") |> render_click()
    assert [only] = votes(view)
    assert only =~ "with key 51"

    view |> element("#proposal-first-votes") |> render_click()
    assert length(votes(view)) == 50
  end

  test "a payment names what it pays, to whom and until when", %{conn: conn} do
    now = DateTime.utc_now()
    ChainHelpers.seed_cursor!(@fleet, read_through_at: DateTime.add(now, -60))
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    ProposalHelpers.proposal!(@fleet, 1,
      kind: :pay,
      asset: @usdc,
      amount: Decimal.new(12_500_000),
      closes_at: DateTime.add(now, -3600),
      eligible_keys: 1,
      execution_expiry: Decimal.new(DateTime.to_unix(~U[2126-11-01 09:30:00Z]))
    )

    votes!(1, true: [1])

    ProposalHelpers.proposal!(@fleet, 2,
      kind: :pay,
      asset: ProposalHelpers.wallet("c"),
      amount: Decimal.new(1_234)
    )

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert fields(view, "#proposal-payment div") == [
             {"Amount", "12.5 USDC"},
             {"Paid to", ProposalHelpers.wallet("b")}
           ]

    refute has_element?(view, "#proposal-payment .proposals-token")

    assert has_element?(
             view,
             "#proposal-last-day",
             "Can be paid until 1 November 2126 at 09:30 UTC"
           )

    # An asset whose token has not been asked yet is shown as the chain
    # holds it, with the token's address.
    other_token = ProposalHelpers.wallet("c")
    {:ok, other, _html} = live(conn, "#{@list}/2")

    assert amount(other, "#proposal-payment div:first-child dd") ==
             {"1,234 in the smallest units of token 0xcccc…cccc", other_token}

    # Once the token has told its symbol and decimals, it is named, and its
    # address is still beside it.
    ProposalHelpers.asset_details!(@fleet, other_token, "WETH", 18)
    {:ok, named, _html} = live(conn, "#{@list}/2")

    assert amount(named, "#proposal-payment div:first-child dd") ==
             {"0.000000000000001234 WETH 0xcccc…cccc", other_token}
  end

  # Only the fleet's own USDC, known by its address, is shown without one. A
  # token anywhere else that calls itself USDC always has its address beside
  # every amount of it.
  test "a token calling itself USDC is shown with its address", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    fake = ProposalHelpers.wallet("d")
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)
    ProposalHelpers.asset_details!(@fleet, fake, "USDC", 6)

    ProposalHelpers.proposal!(@fleet, 1, kind: :pay, asset: fake, amount: 2_000_000)
    ProposalHelpers.proposal!(@fleet, 2, kind: :pay, asset: @usdc, amount: 2_000_000)

    ProposalHelpers.treasury_reading!(@fleet, [
      balance(@usdc, free_capital: 1_000_000),
      balance(fake, free_capital: 1_000_000, backed: 3_000_000)
    ])

    ProposalHelpers.income_split!(@fleet, asset: fake)
    ProposalHelpers.budget_payment!(@fleet, asset: fake)

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert amount(view, "#proposal-payment div:first-child dd") == {"2 USDC 0xdddd…dddd", fake}

    {:ok, view, _html} = live(conn, "#{@list}/2")
    assert amount(view, "#proposal-payment div:first-child dd") == {"2 USDC", nil}

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{fake}'] div") == [
             {"Budget", "1 USDC 0xdddd…dddd"},
             {"Available this month", "0.2 USDC 0xdddd…dddd"},
             {"Set aside for key holders", "3 USDC 0xdddd…dddd"}
           ]

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Budget", "1 USDC"},
             {"Available this month", "0.2 USDC"},
             {"Set aside for key holders", "0 USDC"}
           ]

    tokens =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        "#proposals-income .proposals-token, #proposals-payments .proposals-token"
      )
      |> Enum.map(&{text(&1), &1 |> LazyHTML.attribute("title") |> hd()})

    assert tokens == List.duplicate({"0xdddd…dddd", fake}, 5)
  end

  # How long a proposal can be carried out for matters only while it has
  # passed and waits to be.
  test "the last day to carry a proposal out shows only while it waits to be", %{conn: conn} do
    now = DateTime.utc_now()
    closed = DateTime.add(now, -3600)
    later = Decimal.new(DateTime.to_unix(now) + 86_400)
    ChainHelpers.seed_cursor!(@fleet, read_through_at: DateTime.add(now, -60))

    ProposalHelpers.proposal!(@fleet, 1, kind: :pay, execution_expiry: later)

    ProposalHelpers.proposal!(@fleet, 2,
      kind: :pay,
      closes_at: closed,
      eligible_keys: 2,
      execution_expiry: later
    )

    votes!(2, true: [1])

    for number <- 3..4 do
      ProposalHelpers.proposal!(@fleet, number,
        kind: :pay,
        closes_at: closed,
        eligible_keys: 1,
        execution_expiry: later
      )

      votes!(number, true: [1])
    end

    ProposalHelpers.execution!(@fleet, 4, @voter)

    ProposalHelpers.proposal!(@fleet, 5,
      kind: :pay,
      closes_at: closed,
      eligible_keys: 1,
      execution_expiry: Decimal.new(DateTime.to_unix(now) - 1)
    )

    votes!(5, true: [1])

    for {number, status, shown?} <- [
          {1, "Voting open", false},
          {2, "Did not pass", false},
          {3, "Passed", true},
          {4, "Paid", false},
          {5, "Expired", false}
        ] do
      {:ok, view, _html} = live(conn, "#{@list}/#{number}")
      assert has_element?(view, "#proposal-status", status)
      assert has_element?(view, "#proposal-last-day") == shown?, "proposal #{number}"
    end
  end

  # A token that will not tell its symbol or its decimals is never guessed at.
  test "an amount in a token that doesn't say what it is shows as the chain holds it", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)

    for {number, character, symbol, decimals} <- [{1, "c", nil, 18}, {2, "d", "ODD", nil}] do
      asset = ProposalHelpers.wallet(character)
      ProposalHelpers.asset_details!(@fleet, asset, symbol, decimals)
      ProposalHelpers.proposal!(@fleet, number, kind: :pay, asset: asset, amount: 1_234_000)

      {:ok, view, _html} = live(conn, "#{@list}/#{number}")

      assert amount(view, "#proposal-payment div:first-child dd") ==
               {"1,234,000 in the smallest units of token #{short(asset)}", asset}
    end

    # The fleet's USDC is known by its address even before its token has
    # said what it is.
    ProposalHelpers.proposal!(@fleet, 3, kind: :pay, asset: @usdc, amount: 1_234_000)
    {:ok, view, _html} = live(conn, "#{@list}/3")

    assert amount(view, "#proposal-payment div:first-child dd") ==
             {"1,234,000 in USDC’s smallest units", nil}
  end

  # The contract holds any uint256, which is shown to the last digit.
  test "the largest amount the contract can hold is shown whole", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)
    max = 2 ** 256 - 1

    ProposalHelpers.proposal!(@fleet, 1, kind: :pay, asset: @usdc, amount: Decimal.new(max))

    ProposalHelpers.treasury_reading!(@fleet, [
      balance(@usdc, free_capital: max, backed: max)
    ])

    whole =
      "115,792,089,237,316,195,423,570,985,008,687,907,853,269,984,665,640,564,039,457,584," <>
        "007,913,129.639935 USDC"

    fifth =
      "23,158,417,847,463,239,084,714,197,001,737,581,570,653,996,933,128,112,807,891,516," <>
        "801,582,625.927987 USDC"

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-payment", whole)

    {:ok, list, _html} = live(conn, @list)

    assert fields(list, "[data-asset='#{@usdc}'] div") == [
             {"Budget", whole},
             {"Available this month", fifth},
             {"Set aside for key holders", whole}
           ]
  end

  test "a launch shows its five fields exactly as proposed, once they have been read", %{
    conn: conn
  } do
    now = DateTime.utc_now()
    ChainHelpers.seed_cursor!(@fleet, read_through_at: DateTime.add(now, -60))

    proposal =
      ProposalHelpers.proposal!(@fleet, 1,
        kind: :autolaunch,
        closes_at: DateTime.add(now, -3600),
        eligible_keys: 1,
        execution_expiry: Decimal.new(DateTime.to_unix(~U[2126-10-07 18:00:00Z]))
      )

    votes!(1, true: [1])

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-launch-pending", "Launch details are still being read.")
    refute has_element?(view, "#proposal-launch")

    ProposalHelpers.launch_envelope!(proposal,
      name: "Cascade  Research",
      description: "Line one\nLine <two>",
      required_regent_raised: Decimal.new("250000500000000000000000")
    )

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert fields(view, "#proposal-launch div") == [
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
             "Can be launched until 7 October 2126 at 18:00 UTC"
           )
  end

  describe "a launch's plan" do
    setup do
      ChainHelpers.seed_cursor!(@fleet)
      WorkspaceFixtures.open_log(@fleet)
      :ok
    end

    test "names the plan version the launch points to, and what it says", %{conn: conn} do
      plan = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      launch!(1, digest(plan, 1))

      {:ok, view, _html} = live(conn, "#{@list}/1")

      assert has_element?(
               view,
               ~s|#proposal-plan-version a[href="/app/fleets/#{@fleet}/workspace/launch_card%231"]|,
               "Cascade Research"
             )

      assert text(view, "#proposal-plan-version") ==
               "This launch points to Cascade Research, version 1."

      assert fields(view, "#proposal-plan-fields div") == [
               {"Who it’s for", "Funds that read filings"},
               {"What we offer", "A weekly brief"},
               {"Who does what afterwards", "Key 17 writes the brief"}
             ]

      assert text(view, "#proposal-plan-benefits") ==
               "Who benefits: the fleet receives the launch’s income; after a 2% fee to Regent, " <>
                 "a fifth goes to its budget and the rest to its keys."

      refute has_element?(view, "#proposal-plan-mismatch")
      refute has_element?(view, "#proposal-plan-changed")
      refute has_element?(view, "#proposal-plan-archived")
    end

    test "says when the plan has changed or been archived since", %{conn: conn} do
      plan = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      launch!(1, digest(plan, 1))

      # Archiving alone leaves what the plan says as it was.
      WorkspaceFixtures.archive(@fleet, plan)
      {:ok, view, _html} = live(conn, "#{@list}/1")
      assert has_element?(view, "#proposal-plan-archived", "This plan has since been archived.")
      refute has_element?(view, "#proposal-plan-changed")

      other = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      launch!(2, digest(other, 1))
      WorkspaceFixtures.edit(@fleet, other, %{"what_we_sell" => "A daily brief"})

      {:ok, view, _html} = live(conn, "#{@list}/2")

      assert text(view, "#proposal-plan-changed") =~
               "The plan has changed since; this proposal carries version 1."

      assert text(view, "#proposal-plan-version") =~ "version 1."
      assert {"What we offer", "A weekly brief"} in fields(view, "#proposal-plan-fields div")
      refute has_element?(view, "#proposal-plan-archived")
    end

    test "lists in plain words the launch details that differ from the plan", %{conn: conn} do
      plan = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())

      launch!(1, digest(plan, 1),
        name: "Cascade Research Two",
        required_regent_raised: Decimal.new("250000000000000000000000")
      )

      {:ok, view, _html} = live(conn, "#{@list}/1")

      assert text(view, "#proposal-plan-mismatch") ==
               "These launch details differ from the plan: name, the REGENT to raise."
    end

    test "is not shown for a launch that points to no plan the workspace has", %{conn: conn} do
      launch!(1, "0x" <> String.duplicate("e", 64))
      launch!(2, nil)

      for number <- [1, 2] do
        {:ok, view, _html} = live(conn, "#{@list}/#{number}")

        assert has_element?(
                 view,
                 "#proposal-no-plan",
                 "This launch doesn’t point to a plan in the workspace."
               )

        refute has_element?(view, "#proposal-plan-version")
      end

      ProposalHelpers.proposal!(@fleet, 3)
      {:ok, view, _html} = live(conn, "#{@list}/3")
      refute has_element?(view, "#proposal-plan")
    end

    test "a launch can start from any plan that has all six launch details", %{conn: conn} do
      ready = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      WorkspaceFixtures.edit(@fleet, ready, %{"title" => "Cascade Research, revised"})
      WorkspaceFixtures.create(@fleet, "launch_card", plan_data(%{"image" => nil}))
      WorkspaceFixtures.create(@fleet, "launch_card", plan_data(%{"symbol" => ""}))
      archived = WorkspaceFixtures.create(@fleet, "launch_card", plan_data())
      WorkspaceFixtures.archive(@fleet, archived)

      {:ok, view, _html} = live(conn, @list)

      assert view |> element("#propose-launch-plan") |> render() |> options() == [
               {"", "Don’t use a plan"},
               {digest(ready, 2), "Cascade Research, revised, version 2"}
             ]

      assert has_element?(
               view,
               ~s|#propose-launch-plan option[value="#{digest(ready, 2)}"][data-name="Cascade Research"][data-symbol="CSR"][data-raise="250000.5"]|
             )

      # Going back to the page shows the form as new, never a plan the
      # browser remembers with its details and digest gone.
      assert has_element?(view, ~s|#propose-launch-plan[autocomplete="off"]|)

      assert has_element?(
               view,
               ~s|#propose-launch-digest[type="hidden"][name="digest"][value=""][autocomplete="off"]|
             )

      refute has_element?(
               view,
               ~s|#propose-launch-fields input[name="digest"]:not([type="hidden"])|
             )

      assert pressable?(view, "propose_launch", ["#propose-launch-button"])
    end
  end

  # A launch that passed can be carried out until its last second, and a
  # fleet launches once: after one launch goes ahead, the contract refuses
  # every other.
  test "a passed launch runs out of time, and closes once another launch goes ahead", %{
    conn: conn
  } do
    now = DateTime.utc_now()
    closed = DateTime.add(now, -3600)
    ChainHelpers.seed_cursor!(@fleet, read_through_at: DateTime.add(now, -60))

    for {number, last_second} <- [{1, -1}, {2, 86_400}, {3, 2}, {4, 86_400}] do
      ProposalHelpers.proposal!(@fleet, number,
        kind: :autolaunch,
        closes_at: closed,
        eligible_keys: 1,
        execution_expiry: Decimal.new(DateTime.to_unix(now) + last_second)
      )

      votes!(number, true: [1])
    end

    {:ok, view, _html} = live(conn, @list)

    assert cards(view) == [
             {"4", "Launch", "Passed"},
             {"3", "Launch", "Passed"},
             {"2", "Launch", "Passed"},
             {"1", "Launch", "Expired"}
           ]

    # The page itself notices the last second passing.
    assert shows?(fn -> has_element?(view, ~s([data-proposal="3"]), "Expired") end, 80)

    ProposalHelpers.execution!(@fleet, 4, @voter)
    {:ok, view, _html} = live(conn, @list)

    assert cards(view) == [
             {"4", "Launch", "Launched"},
             {"3", "Launch", "Closed: another launch went ahead"},
             {"2", "Launch", "Closed: another launch went ahead"},
             {"1", "Launch", "Closed: another launch went ahead"}
           ]
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
      assert_raise KeyfleetWeb.NotFoundError, fn -> live(conn, path) end
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
      Keyfleet.PubSub,
      Proposals.topic(@fleet),
      {:proposals_changed, @fleet}
    )

    assert shows?(fn -> has_element?(view, "#proposal-yes", "2 keys") end)
    assert shows?(fn -> has_element?(list, ~s([data-proposal="1"]), "2 yes, 0 no") end)
  end

  test "a notice that balances were read has an open page show them", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#proposals-budget-pending")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, free_capital: 3_000_000)])
    assert has_element?(view, "#proposals-budget-pending")

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      Proposals.topic(@fleet),
      {:balances_changed, @fleet}
    )

    assert shows?(fn -> has_element?(view, "[data-asset='#{@usdc}']", "3 USDC") end)
  end

  test "a proposal on show that closes is shown being counted without anything new recorded",
       %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.proposal!(@fleet, 1, closes_at: DateTime.add(DateTime.utc_now(), 1))

    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert has_element?(view, "#proposal-status", "Voting open")

    assert shows?(fn -> has_element?(view, "#proposal-status", "Counting votes") end, 80)
  end

  test "the budget shows what the fleet holds and what it can pay this month", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    weth = ProposalHelpers.wallet("c")
    as_of = ~U[2026-09-20 12:00:00Z]
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)
    ProposalHelpers.asset_details!(@fleet, weth, "WETH", 18)

    ProposalHelpers.treasury_reading!(
      @fleet,
      [
        balance(@usdc,
          free_capital: 100_000_000,
          backed: 30_000_000,
          pay_period_start: ~U[2026-09-01 08:00:00Z],
          pay_cap: 20_000_000,
          pay_spent: 5_000_000
        ),
        balance(weth, free_capital: 2_000_000_000_000_000_000)
      ],
      block_time: as_of,
      protocol_share_owed: Decimal.new(2_500_000)
    )

    ProposalHelpers.income_split!(@fleet, asset: @usdc)
    ProposalHelpers.budget_payment!(@fleet, asset: @usdc)

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Budget", "100 USDC"},
             {"Available this month", "15 USDC"},
             {"Paid this month", "5 USDC of 20 USDC, until 1 October 2026 at 08:00 UTC"},
             {"Set aside for key holders", "30 USDC"}
           ]

    assert fields(view, "[data-asset='#{weth}'] div") == [
             {"Budget", "2 WETH 0xcccc…cccc"},
             {"Available this month", "0.4 WETH 0xcccc…cccc"},
             {"Set aside for key holders", "0 WETH 0xcccc…cccc"}
           ]

    assert fields(view, "#proposals-held div") == [{"Set aside for REGENT stakers", "2.5 USDC"}]

    assert has_element?(
             view,
             "#proposals-budget-as-of",
             "Figures as of 20 September 2026 at 12:00 UTC."
           )

    refute has_element?(view, "#proposals-payments-closed")

    assert has_element?(view, "#proposals-income li", "10 USDC received")

    assert has_element?(
             view,
             "#proposals-income li",
             "4 USDC to the budget, 5 USDC to key holders, 1 USDC fee"
           )

    assert has_element?(view, "#proposals-payments li", "5 USDC")
    assert has_element?(view, "#proposals-payments li", "to #{ProposalHelpers.wallet("b")}")
  end

  test "the budget says what it doesn't know yet, and when payments can't be made", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#proposals-budget-pending", "Budget figures are still being read.")
    assert has_element?(view, "#proposals-no-income", "No launch income yet.")

    assert has_element?(
             view,
             "#proposals-no-payments",
             "Nothing has been paid from the budget yet."
           )

    # A month that has ended leaves a fifth of the budget as it stands.
    ProposalHelpers.treasury_reading!(
      @fleet,
      [
        balance(@usdc,
          free_capital: 50_000_000,
          pay_period_start: ~U[2026-08-01 08:00:00Z],
          pay_cap: 20_000_000,
          pay_spent: 20_000_000
        )
      ],
      block_time: ~U[2026-09-20 12:00:00Z],
      launch_settled: false,
      cascade_reserve: Decimal.new(7_000_000)
    )

    for _payment <- 1..21, do: ProposalHelpers.budget_payment!(@fleet, asset: @usdc)

    {:ok, view, _html} = live(conn, @list)

    assert has_element?(
             view,
             "#proposals-payments-closed",
             "Payments from the budget open once the launch has finished."
           )

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Budget", "50 USDC"},
             {"Set aside for key holders", "0 USDC"}
           ]

    assert fields(view, "#proposals-held div") == [
             {"Held for the next level", "7 USDC"},
             {"Set aside for REGENT stakers", "0 USDC"}
           ]

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#proposals-payments li")
           |> Enum.count() == 20

    assert render(view) =~ "Earlier payments are not shown here."

    ProposalHelpers.treasury_reading!(
      @fleet,
      [
        balance(@usdc,
          free_capital: 50_000_000,
          pay_period_start: ~U[2026-08-01 08:00:00Z],
          pay_cap: 20_000_000,
          pay_spent: 20_000_000
        )
      ],
      block_time: ~U[2026-09-20 12:00:00Z]
    )

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Budget", "50 USDC"},
             {"Available this month", "10 USDC"},
             {"Set aside for key holders", "0 USDC"}
           ]
  end

  # Until a fleet is on chain it has no budget, and its page says nothing
  # about one.
  test "a fleet not yet on chain shows no budget", %{conn: conn} do
    {:ok, view, html} = live(conn, "/app/fleets/fleet_tech_accelerant/proposals")
    assert has_element?(view, "#proposals-page")
    refute has_element?(view, "#proposals-budget")
    refute has_element?(view, "[data-fleet-action]")
    refute html =~ "Budget"
    refute html =~ "budget"
  end

  test "the fleet's page leads to its proposals", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/fleets/#{@fleet}")
    assert has_element?(view, "#fleet-proposals-link[href='#{@list}']", "Proposals")
  end

  # Every wallet button reaches the wallet whatever the page shows: what the
  # page knows is said beside it, and the contract decides.
  test "the vote buttons take every press, however the vote stands", %{conn: conn} do
    now = DateTime.utc_now()
    ChainHelpers.seed_cursor!(@fleet, read_through_at: DateTime.add(now, -60))

    ProposalHelpers.proposal!(@fleet, 1)
    ProposalHelpers.vote!(@fleet, 1, @holder, true, [2])
    ProposalHelpers.proposal!(@fleet, 2, closes_at: DateTime.add(now, -3600), eligible_keys: 3)
    votes!(2, true: [1])
    ProposalHelpers.vote!(@fleet, 2, @holder, false, [2, 3])

    ProposalHelpers.proposal!(@fleet, 3,
      kind: :pay,
      closes_at: DateTime.add(now, -3600),
      eligible_keys: 1,
      execution_expiry: Decimal.new(DateTime.to_unix(now) - 1)
    )

    votes!(3, true: [1])
    holder = signed_in_as(conn, @holder)

    # Open, by someone who has voted already.
    {:ok, view, _html} = live(holder, "#{@list}/1")
    assert pressable?(view, "vote", ["#proposal-vote-yes", "#proposal-vote-no"])
    refute has_element?(view, "#proposal-vote-closed")

    # Closed.
    {:ok, view, _html} = live(holder, "#{@list}/2")
    assert has_element?(view, "#proposal-status", "Did not pass")
    assert pressable?(view, "vote", ["#proposal-vote-yes", "#proposal-vote-no"])
    assert has_element?(view, "#proposal-vote-closed", "Voting has closed")

    # Past the last second it could be carried out.
    {:ok, view, _html} = live(holder, "#{@list}/3")
    assert has_element?(view, "#proposal-status", "Expired")
    assert pressable?(view, "vote", ["#proposal-vote-yes", "#proposal-vote-no"])

    # Signed out.
    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert pressable?(view, "vote", ["#proposal-vote-yes", "#proposal-vote-no"])

    assert has_element?(
             view,
             "#proposal-vote-action[data-chain-id='8453'][data-to='#{@votes}']"
           )

    assert has_element?(view, ~s(#proposal-vote-yes[data-support="yes"][data-proposal="1"]))
    assert has_element?(view, ~s(#proposal-vote-no[data-support="no"][data-proposal="1"]))
  end

  test "carrying a proposal out takes every press, whatever it says about the outcome", %{
    conn: conn
  } do
    now = DateTime.utc_now()
    closed = DateTime.add(now, -3600)
    ChainHelpers.seed_cursor!(@fleet, read_through_at: DateTime.add(now, -60))
    expired = Decimal.new(DateTime.to_unix(now) - 1)

    ProposalHelpers.proposal!(@fleet, 1)
    ProposalHelpers.proposal!(@fleet, 2, closes_at: DateTime.add(now, -30))
    ProposalHelpers.proposal!(@fleet, 3, closes_at: closed, eligible_keys: 1)
    votes!(3, true: [1])
    ProposalHelpers.proposal!(@fleet, 4, closes_at: closed, eligible_keys: 2)
    votes!(4, true: [1])
    ProposalHelpers.proposal!(@fleet, 5, kind: :pay, closes_at: closed, eligible_keys: 1)
    votes!(5, true: [1])

    ProposalHelpers.proposal!(@fleet, 6,
      kind: :pay,
      closes_at: closed,
      eligible_keys: 1,
      execution_expiry: expired
    )

    votes!(6, true: [1])

    for number <- 7..8 do
      ProposalHelpers.proposal!(@fleet, number,
        kind: :autolaunch,
        closes_at: closed,
        eligible_keys: 1
      )

      votes!(number, true: [1])
    end

    ProposalHelpers.execution!(@fleet, 5, @voter)
    ProposalHelpers.execution!(@fleet, 8, @voter)

    for {number, status, word, note} <- [
          {1, "Voting open", "Record the decision", "Voting is still open"},
          {2, "Counting votes", "Record the decision", "Votes are still being counted"},
          {3, "Passed", "Record the decision", nil},
          {4, "Did not pass", "Record the decision", "It didn’t pass"},
          {5, "Paid", "Make the payment", "It has already been carried out"},
          {6, "Expired", "Make the payment", "Its time to be carried out has passed"},
          {7, "Closed: another launch went ahead", "Start the launch", "Another launch"},
          {8, "Launched", "Start the launch", "It has already been carried out"}
        ] do
      {:ok, view, _html} = live(conn, "#{@list}/#{number}")
      assert has_element?(view, "#proposal-status", status), "proposal #{number}"
      assert pressable?(view, "execute", ["#proposal-carry-out-button"]), "proposal #{number}"
      assert has_element?(view, "#proposal-carry-out-button", word)

      assert has_element?(
               view,
               ~s(#proposal-carry-out-action[data-to="#{@votes}"] [data-proposal="#{number}"])
             )

      if note do
        assert has_element?(view, "#proposal-carry-out-note", note), "proposal #{number}"
      else
        refute has_element?(view, "#proposal-carry-out-note")
      end
    end
  end

  test "proposing and letting another wallet vote take every press, signed in or not", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    weth = ProposalHelpers.wallet("c")
    odd = ProposalHelpers.wallet("d")
    ProposalHelpers.asset_details!(@fleet, weth, "WETH", 18)

    # Payments can't be made until the launch has finished.
    ProposalHelpers.treasury_reading!(
      @fleet,
      [balance(@usdc, free_capital: 1), balance(weth, free_capital: 1), balance(odd, [])],
      launch_settled: false
    )

    buttons = [
      {"propose_decision", "#propose-decision-button"},
      {"propose_pay", "#propose-payment-button"},
      {"propose_launch", "#propose-launch-button"},
      {"delegate", "#voting-delegate-button"},
      {"clear_delegate", "#voting-delegate-clear"}
    ]

    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#proposals-payments-closed")

    for {action, button} <- buttons, do: assert(pressable?(view, action, [button]), button)

    assert has_element?(view, "#propose-decision-action[data-to='#{@votes}']")
    assert has_element?(view, "#propose-payment-action[data-to='#{@votes}']")

    assert view |> element("#propose-payment-asset") |> render() |> options() == [
             {@usdc, "USDC"},
             {weth, "WETH 0xcccc…cccc"},
             {odd, "Token 0xdddd…dddd, in its smallest units"}
           ]

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#propose-payment-action")
           |> LazyHTML.attribute("data-assets")
           |> hd()
           |> Jason.decode!() == %{
             @usdc => %{"decimals" => 6, "unit" => "USDC"},
             weth => %{"decimals" => 18, "unit" => "WETH 0xcccc…cccc"},
             odd => %{"decimals" => 0, "unit" => "smallest units of token 0xdddd…dddd"}
           }

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
    for {action, button} <- buttons, do: assert(pressable?(view, action, [button]), button)
  end

  # The page names the signed-in wallets so each group of buttons can say when
  # the connected wallet is another; every press still goes to the connected one.
  test "every group of wallet buttons carries the signed-in wallets for its wallet note", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.proposal!(@fleet, 1)

    list_groups = ~w(propose-decision-action propose-payment-action propose-launch-action
      voting-delegate-action proposals-stakers-share)

    detail_groups = ~w(proposal-vote-action proposal-carry-out-action)

    for {session, signed_in} <- [{signed_in_as(conn, @holder), [@holder]}, {conn, []}],
        {path, groups} <- [{@list, list_groups}, {"#{@list}/1", detail_groups}] do
      {:ok, view, _html} = live(session, path)

      for group <- groups do
        assert signed_in(view, group) == signed_in, "#{group} on #{path}"
        assert has_element?(view, "##{group} ##{group}-wallet-note[data-wallet-note]")

        # Nothing inside, not even a space, so the page's rule hides them
        # until there is something to say.
        assert child_nodes(view, "##{group}-wallet-note") == 0
        assert child_nodes(view, "##{group}-status") == 0
      end
    end
  end

  test "sending the stakers their share takes every press, owed or not", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    # Before the budget has been read.
    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#proposals-budget-pending")
    assert pressable?(view, "send_share", ["#proposals-send-share"])
    refute has_element?(view, "#proposals-nothing-owed")
    assert has_element?(view, "#proposals-stakers-share[data-to='#{@fleet_contract}']")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, [])])
    {:ok, view, _html} = live(conn, @list)
    assert fields(view, "#proposals-held div") == [{"Set aside for REGENT stakers", "0 USDC"}]
    assert pressable?(view, "send_share", ["#proposals-send-share"])
    assert has_element?(view, "#proposals-nothing-owed")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, [])],
      protocol_share_owed: Decimal.new(2_500_000)
    )

    {:ok, view, _html} = live(conn, @list)
    assert pressable?(view, "send_share", ["#proposals-send-share"])
    refute has_element?(view, "#proposals-nothing-owed")
  end

  # Every launch detail and three of the plan's other fields filled in.
  defp plan_data(attrs \\ %{}) do
    Map.merge(
      %{
        "title" => "Cascade Research",
        "who_we_serve" => "Funds that read filings",
        "what_we_sell" => "A weekly brief",
        "commitments" => "Key 17 writes the brief",
        "name" => "Cascade Research",
        "symbol" => "CSR",
        "description" => "Research the fleet funds",
        "website" => "https://example.test",
        "image" => "ipfs://cascade",
        "required_regent_raised" => "250000.5"
      },
      attrs
    )
  end

  # The digest of `version` of plan `id`, as the workspace keeps it.
  defp digest(id, version) do
    [revision] =
      Graph.current_launch_plan_revisions!(@fleet, [%{object_id: id, version: version}])

    revision.digest
  end

  # Launch proposal `number` pointing to `digest`, its details read as
  # `envelope` says, and otherwise those of `plan_data/0`.
  defp launch!(number, digest, envelope \\ []) do
    @fleet
    |> ProposalHelpers.proposal!(number, kind: :autolaunch, digest: digest)
    |> ProposalHelpers.launch_envelope!(
      Keyword.merge(
        [
          description: "Research the fleet funds",
          required_regent_raised: Decimal.new("250000500000000000000000")
        ],
        envelope
      )
    )
  end

  defp votes!(number, sides) do
    for {support, token_ids} <- sides,
        do: ProposalHelpers.vote!(@fleet, number, @voter, support, token_ids)
  end

  defp balance(asset, figures) do
    Map.merge(
      %{
        asset: asset,
        free_capital: 0,
        backed: 0,
        pay_period_start: nil,
        pay_cap: 0,
        pay_spent: 0
      },
      Map.new(figures)
    )
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

  defp fields(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(fn field ->
      {field |> LazyHTML.query("dt") |> LazyHTML.text(),
       field |> LazyHTML.query("dd") |> LazyHTML.text()}
    end)
  end

  defp text(node), do: node |> LazyHTML.text() |> String.trim()

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # Whether each of `buttons` is there to press for `action`, and nothing
  # stops a press.
  defp pressable?(view, action, buttons) do
    Enum.all?(buttons, fn button ->
      has_element?(
        view,
        ~s|#{button}[data-fleet-action="#{action}"]:not([disabled]):not([aria-disabled])|
      )
    end)
  end

  defp child_nodes(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.child_nodes()
    |> Enum.count()
  end

  defp signed_in(view, group) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{group}")
    |> LazyHTML.attribute("data-signed-in")
    |> hd()
    |> Jason.decode!()
  end

  defp options(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(&{&1 |> LazyHTML.attribute("value") |> hd(), text(&1)})
  end

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:proposals:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end

  # An amount's words, and the full address of its token, if it shows one.
  defp amount(view, selector) do
    node = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
    token = LazyHTML.query(node, ".proposals-token")

    {text(node),
     if(Enum.empty?(token), do: nil, else: token |> LazyHTML.attribute("title") |> hd())}
  end

  defp short(address), do: String.slice(address, 0, 6) <> "…" <> String.slice(address, -4, 4)

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

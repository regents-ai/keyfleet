defmodule KeyfleetWeb.Live.ProposalsPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.TestChainNode
  alias RegentChain.Call

  @fleet "fibonacci_syndicate"
  @list "/app/fleets/fibonacci_syndicate/proposals"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @voter ProposalHelpers.wallet("e")
  @holder ProposalHelpers.wallet("1")
  @votes "0x" <> String.duplicate("9", 40)
  @fleet_contract "0x" <> String.duplicate("7", 40)
  @eth "0x0000000000000000000000000000000000000000"
  @day 86_400
  @rule KeyfleetWeb.ProposalsLive.approval_rule()

  setup do
    Fleets.bootstrap_catalog!()

    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8453,
        contract_address: @fleet_contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: @votes,
        treasury_address: "0x" <> String.duplicate("7e", 20),
        shards_address: "0x" <> String.duplicate("6", 40),
        regent_address: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
        regent_staking_address: "0xb027dc261636e30cbc0fe25b2f8e1ed273354ab5",
        autolaunch_factory_address: "0xf4f591e63f4b6d8240a150081c1ca7edfaeb768e",
        usdc_address: @usdc,
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )

    :ok
  end

  test "anyone can read every proposal and where each one stands", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    ProposalHelpers.proposal!(@fleet, 1)
    closed!(2)
    votes!(2, yes: [1, 2, 3, 4])
    ProposalHelpers.proposal!(@fleet, 3)
    votes!(3, yes: [1, 2, 3], no: [4], abstain: [5])
    closed!(4)
    votes!(4, yes: [1])
    ProposalHelpers.execution!(@fleet, 4, @voter)
    ProposalHelpers.proposal!(@fleet, 5)
    ProposalHelpers.cancellation!(@fleet, 5, @voter)
    # Three keys were present when it opened, and none of them voted.
    closed!(6, opening_count: 3)

    {:ok, view, html} = live(conn, @list)

    assert has_element?(view, ".proposals-rule", @rule)
    refute html =~ "Vote counts are catching up."

    assert cards(view) == [
             {"6", "Not approved"},
             {"5", "Cancelled"},
             {"4", "Carried out"},
             {"3", "Open"},
             {"2", "Approved"},
             {"1", "Open"}
           ]

    assert text(view, ~s([data-proposal="3"] .proposals-detail)) ==
             "3 yes, 1 no, 1 abstain, of 5 keys counted"

    view |> element(~s([data-proposal="2"] a)) |> render_click()
    assert_patch(view, "/app/fleets/#{@fleet}/proposals/2")
  end

  test "a proposal's page shows what it does, how it stands and every vote, fifty at a time",
       %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    paid = ProposalHelpers.wallet("b")

    ProposalHelpers.proposal!(@fleet, 1,
      calls: [
        %{target: paid, value: 10 ** 18, data: "0x"},
        %{target: @usdc, value: 0, data: "0xa9059cbb"}
      ]
    )

    for token_id <- 1..51, do: ProposalHelpers.vote!(@fleet, 1, @voter, :yes, [token_id])
    votes!(1, no: [52], abstain: [53, 54])

    {:ok, view, _html} = live(conn, "#{@list}/1")

    assert has_element?(view, "#proposal-status", "Open")
    assert has_element?(view, "#proposal-yes", "51 keys")
    assert has_element?(view, "#proposal-no", "1 key")
    assert has_element?(view, "#proposal-abstain", "2 keys")
    assert has_element?(view, "#proposal-counted", "54 keys")
    assert has_element?(view, ".proposals-rule", @rule)
    assert text(view, "#proposal-proposer") == "Proposed by 0xffff..ffff with key 1"
    assert has_element?(view, "#proposal-content", "0x" <> String.duplicate("d", 64))

    # ETH is known by its address, so no token address is shown beside it,
    # and a call with no data shows none.
    assert lines(view, "#proposal-calls li") == [
             "Calls 0xbbbb..bbbb with 1 ETH",
             "Calls 0x8335..2913 #{RegentFormat.short_hash("0xa9059cbb")}"
           ]

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#proposal-calls code.proposals-token")
           |> LazyHTML.attribute("title") == ["0xa9059cbb"]

    assert length(lines(view, "#proposal-votes li")) == 50
    assert hd(lines(view, "#proposal-votes li")) =~ ~r/^Yes .* with key 1$/

    view |> element("#proposal-more-votes") |> render_click()
    assert [yes, no, abstain] = lines(view, "#proposal-votes li")
    assert yes =~ ~r/^Yes .* with key 51$/
    assert no =~ ~r/^No .* with key 52$/
    assert abstain =~ ~r/^Abstain .* with keys 53, 54$/

    view |> element("#proposal-first-votes") |> render_click()
    assert length(lines(view, "#proposal-votes li")) == 50

    # A proposal with no calls moves nothing.
    ProposalHelpers.proposal!(@fleet, 2)
    {:ok, view, _html} = live(conn, "#{@list}/2")
    assert has_element?(view, "#proposal-no-calls", "It records a decision and moves nothing.")
  end

  # Only ETH and the fleet's own USDC, known by their addresses, are shown
  # without one. A token anywhere else that calls itself USDC always has its
  # address beside every amount of it.
  test "a token calling itself USDC is shown with its address", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    fake = ProposalHelpers.wallet("d")
    ProposalHelpers.asset_details!(@fleet, fake, "USDC", 6)

    ProposalHelpers.treasury_reading!(@fleet, [
      balance(@usdc, held: 1_000_000),
      balance(fake, held: 1_000_000, backed: 3_000_000)
    ])

    money!(:paid, asset: fake, account: ProposalHelpers.wallet("b"), amount: 2_000_000)

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{fake}'] div") == [
             {"Shared money", "1 USDC 0xdddd..dddd"},
             {"Waiting for key holders", "3 USDC 0xdddd..dddd"}
           ]

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Shared money", "1 USDC"},
             {"Waiting for key holders", "0 USDC"}
           ]

    tokens =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#proposals-history .proposals-token")
      |> Enum.map(&{text(&1), &1 |> LazyHTML.attribute("title") |> hd()})

    assert tokens == [{"0xdddd..dddd", fake}]
  end

  # A token that will not tell its symbol or its decimals is never guessed at.
  test "an amount in a token that doesn't say what it is shows as the chain holds it", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    no_symbol = ProposalHelpers.wallet("c")
    no_decimals = ProposalHelpers.wallet("d")
    ProposalHelpers.asset_details!(@fleet, no_symbol, nil, 18)
    ProposalHelpers.asset_details!(@fleet, no_decimals, "ODD", nil)

    ProposalHelpers.treasury_reading!(@fleet, [
      balance(no_symbol, held: 1_234_000),
      balance(no_decimals, held: 1_234_000)
    ])

    {:ok, view, _html} = live(conn, @list)

    for asset <- [no_symbol, no_decimals] do
      assert fields(view, "[data-asset='#{asset}'] div:first-child") == [
               {"Shared money",
                "1,234,000 in the smallest units of token #{RegentFormat.short_address(asset)}"}
             ]
    end
  end

  # The contract holds any uint256, which is shown to the last digit.
  test "the largest amount the contract can hold is shown whole", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    max = 2 ** 256 - 1
    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: max, backed: max)])

    whole =
      "115,792,089,237,316,195,423,570,985,008,687,907,853,269,984,665,640,564,039,457,584," <>
        "007,913,129.639935 USDC"

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Shared money", whole},
             {"Waiting for key holders", whole}
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

    ProposalHelpers.vote!(@fleet, 1, @voter, :yes, [1, 2])
    assert has_element?(view, "#proposal-yes", "0 keys")

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      Proposals.topic(@fleet),
      {:proposals_changed, @fleet}
    )

    assert shows?(fn -> has_element?(view, "#proposal-yes", "2 keys") end)

    assert shows?(fn ->
             text(list, ~s([data-proposal="1"] .proposals-detail)) =~ "2 yes, 0 no"
           end)
  end

  test "a notice that balances were read has an open page show them", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#proposals-budget-pending")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 3_000_000)])
    assert has_element?(view, "#proposals-budget-pending")

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      Proposals.topic(@fleet),
      {:balances_changed, @fleet}
    )

    assert shows?(fn -> has_element?(view, "[data-asset='#{@usdc}']", "3 USDC") end)
  end

  test "the shared money shows what the fleet holds, shares and pays", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    weth = ProposalHelpers.wallet("c")
    operator = ProposalHelpers.wallet("d")
    ProposalHelpers.asset_details!(@fleet, weth, "WETH", 18)

    ProposalHelpers.treasury_reading!(
      @fleet,
      [
        balance(@eth, held: 10 ** 18),
        balance(@usdc, held: 100_000_000, backed: 30_000_000),
        balance(weth, held: 2 * 10 ** 18)
      ],
      block_time: ~U[2026-09-20 12:00:00Z],
      protocol_share_owed: Decimal.new(2_500_000),
      daily_split_bps: 75,
      next_run_at: ~U[2026-09-21 12:00:00Z]
    )

    money!(:forwarded, asset: @usdc, by: @voter, amount: 10_000_000)
    money!(:split_allocated, asset: @usdc, balance: 50_000_000, per_key: 250_000, keys: 4)
    money!(:paid, asset: weth, account: ProposalHelpers.wallet("b"), amount: 5 * 10 ** 17)
    money!(:protocol_share_sent, by: @voter, amount: 1_000_000)

    money!(:advanced,
      advance_id: 1,
      account: operator,
      asset: @usdc,
      amount: 4_000_000,
      purpose_hash: "0x" <> String.duplicate("e", 64)
    )

    money!(:advance_returned,
      advance_id: 1,
      by: operator,
      amount: 1_000_000,
      outstanding: 3_000_000
    )

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "[data-asset='#{@eth}'] div") == [
             {"Shared money", "1 ETH"},
             {"Waiting for key holders", "0 ETH"}
           ]

    assert fields(view, "[data-asset='#{@usdc}'] div") == [
             {"Shared money", "100 USDC"},
             {"Waiting for key holders", "30 USDC"}
           ]

    assert fields(view, "[data-asset='#{weth}'] div") == [
             {"Shared money", "2 WETH 0xcccc..cccc"},
             {"Waiting for key holders", "0 WETH 0xcccc..cccc"}
           ]

    assert text(view, "#proposals-budget-as-of") ==
             "Figures as of 20 September 2026 at 12:00 UTC."

    assert fields(view, "#proposals-split div") == [
             {"Shared with key holders each day", "0.75%"},
             {"Next share", "21 September 2026 at 12:00 UTC"}
           ]

    assert fields(view, "#proposals-held div") == [{"Set aside for Regents", "2.5 USDC"}]

    assert lines(view, "#proposals-advances li") == [
             "3 USDC of 4 USDC still out with 0xdddd..dddd"
           ]

    # Newest first; an advance coming back changes only what is still out.
    assert lines(view, "#proposals-history li") == [
             "Advanced 4 USDC to 0xdddd..dddd",
             "Sent to Regents 1 USDC",
             "Paid 0.5 WETH 0xcccc..cccc to 0xbbbb..bbbb",
             "Shared with key holders 1 USDC",
             "Received 10 USDC"
           ]
  end

  test "the shared money says what it doesn't know yet", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, view, _html} = live(conn, @list)

    assert has_element?(
             view,
             "#proposals-budget-pending",
             "The shared money’s figures are still being read."
           )

    assert has_element?(view, "#proposals-no-advances", "Nothing is out on an advance.")
    assert has_element?(view, "#proposals-no-history", "No money has come in or gone out yet.")

    ProposalHelpers.treasury_reading!(
      @fleet,
      [balance(@usdc, held: 50_000_000)],
      block_time: ~U[2026-09-20 12:00:00Z],
      cascade_reserve: Decimal.new(7_000_000)
    )

    for _payment <- 1..21,
        do: money!(:paid, asset: @usdc, account: ProposalHelpers.wallet("b"), amount: 1)

    {:ok, view, _html} = live(conn, @list)

    assert fields(view, "#proposals-split div") == [{"Shared with key holders each day", "1%"}]

    assert fields(view, "#proposals-held div") == [
             {"Held for the next level", "7 USDC"},
             {"Set aside for Regents", "0 USDC"}
           ]

    assert length(lines(view, "#proposals-history li")) == 20
    assert render(view) =~ "Earlier money in and out is not shown here."
  end

  # Until a fleet is on chain it has no shared money, and its page says nothing
  # about one.
  test "a fleet not yet on chain shows no shared money", %{conn: conn} do
    {:ok, view, html} = live(conn, "/app/fleets/fleet_tech_classic/proposals")
    assert has_element?(view, "#proposals-page")
    refute has_element?(view, "#proposals-budget")
    refute has_element?(view, "[data-fleet-action]")
    refute html =~ "Shared money"
    refute html =~ "shared money"
  end

  test "the fleet's page leads to its proposals", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/fleets/#{@fleet}")
    assert has_element?(view, "#fleet-proposals-link[href='#{@list}']", "Proposals")
  end

  # Every wallet button reaches the wallet whatever the page shows: what the
  # page knows is said beside it, and the contract decides.
  test "the vote buttons take every press, however the vote stands", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    ProposalHelpers.proposal!(@fleet, 1)
    ProposalHelpers.vote!(@fleet, 1, @holder, :yes, [2])
    closed!(2)
    votes!(2, yes: [1, 2])
    closed!(3)
    votes!(3, yes: [1, 2])
    ProposalHelpers.execution!(@fleet, 3, @voter)
    holder = signed_in_as(conn, @holder)

    # Open, by someone who has voted already.
    {:ok, view, _html} = live(holder, "#{@list}/1")
    assert votes_pressable?(view)
    assert has_element?(view, "#proposal-vote-closed[hidden]")

    # Approved: voting has closed, and the page says so beside the buttons.
    {:ok, view, _html} = live(holder, "#{@list}/2")
    assert has_element?(view, "#proposal-status", "Approved")
    assert votes_pressable?(view)
    assert has_element?(view, "#proposal-vote-closed:not([hidden])", "Voting has closed")

    # Carried out.
    {:ok, view, _html} = live(holder, "#{@list}/3")
    assert has_element?(view, "#proposal-status", "Carried out")
    assert votes_pressable?(view)

    # Signed out.
    {:ok, view, _html} = live(conn, "#{@list}/1")
    assert votes_pressable?(view)
  end

  # The keys typed are the keys voted with; the server builds each of the
  # three steps for the signed-in wallet before anyone presses.
  test "voting builds yes, no and withdraw for the keys typed", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..3)
    ProposalHelpers.proposal!(@fleet, 1)

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
    active!(view, "#proposal-vote-action", @holder)

    assert text(view, "#proposal-vote-action-line") ==
             "Type the numbers of the keys to use, like 3, 7, 12."

    view |> form("#proposal-vote-action-form", keys: "1, 3") |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "proposal-vote-action",
      review: %{signer: @holder, steps: [yes, no, withdraw]}
    })

    assert {yes.step, yes.to, yes.data} ==
             {"yes", @votes, Call.encode("vote(uint256,uint256[],bool)", [1, [1, 3], true])}

    assert {no.step, no.data} ==
             {"no", Call.encode("vote(uint256,uint256[],bool)", [1, [1, 3], false])}

    assert {withdraw.step, withdraw.data} ==
             {"withdraw", Call.encode("withdrawVote(uint256,uint256[])", [1, [1, 3]])}

    assert text(view, "#proposal-vote-action-line") ==
             "Voting, changing or withdrawing uses keys 1, 3. Each key is one vote."

    assert text(view, "#proposal-vote-action-from") == "Sending from 0x1111..1111 on Base."
  end

  # A vote the contract turns down says why it may have been, and the
  # buttons stay to press again.
  test "a vote that doesn't go through says why it may not have", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.keys_sold!(@fleet, 1..3)
    ProposalHelpers.proposal!(@fleet, 1)

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
    active!(view, "#proposal-vote-action", @holder)
    view |> form("#proposal-vote-action-form", keys: "2") |> render_change()
    assert_push_event(view, "onchain-steps:review", %{review: %{steps: [yes | _]} = review})

    hash = "0x" <> String.duplicate("4", 64)
    TestChainNode.land!(hash, review, yes, "0x0")

    view
    |> with_target("#proposal-vote-action")
    |> render_hook("step_sent", %{
      "review_id" => review.id,
      "step" => "yes",
      "transaction_hash" => hash
    })

    render_async(view)

    assert has_element?(
             view,
             "#proposal-vote-action-sent li[data-state=reverted] strong",
             "Vote yes, key 2"
           )

    assert text(view, "#proposal-vote-action-sent span") =~
             "This vote didn’t go through and nothing changed."

    assert votes_pressable?(view)
  end

  test "carrying a proposal out takes every press, whatever it says about the outcome", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    gone = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

    ProposalHelpers.proposal!(@fleet, 1)
    closed!(2)
    closed!(3)
    closed!(4, opening_count: 1)
    closed!(5)
    closed!(6, execution_expiry: gone)
    for number <- [2, 3, 5, 6], do: votes!(number, yes: [1])
    ProposalHelpers.execution!(@fleet, 3, @voter)
    ProposalHelpers.cancellation!(@fleet, 5, @voter)

    for {number, status, note} <- [
          {1, "Open", "Voting is still open"},
          {2, "Approved", nil},
          {3, "Carried out", "It has already been carried out"},
          {4, "Not approved", "It wasn’t approved"},
          {5, "Cancelled", "It was cancelled"},
          {6, "Expired", "It can no longer be carried out"}
        ] do
      {:ok, view, _html} = live(conn, "#{@list}/#{number}")
      assert has_element?(view, "#proposal-status", status), "proposal #{number}"
      assert pressable?(view, "carry_out", ["#proposal-carry-out-button"]), "proposal #{number}"

      shown = shown_notes(view, "#proposal-carry-out [id^=proposal-carry-out-note-]")

      if note do
        assert [shown_note] = shown, "proposal #{number}"
        assert shown_note =~ note
      else
        assert shown == [], "proposal #{number}"
      end
    end

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/2")
    active!(view, "#proposal-carry-out-action", @holder)

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "proposal-carry-out-action",
      review: %{steps: [%{step: "carry_out", to: @votes} = carry_out]}
    })

    assert carry_out.data == Call.encode("execute(uint256)", [2])
  end

  test "proposing and letting another wallet vote take every press, signed in or not", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    weth = ProposalHelpers.wallet("c")
    odd = ProposalHelpers.wallet("d")
    ProposalHelpers.asset_details!(@fleet, weth, "WETH", 18)

    ProposalHelpers.treasury_reading!(@fleet, [
      balance(@usdc, held: 1),
      balance(weth, held: 1),
      balance(odd, [])
    ])

    buttons = [
      {"propose", "#propose-decision-button"},
      {"propose", "#propose-payment-button"},
      {"propose", "#propose-edits-button"},
      {"delegate", "#voting-delegate-button"},
      {"clear", "#voting-delegate-clear"}
    ]

    {:ok, view, _html} = live(conn, @list)

    for {step, button} <- buttons, do: assert(pressable?(view, step, [button]), button)

    assert view |> element("#propose-payment-asset") |> render() |> options() == [
             {@usdc, "USDC"},
             {weth, "WETH 0xcccc..cccc"},
             {odd, "Token 0xdddd..dddd, in its smallest units"},
             {"other", "Another token (paste its address)"}
           ]

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
    for {step, button} <- buttons, do: assert(pressable?(view, step, [button]), button)
  end

  # Each proposal is built on the server from the form as typed, for the
  # signed-in wallet, and the page has it before anyone presses.
  test "a proposal is built from the form as typed", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    weth = ProposalHelpers.wallet("c")
    ProposalHelpers.asset_details!(@fleet, weth, "WETH", 18)
    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, []), balance(weth, [])])
    recipient = ProposalHelpers.wallet("b")
    code = String.duplicate("ab", 32)

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)

    active!(view, "#propose-decision-action", @holder)

    view
    |> form("#propose-decision-action-form", key: "7", text: "Hire a designer", digest: code)
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-decision-action",
      review: %{steps: [decision]}
    })

    assert decision.data ==
             Call.encode("proposeDecision(uint256,string,bytes32)", [
               7,
               "Hire a designer",
               "0x" <> code
             ])

    assert text(view, "#propose-decision-action-line") == "Proposes this decision with key 7."

    active!(view, "#propose-payment-action", @holder)

    view
    |> form("#propose-payment-action-form",
      key: "7",
      asset: weth,
      amount: "1.5",
      recipient: recipient,
      text: "Pay the designer"
    )
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-payment-action",
      review: %{steps: [payment]}
    })

    assert payment.data ==
             Call.encode("proposePay(uint256,address,uint256,address,string,bytes32)", [
               7,
               weth,
               1_500_000_000_000_000_000,
               recipient,
               "Pay the designer",
               "0x" <> String.duplicate("0", 64)
             ])

    assert text(view, "#propose-payment-action-line") ==
             "Proposes paying 1.5 WETH (0xcccc..cccc) to 0xbbbb..bbbb, with key 7."

    # Another token, pasted, is paid in its smallest units.
    pasted = ProposalHelpers.wallet("5")

    view
    |> form("#propose-payment-action-form", asset: "other", other_asset: pasted, amount: "250")
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-payment-action",
      review: %{steps: [pasted_payment]}
    })

    assert pasted_payment.data ==
             Call.encode("proposePay(uint256,address,uint256,address,string,bytes32)", [
               7,
               pasted,
               250,
               recipient,
               "Pay the designer",
               "0x" <> String.duplicate("0", 64)
             ])

    assert text(view, "#propose-payment-action-line") ==
             "Proposes paying 250 in the smallest units of token 0x5555..5555 to 0xbbbb..bbbb, with key 7."

    view
    |> form("#propose-payment-action-form", other_asset: "0x12")
    |> render_change()

    assert text(view, "#propose-payment-action-line") ==
             "The token isn’t a valid address. Copy it again in full: 0x and 40 more letters and numbers."

    active!(view, "#propose-edits-action", @holder)

    view
    |> form("#propose-edits-action-form", key: "7", target: "12", text: "Too many rewrites")
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-edits-action",
      review: %{steps: [restrict]}
    })

    assert restrict.data ==
             Call.encode("proposeRestrictEdits(uint256,uint256,bool,string,bytes32)", [
               7,
               12,
               true,
               "Too many rewrites",
               "0x" <> String.duplicate("0", 64)
             ])

    assert text(view, "#propose-edits-action-line") ==
             "Proposes stopping key 12 and its shards changing the workspace, with key 7. " <>
               "Needs 3 of every 5 keys sold."

    view
    |> form("#propose-edits-action-form", restricted: "false", text: "Settled down")
    |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "propose-edits-action",
      review: %{steps: [allow]}
    })

    assert allow.data ==
             Call.encode("proposeRestrictEdits(uint256,uint256,bool,string,bytes32)", [
               7,
               12,
               false,
               "Settled down",
               "0x" <> String.duplicate("0", 64)
             ])

    assert text(view, "#propose-edits-action-line") ==
             "Proposes letting key 12 and its shards change the workspace again, with key 7. " <>
               "Needs 3 of every 5 keys sold."
  end

  test "letting another wallet vote is built for the wallet typed, and clearing names no wallet",
       %{
         conn: conn
       } do
    ChainHelpers.seed_cursor!(@fleet)
    delegate = ProposalHelpers.wallet("d")

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
    active!(view, "#voting-delegate-action", @holder)

    assert text(view, "#voting-delegate-action-line") ==
             "Type the wallet that may vote for you, or stop any other wallet voting for you."

    # Clearing needs nothing typed.
    assert_push_event(view, "onchain-steps:review", %{
      component_id: "voting-delegate-action",
      review: %{steps: [%{step: "clear"}]}
    })

    view |> form("#voting-delegate-action-form", delegate: delegate) |> render_change()

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "voting-delegate-action",
      review: %{steps: steps}
    })

    assert Map.new(steps, &{&1.step, &1.data}) == %{
             "delegate" => Call.encode("setVotingDelegate(address)", [delegate]),
             "clear" =>
               Call.encode("setVotingDelegate(address)", ["0x" <> String.duplicate("0", 40)])
           }
  end

  # Skill rule 3: with a wallet open that the account doesn't link, the
  # figures stay on the account's own wallet and nothing is given to send.
  test "a wallet the account doesn't link gets nothing to send, and the note names both", %{
    conn: conn
  } do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.proposal!(@fleet, 1)
    stranger = ProposalHelpers.wallet("b")

    {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
    active!(view, "#proposal-vote-action", stranger)
    view |> form("#proposal-vote-action-form", keys: "1") |> render_change()

    refute_push_event(view, "onchain-steps:review", %{review: %{}})

    assert text(view, "#proposal-vote-action-mismatch") ==
             "You're signed in with 0x1111..1111, but your wallet app has 0xbbbb..bbbb open. " <>
               "Switch to a wallet on your account to send from here."

    assert has_element?(view, "#proposal-vote-action-from[hidden]")
    assert votes_pressable?(view)

    # Signed out: nothing is built, and every group of buttons is still there.
    {:ok, view, _html} = live(conn, "#{@list}/1")
    active!(view, "#proposal-vote-action", @holder)
    refute_push_event(view, "onchain-steps:review", %{review: %{}})
    assert has_element?(view, "#proposal-vote-action-line[hidden]")
    assert has_element?(view, "#proposal-vote-action-mismatch[hidden]")

    view
    |> with_target("#proposal-vote-action")
    |> render_hook("step_failed", %{"step" => "yes", "reason" => "wallet_unavailable"})

    assert text(view, "#proposal-vote-action-press-note") ==
             "Sign in to send this. Nothing was sent."
  end

  test "sending Regents its share takes every press, owed or not", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)
    ProposalHelpers.asset_details!(@fleet, @usdc, "USDC", 6)

    # Before the shared money has been read.
    {:ok, view, _html} = live(conn, @list)
    assert has_element?(view, "#proposals-budget-pending")
    assert pressable?(view, "send", ["#proposals-send-share"])
    assert has_element?(view, "#proposals-nothing-owed[hidden]")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, [])])
    {:ok, view, _html} = live(conn, @list)
    assert fields(view, "#proposals-held div") == [{"Set aside for Regents", "0 USDC"}]
    assert pressable?(view, "send", ["#proposals-send-share"])
    refute has_element?(view, "#proposals-nothing-owed[hidden]")

    ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, [])],
      protocol_share_owed: Decimal.new(2_500_000)
    )

    {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
    assert pressable?(view, "send", ["#proposals-send-share"])
    assert has_element?(view, "#proposals-nothing-owed[hidden]")

    active!(view, "#proposals-regents-share", @holder)

    assert_push_event(view, "onchain-steps:review", %{
      component_id: "proposals-regents-share",
      review: %{steps: [%{step: "send", to: @fleet_contract} = send]}
    })

    assert send.data == Call.encode("sendProtocolShare()", [])
  end

  defp votes!(number, sides) do
    for {choice, token_ids} <- sides,
        do: ProposalHelpers.vote!(@fleet, number, @voter, choice, token_ids)
  end

  # Proposal `number`, its voting closed an hour ago, to be carried out
  # within a day unless `attrs` says otherwise.
  defp closed!(number, attrs \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ProposalHelpers.proposal!(
      @fleet,
      number,
      Keyword.merge(
        [
          opened_at: DateTime.add(now, -2 * @day),
          closes_at: DateTime.add(now, -3600),
          execution_expiry: DateTime.add(now, @day)
        ],
        attrs
      )
    )
  end

  # A money event of `kind`, its amounts given as whole numbers.
  defp money!(kind, fields) do
    ProposalHelpers.money_event!(
      @fleet,
      kind,
      Enum.map(fields, fn
        {field, value} when is_integer(value) -> {field, Decimal.new(value)}
        field -> field
      end)
    )
  end

  defp balance(asset, figures),
    do: Map.merge(%{asset: asset, held: 0, backed: 0}, Map.new(figures))

  defp cards(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-proposal]")
    |> Enum.map(fn card ->
      {card |> LazyHTML.attribute("data-proposal") |> hd(),
       card |> LazyHTML.query(".proposals-badge") |> text()}
    end)
  end

  # The words of each element matching `selector`, its parts apart, as the
  # page stacks them, and spaces as one.
  defp lines(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(fn line ->
      line
      |> LazyHTML.child_nodes()
      |> Enum.map_join(" ", &LazyHTML.text/1)
      |> String.split()
      |> Enum.join(" ")
    end)
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

  # Whether each of `buttons` sends `step` when pressed, and nothing stops a
  # press: never disabled, hidden, handled by the page itself or inside a form.
  defp pressable?(view, step, buttons) do
    Enum.all?(buttons, fn button ->
      has_element?(
        view,
        ~s|#{button}[data-onchain-step="#{step}"]:not([disabled]):not([aria-disabled]):not([hidden]):not([phx-click])|
      ) and not has_element?(view, "form #{button}")
    end)
  end

  defp votes_pressable?(view) do
    pressable?(view, "yes", ["#proposal-vote-yes"]) and
      pressable?(view, "no", ["#proposal-vote-no"]) and
      pressable?(view, "withdraw", ["#proposal-vote-withdraw"])
  end

  # The texts of the notes matching `selector` that aren't hidden.
  defp shown_notes(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.reject(&(LazyHTML.attribute(&1, "hidden") != []))
    |> Enum.map(&text/1)
  end

  # Privy's active wallet, as the wallet hook of the group `panel` reports it.
  defp active!(view, panel, wallet) do
    view |> with_target(panel) |> render_hook("onchain_active_wallet", %{"address" => wallet})
    render_async(view)
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

defmodule KeyfleetWeb.Live.ProposalsPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ChainViews
  alias Keyfleet.Fleets
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.Proposals.Actions
  alias Keyfleet.TestChainNode
  alias KeyfleetWeb.WalletWords
  alias RegentChain.Call

  @fleet "fibonacci_syndicate"
  @list "/app/fleets/fibonacci_syndicate/proposals"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @voter ProposalHelpers.wallet("e")
  @holder ProposalHelpers.wallet("1")
  @other ProposalHelpers.wallet("2")
  @votes "0x" <> String.duplicate("9", 40)
  @fleet_contract "0x" <> String.duplicate("7", 40)
  @keys "0x" <> String.duplicate("a1", 20)
  @treasury "0x" <> String.duplicate("7e", 20)
  @shards "0x" <> String.duplicate("6", 40)
  @eth "0x0000000000000000000000000000000000000000"
  @day 86_400
  @rule KeyfleetWeb.ProposalsLive.approval_rule()
  @execute "execute(uint256,(address,uint256,bytes)[])"
  @propose "propose(uint256,bytes32,(address,uint256,bytes)[])"
  # The vote contract's `proposal(uint256)` answer.
  @proposal_types "bytes32,bytes32,bytes32,uint64,uint48,uint64,uint64,uint64," <>
                    "uint32,uint32,uint32,uint32,uint32,bool,bool"
  @statuses [:open, :waiting, :approved, :rejected, :cancelled, :executed, :execution_expired]

  setup do
    Fleets.bootstrap_catalog!()

    ChainHelpers.deploy!(@fleet, %{
      manager_address: @fleet_contract,
      keys_address: @keys,
      votes_address: @votes,
      treasury_address: @treasury,
      shards_address: @shards
    })

    ChainHelpers.seed_cursor!(@fleet)
    :ok
  end

  describe "reading" do
    test "anyone can read every proposal and where each one stands", %{conn: conn} do
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

      assert has_element?(view, "#proposals-rule", @rule)
      refute html =~ "Vote counts are catching up."
      refute has_element?(view, "#proposals-empty")

      assert cards(view) == [
               {"6", "Not approved"},
               {"5", "Cancelled"},
               {"4", "Carried out"},
               {"3", "Open"},
               {"2", "Approved"},
               {"1", "Open"}
             ]

      assert text(view, ~s([data-proposal="3"] .proposals-detail)) ==
               "3 yes, 1 no, 1 abstain, of 5 Keys counted"

      ChainViews.put!(on_chain(2, :approved))
      view |> element(~s([data-proposal="2"] a)) |> render_click()
      assert_patch(view, "/app/fleets/#{@fleet}/proposals/2")
    end

    # Where it stands is what the vote contract says at the latest block, so
    # the figures here are the chain's, not the votes this page recorded.
    test "a proposal's page shows its calls in plain words and exactly, how it stands on chain and every vote",
         %{conn: conn} do
      fleet = Fleets.get_fleet!(@fleet)
      paid = ProposalHelpers.wallet("b")
      operator = ProposalHelpers.wallet("d")
      message = "0x" <> String.duplicate("ab", 32)

      launch = %{
        name: "Fleet Coin",
        symbol: "FLT",
        description: "The fleet's own token",
        website: "https://example.com",
        image: "https://example.com/coin.png"
      }

      actions = [
        {:pay, @usdc, paid, 125_000},
        {:advance, 5, operator, @eth, 100_000, "0x" <> String.duplicate("e", 64)},
        {:rate, 75},
        {:edits, 12, true},
        {:signature, :approve, message},
        {:launch, launch}
      ]

      calls =
        for action <- actions, {target, value, data} <- Actions.encode(action, fleet) do
          %{target: target, value: value, data: data}
        end

      unknown = Call.encode("transferOwnership(address)", [paid])

      ProposalHelpers.proposal!(@fleet, 1,
        calls: calls ++ [%{target: paid, value: 0, data: unknown}]
      )

      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 40_000_000)])

      for token_id <- 1..51, do: ProposalHelpers.vote!(@fleet, 1, @voter, :yes, [token_id])
      votes!(1, no: [52], abstain: [53, 54])
      ProposalHelpers.proposal!(@fleet, 2)

      ChainViews.put!(
        on_chain(1, :open, e0: 60, late: 0, yes: 51, no: 1, abstain: 2) ++
          on_chain(2, :open)
      )

      {:ok, view, _html} = live(conn, "#{@list}/1")

      assert has_element?(view, "#proposal-status", "Open")
      assert has_element?(view, "#proposal-yes", "51 Keys")
      assert has_element?(view, "#proposal-no", "1 Key")
      assert has_element?(view, "#proposal-abstain", "2 Keys")
      assert has_element?(view, "#proposal-counted", "60 Keys")

      assert has_element?(
               view,
               "#proposal-counted-tip",
               "60 present when it opened, and 0 more that voted since."
             )

      assert has_element?(view, "#proposal-rule", @rule)
      assert has_element?(view, "#proposal-proposer", "Key 1,")
      assert has_element?(view, "#proposal-proposer code[title='#{ProposalHelpers.wallet("f")}']")
      assert has_element?(view, "#proposal-content-tip", "0x" <> String.duplicate("d", 64))

      # Each call in a few words, with the wallet or code it names in full.
      assert lines(view, "#proposal-calls .proposals-call-words") == [
               "Pay 12.5% of the treasury’s USDC to #{paid}",
               "Advance 10% of the treasury’s ETH (advance 5) to #{operator}",
               "Set the daily split to 0.75%",
               "Stop Key 12 changing the workspace",
               "Sign a message for the fleet: #{message}",
               "Launch Fleet Coin (FLT) through Autolaunch, for the treasury",
               "A call Keyfleet doesn’t recognize. Check it before you vote."
             ]

      # A payment's share at the treasury's latest balance, and every call
      # exactly as carrying it out sends it.
      assert has_element?(view, "#proposal-calls li", "About 5 USDC at today’s balance")

      assert cell_texts(view, "#proposal-calls li:first-child .proposals-call dd") == [
               "Fleet treasury #{@treasury}",
               "pay(address,address,uint32)",
               hd(calls).data
             ]

      assert cell_texts(view, "#proposal-calls li:last-child .proposals-call dd") == [
               "Not a Keyfleet contract #{paid}",
               "Unknown",
               unknown
             ]

      assert length(lines(view, "#proposal-votes li")) == 50
      assert hd(lines(view, "#proposal-votes li")) == "Yes 0xeeee..eeee, with Key 1"

      view |> element("#proposal-more-votes") |> render_click()

      assert lines(view, "#proposal-votes li") == [
               "Yes 0xeeee..eeee, with Key 51",
               "No 0xeeee..eeee, with Key 52",
               "Abstain 0xeeee..eeee, with Keys 53, 54"
             ]

      view |> element("#proposal-first-votes") |> render_click()
      assert length(lines(view, "#proposal-votes li")) == 50

      # A decision moves nothing.
      {:ok, view, _html} = live(conn, "#{@list}/2")
      assert has_element?(view, "#proposal-no-calls", "A decision. Nothing moves.")
    end

    test "a proposal whose standing can't be read from the network says so", %{conn: conn} do
      ProposalHelpers.proposal!(@fleet, 1)

      ChainViews.put!([
        {@votes, "status(uint256)", [1], :revert},
        {@votes, "proposal(uint256)", [1], :revert}
      ])

      {:ok, view, _html} = live(conn, "#{@list}/1")

      assert has_element?(view, "#proposal-status", "Standing")

      assert has_element?(
               view,
               "#proposal-unread",
               "Can’t reach the network right now. Refresh to try again."
             )

      refute has_element?(view, "#proposal-yes")
    end

    # Only ETH and the fleet's own USDC, known by their addresses, are shown
    # without one. A token anywhere else that calls itself USDC always has its
    # address beside every amount of it.
    test "a token calling itself USDC is shown with its address", %{conn: conn} do
      fake = ProposalHelpers.wallet("d")
      ProposalHelpers.asset_details!(@fleet, fake, "USDC", 6)

      ProposalHelpers.treasury_reading!(@fleet, [
        balance(@usdc, held: 1_000_000),
        balance(fake, held: 1_000_000, backed: 3_000_000)
      ])

      money!(:paid,
        asset: fake,
        account: ProposalHelpers.wallet("b"),
        share: 10_000,
        amount: 2_000_000
      )

      {:ok, view, _html} = live(conn, @list)

      assert cells(view, fake) == ["1 USDC 0xdddd..dddd", "3 USDC 0xdddd..dddd"]
      assert cells(view, @usdc) == ["1 USDC", "0 USDC"]

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
        assert hd(cells(view, asset)) ==
                 "1,234,000 in the smallest units of token #{RegentFormat.short_address(asset)}"
      end
    end

    # The contract holds any uint256, which is shown to the last digit.
    test "the largest amount the contract can hold is shown whole", %{conn: conn} do
      max = 2 ** 256 - 1
      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: max, backed: max)])

      whole =
        "115,792,089,237,316,195,423,570,985,008,687,907,853,269,984,665,640,564,039,457,584," <>
          "007,913,129.639935 USDC"

      {:ok, view, _html} = live(conn, @list)
      assert cells(view, @usdc) == [whole, whole]
    end

    test "while votes are still being read the page says so", %{conn: conn} do
      ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
      ProposalHelpers.proposal!(@fleet, 1)
      ChainViews.put!(on_chain(1, :open))

      for path <- [@list, "#{@list}/1"] do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "#proposals-catching-up", "Vote counts are catching up.")
      end
    end

    test "a fleet or proposal that isn't there says so, and a name that can't be one is not found",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/app/fleets/hull_survey/proposals")
      assert html =~ "This fleet doesn’t exist."

      {:ok, _view, html} = live(conn, "/app/fleets/hull_survey/proposals/1")
      assert html =~ "This fleet doesn’t exist."

      {:ok, view, html} = live(conn, "#{@list}/9")
      assert html =~ "There is no proposal 9 in this fleet yet."
      assert has_element?(view, "#proposal-missing a[href='#{@list}']")

      {:ok, view, _html} = live(conn, @list)
      assert has_element?(view, "#proposals-empty", "No proposals yet.")

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
      ProposalHelpers.proposal!(@fleet, 1)
      ChainViews.put!(on_chain(1, :open))

      {:ok, view, _html} = live(conn, "#{@list}/1")
      {:ok, list, _html} = live(conn, @list)
      assert has_element?(view, "#proposal-yes", "0 Keys")

      ProposalHelpers.vote!(@fleet, 1, @voter, :yes, [1, 2])
      ChainViews.put!(on_chain(1, :open, late: 2, yes: 2))
      assert has_element?(view, "#proposal-yes", "0 Keys")

      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Proposals.topic(@fleet),
        {:proposals_changed, @fleet}
      )

      assert shows?(fn -> has_element?(view, "#proposal-yes", "2 Keys") end)

      assert shows?(fn ->
               text(list, ~s([data-proposal="1"] .proposals-detail)) =~ "2 yes, 0 no"
             end)
    end

    test "a notice that balances were read has an open page show them", %{conn: conn} do
      {:ok, view, _html} = live(conn, @list)
      assert has_element?(view, "#proposals-budget-pending", "Reading…")

      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 3_000_000)])
      assert has_element?(view, "#proposals-budget-pending")

      Phoenix.PubSub.broadcast(
        Keyfleet.PubSub,
        Proposals.topic(@fleet),
        {:balances_changed, @fleet}
      )

      assert shows?(fn -> has_element?(view, "#proposals-balances [data-asset='#{@usdc}']") end)
      assert cells(view, @usdc) == ["3 USDC", "0 USDC"]
    end

    test "the treasury shows each balance, what is set aside, the split, advances and history",
         %{conn: conn} do
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
        daily_split_bps: 75,
        next_run_at: ~U[2026-09-21 12:00:00Z]
      )

      money!(:forwarded, asset: @usdc, by: @voter, amount: 10_000_000)
      money!(:split_allocated, asset: @usdc, balance: 50_000_000, per_key: 250_000, keys: 4)

      money!(:paid,
        asset: weth,
        account: ProposalHelpers.wallet("b"),
        share: 250_000,
        amount: 5 * 10 ** 17
      )

      money!(:protocol_share_sent, by: @voter, amount: 1_000_000)

      money!(:advanced,
        advance_id: 1,
        account: operator,
        asset: @usdc,
        share: 40_000,
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

      assert cells(view, @eth) == ["1 ETH", "0 ETH"]
      assert cells(view, @usdc) == ["100 USDC", "30 USDC"]
      assert cells(view, weth) == ["2 WETH 0xcccc..cccc", "0 WETH 0xcccc..cccc"]

      assert has_element?(
               view,
               "#proposals-backed-tip",
               "Already shared with Keys and waiting to be claimed."
             )

      assert fields(view, "#proposals-split div") == [
               {"Daily split", "0.75%"},
               {"Next split", "21 September 2026 at 12:00 UTC"}
             ]

      assert text(view, "#proposals-advances li > span") ==
               "Advance 1: 3 USDC of 4 USDC, 0xdddd..dddd"

      # The return of all that is still out is typed already.
      assert has_element?(view, "#proposals-return-1-amount[value='3']")

      # Newest first; an advance coming back changes only what is still out.
      assert lines(view, "#proposals-history li") == [
               "Advanced 4 USDC to 0xdddd..dddd",
               "Sent to Regents 1 USDC",
               "Paid 0.5 WETH 0xcccc..cccc to 0xbbbb..bbbb",
               "Shared with Key holders 1 USDC",
               "Received 10 USDC"
             ]
    end

    test "the treasury says what it doesn't know yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, @list)

      assert has_element?(view, "#proposals-budget-pending", "Reading…")
      assert has_element?(view, "#proposals-no-advances", "None.")
      assert has_element?(view, "#proposals-no-history", "Nothing yet.")

      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 50_000_000)])

      for _payment <- 1..21,
          do:
            money!(:paid,
              asset: @usdc,
              account: ProposalHelpers.wallet("b"),
              share: 1,
              amount: 1
            )

      {:ok, view, _html} = live(conn, @list)

      assert fields(view, "#proposals-split div") == [{"Daily split", "1%"}]
      assert length(lines(view, "#proposals-history li")) == 20
      assert has_element?(view, "#proposals-history-more", "Earlier ones aren’t shown.")
    end

    # Until a fleet is on chain it has no treasury, and its page has no
    # buttons and says nothing about one.
    test "a fleet not yet on chain shows no treasury and no buttons", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/app/fleets/fleet_tech_classic"}}} =
               live(conn, "/app/fleets/fleet_tech_classic/proposals")
    end

    test "the fleet's page leads to its proposals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/app/fleets/#{@fleet}")
      assert has_element?(view, "#fleet-proposals-link[href='#{@list}']", "Proposals")
    end
  end

  describe "the wallet buttons on the list" do
    # Keys 1 and 2 are the holder's; Key 3 is another's, with the holder's
    # shard on it, so the holder may mark it present too.
    test "the present card marks every key the wallet may, and says when tidying is needed", %{
      conn: conn
    } do
      ProposalHelpers.keys_sold!(@fleet, 1..2, @holder)
      ProposalHelpers.keys_sold!(@fleet, [3], @other)
      ChainHelpers.issue_shard!(@fleet, 3, @holder)
      until = now() + 3_600

      ChainViews.put!(
        list_views(
          keys: [{1, @holder, until}, {2, @holder, 0}, {3, @other, 0}],
          maintenance: true
        ) ++
          [{@shards, "isActive(uint256,address)", [id(3), @holder], {"bool", [true]}}]
      )

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      active!(view, "#proposals-present-action", @holder)

      assert lines(view, "#proposals-present-keys li") == [
               "Key 1 Present until 7 Oct, 13:00 UTC",
               "Key 2 Not present",
               "Key 3 Not present"
             ]

      assert has_element?(view, "#proposals-present-maintenance", "Maintenance needed")
      assert pressable?(view, "present", ["#proposals-present-mark"])
      assert pressable?(view, "sweep", ["#proposals-present-sweep"])

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-present-action",
        review: %{signer: @holder, steps: [present, sweep]}
      })

      assert {present.to, present.data} ==
               {@votes, Call.encode("present(uint256[])", [[id(1), id(2), id(3)]])}

      assert {sweep.to, sweep.data} == {@votes, Call.encode("sweepExpired(uint256)", [256])}
    end

    test "a wallet with no keys can't mark any present, but may still tidy up", %{conn: conn} do
      ChainViews.put!(list_views())

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      render_async(view)

      assert has_element?(view, "#proposals-present-mark[disabled]")
      assert has_element?(view, "#proposals-present-mark-why", "No Keys to use")
      assert pressable?(view, "sweep", ["#proposals-present-sweep"])
      refute has_element?(view, "#proposals-present-maintenance")
    end

    # Each proposal is built on the server from the form as typed, for the
    # signed-in wallet, and the page has it before anyone presses.
    test "a proposal of each kind is built with its exact calls", %{conn: conn} do
      fleet = Fleets.get_fleet!(@fleet)
      ProposalHelpers.keys_sold!(@fleet, [7], @holder)
      recipient = ProposalHelpers.wallet("b")

      ChainViews.put!(
        list_views(keys: [{7, @holder, 0}], usdc_held: 100_000_000) ++
          [{@votes, "proposalCount()", [], {"uint256", [4]}}],
        balances: %{@treasury => 10 ** 18}
      )

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      active!(view, "#propose-action", @holder)

      assert text(view, "#propose-action-line") == "Type the Key you’re proposing with."
      assert pressable?(view, "propose", ["#propose-button"])

      expect = fn typed, action, line ->
        text = typed[:text] || "Hire a designer"
        typed = Keyword.merge([key: "7", text: text], typed)
        view |> form("#propose-action-form", typed) |> render_change()
        render_async(view)

        assert_push_event(view, "onchain-steps:review", %{
          component_id: "propose-action",
          review: %{signer: @holder, steps: [%{step: "propose", to: @votes} = step]}
        })

        assert step.data ==
                 Call.encode(@propose, [id(7), keccak(text), Actions.encode(action, fleet)])

        assert text(view, "#propose-action-line") == "#{line} Voting closes 8 Oct, 12:00 UTC."
      end

      expect.([kind: "decision"], :decision, "A decision; nothing moves.")

      expect.(
        [kind: "pay", asset: @usdc, share: "12.5", recipient: recipient],
        {:pay, @usdc, recipient, 125_000},
        "Pays 12.5% of the treasury’s USDC (about 12.5 USDC today) to 0xbbbb..bbbb."
      )

      # An advance takes the number the proposal is about to take.
      expect.(
        [kind: "advance", text: "Run the servers", asset: @eth, share: "50"],
        {:advance, 5, recipient, @eth, 500_000, keccak("Run the servers")},
        "Advances 50% of the treasury’s ETH (about 0.5 ETH today) to 0xbbbb..bbbb."
      )

      expect.([kind: "rate", rate: "0.75"], {:rate, 75}, "Sets the daily split to 0.75%.")

      expect.(
        [kind: "edits", target: "12", restricted: "true"],
        {:edits, 12, true},
        "Restricts Key 12’s edits."
      )

      expect.(
        [kind: "edits", restricted: "false"],
        {:edits, 12, false},
        "Allows Key 12’s edits."
      )

      hash = "0x" <> String.duplicate("ab", 32)

      expect.(
        [kind: "signature", signature: "approve", hash: hash],
        {:signature, :approve, hash},
        "Signs the message for the fleet."
      )

      expect.(
        [kind: "signature", signature: "revoke"],
        {:signature, :revoke, hash},
        "Withdraws the fleet’s signature."
      )

      launch = %{
        name: "Fleet Coin",
        symbol: "FLT",
        description: "The fleet's own token",
        website: "https://example.com",
        image: "https://example.com/coin.png"
      }

      expect.(
        [kind: "launch"] ++ Enum.to_list(launch),
        {:launch, launch},
        "Launches FLT through Autolaunch."
      )

      # Typed as it can't be sent, the line says what to fix.
      view |> form("#propose-action-form", kind: "rate", rate: "5") |> render_change()
      render_async(view)
      assert text(view, "#propose-action-line") == "From 0.1% to 2%."
    end

    # The words are saved as the press starts, before the wallet answers, and
    # shown only with a proposal whose fingerprint on the chain is theirs.
    test "a proposal's words are saved at the press and shown with the proposal they match",
         %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, [7], @holder)

      ChainViews.put!(
        list_views(keys: [{7, @holder, 0}]) ++ on_chain(1, :open) ++ on_chain(2, :open)
      )

      words = "Hire a designer\nfor the fleet's page."

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      active!(view, "#propose-action", @holder)

      view
      |> with_target("#propose-action")
      |> render_hook("step_pressed", %{
        "step" => "propose",
        "form" => %{"kind" => "decision", "key" => "7", "text" => "  #{words} "}
      })

      ProposalHelpers.proposal!(@fleet, 1, content_hash: keccak(words))
      ProposalHelpers.proposal!(@fleet, 2, content_hash: keccak("Other words"))

      {:ok, matched, _html} = live(conn, "#{@list}/1")
      assert text(matched, "#proposal-text") == "Hire a designer for the fleet's page."

      {:ok, unmatched, _html} = live(conn, "#{@list}/2")
      refute has_element?(unmatched, "#proposal-text")
      assert has_element?(unmatched, "#proposal-content-tip", "weren’t saved")
    end

    test "proposing with a key the wallet may not use stays in view, saying why", %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, [7], @other)

      ChainViews.put!(
        list_views(keys: [{7, @other, 0}]) ++
          [{@shards, "mayGovern(uint256,address)", [id(7), @holder], {"bool", [false]}}]
      )

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)

      view
      |> form("#propose-action-form", kind: "decision", key: "7", text: "Hire a designer")
      |> render_change()

      render_async(view)

      assert has_element?(view, "#propose-button[disabled]")
      assert has_element?(view, "#propose-button-why", "Not your Key")
    end

    test "the split preview shows each asset's share now, and the split opens on time", %{
      conn: conn
    } do
      opens = now() + 3_600
      last = now() - 20 * 3_600

      views = fn next_run_at ->
        list_views(
          split_assets: [@usdc, @eth],
          usdc_held: 250_000_000,
          minted: 4,
          last_run_at: last,
          next_run_at: next_run_at
        )
      end

      ChainViews.put!(views.(opens), balances: %{@treasury => 10 ** 17})

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      active!(view, "#proposals-split-action", @holder)

      assert preview(view, @usdc) == ["USDC", "250 USDC", "100 USDC", "0.625 USDC"]
      assert preview(view, @eth) == ["ETH", "0.1 ETH", "0.05 ETH", "0.00025 ETH"]
      assert text(view, "#proposals-split-last") == "6 October 2026 at 16:00 UTC"
      assert text(view, "#proposals-split-opens") == "7 October 2026 at 13:00 UTC"

      assert has_element?(view, "#proposals-run-split[disabled]")
      assert has_element?(view, "#proposals-run-split-why", "Opens 7 Oct, 13:00 UTC")

      # Once it is due, anyone may run it.
      ChainViews.put!(views.(now() - 60), balances: %{@treasury => 10 ** 17})
      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      active!(view, "#proposals-split-action", @holder)

      assert pressable?(view, "run_split", ["#proposals-run-split"])

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-split-action",
        review: %{steps: [%{step: "run_split", to: @treasury} = run]}
      })

      assert run.data == Call.encode("runDailySplit()", [])
    end

    test "before any key is sold the split can't run, and says so", %{conn: conn} do
      ChainViews.put!(list_views(minted: 0, next_run_at: 0))

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      render_async(view)

      assert has_element?(view, "#proposals-run-split-why", "No Keys sold yet")
      refute has_element?(view, "#proposals-split-opens")
      assert text(view, "#proposals-split-last") == "Never"
    end

    test "returning an advance approves the token first, then returns it", %{conn: conn} do
      operator = ProposalHelpers.wallet("d")
      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 1)])

      money!(:advanced,
        advance_id: 1,
        account: operator,
        asset: @usdc,
        share: 40_000,
        amount: 4_000_000,
        purpose_hash: "0x" <> String.duplicate("e", 64)
      )

      money!(:advance_returned, advance_id: 1, by: operator, amount: 1, outstanding: 3_000_000)

      views = fn allowance ->
        list_views() ++
          [
            {@treasury, "advances(uint256)", [1],
             {"address,address,uint256,bytes32",
              [operator, @usdc, 3_000_000, "0x" <> String.duplicate("e", 64)]}},
            {@usdc, "balanceOf(address)", [@holder], {"uint256", [5_000_000]}},
            {@usdc, "allowance(address,address)", [@holder, @treasury], {"uint256", [allowance]}}
          ]
      end

      ChainViews.put!(views.(0))

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      active!(view, "#proposals-return-1", @holder)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-return-1",
        review: %{steps: [approve, give_back]} = review
      })

      assert {approve.to, approve.data} ==
               {@usdc, Call.encode("approve(address,uint256)", [@treasury, 3_000_000])}

      assert {give_back.to, give_back.data, give_back.value} ==
               {@treasury, Call.encode("returnAdvance(uint256,uint256)", [1, 3_000_000]), "0x0"}

      assert pressable?(view, "approve", ["#proposals-return-1-approve"])
      assert has_element?(view, "#proposals-return-1-button-why", "Approve first")

      # A pending approval is never a reason: the return may be pressed as
      # soon as the approval is sent, before it lands.
      hash = "0x" <> String.duplicate("4", 64)
      TestChainNode.land!(hash, review, approve, "0x1")

      view
      |> with_target("#proposals-return-1")
      |> render_hook("step_sent", %{
        "review_id" => review.id,
        "step" => "approve",
        "transaction_hash" => hash
      })

      assert pressable?(view, "return", ["#proposals-return-1-button"])

      # More than is still out is certain to fail.
      view |> form("#proposals-return-1-form", amount: "4") |> render_change()
      render_async(view)
      assert has_element?(view, "#proposals-return-1-button-why", "More than is owed")

      # With the approval on chain, the return may be pressed.
      ChainViews.put!(views.(3_000_000))
      view |> form("#proposals-return-1-form", amount: "3") |> render_change()
      render_async(view)
      assert pressable?(view, "return", ["#proposals-return-1-button"])
    end

    test "sending Regents its share says what is owed, and waits for something owed", %{
      conn: conn
    } do
      ChainViews.put!(list_views(owed: 0))

      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      render_async(view)

      assert has_element?(view, "#proposals-send-share[disabled]")
      assert has_element?(view, "#proposals-send-share-why", "Nothing owed")

      ChainViews.put!(list_views(owed: 2_500_000))
      {:ok, view, _html} = live(signed_in_as(conn, @holder), @list)
      active!(view, "#proposals-regents-share", @holder)

      assert text(view, "#proposals-regents-share-line") == "Owed: 2.5 USDC."
      assert pressable?(view, "send_share", ["#proposals-send-share"])

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-regents-share",
        review: %{steps: [%{step: "send_share", to: @fleet_contract} = send]}
      })

      assert send.data == Call.encode("sendProtocolShare()", [])
    end

    # Signed out, the split preview and presence are read from the chain as
    # for a member and shown without their buttons. Nothing is built for the
    # other buttons, so nothing holds them back: every press reaches the
    # wallet, which asks to sign in.
    test "signed out, the split and presence show read-only, and the other buttons take the press",
         %{conn: conn} do
      ChainViews.put!(
        list_views(usdc_held: 250_000_000, minted: 4, keys: [{2, @other, 0}], maintenance: true)
      )

      {:ok, view, _html} = live(conn, @list)
      render_async(view)

      assert preview(view, @usdc) == ["USDC", "250 USDC", "100 USDC", "0.625 USDC"]
      assert has_element?(view, "#proposals-present-maintenance", "Maintenance needed")
      refute has_element?(view, "#proposals-split-action [data-onchain-step]")
      refute has_element?(view, "#proposals-present-action [data-onchain-step]")

      assert pressable?(view, "propose", ["#propose-button"])
      assert pressable?(view, "send_share", ["#proposals-send-share"])
    end
  end

  describe "the wallet buttons on a proposal" do
    # Keys 1 and 2 are the holder's; Key 3 is another's, with the holder's
    # shard on it and its agent voting on.
    test "a ballot votes every key the wallet may, all at once", %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, 1..2, @holder)
      ProposalHelpers.keys_sold!(@fleet, [3], @other)
      ChainHelpers.issue_shard!(@fleet, 3, @holder)
      ProposalHelpers.proposal!(@fleet, 1)

      ChainViews.put!(
        on_chain(1, :open) ++
          owners([{1, @holder}, {2, @holder}, {3, @other}]) ++
          [{@shards, "mayGovern(uint256,address)", [id(3), @holder], {"bool", [true]}}]
      )

      {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
      active!(view, "#proposal-vote-action", @holder)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposal-vote-action",
        review: %{signer: @holder, steps: [yes, no, abstain]}
      })

      for {step, name, choice} <- [{yes, "yes", 1}, {no, "no", 2}, {abstain, "abstain", 3}] do
        assert {step.step, step.to, step.data} ==
                 {name, @votes,
                  Call.encode("castBallot(uint256,uint256[],uint8)", [
                    1,
                    [id(1), id(2), id(3)],
                    choice
                  ])}
      end

      assert text(view, "#proposal-vote-action-line") == "With Keys 1, 2, 3."
      assert text(view, "#proposal-vote-action-from") == "Sending from 0x1111..1111 on Base."
      assert ballot_pressable?(view)
    end

    # Each button the chain's own state makes certain to fail stays in view,
    # disabled, with a few words saying why.
    test "carrying out and cancelling say why, as the proposal stands on chain", %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, [1], @holder)
      for number <- 1..7, do: ProposalHelpers.proposal!(@fleet, number)
      waiting = Proposals.get_by_number(@fleet, 2)
      from = "From " <> WalletWords.at(Proposals.carry_out_from(waiting))

      ChainViews.put!(
        Enum.flat_map(Enum.with_index(@statuses, 1), fn {status, number} ->
          on_chain(number, status)
        end) ++ owners([{1, @holder}])
      )

      holder = signed_in_as(conn, @holder)

      for {number, word, carry_out, cancel} <- [
            {1, "Open", "Voting still open", nil},
            {2, "Approved, waiting", from, nil},
            {3, "Approved", nil, nil},
            {4, "Not approved", "Not approved", "Not approved"},
            {5, "Cancelled", "Cancelled", "Cancelled"},
            {6, "Carried out", "Already carried out", "Already carried out"},
            {7, "Expired", "Expired", "Expired"}
          ] do
        {:ok, view, _html} = live(holder, "#{@list}/#{number}")
        render_async(view)

        assert has_element?(view, "#proposal-status", word), "proposal #{number}"
        assert why(view, "#proposal-carry-out-button") == carry_out, "proposal #{number}"
        assert why(view, "#proposal-cancel-button") == cancel, "proposal #{number}"

        if number != 1 do
          assert why(view, "#proposal-vote-yes") == "Voting closed", "proposal #{number}"
          assert why(view, "#proposal-vote-abstain") == "Voting closed", "proposal #{number}"
        end
      end
    end

    test "carrying out passes the exact calls the proposal recorded", %{conn: conn} do
      fleet = Fleets.get_fleet!(@fleet)
      paid = ProposalHelpers.wallet("b")
      [{target, value, data}] = Actions.encode({:pay, @usdc, paid, 125_000}, fleet)
      ProposalHelpers.proposal!(@fleet, 2, calls: [%{target: target, value: value, data: data}])
      ChainViews.put!(on_chain(2, :approved) ++ owners([{1, @holder}]))

      {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/2")
      active!(view, "#proposal-carry-out-action", @holder)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposal-carry-out-action",
        review: %{steps: [%{step: "carry_out", to: @votes} = carry_out]}
      })

      assert carry_out.data == Call.encode(@execute, [2, [{target, value, data}]])
      assert pressable?(view, "carry_out", ["#proposal-carry-out-button"])
      assert pressable?(view, "cancel", ["#proposal-cancel-button"])
    end

    test "only whoever may vote its key can cancel a proposal", %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, [1], @other)
      ProposalHelpers.proposal!(@fleet, 1)

      ChainViews.put!(
        on_chain(1, :open) ++
          owners([{1, @other}]) ++
          [{@shards, "mayGovern(uint256,address)", [id(1), @holder], {"bool", [false]}}]
      )

      {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
      render_async(view)

      assert why(view, "#proposal-cancel-button") == "Not your Key"
      assert why(view, "#proposal-vote-yes") == "No Keys to use"
    end

    # A ballot the contract turns down says why it may have been, and the
    # buttons stay to press again.
    test "a ballot that doesn't go through says why it may not have", %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, [2], @holder)
      ProposalHelpers.proposal!(@fleet, 1)
      ChainViews.put!(on_chain(1, :open) ++ owners([{1, @other}, {2, @holder}]) ++ cancel_check())

      {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
      active!(view, "#proposal-vote-action", @holder)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposal-vote-action",
        review: %{steps: [yes | _]} = review
      })

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
               "Vote yes"
             )

      assert text(view, "#proposal-vote-action-sent span") =~
               "Not counted. Voting may have closed."

      assert ballot_pressable?(view)
    end

    # Skill rule 3: with a wallet open that the account doesn't link, the
    # figures stay on the account's own wallet and nothing is given to send.
    test "a wallet the account doesn't link gets nothing to send, and the note names both", %{
      conn: conn
    } do
      ProposalHelpers.keys_sold!(@fleet, [1], @holder)
      ProposalHelpers.proposal!(@fleet, 1)
      ChainViews.put!(on_chain(1, :open) ++ owners([{1, @holder}]))
      stranger = ProposalHelpers.wallet("b")

      {:ok, view, _html} = live(signed_in_as(conn, @holder), "#{@list}/1")
      active!(view, "#proposal-vote-action", stranger)

      refute_push_event(view, "onchain-steps:review", %{component_id: "proposal-vote-action"})

      assert text(view, "#proposal-vote-action-mismatch") ==
               "You're signed in with 0x1111..1111, but your wallet app has 0xbbbb..bbbb open. " <>
                 "Switch to a wallet on your account to send from here."

      assert has_element?(view, "#proposal-vote-action-from[hidden]")
      assert ballot_pressable?(view)

      # Signed out: nothing is built, and every button is still there.
      {:ok, view, _html} = live(conn, "#{@list}/1")
      active!(view, "#proposal-vote-action", @holder)
      refute_push_event(view, "onchain-steps:review", %{component_id: "proposal-vote-action"})
      assert has_element?(view, "#proposal-vote-action-line[hidden]")
      assert has_element?(view, "#proposal-vote-action-mismatch[hidden]")
      assert ballot_pressable?(view)
      assert pressable?(view, "carry_out", ["#proposal-carry-out-button"])
      assert pressable?(view, "cancel", ["#proposal-cancel-button"])

      view
      |> with_target("#proposal-vote-action")
      |> render_hook("step_failed", %{"step" => "yes", "reason" => "wallet_unavailable"})

      assert text(view, "#proposal-vote-action-press-note") ==
               "Sign in to send this. Nothing was sent."
    end
  end

  # The vote contract's answers for proposal `number`: its status and its
  # figures, each count 0 and Key 1 its author unless `counts` says.
  defp on_chain(number, status, counts \\ []) do
    counts = Keyword.merge([e0: 0, late: 0, yes: 0, no: 0, abstain: 0], counts)
    zero = "0x" <> String.duplicate("0", 64)

    [
      {@votes, "status(uint256)", [number],
       {"uint8", [Enum.find_index(@statuses, &(&1 == status))]}},
      {@votes, "proposal(uint256)", [number],
       {@proposal_types,
        [zero, zero, zero, id(1), 1, 0, 0, 0] ++
          Enum.map([:e0, :late, :yes, :no, :abstain], &counts[&1]) ++ [false, false]}}
    ]
  end

  defp owners(holders) do
    for {key, holder} <- holders,
        do: {@keys, "ownerOf(uint256)", [id(key)], {"address", [holder]}}
  end

  # Cancelling proposal 1 reads whether its key, held by another, is the
  # holder's to govern through a shard.
  defp cancel_check,
    do: [{@shards, "mayGovern(uint256,address)", [id(1), @holder], {"bool", [false]}}]

  # What the list's buttons read for the signed-in wallet: the presence of
  # each of `keys` (`{key, holder, present until}`, each old enough to take
  # part) and whether lapsed presences wait to be cleared, when the treasury
  # opened, the daily split, and the share owed to Regents.
  defp list_views(opts \\ []) do
    presence =
      for {key, holder, until} <- Keyword.get(opts, :keys, []) do
        [
          {@keys, "ownerOf(uint256)", [id(key)], {"address", [holder]}},
          {@votes, "isActive(uint256)", [id(key)], {"bool", [until > 0]}},
          {@votes, "presentFrom(uint256)", [id(key)], {"uint64", [max(until - 172_800, 0)]}},
          {@votes, "maturesAt(uint256)", [id(key)], {"uint64", [1]}}
        ]
      end

    [
      {@votes, "sweepExpired(uint256)", [0],
       {"uint256,bool", [0, Keyword.get(opts, :maintenance, false)]}},
      {@votes, "treasuryOpensAt()", [], {"uint256", [1]}},
      {@treasury, "splitAssets()", [],
       {"address[]", [Keyword.get(opts, :split_assets, [@usdc])]}},
      {@treasury, "dailySplitBps()", [], {"uint256", [100]}},
      {@treasury, "lastRunAt()", [], {"uint256", [Keyword.get(opts, :last_run_at, 0)]}},
      {@treasury, "nextRunAt()", [], {"uint256", [Keyword.get(opts, :next_run_at, now() - 60)]}},
      {@fleet_contract, "totalMinted()", [], {"uint256", [Keyword.get(opts, :minted, 3)]}},
      {@usdc, "decimals()", [], {"uint8", [6]}},
      {@usdc, "balanceOf(address)", [@treasury], {"uint256", [Keyword.get(opts, :usdc_held, 0)]}},
      {@fleet_contract, "protocolShareOwed()", [], {"uint256", [Keyword.get(opts, :owed, 0)]}}
    ] ++ List.flatten(presence)
  end

  defp now, do: DateTime.to_unix(ChainViews.head().timestamp)

  defp id(key), do: ChainHelpers.onchain_id(@fleet, key)

  defp keccak(text), do: "0x" <> Base.encode16(ExKeccak.hash_256(text), case: :lower)

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

  # The treasury's balance and what is set aside, for one asset.
  defp cells(view, asset), do: cell_texts(view, "#proposals-balances [data-asset='#{asset}'] td")

  # The split preview's row for one asset.
  defp preview(view, asset),
    do: cell_texts(view, "#proposals-split-preview [data-asset='#{asset}'] td")

  defp cell_texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
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
      {field |> LazyHTML.query("dt") |> text(), field |> LazyHTML.query("dd") |> text()}
    end)
  end

  defp text(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> text()
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

  defp ballot_pressable?(view) do
    pressable?(view, "yes", ["#proposal-vote-yes"]) and
      pressable?(view, "no", ["#proposal-vote-no"]) and
      pressable?(view, "abstain", ["#proposal-vote-abstain"])
  end

  # Why a disabled button can't be pressed, as the words beside it say, or
  # nil for a button that takes the press.
  defp why(view, button) do
    if has_element?(view, "#{button}[disabled]") do
      text(view, "#{button}-why")
    else
      refute has_element?(view, "#{button}-why")
      nil
    end
  end

  # Privy's active wallet, as the wallet hook of the group `panel` reports it.
  defp active!(view, panel, wallet) do
    render_async(view)
    view |> with_target(panel) |> render_hook("onchain_active_wallet", %{"address" => wallet})
    render_async(view)
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

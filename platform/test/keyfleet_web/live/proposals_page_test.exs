defmodule KeyfleetWeb.Live.ProposalsPageTest do
  use KeyfleetWeb.ConnCase, async: false

  use Oban.Testing, repo: Keyfleet.Repo

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Chain.ReadBalances
  alias Keyfleet.Chain.StubClient
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ChainViews
  alias Keyfleet.Fleets
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.Proposals.Actions
  alias Keyfleet.SharedReading
  alias Keyfleet.TestChainNode
  alias KeyfleetWeb.FleetNow
  alias KeyfleetWeb.FleetProposals
  alias KeyfleetWeb.WalletWords
  alias RegentChain.BuilderCode
  alias RegentChain.Call

  # A page's first wallet build in a run also loads the code it runs, which
  # can take longer than ExUnit's 100 ms receive wait on a busy machine.
  @async_wait 3_000
  @fleet "fibonacci_syndicate"
  @list "/syndicate/1/proposals"
  @treasury_page "/syndicate/1/treasury"
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

    # Each read of a fleet's pages reads where each proposal on its list
    # stands on chain, so a test that describes no chain has one that can't
    # be reached; a test that describes one says every read, as before.
    StubClient.put_chain(ChainViews.head(), [],
      calls: fn _to, _data, _block -> {:error, :down} end
    )

    # The readings every page shares outlive a test's database, so each test
    # starts with none held.
    for kind <- [:fleet_proposals, :fleet_treasury, :proposal],
        id <- SharedReading.ids(kind),
        do: SharedReading.delete({kind, id})

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

      {:ok, view, html} = open(conn, @list)

      assert has_element?(view, "#proposals-rule", @rule)
      refute html =~ "Vote counts are catching up."
      refute has_element?(view, "#proposals-empty")

      # The fleet's money and the votes carried out are on its Treasury tab.
      assert has_element?(view, ~s(#fleet-tab-treasury[href="#{@treasury_page}"]), "Treasury")
      refute has_element?(view, "#proposals-budget")

      {:ok, treasury, _html} = open(conn, @treasury_page)
      assert has_element?(treasury, "#proposals-budget")
      assert lines(treasury, "#treasury-carried-list li") == ["Proposal 4"]

      assert cards(view) == [
               {"6", "Not approved"},
               {"5", "Cancelled"},
               {"4", "Carried out"},
               {"3", "Open"},
               {"2", "Approved"},
               {"1", "Open"}
             ]

      # Each card says its kind, and how its vote stands as a share of the Keys counted.
      assert text(view, ~s([data-proposal="3"] .proposals-type)) == "Decision"
      assert text(view, ~s([data-proposal="3"] #proposals-share-3)) == "60% yes"
      assert text(view, ~s([data-proposal="3"] .proposals-share .proposals-detail)) == "of 5 Keys"

      assert has_element?(
               view,
               ~s([data-proposal="3"] .proposals-share[title="3 yes, 1 no, 1 abstain, of 5 Keys counted"])
             )

      assert has_element?(view, ~s([data-proposal="3"] .proposals-when), "hours left")

      ChainViews.put!(on_chain(2, :approved))
      view |> element(~s([data-proposal="2"] a)) |> render_click()
      assert_patch(view, "#{Keyfleet.Fleets.path(@fleet)}/proposals/2")
    end

    # Where it stands is what the vote contract says at the latest block, so
    # the figures here are the chain's, not the votes this page recorded.
    test "a proposal's page shows its calls in plain words and exactly, how it stands on chain and every vote",
         %{conn: conn} do
      fleet = Fleets.get_fleet!(@fleet)
      paid = ProposalHelpers.wallet("b")
      operator = ProposalHelpers.wallet("d")
      issued_at = 1_790_000_000

      launch = %{
        name: "Fleet Coin",
        symbol: "FLT",
        description: "The fleet's own token",
        website: "https://example.com",
        image: "https://example.com/coin.png"
      }

      # The site makes no advance or Lit approval, but a proposal made on the
      # chain directly may, and its page says what it does.
      treasury = &[{fleet.treasury_address, 0, Call.encode(&1, &2)}]
      purpose = "0x" <> String.duplicate("e", 64)

      encoded = [
        Actions.encode({:pay, @usdc, paid, 125_000}, fleet),
        treasury.("advance(uint256,address,address,uint32,bytes32)", [
          5,
          operator,
          @eth,
          100_000,
          purpose
        ]),
        Actions.encode({:rate, 75}, fleet),
        Actions.encode({:edits, 12, true}, fleet),
        treasury.("approveLitCreateWallet(uint256)", [issued_at]),
        Actions.encode({:launch, launch}, fleet)
      ]

      calls =
        for {target, value, data} <- Enum.concat(encoded),
            do: %{target: target, value: value, data: data}

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

      # A proposal of more than one kind of call says so on the list.
      {:ok, list, _html} = open(conn, @list)
      assert text(list, ~s([data-proposal="1"] .proposals-type)) == "Several actions"

      {:ok, view, _html} = open(conn, "#{@list}/1")

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

      assert has_element?(
               view,
               "#proposal-proposer-wallet-copy[data-copy-text='#{ProposalHelpers.wallet("f")}']"
             )

      assert has_element?(view, "#proposal-content-tip", "0x" <> String.duplicate("d", 64))

      # Each call in a few words, with the wallet or code it names in full.
      assert lines(view, "#proposal-calls .proposals-call-words") == [
               "Pay 12.5% of the treasury’s USDC to #{paid}",
               "Advance 10% of the treasury’s ETH (advance 5) to #{operator}",
               "Set the Daily Treasury Slice to Keys to 0.75%",
               "Stop Key 12 changing the workspace",
               "Sign the fleet’s Lit wallet request timed 1790000000 (21 September 2026 at 14:13:20 UTC)",
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
      # A voter's wallet shows as every address does: short, then in full.
      voter = "0xeeee..eeee 0x" <> String.duplicate("e", 40)
      assert hd(lines(view, "#proposal-votes li")) == "Yes #{voter} with Key 1"

      view |> element("#proposal-more-votes") |> render_click()

      assert lines(view, "#proposal-votes li") == [
               "Yes #{voter} with Key 51",
               "No #{voter} with Key 52",
               "Abstain #{voter} with Keys 53, 54"
             ]

      view |> element("#proposal-first-votes") |> render_click()
      assert length(lines(view, "#proposal-votes li")) == 50

      # A decision moves nothing.
      {:ok, view, _html} = open(conn, "#{@list}/2")
      assert has_element?(view, "#proposal-no-calls", "A decision. Nothing moves.")
    end

    # An agent proposes and votes from its own wallet, through a shard; the
    # page named only the wallet, so nobody could tell which agent it was.
    test "a proposal and a vote an agent sent name the agent", %{conn: conn} do
      agent = ProposalHelpers.wallet("c")

      Keyfleet.Agents.ensure_profile!(%{name: "Mate", declared_harness: "local"},
        actor: Keyfleet.PairingHelpers.pair_wallet!(agent)
      )

      ProposalHelpers.proposal!(@fleet, 1, proposer: agent, author_key: 1_234)
      ProposalHelpers.vote!(@fleet, 1, agent, :yes, [1_234])
      ProposalHelpers.vote!(@fleet, 1, @voter, :no, [3])
      ChainViews.put!(on_chain(1, :open))

      {:ok, view, _html} = open(conn, "#{@list}/1")

      assert has_element?(view, "#proposal-proposer", "Mate (Key 1,234),")

      assert lines(view, "#proposal-votes li") == [
               "Yes Mate 0xcccc..cccc 0x#{String.duplicate("c", 40)} with Key 1,234",
               "No 0xeeee..eeee 0x#{String.duplicate("e", 40)} with Key 3"
             ]
    end

    # The fleets' shared reading names a fleet with no record by its id alone;
    # the Treasury says so, as the proposals pages do, instead of failing.
    test "the Treasury of a fleet with no record says the fleet doesn't exist" do
      html =
        render_component(&KeyfleetWeb.TreasuryLive.page/1,
          page: %{fleet_id: @fleet, fleet_name: nil},
          actor: nil,
          lease: nil
        )

      assert html =~ ~s(id="treasury-page")
      assert html =~ "This fleet doesn’t exist."
    end

    test "a proposal whose standing can't be read from the network says so", %{conn: conn} do
      ProposalHelpers.proposal!(@fleet, 1)

      ChainViews.put!([
        {@votes, "status(uint256)", [1], :revert},
        {@votes, "proposal(uint256)", [1], :revert}
      ])

      {:ok, view, _html} = open(conn, "#{@list}/1")

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

      {:ok, view, _html} = open(conn, @treasury_page)

      assert cells(view, fake) == ["1 USDC 0xdddd..dddd #{fake}", "3 USDC 0xdddd..dddd #{fake}"]
      assert cells(view, @usdc) == ["1 USDC", "0 USDC"]

      tokens =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#proposals-history .proposals-token .rg-address__label")
        |> Enum.map(&text/1)

      assert tokens == ["0xdddd..dddd"]
      assert has_element?(view, "#proposals-history .proposals-token [data-copy-text='#{fake}']")
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

      {:ok, view, _html} = open(conn, @treasury_page)

      for asset <- [no_symbol, no_decimals] do
        assert hd(cells(view, asset)) ==
                 "1,234,000 in the smallest units of token #{RegentFormat.short_address(asset)} #{asset}"
      end
    end

    test "a balance shows four decimal places, and below one token its first four digits",
         %{conn: conn} do
      ProposalHelpers.treasury_reading!(@fleet, [
        balance(@usdc, held: 27_864_999, backed: 4_321)
      ])

      {:ok, view, _html} = open(conn, @treasury_page)
      assert cells(view, @usdc) == ["27.8649 USDC", "0.004321 USDC"]
    end

    test "REGENT shows two decimal places, and less than 0.01 says so", %{conn: conn} do
      regent = "0x6f89bca4ea5931edfcb09786267b251dee752b07"

      ProposalHelpers.treasury_reading!(@fleet, [
        balance(regent, held: 9_750_773_103_342_555_816_583, backed: 4_321)
      ])

      {:ok, view, _html} = open(conn, @treasury_page)
      assert cells(view, regent) == ["9,750.77 REGENT", "<0.01 REGENT"]
    end

    # The contract holds any uint256, which is shown to its last whole digit
    # and four decimal places.
    test "the largest amount the contract can hold is shown whole", %{conn: conn} do
      max = 2 ** 256 - 1
      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: max, backed: max)])

      whole =
        "115,792,089,237,316,195,423,570,985,008,687,907,853,269,984,665,640,564,039,457,584," <>
          "007,913,129.6399 USDC"

      {:ok, view, _html} = open(conn, @treasury_page)
      assert cells(view, @usdc) == [whole, whole]
    end

    test "while votes are still being read the page says so", %{conn: conn} do
      ChainHelpers.seed_cursor!(@fleet, observed_at: DateTime.add(DateTime.utc_now(), -3600))
      ProposalHelpers.proposal!(@fleet, 1)
      ChainViews.put!(on_chain(1, :open))

      for path <- [@list, "#{@list}/1"] do
        {:ok, view, _html} = open(conn, path)
        assert has_element?(view, "#proposals-catching-up", "Vote counts are catching up.")
      end

      {:ok, view, _html} = open(conn, @treasury_page)
      assert has_element?(view, "#treasury-catching-up", "Treasury figures are catching up.")
    end

    test "a proposal that isn't there says so, and an address no fleet's proposals are at is not found",
         %{conn: conn} do
      {:ok, view, html} = open(conn, "#{@list}/9")
      assert html =~ "There is no proposal 9 in this fleet yet."
      assert has_element?(view, "#proposal-missing a[href='#{@list}']")

      {:ok, view, _html} = open(conn, @list)
      assert has_element?(view, "#proposals-empty", "No proposals yet.")

      for path <- [
            "/app/fleets/hull_survey/proposals",
            "/app/fleets/hull_survey/proposals/1",
            "/app/fleets/#{@fleet}/proposals",
            "/syndicate/2/proposals"
          ] do
        assert get(conn, path).status == 404
      end

      for path <- [
            "#{@list}/0",
            "#{@list}/01",
            "#{@list}/one",
            "#{@list}/#{String.duplicate("9", 19)}",
            "#{@list}?before=0",
            "#{@list}?before=x",
            "#{@list}/1?votes_after=-1"
          ] do
        assert_raise KeyfleetWeb.NotFoundError, fn -> open(conn, path) end
      end
    end

    test "proposals are listed twenty at a time, newest first", %{conn: conn} do
      for number <- 1..21, do: ProposalHelpers.proposal!(@fleet, number)

      {:ok, view, _html} = open(conn, @list)
      assert Enum.map(cards(view), &elem(&1, 0)) == Enum.map(21..2//-1, &to_string/1)
      refute has_element?(view, "#proposals-newest")

      view |> element("#proposals-older") |> render_click()
      assert Enum.map(cards(view), &elem(&1, 0)) == ["1"]
      refute has_element?(view, "#proposals-older")

      view |> element("#proposals-newest") |> render_click()
      assert length(cards(view)) == 20
    end

    # Every open page draws the fleet's next reading, and reads nothing itself.
    test "votes recorded reach every open page with the fleet's next reading", %{conn: conn} do
      ProposalHelpers.proposal!(@fleet, 1)
      ChainViews.put!(on_chain(1, :open))

      {:ok, view, _html} = open(conn, "#{@list}/1")
      {:ok, list, _html} = open(conn, @list)
      assert has_element?(view, "#proposal-yes", "0 Keys")

      ProposalHelpers.vote!(@fleet, 1, @voter, :yes, [1, 2])
      ChainViews.put!(on_chain(1, :open, late: 2, yes: 2))
      assert has_element?(view, "#proposal-yes", "0 Keys")

      FleetProposals.read(@fleet)

      assert shows?(fn -> has_element?(view, "#proposal-yes", "2 Keys") end)
      assert text(view, "#proposal-kind") == "Decision"

      assert has_element?(
               view,
               ~s(.proposals-share[title="2 yes, 0 no, 0 abstain, of 2 Keys counted"])
             )

      assert has_element?(view, "#proposal-left", "hours left")

      assert shows?(fn ->
               has_element?(list, ~s([data-proposal="1"] .proposals-share[title^="2 yes, 0 no"]))
             end)
    end

    test "balances read reach an open Treasury page with the fleet's next reading", %{
      conn: conn
    } do
      {:ok, view, _html} = open(conn, @treasury_page)

      assert has_element?(
               view,
               "#proposals-budget-pending",
               "Balances usually show up within five minutes."
             )

      # The treasury's whole address is there before any balance is read.
      assert has_element?(
               view,
               ~s(#proposals-treasury-explorer[href="https://basescan.org/address/#{@treasury}"])
             )

      assert has_element?(view, ~s(#proposals-treasury-copy[data-copy-text="#{@treasury}"]))

      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 3_000_000)])
      assert has_element?(view, "#proposals-budget-pending")

      FleetProposals.read(@fleet)

      assert shows?(fn -> has_element?(view, "#proposals-balances [data-asset='#{@usdc}']") end)
      assert cells(view, @usdc) == ["3 USDC", "0 USDC"]
      assert has_element?(view, "#proposals-balances[tabindex='0']")
    end

    test "the treasury tab shows the USDC from Key sales waiting to become REGENT", %{
      conn: conn
    } do
      {:ok, view, _html} = open(conn, @treasury_page)

      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 0)],
        conversion_waiting: Decimal.new(72_576_000)
      )

      FleetProposals.read(@fleet)

      assert shows?(fn -> has_element?(view, "#proposals-waiting") end)
      assert text(view, "#proposals-waiting") == "Key sales waiting to become REGENT: 72.576 USDC"
    end

    test "a burst of notices is answered by one read of each fleet, for every open page", %{
      conn: conn
    } do
      producer = start_supervised!(FleetProposals)
      {:ok, _view, _html} = live(conn, @list)
      {:ok, _view, _html} = live(conn, @treasury_page)

      # Watch the fleets the producer reads; the two open pages read nothing.
      :erlang.trace_pattern({FleetProposals, :read, 1}, true, [:global])
      :erlang.trace(producer, true, [:call])
      on_exit(fn -> :erlang.trace_pattern({FleetProposals, :read, 1}, false, [:global]) end)

      send(producer, {:proposals_changed, @fleet})
      send(producer, {:balances_changed, @fleet})
      send(producer, {:keys_changed, @fleet, [1]})
      send(producer, {:proposals_changed, "fibonacci_cascade"})

      assert_receive {:trace, ^producer, :call, {FleetProposals, :read, [@fleet]}}, 2_000
      assert_receive {:trace, ^producer, :call, {FleetProposals, :read, ["fibonacci_cascade"]}}
      refute_receive {:trace, ^producer, :call, {FleetProposals, :read, _}}, 1_500
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

      {:ok, view, _html} = open(conn, @treasury_page)

      assert cells(view, @eth) == ["1 ETH", "0 ETH"]
      assert cells(view, @usdc) == ["100 USDC", "30 USDC"]
      assert cells(view, weth) == ["2 WETH 0xcccc..cccc #{weth}", "0 WETH 0xcccc..cccc #{weth}"]

      assert has_element?(
               view,
               "#proposals-backed-tip",
               "Held separately by the rewards contract, waiting for Key holders to claim."
             )

      assert text(view, "#proposals-split-rate") ==
               "0.75% of eligible balances, shared equally across Keys sold at least 2 days ago."

      assert text(view, "#proposals-split-next") ==
               "Next release: 21 September 2026 at 12:00 UTC."

      assert text(view, "#proposals-advances li > span") ==
               "Advance 1: 3 USDC of 4 USDC, 0xdddd..dddd #{ProposalHelpers.wallet("d")}"

      # Signed out, the advance shows without its Return; signed in, the
      # return of all that is still out is typed already.
      refute has_element?(view, "#proposals-return-1")
      {:ok, member, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      assert has_element?(member, "#proposals-return-1-amount[value='3']")

      # Newest first; an advance coming back changes only what is still out.
      assert lines(view, "#proposals-history li") == [
               "Advanced 4 USDC to 0xdddd..dddd #{ProposalHelpers.wallet("d")}",
               "Sent to REGENT staking 1 USDC",
               "Paid 0.5 WETH 0xcccc..cccc #{weth} to 0xbbbb..bbbb #{ProposalHelpers.wallet("b")}",
               "Shared with Key holders 1 USDC",
               "Received 10 USDC"
             ]
    end

    # Costly failure: a release already due reads as a time gone by, and an
    # agent takes it for one missed (Grok Bot, 19 October 2026).
    test "a treasury release that is due reads as open now", %{conn: conn} do
      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 100_000_000)],
        block_time: ~U[2026-09-21 12:05:00Z],
        daily_split_bps: 75,
        next_run_at: ~U[2026-09-21 12:00:00Z]
      )

      {:ok, view, _html} = open(conn, @treasury_page)
      assert text(view, "#proposals-split-next") == "Next release: open now."
    end

    test "the treasury says what it doesn't know yet", %{conn: conn} do
      {:ok, view, _html} = open(conn, @treasury_page)

      assert has_element?(
               view,
               "#proposals-budget-pending",
               "Balances usually show up within five minutes."
             )

      refute has_element?(view, "#proposals-advances-title")
      assert has_element?(view, "#proposals-no-history", "No money has moved in or out yet.")

      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 50_000_000)])

      for _payment <- 1..21,
          do:
            money!(:paid,
              asset: @usdc,
              account: ProposalHelpers.wallet("b"),
              share: 1,
              amount: 1
            )

      {:ok, view, _html} = open(conn, @treasury_page)

      assert text(view, "#proposals-split-rate") ==
               "1% of eligible balances, shared equally across Keys sold at least 2 days ago."

      refute has_element?(view, "#proposals-split-next")
      assert length(lines(view, "#proposals-history li")) == 20
      assert has_element?(view, "#proposals-history-more", "Earlier ones aren’t shown.")
    end

    # Until a fleet is on chain it has no treasury, and its page has no
    # buttons and says nothing about one.
    test "a fleet not yet on chain shows no treasury and no buttons", %{conn: conn} do
      for page <- ["/classic/1/proposals", "/classic/1/treasury"] do
        assert {:error, {:live_redirect, %{to: "/classic/1"}}} = open(conn, page)
      end
    end

    test "the fleet's page leads to its proposals", %{conn: conn} do
      # A visitor's hall is drawn from the fleet's own reading.
      FleetNow.read(@fleet)
      {:ok, view, _html} = open(conn, "#{Keyfleet.Fleets.path(@fleet)}")
      assert has_element?(view, "#fleet-tab-proposals[href='#{@list}']", "Proposals")
    end
  end

  describe "the wallet buttons on the list" do
    # Keys 1 and 2 are the holder's; Key 3 is another's, with the holder's
    # shard on it, so the holder may mark it present too.
    test "the present card marks every key the wallet may, and lists the idle keys", %{
      conn: conn
    } do
      ProposalHelpers.keys_sold!(@fleet, 1..2, @holder)
      ProposalHelpers.keys_sold!(@fleet, [3], @other)
      ChainHelpers.issue_shard!(@fleet, 3, @holder)
      # The site's own record: Key 1 was marked present just now, so Keys 2
      # and 3 are the idle ones. Key 4 was sold today and waits two days for
      # its automatic start: it has no vote yet and isn't idle.
      ProposalHelpers.presence!(@fleet, 1, DateTime.utc_now())
      ProposalHelpers.keys_sold!(@fleet, [4], @other)
      ProposalHelpers.scheduled!(@fleet, 4, DateTime.add(DateTime.utc_now(), 2, :day))
      until = now() + 3_600

      ChainViews.put!(
        list_views(
          keys: [{1, @holder, until}, {2, @holder, 0}, {3, @other, 0}]
        ) ++
          [{@shards, "isActive(uint256,address)", [id(3), @holder], {"bool", [true]}}]
      )

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @list)
      active!(view, "#proposals-present-action", @holder)

      assert lines(view, "#proposals-present-keys li") == [
               "Key 1 Present until 7 Oct, 13:00 UTC",
               "Key 2 Not present",
               "Key 3 Not present"
             ]

      assert has_element?(view, "#proposals-present-figures-present", "1")

      assert pressable?(view, "present", ["#proposals-present-mark"])

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-present-action",
        review: %{signer: @holder, steps: [present]}
      })

      assert {present.to, present.data} ==
               {@votes,
                BuilderCode.append(Call.encode("present(uint256[])", [[id(1), id(2), id(3)]]))}
    end

    test "a wallet with no keys can't mark any present", %{
      conn: conn
    } do
      ChainViews.put!(list_views())

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @list)
      render_async(view, @async_wait)

      assert has_element?(view, "#proposals-present-mark[disabled]")
      assert has_element?(view, "#proposals-present-mark-why", "No Keys to use")
      assert has_element?(view, "#proposals-present-figures-present", "0")
    end

    # Each proposal is built on the server from the form as typed, for the
    # signed-in wallet, and the page has it before anyone presses.
    test "a proposal of each kind is built with its exact calls", %{conn: conn} do
      fleet = Fleets.get_fleet!(@fleet)
      ProposalHelpers.keys_sold!(@fleet, [7], @holder)
      recipient = ProposalHelpers.wallet("b")

      ChainViews.put!(
        list_views(keys: [{7, @holder, 0}], usdc_held: 100_000_000),
        balances: %{@treasury => 10 ** 18}
      )

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @list)
      active!(view, "#propose-action", @holder)

      assert text(view, "#propose-action-line") == "Type the Key you’re proposing with."
      assert pressable?(view, "propose", ["#propose-button"])

      expect = fn typed, action, line ->
        text = typed[:text] || "Hire a designer"
        typed = Keyword.merge([key: "7", text: text], typed)
        view |> form("#propose-action-form", typed) |> render_change()
        render_async(view, @async_wait)

        assert_push_event(view, "onchain-steps:review", %{
          component_id: "propose-action",
          review: %{signer: @holder, steps: [%{step: "propose", to: @votes} = step]}
        })

        assert step.data ==
                 BuilderCode.append(
                   Call.encode(@propose, [id(7), keccak(text), Actions.encode(action, fleet)])
                 )

        assert text(view, "#propose-action-line") == "#{line} Voting closes 8 Oct, 12:00 UTC."
      end

      expect.([kind: "decision"], :decision, "A decision; nothing moves.")

      expect.(
        [kind: "pay", asset: @usdc, share: "12.5", recipient: recipient],
        {:pay, @usdc, recipient, 125_000},
        "Pays 12.5% of the treasury’s USDC (about 12.5 USDC today) to 0xbbbb..bbbb."
      )

      expect.(
        [kind: "rate", rate: "0.75"],
        {:rate, 75},
        "Sets the Daily Treasury Slice to Keys to 0.75%."
      )

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
      render_async(view, @async_wait)
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

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @list)
      active!(view, "#propose-action", @holder)
      form = %{"kind" => "decision", "key" => "7", "text" => "  #{words} "}

      view |> form("#propose-action-form", form) |> render_change()
      render_async(view, @async_wait)

      press = fn ->
        view
        |> with_target("#propose-action")
        |> render_hook("step_pressed", %{"step" => "propose", "form" => form})
      end

      press.()

      ProposalHelpers.proposal!(@fleet, 1, content_hash: keccak(words))
      ProposalHelpers.proposal!(@fleet, 2, content_hash: keccak("Other words"))

      {:ok, matched, _html} = open(conn, "#{@list}/1")
      assert text(matched, "#proposal-text") == "Hire a designer for the fleet's page."

      {:ok, unmatched, _html} = open(conn, "#{@list}/2")
      refute has_element?(unmatched, "#proposal-text")
      assert has_element?(unmatched, "#proposal-content-tip", "weren’t saved")

      # Moved to another fleet's proposals, the same press saves nothing there,
      # also while that fleet's figures are still being read: a Key of the
      # first fleet says nothing about this one.
      ChainHelpers.deploy!("fibonacci_cascade", %{keys_address: @keys, shards_address: @shards})
      ChainHelpers.seed_cursor!("fibonacci_cascade")

      Keyfleet.Chain.StubClient.put_chain(ChainViews.head(), [],
        calls: fn _to, _data, _block_hash ->
          Process.sleep(300)
          {:error, :timeout}
        end
      )

      FleetProposals.read("fibonacci_cascade")
      render_patch(view, "/cascade/1/proposals")
      press.()
      assert [%{fleet_id: @fleet}] = Ash.read!(Keyfleet.Proposals.Words)
    end

    test "proposing with a key the wallet may not use stays in view, saying why", %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, [7], @other)

      ChainViews.put!(
        list_views(keys: [{7, @other, 0}]) ++
          [{@shards, "mayGovern(uint256,address)", [id(7), @holder], {"bool", [false]}}]
      )

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @list)

      view
      |> form("#propose-action-form", kind: "decision", key: "7", text: "Hire a designer")
      |> render_change()

      render_async(view, @async_wait)

      assert has_element?(view, "#propose-button[disabled]")
      assert has_element?(view, "#propose-button-why", "Not your Key")

      # Its words are not kept, however the press is sent.
      view
      |> with_target("#propose-action")
      |> render_hook("step_pressed", %{
        "step" => "propose",
        "form" => %{"kind" => "decision", "key" => "7", "text" => "Hire a designer"}
      })

      assert Ash.read!(Keyfleet.Proposals.Words) == []
    end

    test "the split preview cuts long amounts to four decimal places", %{conn: conn} do
      ChainViews.put!(list_views(split_assets: [@eth], minted: 4),
        balances: %{@treasury => 123_456_789_012_345_678_901}
      )

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      active!(view, "#proposals-split-action", @holder)

      assert preview(view, @eth) == ["123.4567 ETH", "0.05 ETH", "0.3086 ETH"]
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

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      active!(view, "#proposals-split-action", @holder)

      assert preview(view, @usdc) == ["250 USDC", "100 USDC", "0.625 USDC"]
      assert preview(view, @eth) == ["0.1 ETH", "0.05 ETH", "0.00025 ETH"]
      assert has_element?(view, "#proposals-split-preview[tabindex='0']")
      assert text(view, "#proposals-split-last") == "6 October 2026 at 16:00 UTC"
      assert text(view, "#proposals-split-opens") == "7 October 2026 at 13:00 UTC"

      assert has_element?(view, "#proposals-run-split[disabled]")
      assert has_element?(view, "#proposals-run-split-why", "Opens 7 Oct, 13:00 UTC")

      # Once it is due, anyone may run it.
      ChainViews.put!(views.(now() - 60), balances: %{@treasury => 10 ** 17})
      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      active!(view, "#proposals-split-action", @holder)

      assert text(view, "#proposals-split-opens") == "Open now"
      assert pressable?(view, "run_split", ["#proposals-run-split"])

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-split-action",
        review: %{steps: [%{step: "run_split", to: @treasury} = run]}
      })

      assert run.data == BuilderCode.append(Call.encode("runDailySplit()", []))
    end

    test "before any key is sold the split can't run, and says so", %{conn: conn} do
      ChainViews.put!(list_views(minted: 0, next_run_at: 0))

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      render_async(view, @async_wait)

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

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      active!(view, "#proposals-return-1", @holder)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-return-1",
        review: %{steps: [approve, give_back]} = review
      })

      assert {approve.to, approve.data} ==
               {@usdc,
                BuilderCode.append(
                  Call.encode("approve(address,uint256)", [@treasury, 3_000_000])
                )}

      assert {give_back.to, give_back.data, give_back.value} ==
               {@treasury,
                BuilderCode.append(Call.encode("returnAdvance(uint256,uint256)", [1, 3_000_000])),
                "0x0"}

      assert pressable?(view, "approve", ["#proposals-return-1-approve"])
      assert has_element?(view, "#proposals-return-1-button-why", "Approve first")
      refute has_element?(view, "#proposals-return-1-approve[data-done]")

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
      render_async(view, @async_wait)
      assert has_element?(view, "#proposals-return-1-button-why", "More than is owed")

      # With the approval on chain, the return may be pressed.
      ChainViews.put!(views.(3_000_000))
      view |> form("#proposals-return-1-form", amount: "3") |> render_change()
      render_async(view, @async_wait)
      assert pressable?(view, "return", ["#proposals-return-1-button"])

      # The approval sent from here stays in view, marked done, and still
      # takes presses.
      assert has_element?(view, "#proposals-return-1-approve[data-done]", "Approved")
      assert pressable?(view, "approve", ["#proposals-return-1-approve"])
    end

    test "sending Regents its share says what is owed, and waits for something owed", %{
      conn: conn
    } do
      ChainViews.put!(list_views(owed: 0))

      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      render_async(view, @async_wait)

      assert has_element?(view, "#proposals-send-share[disabled]")
      assert has_element?(view, "#proposals-send-share-why", "Nothing owed")

      ChainViews.put!(list_views(owed: 2_500_000))
      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      active!(view, "#proposals-regents-share", @holder)

      assert text(view, "#proposals-regents-share-line") == "Owed: 2.5 USDC."
      assert pressable?(view, "send_share", ["#proposals-send-share"])

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-regents-share",
        review: %{steps: [%{step: "send_share", to: @fleet_contract} = send]}
      })

      assert send.data == BuilderCode.append(Call.encode("sendProtocolShare()", []))
    end

    # The treasury's figures follow what was just done on its page (Sean,
    # 20 October 2026): a step that goes through reads the balances at once,
    # and the figures beside the other buttons are read again with them.
    test "a step that goes through reads the treasury's balances at once, and the split's figures with them",
         %{conn: conn} do
      ChainViews.put!(list_views(owed: 2_500_000, usdc_held: 250_000_000))
      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      active!(view, "#proposals-regents-share", @holder)

      assert preview(view, @usdc) |> hd() == "250 USDC"

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposals-regents-share",
        review: %{steps: [send_share]} = review
      })

      ChainViews.put!(list_views(owed: 0, usdc_held: 247_500_000))
      hash = "0x" <> String.duplicate("5", 64)
      TestChainNode.land!(hash, review, send_share, "0x1")

      view
      |> with_target("#proposals-regents-share")
      |> render_hook("step_sent", %{
        "review_id" => review.id,
        "step" => "send_share",
        "transaction_hash" => hash
      })

      assert shows?(fn ->
               render_async(view, @async_wait)
               preview(view, @usdc) |> hd() == "247.5 USDC"
             end)

      assert_enqueued(worker: ReadBalances, args: %{fleet_id: @fleet})
    end

    # Anyone may ask for fresh figures, each person once every 30 seconds
    # (Sean, 20 October 2026); here the allowance lasts a second.
    test "the refresh reads the treasury's balances at once, then rests until that person may press it again",
         %{conn: conn} do
      limits = Application.fetch_env!(:keyfleet, :limits)
      on_exit(fn -> Application.put_env(:keyfleet, :limits, limits) end)

      Application.put_env(
        :keyfleet,
        :limits,
        Keyword.put(limits, :treasury_refresh, limit: 1, window_seconds: 1)
      )

      ProposalHelpers.treasury_reading!(@fleet, [balance(@usdc, held: 3_000_000)])
      ChainViews.put!(list_views())
      {:ok, view, _html} = open(conn, @treasury_page)

      assert has_element?(view, "#proposals-read-again[aria-label='Refresh balances']")
      refute has_element?(view, "#proposals-read-again[disabled]")
      refute_enqueued(worker: ReadBalances, args: %{fleet_id: @fleet})

      view |> element("#proposals-read-again") |> render_click()

      assert_enqueued(worker: ReadBalances, args: %{fleet_id: @fleet})
      assert has_element?(view, "#proposals-read-again[disabled]")
      assert shows?(fn -> not has_element?(view, "#proposals-read-again[disabled]") end)
    end

    # Buy REGENT starts over once the wallet has the press (Sean, 19 October
    # 2026), so a second press never repeats an amount by mistake.
    test "a press of Buy REGENT clears its amount", %{conn: conn} do
      ChainViews.put!(list_views())
      {:ok, view, _html} = open(signed_in_as(conn, @holder), @treasury_page)
      render_async(view, @async_wait)

      amount = "#proposals-convert-form input[name=amount]"
      form = %{"amount" => "12.5"}
      view |> form("#proposals-convert-form", form) |> render_change()
      assert has_element?(view, ~s(#{amount}[value="12.5"]))

      view
      |> with_target("#proposals-convert")
      |> render_hook("step_pressed", %{"step" => "convert", "form" => form})

      assert has_element?(view, ~s(#{amount}[value=""]))
    end

    # Signed out, the split preview and presence are read from the chain as
    # for a member and shown without their buttons. The Treasury tab shows a
    # visitor its figures only: sending the staking share and turning USDC
    # into REGENT show once they sign in (Sean, 19 October 2026). Nothing is
    # built for Propose, so nothing holds it back: every press reaches the
    # wallet, which asks to sign in.
    test "signed out, the split and presence show read-only, the treasury shows no buttons, and Propose takes the press",
         %{conn: conn} do
      ChainViews.put!(
        list_views(usdc_held: 250_000_000, minted: 4, keys: [{2, @other, 0}])
      )

      {:ok, view, _html} = open(conn, @list)
      render_async(view, @async_wait)

      assert has_element?(view, "#proposals-present-figures-present", "0")
      refute has_element?(view, "#proposals-present-action [data-onchain-step]")
      assert pressable?(view, "propose", ["#propose-button"])

      {:ok, treasury, _html} = open(conn, @treasury_page)
      render_async(treasury, @async_wait)

      assert preview(treasury, @usdc) == ["250 USDC", "100 USDC", "0.625 USDC"]
      refute has_element?(treasury, "#proposals-split-action [data-onchain-step]")
      refute has_element?(treasury, "#proposals-regents-share")
      refute has_element?(treasury, "#proposals-convert")
      refute has_element?(treasury, "#proposals-share-title")
      refute has_element?(treasury, "#proposals-convert-title")
    end
  end

  describe "the wallet buttons on a proposal" do
    # Keys 1 and 2 are the holder's; Key 3 is another's, with the holder's
    # shard on it and its agent voting on.
    test "a ballot votes every key the wallet may, all at once", %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, 1..2, @holder)
      ProposalHelpers.keys_sold!(@fleet, [3], @other)
      ChainHelpers.issue_shard!(@fleet, 3, @holder)
      for number <- 1..2, do: ProposalHelpers.proposal!(@fleet, number)

      ChainViews.put!(
        on_chain(1, :open) ++
          on_chain(2, :open) ++
          owners([{1, @holder}, {2, @holder}, {3, @other}]) ++
          [{@shards, "mayGovern(uint256,address)", [id(3), @holder], {"bool", [true]}}]
      )

      {:ok, view, _html} = open(signed_in_as(conn, @holder), "#{@list}/1")
      active!(view, "#proposal-vote-action", @holder)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposal-vote-action",
        review: %{signer: @holder, steps: [yes, no, abstain]}
      })

      for {step, name, choice} <- [{yes, "yes", 1}, {no, "no", 2}, {abstain, "abstain", 3}] do
        assert {step.step, step.to, step.data} ==
                 {name, @votes,
                  BuilderCode.append(
                    Call.encode("castBallot(uint256,uint256[],uint8)", [
                      1,
                      [id(1), id(2), id(3)],
                      choice
                    ])
                  )}
      end

      assert text(view, "#proposal-vote-action-line") == "With Keys 1, 2, 3."

      assert text(view, "#proposal-vote-action-from") ==
               "Sending from 0x1111..1111 #{@holder} on Base."

      assert ballot_pressable?(view)

      # Moved to another proposal, this one's ballot leaves the page at once,
      # before the next one's is read.
      render_patch(view, "#{@list}/2")

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposal-vote-action",
        review: nil
      })
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
        {:ok, view, _html} = open(holder, "#{@list}/#{number}")
        render_async(view, @async_wait)

        assert has_element?(view, "#proposal-status", word), "proposal #{number}"
        assert why(view, "#proposal-carry-out-button") == carry_out, "proposal #{number}"
        assert why(view, "#proposal-cancel-button") == cancel, "proposal #{number}"

        closed = if number == 2, do: "Only No while it waits", else: "Voting closed"

        if number != 1 do
          assert why(view, "#proposal-vote-yes") == closed, "proposal #{number}"
          assert why(view, "#proposal-vote-abstain") == closed, "proposal #{number}"
        end
      end
    end

    test "carrying out passes the exact calls the proposal recorded", %{conn: conn} do
      fleet = Fleets.get_fleet!(@fleet)
      paid = ProposalHelpers.wallet("b")
      [{target, value, data}] = Actions.encode({:pay, @usdc, paid, 125_000}, fleet)
      ProposalHelpers.proposal!(@fleet, 2, calls: [%{target: target, value: value, data: data}])
      ChainViews.put!(on_chain(2, :approved) ++ owners([{1, @holder}]))

      {:ok, view, _html} = open(signed_in_as(conn, @holder), "#{@list}/2")
      active!(view, "#proposal-carry-out-action", @holder)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "proposal-carry-out-action",
        review: %{steps: [%{step: "carry_out", to: @votes} = carry_out]}
      })

      assert carry_out.data ==
               BuilderCode.append(Call.encode(@execute, [2, [{target, value, data}]]))

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

      {:ok, view, _html} = open(signed_in_as(conn, @holder), "#{@list}/1")
      render_async(view, @async_wait)

      assert why(view, "#proposal-cancel-button") == "Not your Key"
      assert why(view, "#proposal-vote-yes") == "No Keys to use"
    end

    # A ballot the contract turns down says why it may have been, and the
    # buttons stay to press again.
    test "a ballot that doesn't go through says why it may not have", %{conn: conn} do
      ProposalHelpers.keys_sold!(@fleet, [2], @holder)
      ProposalHelpers.proposal!(@fleet, 1)
      ChainViews.put!(on_chain(1, :open) ++ owners([{1, @other}, {2, @holder}]) ++ cancel_check())

      {:ok, view, _html} = open(signed_in_as(conn, @holder), "#{@list}/1")
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

      render_async(view, @async_wait)

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

      {:ok, view, _html} = open(signed_in_as(conn, @holder), "#{@list}/1")
      active!(view, "#proposal-vote-action", stranger)

      refute_push_event(view, "onchain-steps:review", %{component_id: "proposal-vote-action"})

      assert text(view, "#proposal-vote-action-mismatch") ==
               "Your wallet is on 0xbbbb..bbbb, which isn't linked to this account. " <>
                 "Switch to 0x1111..1111."

      assert has_element?(view, "#proposal-vote-action-from[hidden]")
      assert ballot_pressable?(view)

      # Signed out: nothing is built, and every button is still there.
      {:ok, view, _html} = open(conn, "#{@list}/1")
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
    Enum.flat_map(holders, fn {key, holder} ->
      [
        {@keys, "ownerOf(uint256)", [id(key)], {"address", [holder]}},
        {@votes, "maturesAt(uint256)", [id(key)], {"uint64", [1]}}
      ]
    end)
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
      {@votes, "sweepExpired(uint256)", [256], {"uint256,bool", [0, false]}},
      {@votes, "treasuryOpensAt()", [], {"uint256", [1]}},
      {@treasury, "splitAssets()", [],
       {"address[]", [Keyword.get(opts, :split_assets, [@usdc])]}},
      {@treasury, "dailySplitBps()", [], {"uint256", [100]}},
      {@treasury, "lastRunAt()", [], {"uint256", [Keyword.get(opts, :last_run_at, 0)]}},
      {@treasury, "nextRunAt()", [], {"uint256", [Keyword.get(opts, :next_run_at, now() - 60)]}},
      {@fleet_contract, "totalMinted()", [], {"uint256", [Keyword.get(opts, :minted, 3)]}},
      {@fleet_contract, "matureKeys()", [], {"uint256", [Keyword.get(opts, :minted, 3)]}},
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
    render_async(view, @async_wait)
    view |> with_target(panel) |> render_hook("onchain_active_wallet", %{"address" => wallet})
    render_async(view, @async_wait)
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

  # Pages draw on the readings `KeyfleetWeb.FleetProposals` shares, and its
  # producer doesn't run under test, so each page opens on a fresh read of
  # every fleet, taken after the test has written what the page shows.
  defp open(conn, path) do
    Enum.each(Fleets.catalog_ids(), &FleetProposals.read/1)
    live(conn, path)
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

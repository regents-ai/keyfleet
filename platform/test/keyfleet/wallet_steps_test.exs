defmodule Keyfleet.WalletStepsTest do
  # Each wallet button group's steps, built against a chain whose every view
  # the test names (`Keyfleet.ChainViews`). `Keyfleet.WalletStepsAnvilTest`
  # sends the same steps to the real contracts.
  use ExUnit.Case, async: false

  alias Keyfleet.Actors.Human
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ChainViews
  alias Keyfleet.Fleets
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.Proposals.Actions
  alias Keyfleet.Repo
  alias Keyfleet.WalletSteps
  alias Keyfleet.WalletSteps.{Typed, VoteSteps}
  alias RegentChain.Call

  @fleet "fleet_tech_classic"
  @signer "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @other "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
  @third "0x90f79bf6eb2c4f870365e785982e1f101e93b906"
  @actor %Human{human_account_id: Ecto.UUID.generate(), wallet_addresses: [@signer]}
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @regent "0x6f89bca4ea5931edfcb09786267b251dee752b07"
  @native "0x0000000000000000000000000000000000000000"
  @now DateTime.to_unix(ChainViews.head().timestamp)
  @propose "propose(uint256,bytes32,(address,uint256,bytes)[])"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    fleet = ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    %{fleet: fleet}
  end

  defp build(flow, arguments \\ %{}, actor \\ @actor, signer \\ @signer) do
    WalletSteps.build_steps(@fleet, flow, signer, "panel", Map.new(arguments), actor: actor)
  end

  defp build!(flow, arguments \\ %{}) do
    {:ok, built} = build(flow, arguments)
    built
  end

  defp steps(%{review: review}), do: Map.new(review.steps, &{&1.step, &1})
  defp names(%{review: review}), do: Enum.map(review.steps, & &1.step)

  # --- views the steps read ------------------------------------------------

  # Key `key` of the fleet as the Key collection names it.
  defp id(key), do: ChainHelpers.onchain_id(@fleet, key)
  defp ids(keys), do: Enum.map(keys, &id/1)

  defp owner(fleet, key, wallet),
    do: {fleet.keys_address, "ownerOf(uint256)", [id(key)], {"address", [wallet]}}

  defp shard(fleet, check, key, wallet, answer),
    do: {fleet.shards_address, "#{check}(uint256,address)", [id(key), wallet], {"bool", [answer]}}

  defp matures(fleet, key, at),
    do: {fleet.votes_address, "maturesAt(uint256)", [id(key)], {"uint64", [at]}}

  defp uint(to, signature, arguments \\ [], value),
    do: {to, signature, arguments, {"uint256", [value]}}

  defp status(fleet, proposal, status),
    do: {fleet.votes_address, "status(uint256)", [proposal], {"uint8", [status]}}

  describe "who may build" do
    test "only a signed-in person, for a wallet their account links", %{fleet: fleet} do
      ChainViews.put!([uint(fleet.manager_address, "protocolShareOwed()", 0)])

      assert {:ok, _built} = build(:send_share)
      assert {:error, %Ash.Error.Forbidden{}} = build(:send_share, %{}, nil)
      assert {:error, %Ash.Error.Forbidden{}} = build(:send_share, %{}, @actor, @other)

      # A linked wallet written in capitals is the same wallet.
      assert {:ok, %{review: review}} =
               build(
                 :send_share,
                 %{},
                 @actor,
                 "0x" <> String.upcase(String.slice(@signer, 2..-1//1))
               )

      assert review.signer == @signer
    end

    test "a fleet with no deployment recorded has no steps to build, so its keys can't be bought" do
      assert {:error, _not_on_chain} =
               WalletSteps.build_steps("fibonacci_cascade", :buy, @signer, "panel", %{},
                 actor: @actor
               )
    end

    test "each group names what it is about" do
      assert {:error, %Ash.Error.Invalid{}} = build(:ballot)
      assert {:error, %Ash.Error.Invalid{}} = build(:claim)
      assert {:error, %Ash.Error.Invalid{}} = build(:return_advance)
    end
  end

  describe "buying a key" do
    defp sale(fleet, amount, open? \\ true),
      do: [
        uint(fleet.manager_address, "totalMinted()", 0),
        uint(fleet.manager_address, "nextPrice()", 10_000_000),
        {fleet.keys_address, "salesOpenAt(uint256)", [fleet.chain_fleet_id],
         {"uint64", [if(open?, do: @now, else: 0)]}},
        {@usdc, "allowance(address,address)", [@signer, fleet.manager_address],
         {"uint256", [amount]}}
      ]

    test "approves the price plus room for Keys sold first when the allowance is short, then buys for the signer",
         %{fleet: fleet} do
      ChainViews.put!(sale(fleet, 0))

      built = build!(:buy)
      assert built.problem == nil
      assert %{token_id: 1, price: 10_000_000, max_price: 10_500_000, approve?: true} =
               built.figures
      assert built.figures.blocked == %{"buy" => :approve_usdc_first}
      assert built.review.chain.chain_id == 8453
      assert names(built) == ["approve", "buy"]

      %{"approve" => approve, "buy" => buy} = steps(built)
      assert approve.to == @usdc

      assert approve.data ==
               Call.encode("approve(address,uint256)", [fleet.manager_address, 10_500_000])

      assert buy.to == fleet.manager_address

      assert buy.data ==
               Call.encode("purchase(address,uint256,uint256,bytes32[])", [
                 @signer,
                 10_500_000,
                 @now + 600,
                 []
               ])
    end

    test "an allowance of the most the purchase may cost leaves only the purchase, once sales open",
         %{fleet: fleet} do
      ChainViews.put!(sale(fleet, 10_000_000))
      assert build!(:buy).figures.approve?

      ChainViews.put!(sale(fleet, 10_500_000))
      assert %{figures: %{approve?: false, blocked: blocked}} = built = build!(:buy)
      assert blocked == %{}
      assert names(built) == ["buy"]

      ChainViews.put!(sale(fleet, 10_500_000, false))
      assert build!(:buy).figures.blocked == %{"buy" => :sales_not_open}
    end

    # Costly failure: a plain wallet with too little ETH for any network fee
    # is offered presses that are certain to fail, or a wallet with code,
    # whose fee may be paid for it, is held back.
    test "a plain wallet short of ETH for the fee can't press; a wallet with code can",
         %{fleet: fleet} do
      head = %{ChainViews.head() | base_fee: 1_000_000}
      least = 21_000 * 1_000_000

      ChainViews.put!(sale(fleet, 0), head: head)
      assert names(built = build!(:buy)) == ["approve", "buy"]
      assert built.figures.blocked == %{"approve" => :no_eth_for_gas, "buy" => :no_eth_for_gas}

      ChainViews.put!(sale(fleet, 0), head: head, balances: %{@signer => least})
      assert build!(:buy).figures.blocked == %{"buy" => :approve_usdc_first}

      delegated = <<0xEF, 0x01, 0x00>> <> :binary.copy(<<0x11>>, 20)
      ChainViews.put!(sale(fleet, 0), head: head, codes: %{@signer => {:ok, delegated}})
      assert build!(:buy).figures.blocked == %{"buy" => :approve_usdc_first}
    end

    # Costly failure: a wallet's code or balance the chain didn't answer takes
    # its buttons away or holds a press back, which only the chain may do.
    test "a wallet the chain didn't answer for keeps its buttons", %{fleet: fleet} do
      head = %{ChainViews.head() | base_fee: 1_000_000}
      ChainViews.put!(sale(fleet, 0), head: head, codes: %{@signer => {:error, :no_answer}})

      assert names(built = build!(:buy)) == ["approve", "buy"]
      assert built.problem == nil
      assert built.figures.blocked == %{"buy" => :approve_usdc_first}
    end

    test "a chain that can't be read builds nothing and says so" do
      Keyfleet.Chain.StubClient.put_chain(ChainViews.head(), [],
        calls: fn _to, _data, _hash -> {:error, :chain_unavailable} end
      )

      assert %{problem: :unread, review: %{steps: []}} = build!(:buy)
    end

    test "a sold-out fleet has nothing to buy", %{fleet: fleet} do
      # The manager refuses to price a Key once every Key is sold.
      ChainViews.put!([
        uint(fleet.manager_address, "totalMinted()", 1_024),
        {fleet.manager_address, "nextPrice()", [], :revert}
      ])

      assert %{problem: :sold_out, review: %{steps: []}} = build!(:buy)
    end
  end

  describe "asking again for a key's draw" do
    defp draw(fleet, seed, requested_at) do
      ChainViews.put!([
        {fleet.keys_address, "revealSeed(uint256)", [id(4)], {"bytes32", [seed]}},
        uint(fleet.keys_address, "revealRequestedAt(uint256)", [id(4)], requested_at)
      ])
    end

    test "anyone may ask while no draw was asked for or made", %{fleet: fleet} do
      zero = "0x" <> String.duplicate("0", 64)
      draw(fleet, zero, 0)
      built = build!(:reveal, token_id: 4)
      assert built.figures.blocked == %{}
      assert steps(built)["reveal"].to == fleet.keys_address
      assert steps(built)["reveal"].data == Call.encode("requestReveal(uint256)", [id(4)])

      draw(fleet, zero, @now)
      assert build!(:reveal, token_id: 4).figures.blocked == %{"reveal" => :reveal_requested}

      draw(fleet, "0x" <> String.duplicate("1", 64), @now)
      assert build!(:reveal, token_id: 4).figures.blocked == %{"reveal" => :revealed}
    end
  end

  describe "claiming a key's income" do
    defp income(fleet, holder, extra) do
      ChainViews.put!(
        [
          {fleet.rewards_address, "rewardAssets()", [], {"address[]", [[@usdc, @regent]]}},
          owner(fleet, 5, holder),
          uint(fleet.rewards_address, "accrued(address,uint256)", [@usdc, id(5)], 2_000_000),
          uint(fleet.rewards_address, "accrued(address,uint256)", [@regent, id(5)], 0),
          uint(fleet.rewards_address, "credits(address,address)", [@usdc, holder], 500_000),
          uint(fleet.rewards_address, "credits(address,address)", [@regent, holder], 0)
        ] ++ extra
      )
    end

    test "one step for each token; the holder's own key, with only what's waiting pressable",
         %{fleet: fleet} do
      income(fleet, @signer, [])
      built = build!(:claim, token_id: 5)

      assert [
               %{asset: @usdc, amount: 2_500_000, symbol: "USDC", decimals: 6},
               %{asset: @regent, amount: 0}
             ] = built.figures.waiting

      assert names(built) == ["claim-#{@usdc}", "claim-#{@regent}"]
      claim = steps(built)["claim-#{@usdc}"]
      assert claim.to == fleet.rewards_address
      assert claim.data == Call.encode("claim(uint256[],address[])", [[id(5)], [@usdc]])
      assert built.figures.blocked == %{"claim-#{@regent}" => :nothing_to_claim}
    end

    test "an active shard may claim, paid to the holder, with its own credit counted",
         %{fleet: fleet} do
      income(fleet, @other, [
        shard(fleet, "isActive", 5, @signer, true),
        uint(fleet.rewards_address, "credits(address,address)", [@usdc, @signer], 1),
        uint(fleet.rewards_address, "credits(address,address)", [@regent, @signer], 0)
      ])

      built = build!(:claim, token_id: 5)
      assert built.figures.holder == @other
      assert [%{amount: 2_500_001}, %{amount: 0}] = built.figures.waiting
      assert built.figures.blocked == %{"claim-#{@regent}" => :nothing_to_claim}
    end

    test "anyone else sees what's waiting and can't claim it", %{fleet: fleet} do
      income(fleet, @other, [
        shard(fleet, "isActive", 5, @signer, false),
        uint(fleet.rewards_address, "credits(address,address)", [@usdc, @signer], 0),
        uint(fleet.rewards_address, "credits(address,address)", [@regent, @signer], 0)
      ])

      assert build!(:claim, token_id: 5).figures.blocked == %{
               "claim-#{@usdc}" => :not_your_key,
               "claim-#{@regent}" => :not_your_key
             }
    end
  end

  describe "being present" do
    # Key `key` present for 48 hours until `until`, or not present for nil,
    # and old enough to take part from `matures_at`.
    defp presence(fleet, key, until, matures_at \\ @now - 1) do
      [
        {fleet.votes_address, "isActive(uint256)", [id(key)], {"bool", [until != nil]}},
        {fleet.votes_address, "presentFrom(uint256)", [id(key)],
         {"uint64", [if(until, do: until - 172_800, else: 0)]}},
        matures(fleet, key, matures_at)
      ]
    end

    defp sweep(fleet, due?),
      do: {fleet.votes_address, "sweepExpired(uint256)", [0], {"uint256,bool", [0, due?]}}

    test "every key the signer holds or holds a shard of, marked in one press",
         %{fleet: fleet} do
      ProposalHelpers.keys_sold!(@fleet, [1, 2], @signer)
      ProposalHelpers.keys_sold!(@fleet, [7], @other)
      ChainHelpers.issue_shard!(@fleet, 7, @signer)

      holding = [
        owner(fleet, 1, @signer),
        owner(fleet, 2, @signer),
        owner(fleet, 7, @other),
        shard(fleet, "isActive", 7, @signer, true),
        sweep(fleet, false)
      ]

      ChainViews.put!(
        holding ++
          presence(fleet, 1, @now + 3_600) ++ presence(fleet, 2, nil) ++ presence(fleet, 7, nil)
      )

      built = build!(:present)

      assert built.figures.keys == [
               %{token_id: 1, until: DateTime.from_unix!(@now + 3_600)},
               %{token_id: 2, until: nil},
               %{token_id: 7, until: nil}
             ]

      assert built.figures.maintenance? == false
      assert built.figures.blocked == %{}
      assert steps(built)["present"].to == fleet.votes_address
      assert steps(built)["present"].data == Call.encode("present(uint256[])", [ids([1, 2, 7])])
      assert steps(built)["sweep"].data == Call.encode("sweepExpired(uint256)", [256])

      # A Key sold under two days ago is left out, so the others are still
      # marked; with none old enough the press is certain to fail.
      ChainViews.put!(
        holding ++
          presence(fleet, 1, @now + 3_600) ++
          presence(fleet, 2, nil, @now + 60) ++ presence(fleet, 7, nil)
      )

      built = build!(:present)
      assert built.figures.blocked == %{}
      assert steps(built)["present"].data == Call.encode("present(uint256[])", [ids([1, 7])])

      ChainViews.put!(
        holding ++
          presence(fleet, 1, nil, @now + 60) ++
          presence(fleet, 2, nil, @now + 60) ++ presence(fleet, 7, nil, @now + 60)
      )

      assert build!(:present).figures.blocked == %{"present" => :too_new}
    end

    test "a key's page shows its key to anyone, and lapsed presences need clearing",
         %{fleet: fleet} do
      ChainViews.put!(
        [owner(fleet, 9, @other), shard(fleet, "isActive", 9, @signer, false), sweep(fleet, true)] ++
          presence(fleet, 9, @now + 60)
      )

      built = build!(:present, token_id: 9)
      assert built.figures.keys == [%{token_id: 9, until: DateTime.from_unix!(@now + 60)}]
      assert built.figures.maintenance? == true
      # Continue stays open to anyone.
      assert built.figures.blocked == %{"present" => :not_your_key}
    end

    test "a wallet with no keys may still press Continue", %{fleet: fleet} do
      ChainViews.put!([sweep(fleet, false)])
      assert build!(:present).figures.blocked == %{"present" => :no_keys}
    end
  end

  describe "shards" do
    test "issued for the typed keys, wallet and days by the keys' holder", %{fleet: fleet} do
      ChainViews.put!([owner(fleet, 1, @signer), owner(fleet, 3, @signer)])
      typed = "0x" <> String.upcase(String.slice(@other, 2..-1//1))

      built =
        build!(:issue_shard, inputs: %{"keys" => "3, 1 3", "wallet" => typed, "days" => " 45 "})

      assert %{keys: [1, 3], wallet: @other, days: 45, blocked: blocked} = built.figures
      assert blocked == %{}
      assert steps(built)["issue"].to == fleet.shards_address

      assert steps(built)["issue"].data ==
               Call.encode("issue(uint256[],address,uint16)", [ids([1, 3]), @other, 45])
    end

    test "a key held by someone else, or the signer's own wallet, can't be issued",
         %{fleet: fleet} do
      ChainViews.put!([owner(fleet, 1, @signer), owner(fleet, 3, @other)])
      inputs = %{"keys" => "1, 3", "wallet" => @third, "days" => "30"}
      assert build!(:issue_shard, inputs: inputs).figures.blocked == %{"issue" => :not_your_key}

      inputs = %{"keys" => "1", "wallet" => @signer, "days" => "30"}
      assert build!(:issue_shard, inputs: inputs).figures.blocked == %{"issue" => :own_wallet}
    end

    test "what can't be read names what to fix" do
      for days <- ["0", "366", "1.5", "", "thirty"] do
        assert %{problem: :days_unreadable, review: %{steps: []}} =
                 build!(:issue_shard,
                   inputs: %{"keys" => "1", "wallet" => @other, "days" => days}
                 )
      end

      assert %{problem: :shard_wallet_unreadable} =
               build!(:issue_shard, inputs: %{"keys" => "1", "wallet" => "0x12", "days" => "30"})

      assert %{problem: :no_keys} = build!(:issue_shard, inputs: %{"keys" => " "})
      assert %{problem: :keys_unreadable} = build!(:issue_shard, inputs: %{"keys" => "3, seven"})

      assert %{problem: :key_too_large} =
               build!(:issue_shard, inputs: %{"keys" => Integer.to_string(Integer.pow(2, 256))})
    end

    test "each active shard of the key can be ended or renewed for 30 days", %{fleet: fleet} do
      ProposalHelpers.keys_sold!(@fleet, [3], @signer)
      ChainHelpers.issue_shard!(@fleet, 3, @other)
      ChainViews.put!([owner(fleet, 3, @signer), shard(fleet, "isActive", 3, @other, true)])

      built = build!(:end_shard, token_id: 3)
      assert names(built) == ["end-#{@other}", "renew-#{@other}"]
      assert built.figures.blocked == %{}
      assert steps(built)["end-#{@other}"].to == fleet.shards_address

      assert steps(built)["end-#{@other}"].data ==
               Call.encode("end(uint256[],address)", [[id(3)], @other])

      assert steps(built)["renew-#{@other}"].data ==
               Call.encode("issue(uint256[],address,uint16)", [[id(3)], @other, 30])
    end

    test "a shard already ended on the chain, or someone else's, can't be ended",
         %{fleet: fleet} do
      ProposalHelpers.keys_sold!(@fleet, [3], @third)
      ChainHelpers.issue_shard!(@fleet, 3, @other)
      ChainViews.put!([owner(fleet, 3, @third), shard(fleet, "isActive", 3, @other, true)])

      assert build!(:end_shard, token_id: 3).figures.blocked == %{
               "end-#{@other}" => :not_your_key,
               "renew-#{@other}" => :not_your_key
             }

      ChainViews.put!([owner(fleet, 3, @third), shard(fleet, "isActive", 3, @other, false)])

      assert build!(:end_shard, token_id: 3).figures.blocked == %{
               "end-#{@other}" => :shard_ended,
               "renew-#{@other}" => :not_your_key
             }
    end

    test "agent voting is turned on or off for the typed keys, and shows where it's on",
         %{fleet: fleet} do
      views = [
        owner(fleet, 2, @signer),
        owner(fleet, 4, @signer),
        {fleet.shards_address, "agentVoting(uint256)", [id(2)], {"bool", [true]}},
        {fleet.shards_address, "agentVoting(uint256)", [id(4)], {"bool", [false]}}
      ]

      ChainViews.put!(views)
      built = build!(:agent_voting, inputs: %{"keys" => "4 2"})
      assert %{keys: [2, 4], voting: [2], blocked: blocked} = built.figures
      assert blocked == %{}

      assert steps(built)["on"].data ==
               Call.encode("setAgentVoting(uint256[],bool)", [ids([2, 4]), true])

      assert steps(built)["off"].data ==
               Call.encode("setAgentVoting(uint256[],bool)", [ids([2, 4]), false])

      ChainViews.put!([owner(fleet, 2, @other) | tl(views)])

      assert build!(:agent_voting, inputs: %{"keys" => "4 2"}).figures.blocked == %{
               "on" => :not_your_key,
               "off" => :not_your_key
             }
    end
  end

  describe "a ballot" do
    setup do
      ProposalHelpers.keys_sold!(@fleet, [1, 2], @signer)
      ProposalHelpers.keys_sold!(@fleet, [5], @other)
      ChainHelpers.issue_shard!(@fleet, 5, @signer)
      :ok
    end

    # Key 2 may take part from `two_matures_at`; the others already may.
    defp ballot_views(fleet, state, governs_five?, two_matures_at \\ @now - 1) do
      [
        status(fleet, 4, state),
        owner(fleet, 1, @signer),
        owner(fleet, 2, @signer),
        owner(fleet, 5, @other),
        shard(fleet, "mayGovern", 5, @signer, governs_five?),
        matures(fleet, 1, @now - 1),
        matures(fleet, 2, two_matures_at),
        matures(fleet, 5, @now - 1)
      ]
    end

    test "yes, no and abstain carry every key the signer may vote", %{fleet: fleet} do
      ChainViews.put!(ballot_views(fleet, 0, true))
      built = build!(:ballot, proposal: 4)
      assert %{keys: [1, 2, 5], status: :open, blocked: blocked} = built.figures
      assert blocked == %{}

      for {name, choice} <- [{"yes", 1}, {"no", 2}, {"abstain", 3}] do
        assert steps(built)[name].to == fleet.votes_address

        assert steps(built)[name].data ==
                 Call.encode("castBallot(uint256,uint256[],uint8)", [4, ids([1, 2, 5]), choice])
      end

      # A Key sold under two days ago is left out, so the others still vote.
      ChainViews.put!(ballot_views(fleet, 0, true, @now + 60))
      built = build!(:ballot, proposal: 4)
      assert %{keys: [1, 5], blocked: %{}} = built.figures

      assert steps(built)["yes"].data ==
               Call.encode("castBallot(uint256,uint256[],uint8)", [4, ids([1, 5]), 1])
    end

    test "a shard whose key's agent voting is off doesn't vote", %{fleet: fleet} do
      ChainViews.put!(ballot_views(fleet, 0, false))
      assert build!(:ballot, proposal: 4).figures.keys == [1, 2]
    end

    test "a closed proposal can't be voted on, but one waiting its day still takes No",
         %{fleet: fleet} do
      ChainViews.put!(ballot_views(fleet, 2, true))

      assert build!(:ballot, proposal: 4).figures.blocked == %{
               "yes" => :voting_closed,
               "no" => :voting_closed,
               "abstain" => :voting_closed
             }

      ChainViews.put!(ballot_views(fleet, 1, true))

      assert build!(:ballot, proposal: 4).figures.blocked == %{
               "yes" => :only_no,
               "abstain" => :only_no
             }
    end
  end

  describe "cancelling and carrying out" do
    defp author(fleet, proposal, key) do
      zero = "0x" <> String.duplicate("0", 64)

      {fleet.votes_address, "proposal(uint256)", [proposal],
       {"bytes32,bytes32,bytes32,uint64,uint48,uint64,uint64,uint64,uint32,uint32,uint32,uint32,uint32,bool,bool",
        [zero, zero, zero, id(key), 1, 0, 0, 0, 3, 1, 2, 1, 0, false, false]}}
    end

    test "the proposal's key may cancel it while it is open or approved", %{fleet: fleet} do
      ChainViews.put!([status(fleet, 4, 2), author(fleet, 4, 2), owner(fleet, 2, @signer)])
      built = build!(:cancel, proposal: 4)
      assert built.figures.blocked == %{}
      assert steps(built)["cancel"].data == Call.encode("cancel(uint256)", [4])

      ChainViews.put!([status(fleet, 4, 4), author(fleet, 4, 2), owner(fleet, 2, @signer)])
      assert build!(:cancel, proposal: 4).figures.blocked == %{"cancel" => :cancelled}

      ChainViews.put!([
        status(fleet, 4, 0),
        author(fleet, 4, 2),
        owner(fleet, 2, @other),
        shard(fleet, "mayGovern", 2, @signer, false)
      ])

      assert build!(:cancel, proposal: 4).figures.blocked == %{"cancel" => :not_your_key}
    end

    test "carrying out passes the proposal's exact calls, once it's approved", %{fleet: fleet} do
      calls = Actions.encode({:pay, @usdc, @third, 50_000}, fleet)

      recorded =
        ProposalHelpers.proposal!(@fleet, 4, %{
          calls:
            Enum.map(calls, fn {target, value, data} ->
              %{target: target, value: value, data: data}
            end)
        })

      ChainViews.put!([status(fleet, 4, 2)])
      built = build!(:carry_out, proposal: 4)
      assert built.figures.blocked == %{}
      assert steps(built)["carry_out"].to == fleet.votes_address

      assert steps(built)["carry_out"].data ==
               Call.encode("execute(uint256,(address,uint256,bytes)[])", [4, calls])

      # A proposal that moves money waits after its vote passes.
      waiting = {:carry_out_from, Proposals.carry_out_from(recorded)}

      for {index, reason} <- [
            {0, :open},
            {1, waiting},
            {3, :rejected},
            {5, :executed},
            {6, :execution_expired}
          ] do
        ChainViews.put!([status(fleet, 4, index)])
        assert build!(:carry_out, proposal: 4).figures.blocked == %{"carry_out" => reason}
      end

      assert %{problem: :not_recorded} = build!(:carry_out, proposal: 9)
    end
  end

  describe "proposing" do
    # Key 2 is the signer's and old enough to take part, the treasury opened
    # for spending a day ago, and holds 2,500 USDC and 1 ETH.
    defp proposing(fleet, extra \\ []) do
      ChainViews.put!(
        [
          owner(fleet, 2, @signer),
          matures(fleet, 2, @now - 1),
          uint(fleet.votes_address, "proposalCount()", 6),
          uint(fleet.votes_address, "treasuryOpensAt()", @now - 86_400),
          uint(@usdc, "balanceOf(address)", [fleet.treasury_address], 2_500_000_000)
        ] ++ extra,
        balances: %{fleet.treasury_address => 10 ** 18}
      )
    end

    setup %{fleet: fleet} do
      proposing(fleet)
      :ok
    end

    defp propose(inputs),
      do: build!(:propose, inputs: Map.merge(%{"key" => "2", "text" => "Why"}, inputs))

    defp proposed(fleet, action) do
      Call.encode(@propose, [id(2), VoteSteps.content_hash("Why"), Actions.encode(action, fleet)])
    end

    test "a decision makes no calls and its vote lasts a day", %{fleet: fleet} do
      built = propose(%{"kind" => "decision"})
      assert built.figures.closes_at == DateTime.from_unix!(@now + 24 * 3_600)
      assert built.figures.blocked == %{}
      assert steps(built)["propose"].to == fleet.votes_address
      assert steps(built)["propose"].data == proposed(fleet, :decision)
      assert Actions.encode(:decision, fleet) == []
    end

    test "a payment names a share of what the treasury holds of the token", %{fleet: fleet} do
      built =
        propose(%{"kind" => "pay", "asset" => @usdc, "share" => "1.5", "recipient" => @third})

      assert {:pay, %{address: @usdc}, @third, 15_000, 37_500_000} = built.figures.action
      assert steps(built)["propose"].data == proposed(fleet, {:pay, @usdc, @third, 15_000})

      built =
        propose(%{"kind" => "pay", "asset" => @native, "share" => "50", "recipient" => @third})

      assert {:pay, %{address: @native}, @third, 500_000, 500_000_000_000_000_000} =
               built.figures.action

      assert steps(built)["propose"].data == proposed(fleet, {:pay, @native, @third, 500_000})
    end

    test "an advance takes the proposal's number and its text's hash", %{fleet: fleet} do
      built =
        propose(%{"kind" => "advance", "asset" => @usdc, "share" => "10", "recipient" => @third})

      assert {:advance, 7, %{address: @usdc}, @third, 100_000, 250_000_000} =
               built.figures.action

      assert steps(built)["propose"].data ==
               proposed(
                 fleet,
                 {:advance, 7, @third, @usdc, 100_000, VoteSteps.content_hash("Why")}
               )
    end

    test "a rate change, an edits restriction and a signature", %{fleet: fleet} do
      assert steps(propose(%{"kind" => "rate", "rate" => "1.25"}))["propose"].data ==
               proposed(fleet, {:rate, 125})

      assert steps(propose(%{"kind" => "edits", "target" => "7", "restricted" => "true"}))[
               "propose"
             ].data == proposed(fleet, {:edits, 7, true})

      assert steps(
               propose(%{
                 "kind" => "signature",
                 "signature" => "revoke",
                 "issued_at" => " 1790000000 "
               })
             )["propose"].data == proposed(fleet, {:signature, :revoke, 1_790_000_000})
    end

    test "a launch through Autolaunch names the fleet's treasury", %{fleet: fleet} do
      launch = %{
        "name" => "Tech Classic",
        "symbol" => "TECH",
        "description" => "Our token",
        "website" => "https://keyfleet.ai",
        "image" => "https://keyfleet.ai/tech.png"
      }

      built = propose(Map.put(launch, "kind", "launch"))
      fields = Map.new(launch, fn {name, value} -> {String.to_existing_atom(name), value} end)
      assert built.figures.action == {:launch, fields}
      assert steps(built)["propose"].data == proposed(fleet, {:launch, fields})

      [{target, 0, data}] = Actions.encode({:launch, fields}, fleet)
      assert target == fleet.autolaunch_factory_address

      assert Actions.decode(%{target: target, value: 0, data: data}, fleet) ==
               {:launch, Map.put(fields, :treasury, fleet.treasury_address)}

      assert %{problem: {:too_long, :symbol, 16}} =
               propose(
                 %{launch | "symbol" => String.duplicate("T", 17)}
                 |> Map.put("kind", "launch")
               )
    end

    test "what can't be proposed names what to fix" do
      assert %{problem: :kind_unknown} = propose(%{"kind" => "vote"})
      assert %{problem: :rate_unreadable} = propose(%{"kind" => "rate", "rate" => "2.5"})
      assert %{problem: :rate_unreadable} = propose(%{"kind" => "rate", "rate" => "0.05"})
      assert %{problem: {:missing, :text}} = propose(%{"kind" => "decision", "text" => " "})

      assert %{problem: :issued_at_unreadable} =
               propose(%{"kind" => "signature", "issued_at" => "21 September"})

      assert %{problem: :no_key} = propose(%{"kind" => "decision", "key" => ""})

      assert %{problem: :asset_unreadable} =
               propose(%{"kind" => "pay", "asset" => @third, "share" => "1"})

      for share <- ["0", "99.5", "0.00001", "half"] do
        assert %{problem: :share_unreadable} =
                 propose(%{
                   "kind" => "pay",
                   "asset" => @usdc,
                   "share" => share,
                   "recipient" => @third
                 })
      end
    end

    test "a key the signer may not govern or too new, or money too early, can't propose",
         %{fleet: fleet} do
      proposing(fleet, [owner(fleet, 2, @other), shard(fleet, "mayGovern", 2, @signer, false)])
      assert propose(%{"kind" => "decision"}).figures.blocked == %{"propose" => :not_your_key}

      proposing(fleet, [matures(fleet, 2, @now + 60)])
      assert propose(%{"kind" => "decision"}).figures.blocked == %{"propose" => :too_new}

      # Money waits until the treasury opens; anything else need not.
      pay = %{"kind" => "pay", "asset" => @usdc, "share" => "1", "recipient" => @third}

      proposing(fleet, [uint(fleet.votes_address, "treasuryOpensAt()", 0)])
      assert propose(pay).figures.blocked == %{"propose" => :sales_not_open}
      assert propose(%{"kind" => "decision"}).figures.blocked == %{}

      proposing(fleet, [uint(fleet.votes_address, "treasuryOpensAt()", @now + 60)])

      assert propose(pay).figures.blocked == %{
               "propose" => {:opens_at, DateTime.from_unix!(@now + 60)}
             }
    end
  end

  describe "the daily split" do
    defp split(fleet, next_run_at) do
      ChainViews.put!(
        [
          {fleet.treasury_address, "splitAssets()", [], {"address[]", [[@native, @usdc]]}},
          uint(fleet.treasury_address, "dailySplitBps()", 50),
          uint(fleet.treasury_address, "lastRunAt()", @now - 86_000),
          uint(fleet.treasury_address, "nextRunAt()", next_run_at),
          uint(fleet.manager_address, "totalMinted()", 10),
          {@usdc, "decimals()", [], {"uint8", [6]}},
          uint(@usdc, "balanceOf(address)", [fleet.treasury_address], 50_000_000)
        ],
        balances: %{fleet.treasury_address => 1_000_000_000_000_000_000}
      )
    end

    test "previews each asset and opens at its time", %{fleet: fleet} do
      split(fleet, @now + 400)
      built = build!(:run_split)

      assert [
               %{asset: @native, symbol: "ETH", balance: 1_000_000_000_000_000_000} = eth,
               %{asset: @usdc, symbol: "USDC", balance: 50_000_000, threshold: 100_000_000} =
                 usdc
             ] = built.figures.assets

      # Half a percent of 1 ETH, shared by 10 keys; USDC is under its least.
      assert eth.per_key == 500_000_000_000_000
      assert eth.threshold == 50_000_000_000_000_000
      assert usdc.per_key == 0
      assert built.figures.rate_bps == 50
      assert built.figures.last_run_at == DateTime.from_unix!(@now - 86_000)
      opens_at = DateTime.from_unix!(@now + 400)
      assert built.figures.blocked == %{"run_split" => {:opens_at, opens_at}}
      assert steps(built)["run_split"].to == fleet.treasury_address
      assert steps(built)["run_split"].data == Call.encode("runDailySplit()", [])

      split(fleet, @now)
      assert build!(:run_split).figures.blocked == %{}

      split(fleet, 0)
      assert build!(:run_split).figures.blocked == %{"run_split" => :no_keys_sold}
    end
  end

  describe "returning an advance" do
    defp advance(fleet, asset, outstanding, held, allowance) do
      purpose = "0x" <> String.duplicate("9", 64)

      ChainViews.put!(
        [
          {fleet.treasury_address, "advances(uint256)", [7],
           {"address,address,uint256,bytes32", [@third, asset, outstanding, purpose]}},
          uint(@usdc, "balanceOf(address)", [@signer], held),
          uint(@usdc, "allowance(address,address)", [@signer, fleet.treasury_address], allowance)
        ],
        balances: %{@signer => held}
      )
    end

    defp return_advance(amount),
      do: build!(:return_advance, advance_id: 7, inputs: %{"amount" => amount})

    test "a token is approved to the treasury, then returned", %{fleet: fleet} do
      advance(fleet, @usdc, 5_000_000, 10_000_000, 0)
      built = return_advance("2")
      assert names(built) == ["approve", "return"]
      assert built.figures.blocked == %{"return" => :approve_first}

      assert steps(built)["approve"].data ==
               Call.encode("approve(address,uint256)", [fleet.treasury_address, 2_000_000])

      assert steps(built)["return"].to == fleet.treasury_address

      assert steps(built)["return"].data ==
               Call.encode("returnAdvance(uint256,uint256)", [7, 2_000_000])

      advance(fleet, @usdc, 5_000_000, 10_000_000, 2_000_000)
      assert return_advance("2").figures.blocked == %{}
      assert return_advance("6").figures.blocked == %{"return" => :above_outstanding}

      advance(fleet, @usdc, 5_000_000, 1_000_000, 2_000_000)
      assert return_advance("2").figures.blocked == %{"return" => :not_enough}

      advance(fleet, @usdc, 0, 10_000_000, 2_000_000)
      assert return_advance("2").figures.blocked == %{"return" => :advance_returned}
    end

    test "ETH goes with the call", %{fleet: fleet} do
      advance(fleet, @native, 10 ** 18, 2 * 10 ** 18, 0)
      built = return_advance("0.25")
      assert names(built) == ["return"]
      assert built.figures.blocked == %{}

      assert steps(built)["return"].value ==
               "0x" <> "3782dace9d90000"
    end

    test "an advance the treasury never made", %{fleet: fleet} do
      ChainViews.put!([
        {fleet.treasury_address, "advances(uint256)", [7],
         {"address,address,uint256,bytes32",
          [@native, @native, 0, "0x" <> String.duplicate("0", 64)]}}
      ])

      assert %{problem: :advance_unknown, review: %{steps: []}} = return_advance("1")
    end
  end

  describe "Regents' share" do
    test "sent from the fleet contract while something is owed", %{fleet: fleet} do
      ChainViews.put!([uint(fleet.manager_address, "protocolShareOwed()", 3)])
      built = build!(:send_share)
      assert built.figures == %{owed: 3, blocked: %{}}
      assert steps(built)["send_share"].to == fleet.manager_address
      assert steps(built)["send_share"].data == Call.encode("sendProtocolShare()", [])

      ChainViews.put!([uint(fleet.manager_address, "protocolShareOwed()", 0)])
      assert build!(:send_share).figures.blocked == %{"send_share" => :nothing_owed}
    end
  end

  describe "the launch's upkeep" do
    @auction "0x" <> String.duplicate("1a", 20)
    @subject "0x" <> String.duplicate("2a", 20)
    @escrow "0x" <> String.duplicate("3a", 20)
    @strategy "0x" <> String.duplicate("4a", 20)
    @locker "0x" <> String.duplicate("5a", 20)

    defp launch(fleet, bound_id, lifecycle, migration_block) do
      zero = "0x" <> String.duplicate("0", 64)
      factory = fleet.autolaunch_factory_address

      ChainViews.put!([
        uint(fleet.treasury_address, "launchId()", bound_id),
        {factory, "launches(uint256)", [3],
         {"address,address,address,address,address",
          [fleet.treasury_address, @subject, @auction, @escrow, fleet.treasury_address]}},
        {factory, "strategy()", [], {"address", [@strategy]}},
        {@strategy, "lpLocker()", [], {"address", [@locker]}},
        {@strategy, "distribution(address)", [@auction],
         {"uint8,uint64,uint64,uint64,uint64,uint128,uint128,uint128,uint160,uint256,address,address,address,address,address,bytes32,uint256",
          [lifecycle, 1, 2, 3, migration_block, 0, 0, 0, 0, 0] ++
            List.duplicate(@native, 5) ++ [zero, 77]}}
      ])
    end

    test "anyone may settle, bind, release and collect once the sale is done", %{fleet: fleet} do
      launch(fleet, 3, 2, 900)
      built = build!(:launch_upkeep)
      assert %{launch_id: 3, token: @subject, lifecycle: :graduated, bound?: true} = built.figures
      assert built.figures.blocked == %{"settle" => :launch_settled, "bind" => :bound}
      assert names(built) == ["settle", "bind", "release", "collect"]
      assert steps(built)["settle"].to == @strategy
      assert steps(built)["settle"].data == Call.encode("migrate(address)", [@auction])
      assert steps(built)["bind"].to == fleet.treasury_address
      assert steps(built)["bind"].data == Call.encode("bindLaunchToken(uint256)", [3])
      assert steps(built)["release"].to == @escrow
      assert steps(built)["release"].data == Call.encode("release()", [])
      assert steps(built)["collect"].to == @locker
      assert steps(built)["collect"].data == Call.encode("collect(uint256)", [77])
    end

    test "while the sale runs, only settling waits for its block", %{fleet: fleet} do
      launch(fleet, 3, 1, 1_001)

      assert build!(:launch_upkeep).figures.blocked == %{
               "settle" => :sale_running,
               "bind" => :bound,
               "release" => :not_sold,
               "collect" => :not_sold
             }

      launch(fleet, 3, 1, 1_000)
      assert %{"release" => :not_sold} = blocked = build!(:launch_upkeep).figures.blocked
      refute Map.has_key?(blocked, "settle")

      launch(fleet, 3, 3, 900)
      assert build!(:launch_upkeep).figures.blocked["release"] == :launch_failed
    end

    test "no launch yet", %{fleet: fleet} do
      ChainViews.put!([uint(fleet.treasury_address, "launchId()", 0)])
      assert %{problem: :no_launch, review: %{steps: []}} = build!(:launch_upkeep)
    end
  end

  describe "reading a proposal's calls" do
    test "each kind reads back as itself; anything else as a plain call", %{fleet: fleet} do
      hash = "0x" <> String.duplicate("cd", 32)

      for action <- [
            {:pay, @usdc, @third, 5},
            {:advance, 3, @third, @native, 9, hash},
            {:rate, 75},
            {:signature, :approve, 1_790_000_000},
            {:edits, 4, false}
          ] do
        [{target, value, data}] = Actions.encode(action, fleet)
        assert Actions.decode(%{target: target, value: value, data: data}, fleet) == action
      end

      [{_target, 0, data}] = Actions.encode({:rate, 75}, fleet)

      assert Actions.decode(%{target: @third, value: 0, data: data}, fleet) ==
               {:other, @third, data}

      assert Actions.function(data) == "setDailySplitBps(uint256)"
      assert Actions.function(Call.encode("transferOwnership(address)", [@third])) == nil
    end
  end

  describe "what's typed" do
    test "rates, shares, request times and text" do
      assert Typed.rate("0.1") == {:ok, 10}
      assert Typed.rate("2") == {:ok, 200}
      assert Typed.rate("0.5") == {:ok, 50}
      assert Typed.rate("2.01") == {:error, :rate_unreadable}
      assert Typed.share(" 1.5 ") == {:ok, 15_000}
      assert Typed.share("99.0001") == {:error, :share_unreadable}
      assert Typed.issued_at(" 1790000000 ") == {:ok, 1_790_000_000}
      assert Typed.issued_at("1.5") == {:error, :issued_at_unreadable}
      assert Typed.text("  hi ", :name, 2) == {:ok, "hi"}
      assert Typed.text("hey", :name, 2) == {:error, {:too_long, :name, 2}}
      assert Typed.keys("9 3,3") == {:ok, [3, 9]}
    end
  end
end

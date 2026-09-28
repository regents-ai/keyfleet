defmodule Keyfleet.WalletStepsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors.Human
  alias Keyfleet.Chain.StubClient
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Repo
  alias Keyfleet.WalletSteps
  alias RegentChain.Call

  @fleet "fleet_tech_classic"
  @signer "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @other "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
  @actor %Human{human_account_id: Ecto.UUID.generate(), wallet_addresses: [@signer]}
  @head %{
    number: 1_000,
    hash: "0x" <> String.duplicate("c", 64),
    timestamp: ~U[2026-09-27 12:00:00Z]
  }
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @factory "0x" <> String.duplicate("fa", 20)
  @strategy "0x" <> String.duplicate("5a", 20)
  # A floor price of 0.000001 REGENT per token.
  @floor 79_228_162_514_264_337_593_500

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

  defp steps(%{review: review}), do: Map.new(review.steps, &{&1.step, &1})

  describe "who may build" do
    test "only a signed-in person, for a wallet their account links" do
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

    test "a fleet with no deployment recorded has no steps to build" do
      assert {:error, _not_on_chain} =
               WalletSteps.build_steps("fibonacci_cascade", :send_share, @signer, "panel", %{},
                 actor: @actor
               )
    end
  end

  describe "buying a key" do
    test "approves exactly the price when the allowance is short, then buys for the signer",
         %{fleet: fleet} do
      answering(allowance: 0)

      assert {:ok, built} = build(:buy)
      assert built.problem == nil
      assert %{token_id: 1, price: 10_000_000, approve?: true} = built.figures

      assert built.review.chain == %{
               chain_id: 8_453,
               name: "Base",
               rpc_url: "https://mainnet.base.org"
             }

      deadline = DateTime.to_unix(@head.timestamp) + 600

      assert %{"approve" => approve, "buy" => buy} = steps(built)
      assert approve.to == @usdc

      assert approve.data ==
               Call.encode("approve(address,uint256)", [fleet.contract_address, 10_000_000])

      assert buy.to == fleet.contract_address

      assert buy.data ==
               Call.encode("purchase(address,uint256,uint256)", [@signer, 10_000_000, deadline])

      assert Enum.map(built.review.steps, & &1.step) == ["approve", "buy"]
    end

    test "an allowance of the price or more leaves only the purchase" do
      answering(allowance: 10_000_000)
      assert {:ok, built} = build(:buy)
      assert Map.keys(steps(built)) == ["buy"]
      assert built.figures.approve? == false
    end

    test "a chain that can't be read builds nothing and says so" do
      StubClient.put_chain(@head, [],
        calls: fn _to, _data, _hash -> {:error, :chain_unavailable} end
      )

      assert {:ok, %{problem: :unread, review: %{steps: []}}} = build(:buy)
    end

    test "a sold-out fleet has nothing to buy" do
      ProposalHelpers.keys_sold!(@fleet, [144])
      assert {:ok, %{problem: :sold_out, review: %{steps: []}}} = build(:buy)
    end
  end

  describe "votes" do
    test "yes, no and withdraw carry the typed keys", %{fleet: fleet} do
      assert {:ok, built} = build(:vote, proposal: 4, inputs: %{"keys" => " 3, 7 12"})
      assert built.figures == %{keys: [3, 7, 12]}
      assert built.review.inputs == %{"keys" => " 3, 7 12"}

      %{"yes" => yes, "no" => no, "withdraw" => withdraw} = steps(built)
      assert yes.to == fleet.votes_address
      assert yes.data == Call.encode("vote(uint256,uint256[],bool)", [4, [3, 7, 12], true])
      assert no.data == Call.encode("vote(uint256,uint256[],bool)", [4, [3, 7, 12], false])
      assert withdraw.data == Call.encode("withdrawVote(uint256,uint256[])", [4, [3, 7, 12]])
    end

    test "keys that can't be read build nothing and name what to fix" do
      assert {:ok, %{problem: :no_keys, review: %{steps: []}}} =
               build(:vote, proposal: 4, inputs: %{"keys" => " "})

      assert {:ok, %{problem: :keys_unreadable}} =
               build(:vote, proposal: 4, inputs: %{"keys" => "3, seven"})

      assert {:ok, %{problem: :key_too_large}} =
               build(:vote,
                 proposal: 4,
                 inputs: %{"keys" => Integer.to_string(Integer.pow(2, 256))}
               )
    end

    test "a vote needs its proposal" do
      assert {:error, %Ash.Error.Invalid{}} = build(:vote, inputs: %{"keys" => "3"})
    end

    test "carrying out and collecting name the proposal", %{fleet: fleet} do
      assert {:ok, built} = build(:carry_out, proposal: 9)
      assert steps(built)["carry_out"].data == Call.encode("execute(uint256)", [9])

      assert {:ok, built} = build(:collect, proposal: 9, inputs: %{"keys" => "5"})
      assert steps(built)["collect"].to == fleet.votes_address
      assert steps(built)["collect"].data == Call.encode("collect(uint256,uint256[])", [9, [5]])
    end
  end

  describe "proposals" do
    test "a decision carries its key, text and document code" do
      code = String.duplicate("ab", 32)

      assert {:ok, built} =
               build(:propose_decision,
                 inputs: %{"key" => "12", "text" => "Hire an editor", "digest" => "0x" <> code}
               )

      assert steps(built)["propose"].data ==
               Call.encode("proposeDecision(uint256,string,bytes32)", [
                 12,
                 "Hire an editor",
                 "0x" <> code
               ])

      assert {:ok, %{problem: :document_code}} =
               build(:propose_decision, inputs: %{"key" => "12", "digest" => "abc"})

      assert {:ok, %{problem: :no_key}} = build(:propose_decision, inputs: %{"text" => "x"})
    end

    test "a payment in USDC is typed in whole USDC, and a pasted token in its smallest units" do
      recipient = "0x90f79bf6eb2c4f870365e785982e1f101e93b906"
      zero = "0x" <> String.duplicate("0", 64)

      assert {:ok, built} =
               build(:propose_payment,
                 inputs: %{
                   "key" => "2",
                   "asset" => @usdc,
                   "amount" => "1,250.5",
                   "recipient" => recipient
                 }
               )

      assert built.figures.amount == 1_250_500_000

      assert steps(built)["propose"].data ==
               Call.encode("proposePay(uint256,address,uint256,address,string,bytes32)", [
                 2,
                 @usdc,
                 1_250_500_000,
                 recipient,
                 "",
                 zero
               ])

      token = "0x" <> String.duplicate("7", 40)

      assert {:ok, built} =
               build(:propose_payment,
                 inputs: %{
                   "key" => "2",
                   "asset" => "other",
                   "other_asset" => token,
                   "amount" => "500",
                   "recipient" => recipient
                 }
               )

      assert built.figures.asset == %{address: token, symbol: nil, decimals: nil, usdc?: false}
      assert built.figures.amount == 500

      assert {:ok, %{problem: {:too_many_decimals, 0}}} =
               build(:propose_payment,
                 inputs: %{
                   "key" => "2",
                   "asset" => "other",
                   "other_asset" => token,
                   "amount" => "1.5",
                   "recipient" => recipient
                 }
               )

      assert {:ok, %{problem: :asset_unreadable}} =
               build(:propose_payment,
                 inputs: %{"key" => "2", "asset" => "other", "other_asset" => "0x12"}
               )

      assert {:ok, %{problem: :recipient_unreadable}} =
               build(:propose_payment,
                 inputs: %{"key" => "2", "asset" => @usdc, "amount" => "1", "recipient" => "me"}
               )
    end

    test "a launch carries its details, its floor price and the keys' own minimum raise" do
      answering(required: {:ok, 19_999_999_999_999_999_999_989})

      inputs = %{
        "key" => "1",
        "name" => "Fleet",
        "symbol" => "FLT",
        "description" => "A fleet token",
        "website" => "https://example.com",
        "image" => "https://example.com/a.png",
        "floor" => "0.000001",
        "minimum" => "",
        "digest" => ""
      }

      assert {:ok, built} = build(:propose_launch, inputs: inputs)
      assert built.problem == nil

      # 0.000001 times 2^96 is 79,228,162,514,264,337,593,543.95, rounded
      # down to a whole number of bid ticks.
      assert %{
               key: 1,
               floor_price_q96: @floor,
               minimum_regent_raised: 0,
               required_regent_raised: 19_999_999_999_999_999_999_989
             } = built.figures

      assert steps(built)["propose"].data ==
               Call.encode(
                 "proposeAutolaunch(uint256,(string,string,string,string,string,uint256,uint128,bytes32))",
                 [
                   1,
                   {"Fleet", "FLT", "A fleet token", "https://example.com",
                    "https://example.com/a.png", @floor, 0, "0x" <> String.duplicate("0", 64)}
                 ]
               )

      # What it must raise is asked of the strategy behind the fleet's
      # factory, at the latest block.
      assert List.last(StubClient.call_requests()) ==
               {@strategy, Call.encode("requiredRegentRaisedFor(uint256,uint128)", [@floor, 0]),
                @head.hash}

      minimum = 25_000 * Integer.pow(10, 18)
      answering(required: {:ok, minimum})

      assert {:ok, %{figures: %{minimum_regent_raised: ^minimum}} = built} =
               build(:propose_launch, inputs: %{inputs | "minimum" => "25,000"})

      assert steps(built)["propose"].data ==
               Call.encode(
                 "proposeAutolaunch(uint256,(string,string,string,string,string,uint256,uint128,bytes32))",
                 [
                   1,
                   {"Fleet", "FLT", "A fleet token", "https://example.com",
                    "https://example.com/a.png", @floor, minimum,
                    "0x" <> String.duplicate("0", 64)}
                 ]
               )
    end

    # The step is built all the same when the strategy refuses the floor and
    # minimum, or can't be read: the vote contract asks the strategy again
    # when the proposal is made.
    test "a launch the strategy refuses, or can't answer for, is still sent" do
      inputs = %{"key" => "1", "floor" => "0", "minimum" => "", "digest" => ""}

      for {answer, problem} <- [
            {{:error, :reverted}, :launch_refused},
            {{:error, :chain_unavailable}, :unread}
          ] do
        answering(required: answer)

        assert {:ok, %{problem: ^problem, figures: %{required_regent_raised: nil}} = built} =
                 build(:propose_launch, inputs: inputs)

        assert Map.keys(steps(built)) == ["propose"]
      end
    end

    test "a floor or minimum that can't be put into the call names why" do
      answering(required: {:ok, 1})
      inputs = %{"key" => "1", "floor" => "0.000001", "minimum" => "", "digest" => ""}

      for {typed, problem} <- [
            {%{"floor" => ""}, :floor_unreadable},
            {%{"floor" => "a tenth"}, :floor_unreadable},
            {%{"floor" => "0,5"}, :amount_commas},
            {%{"minimum" => "lots"}, :amount_unreadable},
            {%{"minimum" => "0.0000000000000000001"}, {:too_many_decimals, 18}},
            {%{"minimum" => Integer.to_string(Integer.pow(2, 128))}, :amount_too_large}
          ] do
        assert {:ok, %{problem: ^problem, review: %{steps: []}}} =
                 build(:propose_launch, inputs: Map.merge(inputs, typed))
      end
    end
  end

  describe "voting for another and the stakers' share" do
    test "a typed wallet may vote for the signer; clearing names no wallet" do
      assert {:ok, built} = build(:delegate, inputs: %{"delegate" => @other})

      assert steps(built)["delegate"].data ==
               Call.encode("setVotingDelegate(address)", [@other])

      assert steps(built)["clear"].data ==
               Call.encode("setVotingDelegate(address)", ["0x" <> String.duplicate("0", 40)])

      assert {:ok, %{problem: :delegate_unreadable} = built} =
               build(:delegate, inputs: %{"delegate" => "0x12"})

      assert Map.keys(steps(built)) == ["clear"]
    end

    test "the stakers' share is sent from the fleet contract", %{fleet: fleet} do
      assert {:ok, built} = build(:send_share)
      assert steps(built)["send"].to == fleet.contract_address
      assert steps(built)["send"].data == Call.encode("sendProtocolShare()", [])
    end
  end

  describe "claiming a key's income" do
    test "one step for each token with income waiting, paid to the signer", %{fleet: fleet} do
      regent = "0x" <> String.duplicate("9", 40)
      answering(reward_assets: [@usdc, regent], accrued: %{@usdc => 2_500_000, regent => 0})

      assert {:ok, built} = build(:claim, token_id: 5)

      assert built.figures.waiting == [
               %{asset: @usdc, amount: 2_500_000, symbol: "USDC", decimals: 6, usdc?: true},
               %{asset: regent, amount: 0, symbol: nil, decimals: nil, usdc?: false}
             ]

      assert [claim] = built.review.steps
      assert claim.step == "claim-#{@usdc}"
      assert claim.to == fleet.rewards_address

      assert claim.data ==
               Call.encode("claim(address,uint256[],address)", [@usdc, [5], @signer])
    end

    test "nothing waiting builds nothing" do
      answering(reward_assets: [@usdc], accrued: %{@usdc => 0})

      assert {:ok, %{problem: :nothing_waiting, review: %{steps: []}}} =
               build(:claim, token_id: 5)
    end
  end

  # The node answers the views the builder reads: USDC allowances, the
  # rewards contract's assets and what a key has accrued in each.
  defp answering(answers) do
    allowance = Call.selector("allowance(address,address)")
    reward_assets = Call.selector("rewardAssets()")
    accrued = Call.selector("accrued(address,uint256)")
    factory = Call.selector("FACTORY()")
    strategy = Call.selector("strategy()")
    required = Call.selector("requiredRegentRaisedFor(uint256,uint128)")

    StubClient.put_chain(@head, [],
      calls: fn _to, data, _hash ->
        case String.split_at(data, 10) do
          {^allowance, _arguments} ->
            {:ok, <<Keyword.fetch!(answers, :allowance)::256>>}

          {^reward_assets, ""} ->
            assets = Keyword.fetch!(answers, :reward_assets)

            {:ok,
             <<32::256, length(assets)::256>> <>
               Enum.map_join(assets, &(<<0::96>> <> address(&1)))}

          {^accrued, <<_pad::binary-size(24), asset::binary-size(40), _token::binary-size(64)>>} ->
            {:ok, <<Map.fetch!(answers[:accrued], "0x" <> asset)::256>>}

          {^factory, ""} ->
            {:ok, <<0::96>> <> address(@factory)}

          {^strategy, ""} ->
            {:ok, <<0::96>> <> address(@strategy)}

          {^required, _arguments} ->
            with {:ok, raise} <- Keyword.fetch!(answers, :required), do: {:ok, <<raise::256>>}
        end
      end
    )
  end

  defp address("0x" <> hex), do: Base.decode16!(hex, case: :lower)
end

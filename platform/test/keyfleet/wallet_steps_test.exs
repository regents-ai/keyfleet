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
  @usdc "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

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
      assert %{token_id: 1, price: 8_000_000, approve?: true} = built.figures

      assert built.review.chain == %{
               chain_id: 1,
               name: "Ethereum",
               rpc_url: "https://eth.merkle.io"
             }

      deadline = DateTime.to_unix(@head.timestamp) + 600

      assert %{"approve" => approve, "buy" => buy} = steps(built)
      assert approve.to == @usdc

      assert approve.data ==
               Call.encode("approve(address,uint256)", [fleet.contract_address, 8_000_000])

      assert buy.to == fleet.contract_address

      assert buy.data ==
               Call.encode("purchase(address,uint256,uint256)", [@signer, 8_000_000, deadline])

      assert Enum.map(built.review.steps, & &1.step) == ["approve", "buy"]
    end

    test "an allowance of the price or more leaves only the purchase" do
      answering(allowance: 8_000_000)
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
      ProposalHelpers.keys_sold!(@fleet, [1_024])
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
  end

  describe "restricting and allowing a key's edits" do
    test "names the proposing key, the key voted on, and restrict or allow", %{fleet: fleet} do
      code = String.duplicate("cd", 32)

      for {restricted, typed} <- [{true, "true"}, {false, "false"}] do
        assert {:ok, built} =
                 build(:propose_edits,
                   inputs: %{
                     "key" => "2",
                     "target" => "7",
                     "restricted" => typed,
                     "text" => "Key 7 keeps deleting goals",
                     "digest" => "0x" <> code
                   }
                 )

        assert %{to: to, data: data} = steps(built)["propose"]
        assert to == fleet.votes_address

        assert data ==
                 Call.encode("proposeRestrictEdits(uint256,uint256,bool,string,bytes32)", [
                   2,
                   7,
                   restricted,
                   "Key 7 keeps deleting goals",
                   "0x" <> code
                 ])
      end

      assert {:ok, %{problem: :no_target}} =
               build(:propose_edits, inputs: %{"key" => "2", "restricted" => "true"})
    end
  end

  describe "shards" do
    test "issuing sends the key, the typed wallet and the days to the shards contract",
         %{fleet: fleet} do
      typed = "0x" <> String.upcase(String.slice(@other, 2..-1//1))

      assert {:ok, built} =
               build(:issue_shard, token_id: 3, inputs: %{"wallet" => typed, "days" => " 45 "})

      assert %{to: to, data: data} = steps(built)["issue"]
      assert to == fleet.shards_address
      assert data == Call.encode("issue(uint256,address,uint16)", [3, @other, 45])

      for days <- ["0", "366", "1.5", "", "thirty"] do
        assert {:ok, %{problem: :days_unreadable, review: %{steps: []}}} =
                 build(:issue_shard, token_id: 3, inputs: %{"wallet" => @other, "days" => days}),
               days
      end

      assert {:ok, %{problem: :shard_wallet_unreadable}} =
               build(:issue_shard, token_id: 3, inputs: %{"wallet" => "0x12", "days" => "30"})
    end

    test "each active shard of the key can be ended now or renewed for 30 days",
         %{fleet: fleet} do
      ProposalHelpers.keys_sold!(@fleet, [3], @signer)
      ChainHelpers.issue_shard!(@fleet, 3, @other)

      assert {:ok, built} = build(:end_shard, token_id: 3)
      built = steps(built)
      assert Map.keys(built) == ["end-#{@other}", "renew-#{@other}"]
      assert built["end-#{@other}"].to == fleet.shards_address
      assert built["end-#{@other}"].data == Call.encode("end(uint256,address)", [3, @other])

      assert built["renew-#{@other}"].data ==
               Call.encode("issue(uint256,address,uint16)", [3, @other, 30])

      ChainHelpers.end_shard!(@fleet, 3, @other, @signer)
      assert {:ok, %{review: %{steps: []}}} = build(:end_shard, token_id: 3)
    end
  end

  describe "voting for another and Regents' share" do
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

    test "Regents' share is sent from the fleet contract", %{fleet: fleet} do
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
        end
      end
    )
  end

  defp address("0x" <> hex), do: Base.decode16!(hex, case: :lower)
end

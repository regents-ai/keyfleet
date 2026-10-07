defmodule Keyfleet.WalletStepsAnvilTest do
  # Every wallet button's steps, built by the server and sent to a real node:
  # a local anvil, never a real network, with the fleet `AnvilLab.s.sol` puts
  # on it. The lab's buyer holds keys 1 and 2 and has approved the USDC for a
  # third; the treasury holds 1 ETH, 500 REGENT and 500 USDC. The site's own
  # chain reader records what the lab did, so the steps that start from the
  # record (a person's own keys, a proposal's exact calls, a launch's receipt)
  # read it as they would on Base. Each test starts from the lab as it was
  # built.
  #
  # A wallet here is an account anvil has unlocked, sending exactly the step
  # the server built with a fixed gas limit, so a step the contract refuses
  # is still mined and read back as refused, the way a person who sends past
  # their wallet's warning, or past a button turned off, would see it.
  use ExUnit.Case, async: false

  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.{AnvilLab, ChainClient, Fleets, Repo, WalletSteps}
  alias Keyfleet.Chain.{RpcClient, Scanner}
  alias Keyfleet.WalletSteps.{Reads, VoteSteps}
  alias RegentChain.{Abi, Call, Event, Outcome, Review}

  @moduletag :external
  @moduletag timeout: 900_000

  @fleet_id "fleet_tech_classic"
  @chain_id 31_337
  @buyer "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @second "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
  @third "0x90f79bf6eb2c4f870365e785982e1f101e93b906"
  @gas "0x2dc6c0"
  @hour 3_600
  @eth "0x0000000000000000000000000000000000000000"

  setup_all do
    url = AnvilLab.start!()
    lab = AnvilLab.lab!(url, @buyer)

    chain = Application.fetch_env!(:keyfleet, Keyfleet.Chain)
    wallet_chains = Application.fetch_env!(:keyfleet, :wallet_chains)
    Application.put_env(:keyfleet, Keyfleet.Chain, Keyword.put(chain, :client, RpcClient))

    Application.put_env(:keyfleet, :wallet_chains, %{
      @chain_id => %{name: "the lab chain", rpc_url: url}
    })

    on_exit(fn ->
      Application.put_env(:keyfleet, :wallet_chains, wallet_chains)
      Application.put_env(:keyfleet, Keyfleet.Chain, chain)
    end)

    %{
      url: url,
      lab: %{
        fleet: lab["fleet"],
        rewards: lab["rewards"],
        shards: lab["shards"],
        votes: lab["votes"],
        treasury: lab["treasury"],
        staking: lab["staking"],
        usdc: lab["usdcToken"],
        regent: lab["regentToken"],
        factory: lab["autolaunchFactory"]
      }
    }
  end

  setup %{url: url, lab: lab} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()

    @fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: @chain_id,
        contract_address: lab.fleet,
        rewards_address: lab.rewards,
        votes_address: lab.votes,
        treasury_address: lab.treasury,
        shards_address: lab.shards,
        regent_address: lab.regent,
        regent_staking_address: lab.staking,
        autolaunch_factory_address: lab.factory,
        usdc_address: lab.usdc,
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %System{}
    )

    snapshot = AnvilLab.rpc!(url, "evm_snapshot")
    on_exit(fn -> AnvilLab.rpc!(url, "evm_revert", [snapshot]) end)
    scan!()
    :ok
  end

  describe "buying a key" do
    test "an approval first, then the purchase; a repeat press reaches the chain and is refused",
         %{url: url, lab: lab} do
      send!(url, @second, lab.usdc, Call.encode("mint(uint256)", [100_000_000]))

      built = build!(:buy, @second)
      price = uint!(url, lab.fleet, "nextPrice()")
      assert %{token_id: 3, price: ^price, approve?: true} = built.figures
      assert names(built) == ["approve", "buy"]

      # The approval, pressed twice: both reach the chain, and both land.
      first = press!(url, @second, built.review, "approve")
      again = press!(url, @second, built.review, "approve")
      assert outcome(built.review, "approve", first) == {:ok, :confirmed}
      assert outcome(built.review, "approve", again) == {:ok, :confirmed}

      # Built again once the approval lands: only the purchase is left.
      built = build!(:buy, @second)
      assert names(built) == ["buy"]
      assert built.figures.approve? == false

      bought = press!(url, @second, built.review, "buy")
      assert outcome(built.review, "buy", bought) == {:ok, :confirmed}
      assert address!(url, lab.fleet, "ownerOf(uint256)", [3]) == @second

      # The same purchase pressed again reaches the chain, which refuses it:
      # the approval was for one key.
      repeat = press!(url, @second, built.review, "buy")
      assert outcome(built.review, "buy", repeat) == {:ok, :reverted}
      assert uint!(url, lab.fleet, "totalMinted()") == 3
    end

    test "an allowance already there leaves only the purchase", %{url: url, lab: lab} do
      built = build!(:buy, @buyer)
      assert names(built) == ["buy"]

      assert pressed(url, built, "buy") == {:ok, :confirmed}
      assert address!(url, lab.fleet, "ownerOf(uint256)", [3]) == @buyer
    end
  end

  describe "who sends" do
    test "only a signed-in person builds steps, and only for a wallet their account links" do
      assert {:error, %Ash.Error.Forbidden{}} = build(:send_share, @buyer, nil)
      assert {:error, %Ash.Error.Forbidden{}} = build(:send_share, @buyer, actor(@second))
    end

    test "a step sent from another wallet is not the step the page follows", %{url: url} do
      built = build!(:send_share, @buyer)
      hash = press!(url, @second, built.review, "send_share")

      assert outcome(built.review, "send_share", hash) == {:error, :not_this_step}
    end
  end

  describe "being present" do
    test "every key at once, until 48 hours on; once they lapse, anyone tidies up",
         %{url: url, lab: lab} do
      built = build!(:present, @buyer)
      assert built.figures.blocked == %{}
      assert Enum.map(built.figures.keys, & &1.token_id) == [1, 2]
      assert Enum.all?(built.figures.keys, &is_nil(&1.until))

      assert Review.find(built.review, "present").data ==
               Call.encode("present(uint256[])", [[1, 2]])

      assert pressed(url, built, "present") == {:ok, :confirmed}
      now = timestamp!(url)

      built = build!(:present, @buyer)
      assert [%{until: until}, %{until: until}] = built.figures.keys
      assert DateTime.to_unix(until) == now + 48 * @hour
      refute built.figures.maintenance?

      # A wallet with no keys may still press: the chain refuses it.
      stranger = build!(:present, @third)
      assert stranger.figures.blocked == %{"present" => :no_keys}
      assert pressed(url, stranger, "present") == {:ok, :reverted}

      skip!(url, 49 * @hour)
      built = build!(:present, @third)
      assert built.figures.maintenance?
      assert pressed(url, built, "sweep") == {:ok, :confirmed}
      assert [0, 0, 0] = uints!(url, lab.votes, "presenceQueue()", 3)
      refute build!(:present, @third).figures.maintenance?
    end
  end

  describe "a decision" do
    test "proposed, voted with every key at once, carried out once; a cancelled one stays so",
         %{url: url, lab: lab} do
      proposed = propose!(url, @buyer, %{"kind" => "decision"})
      assert Review.find(proposed.review, "propose").data =~ propose_selector()
      assert uint!(url, lab.votes, "proposalCount()") == 1

      ballot = build!(:ballot, @buyer, proposal: 1)
      assert ballot.figures.keys == [1, 2]
      assert pressed(url, ballot, "no") == {:ok, :confirmed}
      # Changing both keys' ballots to yes; the same again is counted again.
      assert pressed(url, ballot, "yes") == {:ok, :confirmed}
      assert pressed(url, ballot, "yes") == {:ok, :confirmed}
      assert %{yes: 2, no: 0, e0: 1, late: 1} = on_chain(1)

      carry_out = build!(:carry_out, @buyer, proposal: 1)
      assert carry_out.figures.blocked == %{"carry_out" => :open}
      assert pressed(url, carry_out, "carry_out") == {:ok, :reverted}

      skip!(url, @hour + 1)
      carry_out = build!(:carry_out, @third, proposal: 1)
      assert carry_out.figures.blocked == %{}
      assert pressed(url, carry_out, "carry_out") == {:ok, :confirmed}
      assert pressed(url, carry_out, "carry_out") == {:ok, :reverted}

      closed = build!(:ballot, @buyer, proposal: 1)
      assert closed.figures.blocked["yes"] == :voting_closed
      assert pressed(url, closed, "yes") == {:ok, :reverted}

      propose!(url, @buyer, %{"kind" => "decision"})
      cancel = build!(:cancel, @buyer, proposal: 2)
      assert cancel.figures.blocked == %{}
      assert build!(:cancel, @third, proposal: 2).figures.blocked == %{"cancel" => :not_your_key}
      assert pressed(url, cancel, "cancel") == {:ok, :confirmed}
      assert build!(:cancel, @buyer, proposal: 2).figures.blocked == %{"cancel" => :cancelled}
      assert pressed(url, cancel, "cancel") == {:ok, :reverted}
    end
  end

  describe "the treasury's proposals" do
    test "each kind carried out with its exact calls", %{url: url, lab: lab} do
      held = uint!(url, lab.usdc, "balanceOf(address)", [@third])

      approved!(url, %{
        "kind" => "pay",
        "asset" => lab.usdc,
        "amount" => "1.5",
        "recipient" => @third
      })

      assert uint!(url, lab.usdc, "balanceOf(address)", [@third]) == held + 1_500_000

      approved!(url, %{"kind" => "rate", "rate" => "0.5"})
      assert uint!(url, lab.treasury, "dailySplitBps()") == 50

      approved!(url, %{"kind" => "edits", "target" => "2", "restricted" => "true"})
      assert uint!(url, lab.votes, "editsRestricted(uint256)", [2]) == 1

      hash = "0x" <> String.duplicate("ab", 32)
      approved!(url, %{"kind" => "signature", "signature" => "approve", "hash" => hash})
      assert uint!(url, lab.treasury, "approvedHash(bytes32)", [hash]) == 1
      approved!(url, %{"kind" => "signature", "signature" => "revoke", "hash" => hash})
      assert uint!(url, lab.treasury, "approvedHash(bytes32)", [hash]) == 0
    end

    test "an advance goes out, and comes back in part from whoever presses, approved first",
         %{url: url, lab: lab} do
      proposed =
        approved!(url, %{
          "kind" => "advance",
          "asset" => lab.usdc,
          "amount" => "40",
          "recipient" => @third,
          "text" => "Hosting"
        })

      assert {:advance, 1, %{usdc?: true}, @third, 40_000_000} = proposed.figures.action

      assert [@third, usdc, 40_000_000, purpose] =
               words!(url, lab.treasury, "advances(uint256)", [1], [
                 :address,
                 :address,
                 {:uint, 256},
                 :bytes32
               ])

      assert usdc == lab.usdc
      assert purpose == VoteSteps.content_hash("Hosting")

      returned = build!(:return_advance, @third, advance_id: 1, inputs: %{"amount" => "15"})
      assert names(returned) == ["approve", "return"]
      assert returned.figures.blocked == %{"return" => :approve_first}
      assert pressed(url, returned, "approve") == {:ok, :confirmed}

      returned = build!(:return_advance, @third, advance_id: 1, inputs: %{"amount" => "15"})
      assert returned.figures.blocked == %{}
      assert pressed(url, returned, "return") == {:ok, :confirmed}

      assert [_operator, _asset, 25_000_000, _purpose] =
               words!(url, lab.treasury, "advances(uint256)", [1], [
                 :address,
                 :address,
                 {:uint, 256},
                 :bytes32
               ])

      over = build!(:return_advance, @third, advance_id: 1, inputs: %{"amount" => "30"})
      assert over.figures.blocked == %{"return" => :above_outstanding}
      assert pressed(url, over, "return") == {:ok, :reverted}
    end

    test "a token launched through Autolaunch is settled, added to the daily split, released and collected by anyone",
         %{url: url, lab: lab} do
      assert %{problem: :no_launch} = build!(:launch_upkeep, @third)

      approved!(url, %{
        "kind" => "launch",
        "name" => "Lab Fleet Token",
        "symbol" => "LAB",
        "description" => "The lab fleet's own token.",
        "website" => "https://keyfleet.ai",
        "image" => "https://keyfleet.ai/mark.png"
      })

      upkeep = build!(:launch_upkeep, @third)
      assert %{launch_id: 1, lifecycle: :active, bound?: false} = upkeep.figures
      assert names(upkeep) == ["settle", "bind", "release", "collect"]

      assert upkeep.figures.blocked == %{
               "settle" => :sale_running,
               "bind" => :not_sold,
               "release" => :not_sold,
               "collect" => :not_sold
             }

      # Pressed anyway while the sale runs: the chain refuses each.
      assert pressed(url, upkeep, "settle") == {:ok, :reverted}
      assert pressed(url, upkeep, "bind") == {:ok, :reverted}

      AnvilLab.rpc!(url, "anvil_mine", ["0xa"])
      upkeep = build!(:launch_upkeep, @third)
      assert upkeep.figures.blocked["settle"] == nil
      assert pressed(url, upkeep, "settle") == {:ok, :confirmed}

      upkeep = build!(:launch_upkeep, @third)

      assert %{lifecycle: :graduated, bound?: false, blocked: %{"settle" => :launch_settled}} =
               upkeep.figures

      assert pressed(url, upkeep, "bind") == {:ok, :confirmed}
      assert uint!(url, lab.treasury, "launchId()") == 1

      upkeep = build!(:launch_upkeep, @third)
      assert %{bound?: true, blocked: %{"bind" => :bound}} = upkeep.figures
      token = upkeep.figures.token
      assert pressed(url, upkeep, "release") == {:ok, :confirmed}
      assert uint!(url, token, "balanceOf(address)", [lab.treasury]) == 700 * 10 ** 18
      assert pressed(url, upkeep, "collect") == {:ok, :confirmed}
      assert pressed(url, upkeep, "settle") == {:ok, :reverted}

      assert List.last(list!(url, lab.treasury, "splitAssets()")) == token
    end
  end

  describe "the daily split and claims" do
    test "run once it opens, then claimed per asset by the holder or the key's shard, always to the holder",
         %{url: url, lab: lab} do
      split = build!(:run_split, @third)
      assert %{"run_split" => {:opens_at, opens_at}} = split.figures.blocked
      assert pressed(url, split, "run_split") == {:ok, :reverted}

      skip!(url, DateTime.to_unix(opens_at) - timestamp!(url) + 1)
      split = build!(:run_split, @third)
      assert split.figures.blocked == %{}
      assert %{keys: 2, rate_bps: bps} = split.figures
      usdc = Enum.find(split.figures.assets, &(&1.asset == lab.usdc))
      assert usdc.per_key == div(div(usdc.balance * bps, 10_000), 2)
      assert usdc.per_key > 0
      eth = Enum.find(split.figures.assets, &(&1.asset == @eth))
      assert eth.per_key > 0

      assert pressed(url, split, "run_split") == {:ok, :confirmed}
      assert pressed(url, split, "run_split") == {:ok, :reverted}

      claim = build!(:claim, @buyer, token_id: 1)
      assert %{amount: owed} = Enum.find(claim.figures.waiting, &(&1.asset == lab.usdc))
      assert owed == usdc.per_key
      held = uint!(url, lab.usdc, "balanceOf(address)", [@buyer])
      assert pressed(url, claim, "claim-#{lab.usdc}") == {:ok, :confirmed}
      assert uint!(url, lab.usdc, "balanceOf(address)", [@buyer]) == held + owed
      assert pressed(url, claim, "claim-#{lab.usdc}") == {:ok, :reverted}

      assert build!(:claim, @buyer, token_id: 1).figures.blocked["claim-#{lab.usdc}"] ==
               :nothing_to_claim

      # Key 2's shard claims; the money goes to the key's holder.
      issue_shard!(url, 2, @third)
      claim = build!(:claim, @third, token_id: 2)
      assert claim.figures.holder == @buyer
      assert claim.figures.blocked == %{}
      agent_held = uint!(url, lab.usdc, "balanceOf(address)", [@third])
      assert pressed(url, claim, "claim-#{lab.usdc}") == {:ok, :confirmed}
      assert uint!(url, lab.usdc, "balanceOf(address)", [@buyer]) == held + 2 * owed
      assert uint!(url, lab.usdc, "balanceOf(address)", [@third]) == agent_held

      stranger = build!(:claim, @second, token_id: 1)
      assert stranger.figures.blocked["claim-#{@eth}"] == :not_your_key
      assert pressed(url, stranger, "claim-#{@eth}") == {:ok, :reverted}
    end

    test "the stakers' share is sent once by anyone; a repeat press finds nothing owed",
         %{url: url, lab: lab} do
      share = build!(:send_share, @third)
      assert share.figures.owed > 0
      assert pressed(url, share, "send_share") == {:ok, :confirmed}
      assert uint!(url, lab.fleet, "protocolShareOwed()") == 0
      assert build!(:send_share, @third).figures.blocked == %{"send_share" => :nothing_owed}
      assert pressed(url, share, "send_share") == {:ok, :reverted}
    end
  end

  describe "a key's shards" do
    test "issued for several keys at once, renewed and ended by the owner; each press reaches the chain",
         %{url: url, lab: lab} do
      issued =
        build!(:issue_shard, @buyer,
          inputs: %{"keys" => "1, 2", "wallet" => @third, "days" => "45"}
        )

      assert %{keys: [1, 2], days: 45, blocked: %{}} = issued.figures
      assert pressed(url, issued, "issue") == {:ok, :confirmed}
      assert shard_active?(url, lab, 1, @third)
      assert shard_active?(url, lab, 2, @third)

      # Only the keys' owner may issue.
      stranger =
        build!(:issue_shard, @second,
          inputs: %{"keys" => "1", "wallet" => @third, "days" => "30"}
        )

      assert stranger.figures.blocked == %{"issue" => :not_your_key}
      assert pressed(url, stranger, "issue") == {:ok, :reverted}

      # Each key shows its own shard, and each is renewed or ended on its own.
      scan!()

      for token_id <- [1, 2] do
        shards = build!(:end_shard, @buyer, token_id: token_id)
        assert names(shards) == ["end-#{@third}", "renew-#{@third}"]
        assert pressed(url, shards, "renew-#{@third}") == {:ok, :confirmed}
        assert pressed(url, shards, "end-#{@third}") == {:ok, :confirmed}
        refute shard_active?(url, lab, token_id, @third)
        assert pressed(url, shards, "end-#{@third}") == {:ok, :reverted}
      end
    end

    test "with agent voting on, a shard votes its key; turned off, it can't", %{url: url} do
      issue_shard!(url, 1, @third)
      propose!(url, @buyer, %{"kind" => "decision"})

      ballot = build!(:ballot, @third, proposal: 1)
      assert ballot.figures.keys == [1]
      assert pressed(url, ballot, "abstain") == {:ok, :confirmed}
      assert %{abstain: 1} = on_chain(1)

      voting = build!(:agent_voting, @buyer, inputs: %{"keys" => "1"})
      assert voting.figures.voting == [1]
      assert pressed(url, voting, "off") == {:ok, :confirmed}
      assert build!(:agent_voting, @buyer, inputs: %{"keys" => "1"}).figures.voting == []

      off = build!(:ballot, @third, proposal: 1)
      assert off.figures.blocked["yes"] == :no_keys
      assert pressed(url, ballot, "yes") == {:ok, :reverted}

      assert pressed(url, voting, "on") == {:ok, :confirmed}
      assert build!(:ballot, @third, proposal: 1).figures.keys == [1]
    end
  end

  describe "a key's random draw" do
    test "asked again by anyone while refused; once accepted, and once drawn, the button says why it's off",
         %{url: url, lab: lab} do
      coordinator = address!(url, lab.fleet, "VRF_COORDINATOR()")

      # The lab sold keys 1 and 2 while the coordinator refused every request.
      built = build!(:reveal, @third, token_id: 1)
      assert %{problem: nil, figures: %{token_id: 1, blocked: %{}}} = built

      assert %{to: fleet, data: data} = Review.find(built.review, "reveal")
      assert fleet == lab.fleet
      assert data == Call.encode("requestReveal(uint256)", [1])

      # Refused again: the press lands, and the key is offered again.
      send!(url, @buyer, coordinator, Call.encode("setRevertAll(bool)", [true]))
      refused = press!(url, @third, built.review, "reveal")
      assert outcome(built.review, "reveal", refused) == {:ok, :confirmed}
      assert {:ok, {[1], []}} = reveal_log(url, refused, lab, "RevealRequestFailed(uint256)", 1)
      assert build!(:reveal, @third, token_id: 1).figures.blocked == %{}

      # Accepted: the draw is on its way, and a repeat press is refused.
      send!(url, @buyer, coordinator, Call.encode("setRevertAll(bool)", [false]))
      accepted = press!(url, @third, built.review, "reveal")
      assert outcome(built.review, "reveal", accepted) == {:ok, :confirmed}

      assert {:ok, {[1, request_id], []}} =
               reveal_log(url, accepted, lab, "RevealRequested(uint256,uint256)", 2)

      assert build!(:reveal, @third, token_id: 1).figures.blocked == %{
               "reveal" => :reveal_requested
             }

      assert pressed(url, built, "reveal") == {:ok, :reverted}

      # Drawn: the coordinator answers, and there is nothing to ask for.
      send!(
        url,
        @buyer,
        coordinator,
        Call.encode("fulfill(uint256,uint256[])", [request_id, [42]])
      )

      assert build!(:reveal, @third, token_id: 1).figures.blocked == %{"reveal" => :revealed}
    end
  end

  # --- building and sending --------------------------------------------

  defp actor(wallet),
    do: %Human{human_account_id: Ecto.UUID.generate(), wallet_addresses: [wallet]}

  defp build(flow, signer, actor, arguments \\ []),
    do: WalletSteps.build_steps(@fleet_id, flow, signer, "lab", Map.new(arguments), actor: actor)

  defp build!(flow, signer, arguments \\ []) do
    {:ok, built} = build(flow, signer, actor(signer), arguments)
    built
  end

  # A proposal made with key 1 by `signer`, open to votes for an hour, and
  # recorded by the chain reader.
  defp propose!(url, signer, inputs) do
    inputs = Map.merge(%{"key" => "1", "hours" => "1", "text" => "Lab proposal"}, inputs)
    built = build!(:propose, signer, inputs: inputs)
    assert built.problem == nil
    assert built.figures.blocked == %{}
    assert pressed(url, built, "propose") == {:ok, :confirmed}

    scan!()
    built
  end

  # A proposal made, voted yes with keys 1 and 2, closed and carried out with
  # its exact calls; the steps it was proposed with.
  defp approved!(url, inputs) do
    proposed = propose!(url, @buyer, inputs)
    number = uint!(url, Fleets.get_fleet!(@fleet_id).votes_address, "proposalCount()")
    assert pressed(url, build!(:ballot, @buyer, proposal: number), "yes") == {:ok, :confirmed}
    skip!(url, @hour + 1)
    carry_out = build!(:carry_out, @third, proposal: number)
    assert carry_out.figures.blocked == %{}
    assert pressed(url, carry_out, "carry_out") == {:ok, :confirmed}
    scan!()
    proposed
  end

  defp issue_shard!(url, token_id, wallet) do
    issued =
      build!(:issue_shard, @buyer,
        inputs: %{"keys" => "#{token_id}", "wallet" => wallet, "days" => "30"}
      )

    assert pressed(url, issued, "issue") == {:ok, :confirmed}
    scan!()
  end

  # The site's chain reader, recording what the lab chain did since its last
  # pass.
  defp scan! do
    assert :ok = @fleet_id |> Fleets.get_fleet!() |> Scanner.step(RpcClient)
  end

  defp names(%{review: review}), do: Enum.map(review.steps, & &1.step)

  # A press of `name`, sent from the wallet the steps were built for, and
  # how it landed as the page reads it.
  defp pressed(url, %{review: review}, name),
    do: outcome(review, name, press!(url, review.signer, review, name))

  defp press!(url, from, review, name) do
    %{to: to, data: data, value: value} = Review.find(review, name)
    send!(url, from, to, data, value)
  end

  defp send!(url, from, to, data, value \\ "0x0") do
    hash =
      AnvilLab.rpc!(url, "eth_sendTransaction", [
        %{from: from, to: to, data: data, value: value, gas: @gas}
      ])

    AnvilLab.receipt!(url, hash)
    hash
  end

  defp outcome(review, name, hash),
    do: Outcome.of(ChainClient, review, Review.find(review, name), hash)

  # Moves the lab chain's clock on and mines a block at the new time.
  defp skip!(url, seconds) do
    AnvilLab.rpc!(url, "evm_increaseTime", [seconds])
    AnvilLab.rpc!(url, "evm_mine")
  end

  # --- reading the lab -------------------------------------------------

  defp propose_selector,
    do: Call.selector("propose(uint256,bytes32,uint64,(address,uint256,bytes)[])")

  defp on_chain(number) do
    {:ok, reads} = Reads.at_head()
    {:ok, proposal} = VoteSteps.proposal(reads, Fleets.get_fleet!(@fleet_id), number)
    proposal
  end

  defp timestamp!(url) do
    %{"timestamp" => "0x" <> hex} = AnvilLab.rpc!(url, "eth_getBlockByNumber", ["latest", false])
    String.to_integer(hex, 16)
  end

  # The indexed words of the one `signature` log the fleet emitted in the
  # transaction `hash`.
  defp reveal_log(url, hash, lab, signature, indexed) do
    %{"logs" => logs} = AnvilLab.receipt!(url, hash)
    Event.one(logs, signature, lab.fleet, indexed, 0)
  end

  defp uint!(url, to, signature, arguments \\ []) do
    "0x" <> hex = view!(url, to, signature, arguments)
    String.to_integer(hex, 16)
  end

  defp uints!(url, to, signature, count) do
    "0x" <> hex = view!(url, to, signature, [])
    for index <- 0..(count - 1), do: String.to_integer(String.slice(hex, index * 64, 64), 16)
  end

  defp address!(url, to, signature, arguments \\ []) do
    "0x" <> hex = view!(url, to, signature, arguments)
    "0x" <> String.slice(hex, -40, 40)
  end

  defp list!(url, to, signature) do
    [addresses] = words!(url, to, signature, [], [{:array, :address}])
    addresses
  end

  defp words!(url, to, signature, arguments, types) do
    "0x" <> hex = view!(url, to, signature, arguments)
    {:ok, words} = Abi.decode(Base.decode16!(hex, case: :lower), types)
    words
  end

  defp shard_active?(url, lab, token_id, wallet),
    do: uint!(url, lab.shards, "isActive(uint256,address)", [token_id, wallet]) == 1

  defp view!(url, to, signature, arguments),
    do:
      AnvilLab.rpc!(url, "eth_call", [
        %{to: to, data: Call.encode(signature, arguments)},
        "latest"
      ])
end

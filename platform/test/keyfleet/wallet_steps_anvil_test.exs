defmodule Keyfleet.WalletStepsAnvilTest do
  # Every wallet button's steps, built by the server and sent to a real node:
  # a local anvil, never a real network, with the fleet `AnvilLab.s.sol`
  # puts on it. The lab's buyer holds keys 1 and 2 and has approved the USDC
  # for a third. Each test starts from the lab as it was built.
  #
  # A wallet here is an account anvil has unlocked, sending exactly the step
  # the server built with a fixed gas limit, so a step the contract refuses
  # is still mined and read back as refused, the way a person who sends past
  # their wallet's warning would see it.
  use ExUnit.Case, async: false

  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.{AnvilLab, ChainClient, ChainHelpers, Fleets, ProposalHelpers, Repo, WalletSteps}
  alias Keyfleet.Chain.RpcClient
  alias RegentChain.{Call, Event, Outcome, Review}

  @moduletag :external
  @moduletag timeout: 600_000

  @fleet_id "fleet_tech_classic"
  @chain_id 31_337
  @buyer "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @second "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
  @third "0x90f79bf6eb2c4f870365e785982e1f101e93b906"
  @gas "0x2dc6c0"

  setup_all do
    url = AnvilLab.start!()
    %{"fleet" => fleet, "shards" => shards} = AnvilLab.lab!(url, @buyer)

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

    addresses = %{
      fleet: fleet,
      shards: shards,
      rewards: address!(url, fleet, "REWARDS()"),
      votes: address!(url, fleet, "VOTES()"),
      usdc: address!(url, fleet, "USDC()")
    }

    %{url: url, lab: addresses}
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
        shards_address: lab.shards,
        usdc_address: lab.usdc,
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %System{}
    )

    ChainHelpers.seed_cursor!(@fleet_id)
    ProposalHelpers.keys_sold!(@fleet_id, [1, 2], @buyer)

    snapshot = AnvilLab.rpc!(url, "evm_snapshot")
    on_exit(fn -> AnvilLab.rpc!(url, "evm_revert", [snapshot]) end)
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

      bought = press!(url, @buyer, built.review, "buy")
      assert outcome(built.review, "buy", bought) == {:ok, :confirmed}
      assert address!(url, lab.fleet, "ownerOf(uint256)", [3]) == @buyer
    end
  end

  describe "who sends" do
    test "only a signed-in person builds steps, and only for a wallet their account links" do
      assert {:error, %Ash.Error.Forbidden{}} = build(:send_share, @buyer, nil)
      assert {:error, %Ash.Error.Forbidden{}} = build(:send_share, @buyer, actor(@second))
    end

    test "a step sent from another wallet is not the step the page follows",
         %{url: url} do
      built = build!(:send_share, @buyer)
      hash = press!(url, @second, built.review, "send")

      assert outcome(built.review, "send", hash) == {:error, :not_this_step}
    end
  end

  describe "a decision" do
    test "proposed, voted, changed, withdrawn and carried out; each repeat reaches the chain",
         %{url: url, lab: lab} do
      proposed = build!(:propose_decision, @buyer, inputs: %{"key" => "1", "text" => "Hire"})
      hash = press!(url, @buyer, proposed.review, "propose")
      assert outcome(proposed.review, "propose", hash) == {:ok, :confirmed}
      assert uint!(url, lab.votes, "proposalCount()") == 1

      one = vote_steps!(1, "1")
      both = vote_steps!(1, "1, 2")
      two = vote_steps!(1, "2")

      assert pressed(url, one, "no") == {:ok, :confirmed}
      # Changing key 1's vote to yes, with key 2 alongside.
      assert pressed(url, both, "yes") == {:ok, :confirmed}
      # The same vote again: the contract refuses a key that already voted so.
      assert pressed(url, both, "yes") == {:ok, :reverted}

      assert pressed(url, two, "withdraw") == {:ok, :confirmed}
      carry_out = build!(:carry_out, @buyer, proposal: 1)
      # One yes of two keys sold is not more than half.
      assert pressed(url, carry_out, "carry_out") == {:ok, :reverted}

      assert pressed(url, two, "yes") == {:ok, :confirmed}
      assert pressed(url, carry_out, "carry_out") == {:ok, :confirmed}
      assert pressed(url, carry_out, "carry_out") == {:ok, :reverted}
    end
  end

  describe "a payment" do
    test "a pasted token paid on approval, with the key that didn't vote yes matched",
         %{url: url, lab: lab} do
      bought = build!(:buy, @buyer)
      assert pressed(url, bought, "buy") == {:ok, :confirmed}

      proposed =
        build!(:propose_payment, @buyer,
          inputs: %{
            "key" => "1",
            "asset" => "other",
            # Pasted as a block explorer writes it, in mixed capitals.
            "other_asset" => "0x" <> String.upcase(String.slice(lab.usdc, 2..-1//1)),
            "amount" => "1",
            "recipient" => @third,
            "text" => "Editing"
          }
        )

      assert %{amount: 1_000_000, asset: %{symbol: "USDC"}} = proposed.figures
      assert pressed(url, proposed, "propose") == {:ok, :confirmed}

      assert pressed(url, vote_steps!(1, "1, 2"), "yes") == {:ok, :confirmed}

      assert pressed(url, build!(:carry_out, @buyer, proposal: 1), "carry_out") ==
               {:ok, :confirmed}

      assert uint!(url, lab.usdc, "balanceOf(address)", [@third]) == 1_000_000

      # Key 3 stayed silent, so it is matched: half the payment, as two keys
      # voted yes. Anyone may press; the match goes to the key's holder.
      held = uint!(url, lab.usdc, "balanceOf(address)", [@buyer])
      collect = build!(:collect, @buyer, proposal: 1, inputs: %{"keys" => "3"})
      assert pressed(url, collect, "collect") == {:ok, :confirmed}
      assert uint!(url, lab.usdc, "balanceOf(address)", [@buyer]) == held + 500_000
      assert pressed(url, collect, "collect") == {:ok, :reverted}

      voted_yes = build!(:collect, @buyer, proposal: 1, inputs: %{"keys" => "1"})
      assert pressed(url, voted_yes, "collect") == {:ok, :reverted}
    end
  end

  describe "a key's shards" do
    test "issued by the key's owner, renewed and ended; each press reaches the chain",
         %{url: url, lab: lab} do
      issued = build!(:issue_shard, @buyer, token_id: 1, inputs: shard_inputs(@third))
      assert pressed(url, issued, "issue") == {:ok, :confirmed}
      assert shard_active?(url, lab, @third)

      # Only the key's owner may issue, and a wallet holds one key's shard.
      stranger = build!(:issue_shard, @second, token_id: 1, inputs: shard_inputs(@third))
      assert pressed(url, stranger, "issue") == {:ok, :reverted}
      other_key = build!(:issue_shard, @buyer, token_id: 2, inputs: shard_inputs(@third))
      assert pressed(url, other_key, "issue") == {:ok, :reverted}

      ChainHelpers.issue_shard!(@fleet_id, 1, @third)
      shards = build!(:end_shard, @buyer, token_id: 1)
      assert names(shards) == ["end-#{@third}", "renew-#{@third}"]

      assert pressed(url, shards, "renew-#{@third}") == {:ok, :confirmed}
      assert pressed(url, shards, "end-#{@third}") == {:ok, :confirmed}
      refute shard_active?(url, lab, @third)
      assert pressed(url, shards, "end-#{@third}") == {:ok, :reverted}
    end

    test "the shard's wallet steps down with the call the agent API hands it",
         %{url: url, lab: lab} do
      issued = build!(:issue_shard, @buyer, token_id: 1, inputs: shard_inputs(@third))
      assert pressed(url, issued, "issue") == {:ok, :confirmed}

      send!(url, @third, lab.shards, Call.encode("end(uint256,address)", [1, @third]))
      refute shard_active?(url, lab, @third)
    end
  end

  describe "voting for another" do
    test "a named wallet may propose with the holder's key until the holder clears it",
         %{url: url} do
      delegated = build!(:delegate, @buyer, inputs: %{"delegate" => @third})
      assert pressed(url, delegated, "delegate") == {:ok, :confirmed}

      for_holder = build!(:propose_decision, @third, inputs: %{"key" => "1", "text" => "For"})
      assert pressed(url, for_holder, "propose") == {:ok, :confirmed}

      assert pressed(url, delegated, "clear") == {:ok, :confirmed}
      assert pressed(url, for_holder, "propose") == {:ok, :reverted}
    end
  end

  describe "the stakers' share" do
    test "sent once by anyone; a repeat press finds nothing owed", %{url: url, lab: lab} do
      share = build!(:send_share, @third)
      assert pressed(url, share, "send") == {:ok, :confirmed}
      assert uint!(url, lab.fleet, "protocolShareOwed()") == 0
      assert pressed(url, share, "send") == {:ok, :reverted}
    end
  end

  describe "a key's income" do
    test "claimed to the signer; built again, nothing is waiting", %{url: url, lab: lab} do
      # The fleet alone hands income to a cohort, so anvil sends as the fleet.
      send!(url, @buyer, lab.usdc, Call.encode("mint(uint256)", [4_000_000]))

      send!(
        url,
        @buyer,
        lab.usdc,
        Call.encode("transfer(address,uint256)", [lab.rewards, 4_000_000])
      )

      cohort = uint!(url, lab.rewards, "keyCohort(uint256)", [1])
      AnvilLab.rpc!(url, "anvil_impersonateAccount", [lab.fleet])
      AnvilLab.rpc!(url, "anvil_setBalance", [lab.fleet, "0xde0b6b3a7640000"])

      send!(
        url,
        lab.fleet,
        lab.rewards,
        Call.encode("allocateToCohort(address,uint256,uint256)", [lab.usdc, cohort, 4_000_000])
      )

      built = build!(:claim, @buyer, token_id: 1)
      claim = "claim-#{lab.usdc}"
      assert names(built) == [claim]
      # Every token the keys are paid in is shown, with only those that
      # have something waiting sent.
      assert %{amount: waiting, symbol: "USDC"} =
               Enum.find(built.figures.waiting, &(&1.asset == lab.usdc))

      assert waiting > 0
      assert Enum.all?(built.figures.waiting, &(&1.asset == lab.usdc or &1.amount == 0))

      held = uint!(url, lab.usdc, "balanceOf(address)", [@buyer])
      assert pressed(url, built, claim) == {:ok, :confirmed}
      assert uint!(url, lab.usdc, "balanceOf(address)", [@buyer]) == held + waiting
      assert pressed(url, built, claim) == {:ok, :reverted}

      assert %{problem: :nothing_waiting, review: %{steps: []}} =
               build!(:claim, @buyer, token_id: 1)
    end
  end

  describe "a key's random draw" do
    test "asked again by anyone while refused; once accepted, and once drawn, nothing is offered",
         %{url: url, lab: lab} do
      coordinator = address!(url, lab.fleet, "VRF_COORDINATOR()")

      # The lab sold keys 1 and 2 while the coordinator refused every request.
      built = build!(:reveal, @third, token_id: 1)
      assert %{problem: nil, figures: %{token_id: 1}} = built
      assert names(built) == ["reveal"]

      assert %{to: fleet, data: data} = Review.find(built.review, "reveal")
      assert fleet == lab.fleet
      assert data == Call.encode("requestReveal(uint256)", [1])

      # Refused again: the press lands, and the key is offered again.
      send!(url, @buyer, coordinator, Call.encode("setRevertAll(bool)", [true]))
      refused = press!(url, @third, built.review, "reveal")
      assert outcome(built.review, "reveal", refused) == {:ok, :confirmed}
      assert {:ok, {[1], []}} = reveal_log(url, refused, lab, "RevealRequestFailed(uint256)", 1)
      assert names(build!(:reveal, @third, token_id: 1)) == ["reveal"]

      # Accepted: the draw is on its way, and a repeat press is refused.
      send!(url, @buyer, coordinator, Call.encode("setRevertAll(bool)", [false]))
      accepted = press!(url, @third, built.review, "reveal")
      assert outcome(built.review, "reveal", accepted) == {:ok, :confirmed}

      assert {:ok, {[1, request_id], []}} =
               reveal_log(url, accepted, lab, "RevealRequested(uint256,uint256)", 2)

      assert %{problem: :reveal_requested, review: %{steps: []}} =
               build!(:reveal, @third, token_id: 1)

      assert pressed(url, built, "reveal") == {:ok, :reverted}

      # Drawn: the coordinator answers, and there is nothing to ask for.
      send!(
        url,
        @buyer,
        coordinator,
        Call.encode("fulfill(uint256,uint256[])", [request_id, [42]])
      )

      assert %{problem: :revealed, review: %{steps: []}} = build!(:reveal, @third, token_id: 1)
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

  defp vote_steps!(proposal, keys),
    do: build!(:vote, @buyer, proposal: proposal, inputs: %{"keys" => keys})

  defp shard_inputs(wallet), do: %{"wallet" => wallet, "days" => "30"}

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

  # --- reading the lab -------------------------------------------------

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

  defp address!(url, to, signature, arguments \\ []) do
    "0x" <> hex = view!(url, to, signature, arguments)
    "0x" <> String.slice(hex, -40, 40)
  end

  # The last of the four words `shardOf` returns says whether it is active.
  defp shard_active?(url, lab, wallet) do
    "0x" <> words = view!(url, lab.shards, "shardOf(address)", [wallet])
    String.to_integer(String.slice(words, -64, 64), 16) == 1
  end

  defp view!(url, to, signature, arguments),
    do:
      AnvilLab.rpc!(url, "eth_call", [
        %{to: to, data: Call.encode(signature, arguments)},
        "latest"
      ])
end

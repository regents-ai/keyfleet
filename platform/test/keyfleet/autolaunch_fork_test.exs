defmodule Keyfleet.AutolaunchForkTest do
  # A whole Autolaunch v2 launch as the site and the keeper see it, on a
  # local anvil forking the chain `KEYFLEET_FORK_RPC_URL` names, whose
  # Autolaunch v2 factory `KEYFLEET_FORK_FACTORY` names. The forked chain is
  # only read; everything is sent to the local fork, which is killed when the
  # test ends. `contracts/script/LaunchLab.s.sol` puts a Classic fleet on the
  # fork whose buyer holds every key it must sell before it may propose a
  # launch.
  #
  # The launch is proposed, voted and carried out with the steps the server
  # builds, the chain reader records the proposal and reads its launch, one
  # bidder buys the whole sale, and the keeper settles the auction and moves
  # a month of the launch's income into the fleet.
  #
  # Excluded unless asked for, since it needs a chain carrying Autolaunch v2:
  #
  #     KEYFLEET_FORK_RPC_URL=http://127.0.0.1:58741 \
  #     KEYFLEET_FORK_FACTORY=0xcc0dF8493B348bFD7C58730A2c5e97b3A73aCb00 \
  #     mix test --only autolaunch_fork
  use ExUnit.Case, async: false

  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.{AnvilLab, ChainClient, Fleets, Keeper, Proposals, Repo, WalletSteps}
  alias Keyfleet.Chain.{LaunchEnvelopes, RpcClient, Scanner}
  alias Keyfleet.Keeper.{Income, RpcNode, Sender, Wallet}
  alias RegentChain.{Call, Outcome, Review}

  @moduletag :autolaunch_fork
  @moduletag timeout: 900_000

  @fleet_id "fleet_tech_classic"
  @chain_id 31_337
  @script "script/LaunchLab.s.sol:LaunchLab"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @regent "0x6f89bca4ea5931edfcb09786267b251dee752b07"
  @permit2 "0x000000000022d473030f116ddee9f6b43ac78ba3"
  # Fresh wallets: on a copy of Base some of anvil's own accounts carry
  # delegated code that refuses a key.
  @buyer "0x5eed0000000000000000000000000000000000b1"
  @bidder "0x5eed0000000000000000000000000000000000b2"
  @keeper_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @keys 100
  @gas "0x1c9c380"
  # 0.000001 REGENT per token, the Autolaunch site's default floor, and the
  # REGENT the auction must raise at it.
  @floor 79_228_162_514_264_337_593_500
  @floor_minimum 19_999_999_999_999_999_999_989
  # The keys' own higher minimum, and one bid above it.
  @minimum 21_000 * Integer.pow(10, 18)
  @bid 22_000 * Integer.pow(10, 18)
  @month 30 * 86_400

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()

    factory = String.downcase(Elixir.System.fetch_env!("KEYFLEET_FORK_FACTORY"))
    url = AnvilLab.start!(["--fork-url", Elixir.System.fetch_env!("KEYFLEET_FORK_RPC_URL")])

    for wallet <- [@buyer, @bidder] do
      AnvilLab.rpc!(url, "anvil_impersonateAccount", [wallet])
      AnvilLab.rpc!(url, "anvil_setBalance", [wallet, hex(100 * Integer.pow(10, 18))])
    end

    AnvilLab.rpc!(url, "anvil_dealERC20", [@buyer, @usdc, hex(@keys * 10_000_000)])

    deployed_block = block_number(url) + 1

    %{"fleet" => fleet} =
      AnvilLab.lab!(url, @buyer, @script, [
        "--sig",
        "run(address)",
        factory,
        "--with-gas-price",
        "1000000000"
      ])

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

    lab = %{
      fleet: fleet,
      factory: factory,
      strategy: address!(url, factory, "strategy()"),
      votes: address!(url, fleet, "VOTES()"),
      rewards: address!(url, fleet, "REWARDS()")
    }

    @fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: @chain_id,
        contract_address: lab.fleet,
        rewards_address: lab.rewards,
        votes_address: lab.votes,
        usdc_address: @usdc,
        deployed_block: deployed_block,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %System{}
    )

    %{url: url, lab: lab}
  end

  test "a launch the keys approve is recorded, graduates and pays the fleet",
       %{url: url, lab: lab} do
    assert :ok = scan()

    # The strategy's own figures, read when the steps are built: the raise at
    # the floor, or the keys' higher minimum, and a minimum no auction could
    # raise, which is still built for the wallet.
    assert %{required_regent_raised: @floor_minimum} =
             build!(:propose_launch, inputs: launch()).figures

    assert %{problem: :launch_refused, review: %{steps: [_propose]}} =
             build!(:propose_launch, inputs: launch(%{"minimum" => "340000000000000000000"}))

    proposed = build!(:propose_launch, inputs: launch(%{"minimum" => "21000"}))

    assert %{floor_price_q96: @floor, minimum_regent_raised: @minimum} = proposed.figures
    assert proposed.figures.required_regent_raised == @minimum
    assert pressed(url, proposed, "propose") == {:ok, :confirmed}

    # The chain reader records the proposal, then reads the launch it fixes.
    assert :ok = scan()
    assert :ok = LaunchEnvelopes.read(fleet(), RpcClient)

    assert %{kind: :autolaunch, launch_envelope: envelope} =
             Proposals.get_proposal!(@fleet_id, 1, load: [:launch_envelope])

    assert %{name: "Lab Launch", symbol: "LABL"} = envelope
    assert Decimal.eq?(envelope.floor_price_q96, @floor)
    assert Decimal.eq?(envelope.minimum_regent_raised, @minimum)

    every_key = Enum.map_join(1..@keys, ", ", &Integer.to_string/1)
    vote = build!(:vote, proposal: 1, inputs: %{"keys" => every_key})
    assert pressed(url, vote, "yes") == {:ok, :confirmed}
    assert pressed(url, build!(:carry_out, proposal: 1), "carry_out") == {:ok, :confirmed}

    sender = keeper!()
    assert {:ok, :auction_created} = Sender.read(sender, lab.fleet, :launch_state)
    assert {:ok, record} = Sender.read(sender, lab.fleet, :launch_record)
    assert {:ok, opened} = Sender.read(sender, lab.fleet, :launch_distribution)

    assert %{
             lifecycle: :active,
             floor_price_q96: @floor,
             required_regent_raised: @minimum,
             treasury: treasury
           } = opened

    assert treasury == lab.fleet

    # Before the auction may be settled, the keeper leaves it alone.
    sender = Income.run(sender)
    assert migrations() == []

    bid!(url, lab, record.auction)
    mine!(url, opened.migration_block - block_number(url))

    # The keeper settles the auction, then has the fleet record its verdict.
    sender = Income.run(sender)

    assert [
             %{function: :migrate, target: strategy, status: :mined},
             %{function: :sync_launch, status: :mined}
           ] = migrations()

    assert strategy == lab.strategy
    assert {:ok, :graduated} = Sender.read(sender, lab.fleet, :launch_state)
    assert {:ok, graduated} = Sender.read(sender, lab.fleet, :launch_distribution)

    assert %{lifecycle: :graduated, floor_price_q96: @floor, required_regent_raised: @minimum} =
             graduated

    # The REGENT the auction raised that the pool did not use is the fleet's
    # shared money, and at least a quarter of the raise.
    <<_price::256, _sold::256, raised::256>> =
      words!(url, record.auction, "lbpInitializationParams()")

    to_fleet = uint!(url, lab.fleet, "freeCapital(address)", [@regent])
    assert raised >= @minimum
    assert to_fleet == raised - graduated.lp_regent_used
    assert to_fleet == uint!(url, @regent, "balanceOf(address)", [lab.fleet])
    assert to_fleet * 4 >= raised

    # A month on, the keeper releases the vested launched token to the fleet,
    # where it is shared money, and the chain reader reads what the fleet
    # booked.
    AnvilLab.rpc!(url, "evm_increaseTime", [@month])
    mine!(url, 1)
    Income.run(sender)

    assert Enum.any?(txs(), &match?(%{function: :release, status: :mined}, &1))
    released = uint!(url, record.subject, "balanceOf(address)", [lab.fleet])
    assert released > 0
    assert uint!(url, lab.fleet, "freeCapital(address)", [record.subject]) == released
    assert uint!(url, lab.fleet, "surplus(address)", [record.subject]) == 0
    assert :ok = scan()
  end

  # --- the site ----------------------------------------------------------

  defp fleet, do: Fleets.get_fleet!(@fleet_id)

  defp scan, do: Scanner.step(fleet(), RpcClient)

  defp launch(inputs \\ %{}) do
    Map.merge(
      %{
        "key" => "1",
        "name" => "Lab Launch",
        "symbol" => "LABL",
        "description" => "A launch the lab's keys approve",
        "website" => "https://example.com",
        "image" => "https://example.com/lab.png",
        "floor" => "0.000001"
      },
      inputs
    )
  end

  defp build!(flow, arguments) do
    actor = %Human{human_account_id: Ecto.UUID.generate(), wallet_addresses: [@buyer]}

    {:ok, built} =
      WalletSteps.build_steps(@fleet_id, flow, @buyer, "lab", Map.new(arguments), actor: actor)

    built
  end

  # A press of `name` from the buyer's wallet, and how it landed as the page
  # reads it.
  defp pressed(url, %{review: review}, name) do
    %{to: to, data: data, value: value} = Review.find(review, name)
    hash = send!(url, review.signer, to, data, value)
    AnvilLab.receipt!(url, hash)
    Outcome.of(ChainClient, review, Review.find(review, name), hash)
  end

  # --- the keeper --------------------------------------------------------

  defp keeper! do
    {:ok, wallet} = Wallet.new(@keeper_key)
    {:ok, sender} = Sender.start(%{Sender.new(wallet, RpcNode) | receipt_poll_ms: 100})
    sender
  end

  defp txs do
    Keeper.Transaction
    |> Ash.read!(actor: %System{})
    |> Enum.sort_by(& &1.nonce)
  end

  defp migrations, do: Enum.filter(txs(), &(&1.function in [:migrate, :sync_launch]))

  # --- the bidder --------------------------------------------------------

  # One bid in the auction's first block, priced well above where it clears,
  # sent the way a connected wallet sends it: approve Permit2, allow the
  # auction through Permit2, and bid on the tick grid.
  defp bid!(url, lab, auction) do
    mine!(url, uint!(url, auction, "startBlock()") - block_number(url))
    sent!(url, @bidder, auction, Call.encode("checkpoint()", []))

    tick = uint!(url, lab.strategy, "bidTickSpacingFor(uint256)", [@floor])
    base = max(uint!(url, auction, "clearingPrice()"), @floor)
    price = base - rem(base, tick) + 100 * tick

    AnvilLab.rpc!(url, "anvil_dealERC20", [@bidder, @regent, hex(@bid)])
    sent!(url, @bidder, @regent, Call.encode("approve(address,uint256)", [@permit2, @bid]))

    sent!(
      url,
      @bidder,
      @permit2,
      Call.encode("approve(address,address,uint160,uint48)", [@regent, auction, @bid, 2 ** 40])
    )

    sent!(
      url,
      @bidder,
      auction,
      Call.encode("submitBid(uint256,uint128,address,uint256,bytes)", [
        price,
        @bid,
        @bidder,
        @floor,
        "0x"
      ])
    )
  end

  # --- the fork ----------------------------------------------------------

  defp send!(url, from, to, data, value),
    do:
      AnvilLab.rpc!(url, "eth_sendTransaction", [
        %{from: from, to: to, data: data, value: value, gas: @gas}
      ])

  # A transaction the test needs to land.
  defp sent!(url, from, to, data) do
    hash = send!(url, from, to, data, "0x0")
    assert AnvilLab.receipt!(url, hash)["status"] == "0x1", "#{data} to #{to} reverted"
  end

  defp mine!(url, blocks) when blocks > 0, do: AnvilLab.rpc!(url, "anvil_mine", [hex(blocks)])
  defp mine!(_url, _blocks), do: nil

  defp block_number(url), do: AnvilLab.number(AnvilLab.rpc!(url, "eth_blockNumber"))

  defp uint!(url, to, signature, arguments \\ []) do
    "0x" <> digits = view!(url, to, signature, arguments)
    String.to_integer(digits, 16)
  end

  defp words!(url, to, signature) do
    "0x" <> digits = view!(url, to, signature, [])
    Base.decode16!(digits, case: :mixed)
  end

  defp address!(url, to, signature) do
    "0x" <> digits = view!(url, to, signature, [])
    "0x" <> String.slice(digits, -40, 40)
  end

  defp view!(url, to, signature, arguments),
    do:
      AnvilLab.rpc!(url, "eth_call", [
        %{to: to, data: Call.encode(signature, arguments)},
        "latest"
      ])

  defp hex(n), do: "0x" <> Integer.to_string(n, 16)
end

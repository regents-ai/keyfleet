defmodule Keyfleet.Treasury.UpkeepAnvilTest do
  # The upkeep pressing Classic #1's Treasury buttons on a real node: a local
  # anvil, never a real network, with Classic #1 as `AnvilLab.s.sol` puts it
  # there. Two days after the lab's two Keys were sold, a third Key is bought,
  # so the daily split is due, the stakers' share is owed and the third Key's
  # USDC waits to become REGENT. The upkeep account is one of anvil's own,
  # signing with anvil's published test key; another holds no ETH. Each test
  # starts from the lab as setup left it.
  #
  # Anvil always suggests a tip of 1 gwei, the most the upkeep pays per gas
  # in all, so each test sets the base fee: 0, where the fee is exactly that
  # most, or 1 gwei, where it is above it.
  use ExUnit.Case, async: false

  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.{AnvilLab, ChainClient, Fleets, Repo, Traits, Treasury, WalletSteps}
  alias Keyfleet.Chain.{RpcClient, Scanner}
  alias Keyfleet.Treasury.Upkeep
  alias RegentChain.{Call, Outcome, Review}

  @moduletag :external
  @moduletag timeout: 600_000

  @fleet_id "fleet_tech_classic"
  @chain_id 31_337
  @buyer "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @second "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
  # Anvil's fifth account and its published test key.
  @operator "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65"
  @operator_key "47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"
  # A key no anvil account has, so its account holds no ETH.
  @empty_key String.duplicate("11", 32)
  @gas "0x2dc6c0"
  @day 86_400
  @deck "0xf11579d3bd868d9a111bc512d814d04c0f10beb44fba7f3a92fa26eb67500356"

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
      Application.delete_env(:keyfleet, Upkeep)
    end)

    skip!(url, 2 * @day + 1)
    %{url: url, lab: Map.put(lab, :autolaunch, autolaunch!(url, lab.treasury))}
  end

  setup %{url: url, lab: lab} do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()

    @fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(deployment(lab), actor: %System{})

    snapshot = AnvilLab.rpc!(url, "evm_snapshot")
    on_exit(fn -> AnvilLab.rpc!(url, "evm_revert", [snapshot]) end)
    scan!()
    buy_key!(url, @second)
    upkeep_key!(@operator_key)
    :ok
  end

  test "paused, it sends nothing; resumed, it presses each due button once, then finds none due",
       %{url: url, lab: lab} do
    owed = uint!(url, lab.manager, "protocolShareOwed()")
    waiting = uint!(url, lab.manager, "pendingConversion()")
    regent = uint!(url, lab.regent, "balanceOf(address)", [lab.treasury])
    assert owed > 0
    assert waiting > 0

    # It starts paused.
    assert Treasury.upkeep_paused?()
    run!()
    assert sent!(url) == 0
    assert Treasury.upkeep(@fleet_id).lines == []

    Treasury.resume_upkeep!(1)
    base_fee!(url, 0)
    run!()

    assert sent!(url) == 3
    assert uint!(url, lab.manager, "protocolShareOwed()") == 0
    assert uint!(url, lab.manager, "pendingConversion()") == 0
    assert uint!(url, lab.regent, "balanceOf(address)", [lab.treasury]) > regent

    assert %{paused?: false, lines: lines, recent: recent} = Treasury.upkeep(@fleet_id)

    assert Enum.map(lines, &{&1.step, &1.outcome}) == [
             run_split: :done,
             send_share: :done,
             convert: :done
           ]

    # The piece asked for is the most the buyer takes, 250 USDC; it turned
    # what was in line.
    assert Enum.find(lines, &(&1.step == :convert)).amount == waiting
    assert length(recent) == 3

    for %{transaction_hash: hash} <- lines do
      assert %{"status" => "0x1", "from" => @operator} = AnvilLab.receipt!(url, hash)
    end

    # Nothing is due now: each button is skipped, with why.
    run!()
    assert sent!(url) == 3

    assert [
             %{step: :run_split, outcome: :skipped, reason: :not_due, opens_at: %DateTime{}},
             %{step: :send_share, outcome: :skipped, reason: :nothing_owed},
             %{step: :convert, outcome: :skipped, reason: :nothing_queued}
           ] = Treasury.upkeep(@fleet_id).lines

    # Paused again by the admin, the next run sends nothing and leaves the
    # last run's lines.
    Treasury.pause_upkeep!(1)
    skip!(url, @day + 1)
    run!()
    assert sent!(url) == 3
    assert Enum.all?(Treasury.upkeep(@fleet_id).lines, &(&1.outcome == :skipped))
  end

  test "an account without ETH for the fee presses nothing and says so", %{url: url, lab: lab} do
    upkeep_key!(@empty_key)
    Treasury.resume_upkeep!(1)
    base_fee!(url, 0)
    owed = uint!(url, lab.manager, "protocolShareOwed()")

    run!()

    assert uint!(url, lab.manager, "protocolShareOwed()") == owed

    assert Enum.map(Treasury.upkeep(@fleet_id).lines, &{&1.step, &1.reason}) == [
             run_split: :no_eth_for_gas,
             send_share: :no_eth_for_gas,
             convert: :no_eth_for_gas
           ]
  end

  test "a fee above 1 gwei per gas waits for a calmer run", %{url: url, lab: lab} do
    Treasury.resume_upkeep!(1)
    base_fee!(url, 1_000_000_000)
    owed = uint!(url, lab.manager, "protocolShareOwed()")

    run!()

    assert sent!(url) == 0
    assert uint!(url, lab.manager, "protocolShareOwed()") == owed

    assert Enum.map(Treasury.upkeep(@fleet_id).lines, &{&1.step, &1.reason}) == [
             run_split: :fees_high,
             send_share: :fees_high,
             convert: :fees_high
           ]
  end

  test "without the upkeep key nothing runs and the Treasury tab shows no upkeep" do
    Application.delete_env(:keyfleet, Upkeep)
    run!()
    assert Treasury.upkeep(@fleet_id) == nil
  end

  # --- the upkeep ------------------------------------------------------

  defp run!, do: assert(:ok = Upkeep.perform(%Oban.Job{}))

  defp upkeep_key!(hex),
    do: Application.put_env(:keyfleet, Upkeep, private_key: Base.decode16!(hex, case: :lower))

  # How many transactions the upkeep account has sent.
  defp sent!(url),
    do: AnvilLab.number(AnvilLab.rpc!(url, "eth_getTransactionCount", [@operator, "latest"]))

  # The base fee from the next block on, in wei.
  defp base_fee!(url, wei) do
    AnvilLab.rpc!(url, "anvil_setNextBlockBaseFeePerGas", ["0x" <> Integer.to_string(wei, 16)])
    AnvilLab.rpc!(url, "evm_mine")
  end

  # --- the lab ---------------------------------------------------------

  defp deployment(lab) do
    %{
      chain_id: @chain_id,
      chain_fleet_id: 1,
      keys_address: lab.keys,
      manager_address: lab.manager,
      rewards_address: lab.rewards,
      votes_address: lab.votes,
      treasury_address: lab.treasury,
      shards_address: lab.shards,
      regent_address: lab.regent,
      regent_staking_address: lab.staking,
      autolaunch_factory_address: lab.autolaunch,
      club_claims_address: lab.club_claims,
      usdc_address: lab.usdc,
      deployed_block: 1,
      trait_table_hash: Traits.keccak256("anvil lab trait table"),
      deck_hash: @deck,
      deck_size: 1
    }
  end

  # The next Key, bought by `wallet` with USDC minted for it.
  defp buy_key!(url, wallet) do
    %{usdc_address: usdc} = Fleets.get_fleet!(@fleet_id)
    send!(url, wallet, usdc, Call.encode("mint(address,uint256)", [wallet, 100_000_000]))
    assert pressed(url, build!(:buy, wallet), "approve") == {:ok, :confirmed}
    assert pressed(url, build!(:buy, wallet), "buy") == {:ok, :confirmed}
    scan!()
  end

  defp build!(flow, signer) do
    actor = %Human{human_account_id: Ecto.UUID.generate(), wallet_addresses: [signer]}
    {:ok, built} = WalletSteps.build_steps(@fleet_id, flow, signer, "lab", %{}, actor: actor)
    built
  end

  defp pressed(url, %{review: review}, name) do
    step = Review.find(review, name)
    hash = send!(url, review.signer, step.to, step.data, step.value)
    Outcome.of(ChainClient, review, step, hash)
  end

  defp send!(url, from, to, data, value \\ "0x0") do
    hash =
      AnvilLab.rpc!(url, "eth_sendTransaction", [
        %{from: from, to: to, data: data, value: value, gas: @gas}
      ])

    AnvilLab.receipt!(url, hash)
    hash
  end

  defp scan! do
    assert :ok = @fleet_id |> Fleets.get_fleet!() |> Scanner.step(RpcClient)
  end

  defp skip!(url, seconds) do
    AnvilLab.rpc!(url, "evm_increaseTime", [seconds])
    AnvilLab.rpc!(url, "evm_mine")
  end

  defp autolaunch!(url, treasury) do
    "0x" <> hex =
      AnvilLab.rpc!(url, "eth_call", [
        %{to: treasury, data: Call.encode("AUTOLAUNCH()", [])},
        "latest"
      ])

    "0x" <> String.slice(hex, -40, 40)
  end

  defp uint!(url, to, signature, arguments \\ []) do
    "0x" <> hex =
      AnvilLab.rpc!(url, "eth_call", [
        %{to: to, data: Call.encode(signature, arguments)},
        "latest"
      ])

    String.to_integer(hex, 16)
  end
end

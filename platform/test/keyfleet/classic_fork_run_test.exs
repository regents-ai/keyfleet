defmodule Keyfleet.ClassicForkRunTest do
  # Classic #1's whole path on the live Base contracts, run on a local anvil
  # fork of Base: the Regents Safe's two files, written by the release's own
  # Safe steps and carried out through the real Safe, then a customer's Keys 1
  # and 2 bought with the site's own steps, the site's record of them, the
  # Key owner's agent and the Key owner reading what the Keys open, a decision
  # voted and carried out, and the routine presses of the fleet's money.
  #
  # The fork keeps Base's chain id, so a signed transaction sent here could be
  # sent to Base as well. Nothing here signs: every transaction is an
  # `eth_sendTransaction` from an address anvil impersonates, never from one
  # of anvil's own accounts, and before anything is sent every node the site
  # reads is checked to be the fork. `BASE_RPC_URL`, the node the fork is made
  # from, may carry a key, so it is never printed or written.
  #
  # Each step prints `PASS <n>. <title>: <evidence>`, read from the chain, or
  # `FAIL <n>. <title>: <reason>` and stops the run. The lines are written to
  # `docs/runs/classic-fork-run.md` either way. Every number expected comes
  # from `contracts/src`, as each step says. It runs on its own:
  #
  #     BASE_RPC_URL=... mix test --only base_fork test/keyfleet/classic_fork_run_test.exs
  #
  # `KEYFLEET_OPENS_AT`, when set, is the opening time the phase-2 file names.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
  import Phoenix.LiveViewTest

  alias Keyfleet.{Actors, AnvilLab, Chain, ChainClient, Fleets, Keys, PairingHelpers, Repo}
  alias Keyfleet.WalletSteps
  alias Keyfleet.Chain.{RpcClient, Scanner}
  alias Keyfleet.Fleets.Fleet
  alias KeyfleetWeb.{KeyLinks, ProposalsPage, RefusalHelpers, SessionAuthorityHelpers}
  alias KeyfleetWeb.SignedAgentHelpers
  alias RegentChain.{Abi, Call, Outcome, Review}

  @endpoint KeyfleetWeb.Endpoint

  @moduletag :base_fork
  @moduletag timeout: 1_800_000

  @fleet_id "fleet_tech_classic"
  @chain_id 8453
  @gas "0x2dc6c0"
  # 16 million: a fleet's creation uses about 11.8 million, and Base takes at
  # most 16,777,216 in one transaction.
  @safe_gas "0xf42400"
  @eth "0xde0b6b3a7640000"
  @zero "0x0000000000000000000000000000000000000000"
  @day 86_400
  # KeyfleetManifest.BASE_REGENTS_SAFE and BASE_USDC.
  @safe "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  # Base USDC keeps each balance in slot 9's mapping (script/base-fork-lab.sh).
  @usdc_balance_slot 9
  # Classic #1's deck in deployments/base.json, and its 1,000 cards.
  @deck "0xe9b1900adb56811096d08f67852af8a64ec509ed2982e94f14f172f687b577e7"
  # Where docs/recurring-jobs.md says Classic #1's manager will be.
  @predicted_manager "0xc73d8774dfc51bc11207dc04b0ff5117c30458b6"
  # KeyfleetPresets.CLASSIC_START_USDC is Key 1's price; KeyfleetClassicPrices
  # gives Keys 2 and 3 at 1,002 and 1,005 cents.
  @key_1_price 10_000_000
  @key_2_price 10_020_000
  @key_3_price 10_050_000
  @create "createFoundingFleet(uint8,bytes32,uint256,(string,string,string))"
  @safe_tx_hash "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)"
  @exec "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)"
  @contracts Path.expand("../../../contracts", __DIR__)
  @transcript Path.expand("../../../docs/runs/classic-fork-run.md", __DIR__)
  @broadcast "broadcast/DeployKeyfleets.s.sol/8453/run-latest.json"
  @record "deployments/base-fork-run.json"
  @founding_file "deployments/safe/base.founding-fleet-1.json"
  @phase_file "deployments/safe/base.phase-2.json"
  @join "/api/v1/agent/join/status"
  @join_body ~s({ "name": "Fork run agent", "declared_harness": "local" })
  # General is the one room anyone reads; Coding is the fleet's members'.
  @members_read "/api/v1/agent/fleets/fleet_tech_classic/rooms/coding/messages/read"

  test "Classic #1, from the Safe's files to its Keys' routine presses" do
    fork_url = System.get_env("BASE_RPC_URL", "")
    if fork_url == "", do: flunk("Set BASE_RPC_URL to a Base node for the fork to start from.")

    # Shared at repeatable read, as `KeyfleetWeb.ConnCase` does, so a page or
    # a signed request served here reads the run's own record.
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    started = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    {:ok, run} = Agent.start_link(fn -> %{secret: fork_url, started: started, lines: []} end)

    url = step!(run, 1, "Fork", fn -> fork!(run, fork_url) end)
    system = step!(run, 2, "Live system read back", fn -> live_system!(url) end)
    data = step!(run, 3, "Safe file founding-fleet-1", fn -> founding_file!(url, system) end)
    classic = step!(run, 4, "Safe creates Classic #1", fn -> create!(url, system, data) end)
    phase = step!(run, 5, "Safe file phase-2", fn -> phase_file!(url, system) end)
    step!(run, 6, "Safe opens Classic #1's sales", fn -> open_sales!(url, system, phase) end)
    fleet = step!(run, 7, "Record and seed", fn -> record_and_seed!(url, classic) end)
    customer = step!(run, 8, "Customer buys Key 1", fn -> first_key!(url, system, fleet) end)
    step!(run, 9, "Customer buys Key 2", fn -> second_key!(url, system, fleet, customer) end)
    step!(run, 10, "Scanner indexes holders", fn -> indexed!(url, customer) end)
    account = step!(run, 11, "Agent reads a members' room", fn -> room!(url, customer) end)
    step!(run, 12, "A person sees the Keys on the fleet pages", fn -> pages!(account) end)
    step!(run, 13, "Proposal lifecycle", fn -> decision!(url, fleet, customer) end)
    routine = step!(run, 14, "Treasury conversion", fn -> convert!(url, fleet) end)
    step!(run, 15, "Share and daily split", fn -> share_and_split!(url, fleet, routine) end)

    note!(run, "The Safe's files: contracts/#{@founding_file} and contracts/#{@phase_file}")
    write!(run)
  end

  # --- the steps -------------------------------------------------------

  # The fork answers as anvil, on Base's chain id, at a loopback address, and
  # every node the site reads is the fork: the fleet reader's, the one it
  # checks sent steps through, and the one a wallet adds Base with, which
  # config/config.exs sets to Base itself. Key cards come from the decks and
  # trait tables the release ships.
  defp fork!(run, fork_url) do
    url = AnvilLab.start_fork!(fork_url)
    wallet_chains = Application.fetch_env!(:keyfleet, :wallet_chains)
    decks = Application.fetch_env!(:keyfleet, Keyfleet.Decks)
    traits = Application.fetch_env!(:keyfleet, Keyfleet.Traits)

    # `start_fork!/1` puts the fleet reader's settings back as they were.
    chain = Application.fetch_env!(:keyfleet, Keyfleet.Chain)
    Application.put_env(:keyfleet, Keyfleet.Chain, Keyword.put(chain, :client, RpcClient))

    Application.put_env(:keyfleet, :wallet_chains, %{
      @chain_id => %{name: "Base fork", rpc_url: url}
    })

    Application.put_env(:keyfleet, Keyfleet.Decks,
      directory: Application.app_dir(:keyfleet, "priv/decks")
    )

    Application.put_env(:keyfleet, Keyfleet.Traits,
      directory: Application.app_dir(:keyfleet, "priv/trait_tables")
    )

    on_exit(fn ->
      Application.put_env(:keyfleet, :wallet_chains, wallet_chains)
      Application.put_env(:keyfleet, Keyfleet.Decks, decks)
      Application.put_env(:keyfleet, Keyfleet.Traits, traits)
    end)

    assert URI.parse(url).host == "127.0.0.1"
    assert AnvilLab.number(AnvilLab.rpc!(url, "eth_chainId")) == @chain_id
    client = AnvilLab.rpc!(url, "web3_clientVersion")
    assert String.starts_with?(client, "anvil")

    for {_chain_id, chain} <- Application.fetch_env!(:keyfleet, :wallet_chains),
        do: assert(chain.rpc_url == url)

    assert Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:rpc_url] == url

    for {_chain_id, node} <- Application.fetch_env!(:keyfleet, :chain_nodes),
        do: assert(node == url)

    %{"number" => number, "hash" => hash, "timestamp" => timestamp} =
      AnvilLab.rpc!(url, "eth_getBlockByNumber", ["latest", false])

    fork = "block #{AnvilLab.number(number)}, hash #{hash}"
    Agent.update(run, &Map.put(&1, :fork, fork))
    seconds = AnvilLab.number(timestamp)

    {"#{fork}, timestamp #{seconds} (#{utc(seconds)}), chain id #{@chain_id}, #{client}; " <>
       "every site node is the fork", url}
  end

  # The live system as the release's record step reads it back against the
  # Base manifest: the Regents Club is there, Classic #1 is not yet, and the
  # collection is in phase 1, the Club's.
  defp live_system!(url) do
    if !File.exists?(Path.join(@contracts, @broadcast)),
      do:
        flunk(
          "contracts/#{@broadcast} is missing: put the live deployment's broadcast there " <>
            "(on the Mac, from artifacts/keyfleet-club-only-deployment/)"
        )

    record = record!(url)
    factory = String.downcase(record["factory"]["address"])
    collection = String.downcase(record["collection"]["address"])
    safe = String.downcase(record["collection"]["safe"])
    assert safe == @safe
    assert Map.has_key?(record["fleets"], "5")
    refute Map.has_key?(record["fleets"], "1")
    assert uint!(url, collection, "phase()") == 1

    {"factory #{factory}, collection #{collection}, Safe #{safe}, phase 1",
     %{factory: factory, collection: collection, safe: safe, record: record}}
  end

  # The Safe's file creating Classic #1, as the release's Safe step writes it
  # on Base: one call from the Regents Safe to the factory, carrying exactly
  # Classic #1's type (KeyfleetPresets.Preset.FleetTechClassic is 2), deck and
  # profile from deployments/base.json, and no other founding fleet's file.
  defp founding_file!(url, %{factory: factory}) do
    file = Path.join(@contracts, @founding_file)
    File.rm(file)
    others = other_founding_files()
    safe_step!(url, [{"KEYFLEET_STEP", "founding-fleets"}])
    assert other_founding_files() == others

    assert %{
             "chainId" => "8453",
             "meta" => %{"createdFromSafeAddress" => safe},
             "transactions" => [%{"to" => to, "value" => "0", "data" => data}]
           } = file |> File.read!() |> Jason.decode!()

    assert String.downcase(safe) == @safe
    assert String.downcase(to) == factory
    data = String.downcase(data)
    assert data == calldata!(@create, ["2", @deck, "1000", ~s{("Classic #1","","")}])

    {"contracts/#{@founding_file}, to #{to}, data keccak #{keccak(hex!(data))}", data}
  end

  # The real Safe creates Classic #1 from the file's call. KeyfleetPresets:
  # every founding fleet starts at Q_USDC, and a Classic fleet has
  # CLASSIC_SUPPLY Keys. Sales stay closed until phase 2.
  defp create!(url, %{factory: factory, collection: collection, safe: safe}, data) do
    carried = safe_exec!(url, safe, factory, data)
    manager = address!(url, collection, "managerOf(uint256)", [1])
    assert AnvilLab.rpc!(url, "eth_getCode", [manager, "latest"]) != "0x"
    assert uint!(url, collection, "fleetExists(uint256)", [1]) == 1
    deck = words!(url, collection, "deckOf(uint256)", [1], [:bytes32, {:uint, 256}])
    assert deck == [@deck, 1000]
    assert uint!(url, manager, "START_PRICE()") == @key_1_price
    assert uint!(url, manager, "maxSupply()") == 1024
    assert uint!(url, manager, "nextPrice()") == @key_1_price
    assert uint!(url, collection, "salesOpen(uint256)", [1]) == 0

    predicted =
      if manager == @predicted_manager,
        do: "the address docs/recurring-jobs.md predicts",
        else: "not docs/recurring-jobs.md's #{@predicted_manager}"

    {"#{safe_evidence(carried)}; manager #{manager}, #{predicted}",
     Map.put(carried, :manager, manager)}
  end

  # The Safe's file moving the collection to phase 2, which opens Classic
  # #1's sales at Sean's opening time when it is given, or else ten minutes
  # after the fork's clock.
  defp phase_file!(url, %{collection: collection}) do
    file = Path.join(@contracts, @phase_file)
    File.rm(file)

    {opens_at, whose} =
      case System.get_env("KEYFLEET_OPENS_AT", "") do
        "" -> {timestamp!(url) + 600, "the rehearsal's own time"}
        given -> {String.to_integer(given), "Sean's opening time (KEYFLEET_OPENS_AT)"}
      end

    safe_step!(url, [{"KEYFLEET_STEP", "advance-phase"}, {"KEYFLEET_OPENS_AT", "#{opens_at}"}])

    assert %{"transactions" => [%{"to" => to, "value" => "0", "data" => data}]} =
             file |> File.read!() |> Jason.decode!()

    assert String.downcase(to) == collection
    data = String.downcase(data)
    assert data == String.downcase(Call.encode("advancePhase(uint64)", [opens_at]))

    {"contracts/#{@phase_file}, to #{to}, opens at #{opens_at} (#{utc(opens_at)}), #{whose}",
     %{opens_at: opens_at, data: data}}
  end

  # The real Safe moves the collection to phase 2; Classic #1's sales open at
  # the file's time and not before.
  defp open_sales!(url, %{collection: collection, safe: safe}, phase) do
    carried = safe_exec!(url, safe, collection, phase.data)
    assert uint!(url, collection, "phase()") == 2
    assert uint!(url, collection, "salesOpen(uint256)", [1]) == 0
    skip!(url, phase.opens_at - timestamp!(url))
    assert uint!(url, collection, "salesOpen(uint256)", [1]) == 1

    opened = utc(timestamp!(url))
    {"#{safe_evidence(carried)}; phase 2, closed until the fork's clock reached #{opened}", nil}
  end

  # The record step's record now holds Classic #1 as created, and the site is
  # seeded from it the way a release seeds Base.
  defp record_and_seed!(url, classic) do
    record = record!(url)

    assert %{
             "type" => "classic",
             "typeNumber" => 1,
             "deckSize" => 1000,
             "startPrice" => @key_1_price,
             "manager" => manager
           } = record["fleets"]["1"]

    assert String.downcase(manager) == classic.manager
    :ok = Keyfleet.Release.seed_deployment!(Path.join(@contracts, @record))
    fleet = Fleets.get_fleet!(@fleet_id)
    assert fleet.manager_address == classic.manager

    # The record's deploymentBlock is the system's, weeks before the fork,
    # and the chain reader reads at most 10,000 blocks a pass, each through
    # the fork from Base. Nothing of Classic #1 comes before the block that
    # created it, so its reading starts there, as a cursor opened before the
    # reader's first pass.
    Chain.open_cursor!(%{fleet_id: @fleet_id, next_block: classic.block},
      actor: %Actors.System{}
    )

    {"contracts/#{@record}, fleet 1 bound to manager #{fleet.manager_address}, " <>
       "read from block #{classic.block}", fleet}
  end

  # A customer of their own, with 1 ETH and exactly 100 USDC, buys Key 1.
  defp first_key!(url, system, fleet) do
    customer = fresh!(url, "Keyfleet Classic fork run customer")
    AnvilLab.rpc!(url, "anvil_setStorageAt", [@usdc, usdc_slot(customer), word(100_000_000)])
    assert uint!(url, @usdc, "balanceOf(address)", [customer]) == 100_000_000

    # KeyfleetPresets.PROTOCOL_BPS: 10% for REGENT staking; the other 90% is
    # Classic's treasury's, booked to become REGENT (splitPurchase).
    bought = bought!(url, system, fleet, customer, 1, @key_1_price, 1_000_000, 9_000_000)

    %{"vrf" => %{"coordinator" => coordinator, "subscriptionId" => subscription}} = system.record
    coordinator = String.downcase(coordinator)
    subscription = String.to_integer(subscription)
    types = [{:uint, 256}, {:uint, 256}, {:uint, 256}, :address, {:array, :address}]

    [_balance, _native, _requests, _owner, consumers] =
      words!(url, coordinator, "getSubscription(uint256)", [subscription], types)

    listed = if system.collection in consumers, do: "lists", else: "does not list"

    {"customer #{customer}, 100 USDC; #{bought}; the VRF subscription #{listed} " <>
       "the collection (expected not: no VRF)", customer}
  end

  # Key 2 at its own price, which moves the next one on.
  defp second_key!(url, system, fleet, customer) do
    bought = bought!(url, system, fleet, customer, 2, @key_2_price, 2_002_000, 18_018_000)
    assert uint!(url, fleet.manager_address, "nextPrice()") == @key_3_price
    {"#{bought}; next price #{@key_3_price}", nil}
  end

  # The site's chain reader records both Keys as the customer's.
  defp indexed!(url, customer) do
    scan!(url)
    keys = for key <- [1, 2], do: Keys.current_key!(@fleet_id, key)
    assert Enum.map(keys, & &1.owner_wallet) == [customer, customer]
    [one, two] = Enum.map(keys, & &1.block_number)

    {"Keys 1 and 2 recorded as #{customer}'s at blocks #{one} and #{two}; read up to block " <>
       "#{Chain.get_cursor!(@fleet_id).next_block - 1}", nil}
  end

  # An agent paired with the customer reads one of Classic #1's members'
  # rooms; an agent paired with a person whose wallet holds no Key is refused
  # it. The customer's account is the one the pairing made.
  defp room!(url, customer) do
    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    endpoint = &KeyfleetWeb.Endpoint.call(&1, KeyfleetWeb.Endpoint.init(&2))
    app = SignedAgentHelpers.serve!(:product, endpoint)
    {:ok, holder} = Siwa.LocalSigner.new()
    {:ok, stranger} = Siwa.LocalSigner.new()

    paired =
      PairingHelpers.pair!(
        %Actors.Agent{
          wallet_address: holder.address,
          chain_id: @chain_id,
          verification_method: :eoa_recovery,
          audience: "keyfleet"
        },
        [customer]
      )

    PairingHelpers.pair_wallet!(stranger.address)
    # Who holds a Key is told only while the reading is fresh.
    scan!(url)

    for agent <- [holder, stranger],
        do: assert(signed!(app, agent, secret, @join, @join_body).status == 200)

    read = signed!(app, holder, secret, @members_read, "{}")
    assert read.status == 200
    assert is_list(read.body["messages"])

    refused = signed!(app, stranger, secret, @members_read, "{}")
    assert {refused.status, refused.body} == {403, RefusalHelpers.refused("not_a_member")}

    {"room coding: the Key owner's agent #{read.status}, an agent whose person holds no Key " <>
       "#{refused.status} not_a_member", paired.human_account_id}
  end

  # Signed in as the customer: the fleet page shows their two cards, Key 1's
  # page says it is theirs, and Account lists both.
  defp pages!(account_id) do
    conn =
      SessionAuthorityHelpers.init_test_session(SessionAuthorityHelpers.build_conn(), %{
        human_account_id: account_id
      })

    fleet_path = Fleets.path(@fleet_id)
    key_path = KeyLinks.page_path(@fleet_id, 1)

    {:ok, fleet, _html} = live(conn, fleet_path)
    render_async(fleet)
    assert has_element?(fleet, "#fleet-entry-card-1", "Key 1")
    assert has_element?(fleet, "#fleet-entry-card-2", "Key 2")

    {:ok, key, _html} = live(conn, key_path)
    render_async(key)
    assert has_element?(key, "#key-owner-you", "You")

    {:ok, account, _html} = live(conn, "/account")

    assert account
           |> render_async()
           |> LazyHTML.from_document()
           |> LazyHTML.query("#account-keys li a")
           |> LazyHTML.attribute("href") == ["/classic/1?key=1", "/classic/1?key=2"]

    {"#{fleet_path}, #{key_path} and /account show Keys 1 and 2 as the customer's", nil}
  end

  # A decision proposed with Key 1, voted yes with both Keys, refused while
  # it is open, carried out once by someone else, and shown so once read
  # again from the record, as wallet_steps_anvil_test's decision is.
  defp decision!(url, fleet, customer) do
    # KeyfleetVotes.KEY_MATURITY: a Key takes part two days after it is sold.
    skip!(url, 2 * @day + 1)

    proposed =
      build!(:propose, customer,
        inputs: %{"key" => "1", "text" => "Classic fork run decision", "kind" => "decision"}
      )

    assert proposed.problem == nil
    assert proposed.figures.blocked == %{}
    proposal = landed_step!(url, customer, proposed, "propose")
    number = uint!(url, fleet.votes_address, "proposalCount()")
    scan!(url)

    ballot = build!(:ballot, customer, proposal: number)
    assert ballot.figures.keys == [1, 2]
    yes = landed_step!(url, customer, ballot, "yes")

    carry_out = build!(:carry_out, customer, proposal: number)
    assert carry_out.figures.blocked == %{"carry_out" => :open}
    early = press!(url, customer, carry_out.review, "carry_out")
    assert outcome(carry_out.review, "carry_out", early) == {:ok, :reverted}

    # KeyfleetVotes.VOTING_PERIOD: a decision moves no money, so it is
    # carried out as its day of voting ends.
    skip!(url, @day + 1)
    carrier = fresh!(url, "Keyfleet Classic fork run carrier")
    carry_out = build!(:carry_out, carrier, proposal: number)
    assert carry_out.figures.blocked == %{}
    carried = landed_step!(url, carrier, carry_out, "carry_out")
    again = press!(url, carrier, carry_out.review, "carry_out")
    assert outcome(carry_out.review, "carry_out", again) == {:ok, :reverted}

    scan!(url)
    conn = SessionAuthorityHelpers.build_conn()
    {:ok, list, _html} = live(conn, ProposalsPage.list_path(@fleet_id))
    tally = "2 yes, 0 no, 0 abstain, of 2 Keys counted"
    assert cards(list) == [{"#{number}", "Carried out", tally}]

    {:ok, detail, _html} = live(conn, ProposalsPage.detail_path(@fleet_id, number))
    assert has_element?(detail, "#proposal-status", "Carried out")
    assert has_element?(detail, "#proposal-yes", "2 Keys")
    assert has_element?(detail, "#proposal-no", "0 Keys")
    assert has_element?(detail, "#proposal-executor")

    {"proposal #{number}: proposed #{proposal}, yes with Keys 1 and 2 #{yes}, carry-out while " <>
       "open #{early} refused, carried out by #{carrier} #{carried}, again #{again} refused; " <>
       tally, nil}
  end

  # The booked USDC turned into REGENT for the treasury through Base's own
  # USDC/WETH and WETH/REGENT pools. KeyfleetRegentBuyer.PIECE_USDC: a piece
  # is at most 250 USDC, so the 18.018 USDC booked goes in one.
  defp convert!(url, fleet) do
    routine = fresh!(url, "Keyfleet Classic fork run routine presses")
    regent = fleet.regent_address
    treasury = fleet.treasury_address
    held = uint!(url, regent, "balanceOf(address)", [treasury])
    pending = uint!(url, fleet.manager_address, "pendingConversion()")

    built = build!(:convert, routine, inputs: %{"amount" => "250"})
    assert built.figures.waiting == pending
    assert built.figures.blocked == %{}
    converted = landed_step!(url, routine, built, "convert")

    now_held = uint!(url, regent, "balanceOf(address)", [treasury])
    assert now_held > held
    assert uint!(url, fleet.manager_address, "pendingConversion()") == 0

    {"convert #{converted} from #{routine}: treasury REGENT #{held} -> #{now_held}, " <>
       "pending conversion #{pending} -> 0", routine}
  end

  # The other two routine presses: the protocol share owed to REGENT staking,
  # 10% of Keys 1 and 2, and the treasury's daily split, once it is due.
  defp share_and_split!(url, fleet, routine) do
    manager = fleet.manager_address
    staking = fleet.regent_staking_address
    staked = uint!(url, @usdc, "balanceOf(address)", [staking])

    share = build!(:send_share, routine)
    assert share.figures.owed == 2_002_000
    assert share.figures.blocked == %{}
    sent = landed_step!(url, routine, share, "send_share")
    assert uint!(url, manager, "protocolShareOwed()") == 0
    now_staked = uint!(url, @usdc, "balanceOf(address)", [staking])

    shared =
      "send_share #{sent}: owed 2002000 -> 0, staking contract's USDC #{staked} -> #{now_staked}"

    {"#{shared}; #{split!(url, fleet, routine)}", nil}
  end

  defp split!(url, fleet, routine) do
    split = build!(:run_split, routine)

    case split.figures.blocked do
      %{"run_split" => {:opens_at, opens_at}} ->
        "daily split not due until #{opens_at}"

      blocked ->
        assert blocked == %{}
        regent = &uint!(url, fleet.regent_address, "balanceOf(address)", [&1])
        {treasury, ledger} = {regent.(fleet.treasury_address), regent.(fleet.rewards_address)}
        ran = landed_step!(url, routine, split, "run_split")

        "daily split #{ran} for #{split.figures.keys} Keys at #{split.figures.rate_bps} bps: " <>
          "treasury REGENT #{treasury} -> #{regent.(fleet.treasury_address)}, reward ledger " <>
          "REGENT #{ledger} -> #{regent.(fleet.rewards_address)}"
    end
  end

  # --- the run's lines ---------------------------------------------------

  # Runs step `n`, which answers `{evidence, result}`, prints and keeps its
  # line and answers its result. A step that fails prints and keeps why,
  # writes the transcript and stops the run.
  defp step!(run, n, title, step) do
    {evidence, result} = step.()
    note!(run, "PASS #{n}. #{title}: #{evidence}")
    result
  rescue
    error -> stop!(run, "FAIL #{n}. #{title}: #{Exception.message(error)}")
  catch
    kind, reason -> stop!(run, "FAIL #{n}. #{title}: #{inspect({kind, reason})}")
  end

  defp stop!(run, line) do
    line = note!(run, line)
    write!(run)
    flunk(line)
  end

  # Prints and keeps `line` on one line, with the fork's source taken out of
  # it wherever a node's error repeated it.
  defp note!(run, line) do
    line = run |> Agent.get(&hidden(&1.secret, line)) |> String.split() |> Enum.join(" ")
    IO.puts(line)
    Agent.update(run, &%{&1 | lines: [line | &1.lines]})
    line
  end

  # The node's address and each part of it that could be a key.
  defp hidden(secret, text) do
    %URI{path: path, query: query, userinfo: userinfo} = URI.parse(secret)

    parts = for part <- [path, query, userinfo], is_binary(part), byte_size(part) >= 8, do: part
    Enum.reduce([secret | parts], text, &String.replace(&2, &1, "[BASE_RPC_URL]"))
  end

  defp write!(run) do
    %{started: started, lines: lines} = run_state = Agent.get(run, & &1)
    File.mkdir_p!(Path.dirname(@transcript))

    File.write!(@transcript, """
    # Classic #1 fork run

    Classic #1's path on the live Base contracts, run on a local anvil fork of
    Base by `platform/test/keyfleet/classic_fork_run_test.exs`.

    - Run at: #{started}
    - Fork: #{Map.get(run_state, :fork, "not started")}

    ## Steps

    #{lines |> Enum.reverse() |> Enum.map_join("\n", &("- " <> &1))}
    """)
  end

  # --- the Safe ----------------------------------------------------------

  # The release's Safe step on the fork: on chain 8453 it runs the Safe's
  # calls from the Safe's address and writes each as a file under
  # `deployments/safe/`, sending nothing.
  defp safe_step!(url, env),
    do:
      forge!(url, ["script/KeyfleetSafeSteps.s.sol:KeyfleetSafeSteps"], [
        {"KEYFLEET_MANIFEST", "base"} | env
      ])

  # The fork run's record of the live system, from the release's record step
  # (`script/ClassicForkRun.s.sol`).
  defp record!(url) do
    path = Path.join(@contracts, @record)
    File.rm(path)
    forge!(url, ["script/ClassicForkRun.s.sol:ClassicForkRun", "--sig", "record()"], [])
    path |> File.read!() |> Jason.decode!()
  end

  # Forge reads only the fork, so it is not handed BASE_RPC_URL at all.
  defp forge!(url, args, env) do
    {output, status} =
      System.cmd("forge", ["script" | args] ++ ["--rpc-url", url],
        cd: @contracts,
        env: [{"BASE_RPC_URL", nil} | env],
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("forge #{hd(args)} failed: #{String.slice(output, -2_000, 2_000)}")
    output
  end

  defp other_founding_files do
    @contracts
    |> Path.join("deployments/safe/base.founding-fleet-*.json")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == Path.basename(@founding_file)))
    |> Map.new(&{&1, File.stat!(&1).mtime})
  end

  # The real Safe carries out `data` to `to` as its signers would: the first
  # `threshold` owners each approve the Safe transaction's hash on chain, and
  # one of them executes it with an approved-hash signature for each, ordered
  # by address (the Safe's `v = 1`: `r` the owner, `s` zero).
  defp safe_exec!(url, safe, to, data) do
    [version] = words!(url, safe, "VERSION()", [], [:bytes])
    threshold = uint!(url, safe, "getThreshold()")
    owners = list!(url, safe, "getOwners()")
    nonce = uint!(url, safe, "nonce()")
    safe_tx = view!(url, safe, @safe_tx_hash, [to, 0, data, 0, 0, 0, 0, @zero, @zero, nonce])
    approvers = Enum.take(owners, threshold)

    for owner <- approvers do
      sendable!(url, owner)
      landed!(url, send!(url, owner, safe, Call.encode("approveHash(bytes32)", [safe_tx])))
    end

    signatures =
      for "0x" <> owner <- Enum.sort(approvers),
          into: "0x",
          do: String.pad_leading(owner, 64, "0") <> String.duplicate("0", 64) <> "01"

    exec = Call.encode(@exec, [to, 0, data, 0, 0, 0, 0, @zero, @zero, signatures])
    hash = send!(url, hd(approvers), safe, exec, "0x0", @safe_gas)
    receipt = landed!(url, hash)
    success = keccak("ExecutionSuccess(bytes32,uint256)")

    assert Enum.any?(
             receipt["logs"],
             &(String.downcase(&1["address"]) == safe and Enum.at(&1["topics"], 0) == success)
           )

    %{
      version: version,
      threshold: threshold,
      owners: length(owners),
      nonce: nonce,
      tx: hash,
      block: AnvilLab.number(receipt["blockNumber"]),
      gas: AnvilLab.number(receipt["gasUsed"])
    }
  end

  defp safe_evidence(carried),
    do:
      "Safe #{carried.version}, threshold #{carried.threshold} of #{carried.owners} owners, " <>
        "nonce #{carried.nonce}, tx #{carried.tx} in block #{carried.block}, gas used #{carried.gas}"

  # The calldata Foundry's own encoder makes, to check the Safe step's by.
  defp calldata!(signature, arguments) do
    {output, status} =
      System.cmd("cast", ["calldata", signature | arguments], stderr_to_stdout: true)

    if status != 0, do: flunk("cast calldata failed: #{output}")
    output |> String.trim() |> String.downcase()
  end

  # --- building and sending --------------------------------------------

  # Key `key` bought by `customer` with the site's own steps, an approval
  # first: it is theirs, its price left their USDC, the manager owes REGENT
  # staking `owed` and holds `pending` to turn into REGENT, and the Key holds
  # its deck's card by number, so the purchase asked for no draw.
  defp bought!(url, system, fleet, customer, key, price, owed, pending) do
    held = uint!(url, @usdc, "balanceOf(address)", [customer])

    built = build!(:buy, customer)
    assert %{token_id: ^key, price: ^price, approve?: true} = built.figures
    assert names(built) == ["approve", "buy"]
    approved = landed_step!(url, customer, built, "approve")

    built = build!(:buy, customer)
    assert names(built) == ["buy"]
    bought = landed_step!(url, customer, built, "buy")

    token_id = id(key)
    assert address!(url, system.collection, "ownerOf(uint256)", [token_id]) == customer
    assert uint!(url, @usdc, "balanceOf(address)", [customer]) == held - price
    assert uint!(url, fleet.manager_address, "protocolShareOwed()") == owed
    assert uint!(url, fleet.manager_address, "pendingConversion()") == pending
    assert uint!(url, system.collection, "dealtByNumber(uint256)", [token_id]) == 1

    draws = [keccak("RevealRequested(uint256,uint256)"), keccak("RevealRequestFailed(uint256)")]
    %{"logs" => logs, "blockNumber" => block} = AnvilLab.receipt!(url, bought)

    assert for(
             log <- logs,
             String.downcase(log["address"]) == system.collection,
             Enum.at(log["topics"], 0) in draws,
             do: log
           ) == []

    "Key #{key} (token #{token_id}): approve #{approved}, buy #{bought} in block " <>
      "#{AnvilLab.number(block)} at #{price}; protocol share owed #{owed}, pending conversion " <>
      "#{pending}; dealt by number, no draw asked"
  end

  defp actor(wallet),
    do: %Actors.Human{human_account_id: Ecto.UUID.generate(), wallet_addresses: [wallet]}

  defp build!(flow, signer, arguments \\ []) do
    {:ok, built} =
      WalletSteps.build_steps(@fleet_id, flow, signer, "fork", Map.new(arguments),
        actor: actor(signer)
      )

    built
  end

  defp names(%{review: review}), do: Enum.map(review.steps, & &1.step)

  # A press of `name` from `from` that the chain is asked first, so a step it
  # refuses fails with its own reason, then sent and read back as the page
  # reads it: done.
  defp landed_step!(url, from, %{review: review}, name) do
    %{to: to, data: data, value: value} = Review.find(review, name)
    AnvilLab.rpc!(url, "eth_call", [%{from: from, to: to, data: data, value: value}, "latest"])
    hash = press!(url, from, review, name)
    assert outcome(review, name, hash) == {:ok, :confirmed}
    hash
  end

  defp press!(url, from, review, name) do
    %{to: to, data: data, value: value} = Review.find(review, name)
    send!(url, from, to, data, value)
  end

  defp send!(url, from, to, data, value \\ "0x0", gas \\ @gas) do
    hash =
      AnvilLab.rpc!(url, "eth_sendTransaction", [
        %{from: from, to: to, data: data, value: value, gas: gas}
      ])

    AnvilLab.receipt!(url, hash)
    hash
  end

  defp landed!(url, hash) do
    receipt = AnvilLab.receipt!(url, hash)
    assert receipt["status"] == "0x1"
    receipt
  end

  defp outcome(review, name, hash),
    do: Outcome.of(ChainClient, review, Review.find(review, name), hash)

  # An address of its own for `label`, the last 20 bytes of its keccak256,
  # with no code on the fork (Base's anvil accounts carry delegated code),
  # made sendable.
  defp fresh!(url, label) do
    "0x" <> hash = keccak(label)
    address = "0x" <> String.slice(hash, -40, 40)
    assert AnvilLab.rpc!(url, "eth_getCode", [address, "latest"]) == "0x"
    sendable!(url, address)
  end

  # `address` sends through anvil's impersonation, with 1 ETH for its fees.
  defp sendable!(url, address) do
    AnvilLab.rpc!(url, "anvil_impersonateAccount", [address])
    AnvilLab.rpc!(url, "anvil_setBalance", [address, @eth])
    address
  end

  # Moves the fork's clock on and mines a block at the new time.
  defp skip!(url, seconds) do
    AnvilLab.rpc!(url, "evm_increaseTime", [seconds])
    AnvilLab.rpc!(url, "evm_mine")
  end

  # The site's chain reader, recording what the fork did since its last pass,
  # pass after pass until it has read up to the fork's head.
  defp scan!(url) do
    assert :ok = @fleet_id |> Fleets.get_fleet!() |> Scanner.step(RpcClient)
    head = AnvilLab.number(AnvilLab.rpc!(url, "eth_blockNumber"))
    if Chain.get_cursor!(@fleet_id).next_block <= head, do: scan!(url), else: :ok
  end

  # One signed agent request, sent to the site served here.
  defp signed!(app, signer, secret, path, body) do
    request = SignedAgentHelpers.sign(signer, secret, "POST", path, body)

    Req.post!(app <> request.path,
      headers: request.headers,
      body: request.body,
      retry: false,
      redirect: false
    )
  end

  # Each proposal on a list page: its number, its status and its tally.
  defp cards(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-proposal]")
    |> Enum.map(fn card ->
      {card |> LazyHTML.attribute("data-proposal") |> hd(),
       card |> LazyHTML.query(".proposals-badge") |> words(),
       card |> LazyHTML.query(".proposals-detail") |> words()}
    end)
  end

  defp words(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  # --- reading the fork --------------------------------------------------

  # Classic #1's Key `key` as the chain numbers it: the first fleet's.
  defp id(key), do: Fleet.onchain_token_id(%{chain_fleet_id: 1}, key)

  # Where Base USDC keeps `account`'s balance.
  defp usdc_slot(account) do
    {:ok, address} = RegentChain.Address.decode(account)
    keccak(<<0::96>> <> address <> <<@usdc_balance_slot::256>>)
  end

  defp word(value), do: "0x" <> Base.encode16(<<value::256>>, case: :lower)

  defp keccak(bytes), do: "0x" <> Base.encode16(ExKeccak.hash_256(bytes), case: :lower)

  defp hex!("0x" <> hex), do: Base.decode16!(hex, case: :mixed)

  defp utc(seconds), do: seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp timestamp!(url) do
    %{"timestamp" => timestamp} = AnvilLab.rpc!(url, "eth_getBlockByNumber", ["latest", false])
    AnvilLab.number(timestamp)
  end

  defp uint!(url, to, signature, arguments \\ []) do
    "0x" <> hex = view!(url, to, signature, arguments)
    String.to_integer(hex, 16)
  end

  defp address!(url, to, signature, arguments) do
    "0x" <> hex = view!(url, to, signature, arguments)
    "0x" <> String.slice(hex, -40, 40)
  end

  defp list!(url, to, signature) do
    [addresses] = words!(url, to, signature, [], [{:array, :address}])
    addresses
  end

  defp words!(url, to, signature, arguments, types) do
    {:ok, words} = Abi.decode(hex!(view!(url, to, signature, arguments)), types)
    words
  end

  defp view!(url, to, signature, arguments),
    do:
      AnvilLab.rpc!(url, "eth_call", [
        %{to: to, data: Call.encode(signature, arguments)},
        "latest"
      ])
end

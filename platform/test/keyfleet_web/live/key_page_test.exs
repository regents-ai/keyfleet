defmodule KeyfleetWeb.Live.KeyPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ChainViews
  alias Keyfleet.Fleets
  alias Keyfleet.Keys

  @fleet "fleet_tech_classic"
  @path "/app/keys/fleet_tech_classic/1"
  @owner "0x" <> String.duplicate("a", 40)
  @stranger "0x" <> String.duplicate("b", 40)
  @agent "0x" <> String.duplicate("c", 40)
  @bare "0x" <> String.duplicate("d", 40)

  setup do
    Fleets.bootstrap_catalog!()
    fleet = ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    # The wallet buttons are built from the chain's latest block.
    chain!(fleet, present_until: 0, agent_voting: false)

    epoch!(1, @owner)

    agent = %Actors.Agent{
      wallet_address: @agent,
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "claude-code"}, actor: agent)
    %{fleet: fleet}
  end

  test "the owner reads the key's shards and is offered issuing, renewing and ending them", %{
    conn: conn
  } do
    ChainHelpers.issue_shard!(@fleet, 1, @agent, 45)
    ChainHelpers.issue_shard!(@fleet, 1, @bare)

    {:ok, view, html} = conn |> signed_in_as(@owner) |> live(@path)
    render_async(view)

    assert html =~ "Key 1"
    assert has_element?(view, "#key-owner-you", "You")
    refute has_element?(view, "#key-no-shards")
    refute has_element?(view, "#key-edits-restricted")

    assert has_element?(view, "#key-shard-#{@agent}", "Orbit runner")
    assert has_element?(view, "#key-shard-#{@agent}", "claude-code")
    assert has_element?(view, "#key-shard-#{@agent}", "Until ")
    assert has_element?(view, "#key-shard-#{@bare}", "No agent yet")

    # The owner compares the wallet's whole address before trusting it.
    assert view |> element("#key-shard-address-#{@agent}") |> render() =~
             ~s(data-copy-text="#{@agent}")

    for wallet <- [@agent, @bare] do
      assert has_element?(view, "#key-shard-renew-#{wallet}")
      assert has_element?(view, "#key-shard-end-#{wallet}")
    end

    assert has_element?(view, "#key-issue-shard #key-shard-wallet")
    assert has_element?(view, "#key-issue-shard-button", "Issue shard")
    assert has_element?(view, "#key-issue-tip", "Check the agent’s wallet address.")
  end

  test "anyone else reads the key's shards without the owner's buttons", %{conn: conn} do
    ChainHelpers.issue_shard!(@fleet, 1, @agent)

    for conn <- [signed_in_as(conn, @stranger), conn] do
      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      refute has_element?(view, "#key-owner-you")
      assert has_element?(view, "#key-shard-#{@agent}", "Orbit runner")
      refute has_element?(view, "#key-shard-end-#{@agent}")
      refute has_element?(view, "#key-shard-renew-#{@agent}")
      refute has_element?(view, "#key-issue-shard")
      refute has_element?(view, "#key-agent-voting")
    end
  end

  test "a shard that ended, ran out or was issued under an earlier owner is not shown", %{
    conn: conn
  } do
    ChainHelpers.issue_shard!(@fleet, 1, @agent)
    ChainHelpers.end_shard!(@fleet, 1, @agent, @owner)
    ChainHelpers.issue_shard!(@fleet, 1, @bare, -1)

    {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
    render_async(view)
    assert has_element?(view, "#key-no-shards", "None")

    ChainHelpers.issue_shard!(@fleet, 1, @agent)
    epoch!(2, @stranger)

    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)
    render_async(view)
    assert has_element?(view, "#key-owner-you")
    assert has_element?(view, "#key-no-shards")
  end

  test "a key whose edits a vote restricted says so", %{conn: conn} do
    Keys.record_edits_restriction!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        restricted: true,
        block_number: 20,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: "0x" <> String.duplicate("e", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#key-edits-restricted", "Edits restricted")

    assert has_element?(
             view,
             "#key-edits-tip",
             "A vote of the fleet stopped this key and its shards changing the workspace."
           )
  end

  test "a key nobody has bought shows nothing but says so", %{conn: conn} do
    {:ok, view, html} = conn |> signed_in_as(@owner) |> live("/app/keys/fibonacci_cascade/9")

    assert has_element?(view, "#key-not-sold", "Not sold yet")
    refute html =~ "Orbit runner"
    refute has_element?(view, "#key-present")
  end

  describe "being present" do
    test "anyone sees whether the key is present; its holder may mark it", %{
      conn: conn,
      fleet: fleet
    } do
      until = DateTime.to_unix(ChainViews.head().timestamp) + 3_600
      chain!(fleet, present_until: until, agent_voting: false)

      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
      render_async(view)

      assert has_element?(
               view,
               "#key-present-keys [data-key='1']",
               "Present until 7 Oct, 13:00 UTC"
             )

      assert has_element?(view, "#key-present-mark:not([disabled])", "Mark present")
      assert has_element?(view, "#key-present-sweep:not([disabled])", "Tidy up")
      refute has_element?(view, "#key-present-maintenance")

      {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)
      render_async(view)

      assert has_element?(view, "#key-present-keys [data-key='1']", "Present until")
      assert has_element?(view, "#key-present-mark[disabled]")
      assert has_element?(view, "#key-present-action", "Not your key")
      assert has_element?(view, "#key-present-sweep:not([disabled])")
    end

    test "a lapsed presence says it isn't present", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
      render_async(view)
      assert has_element?(view, "#key-present-keys [data-key='1']", "Not present")
    end
  end

  test "the owner turns agent voting on or off and sees where it is on", %{
    conn: conn,
    fleet: fleet
  } do
    chain!(fleet, present_until: 0, agent_voting: true)

    {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
    render_async(view)

    assert has_element?(view, "#key-agent-voting-state", "On for key 1")
    assert has_element?(view, "#key-agent-voting-on:not([disabled])", "Turn on")
    assert has_element?(view, "#key-agent-voting-off:not([disabled])", "Turn off")
    assert has_element?(view, "#key-agent-voting-keys[data-onchain-input=keys][value='1']")
  end

  # Reading never waits on ownership being fresh; only acting on a key does.
  test "a fleet's page lists its keys even while ownership is being refreshed", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)
    reader = "0x" <> String.duplicate("d", 40)
    fleet = Fleets.get_fleet!(@fleet)

    # The page's buttons read the reader's USDC allowance and whether the
    # fleet has launched a token.
    ChainViews.put!([
      {fleet.usdc_address, "allowance(address,address)", [reader, fleet.contract_address],
       {"uint256", [0]}},
      {fleet.treasury_address, "launchId()", [], {"uint256", [0]}}
    ])

    {:ok, view, _html} = conn |> signed_in_as(reader) |> live("/app/fleets/#{@fleet}")

    assert view |> element("#fleet-key-1") |> render() =~ "Held by 0xaaaa..aaaa"
    # The page's buy steps are built after it opens; let them finish.
    render_async(view)
  end

  # The views the key's wallet buttons read for key 1: its holder, whether
  # each shard wallet is active, when the key's presence runs out, the
  # presence queue, and whether its agent voting is on.
  defp chain!(fleet, present_until: until, agent_voting: voting) do
    shard_checks =
      for check <- ["isActive", "mayGovern"], wallet <- [@agent, @bare, @stranger] do
        {fleet.shards_address, "#{check}(uint256,address)", [1, wallet], {"bool", [true]}}
      end

    ChainViews.put!([
      {fleet.contract_address, "ownerOf(uint256)", [1], {"address", [@owner]}},
      {fleet.votes_address, "presenceEntry(uint256)", [1],
       {"uint32,uint32,uint64", [0, 0, until]}},
      {fleet.votes_address, "presenceQueue()", [], {"uint32,uint32,uint32", [0, 0, 0]}},
      {fleet.shards_address, "agentVoting(uint256)", [1], {"bool", [voting]}}
      | List.replace_at(shard_checks, 2, isactive_false(fleet))
    ])
  end

  defp isactive_false(fleet),
    do: {fleet.shards_address, "isActive(uint256,address)", [1, @stranger], {"bool", [false]}}

  defp epoch!(epoch, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: epoch,
        owner_wallet: owner,
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate(Integer.to_string(epoch), 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:key-page:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end
end

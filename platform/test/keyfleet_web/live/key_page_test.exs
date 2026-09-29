defmodule KeyfleetWeb.Live.KeyPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Chain.StubClient
  alias Keyfleet.ChainHelpers
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
    ChainHelpers.deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    # The owner's wallet buttons are built from the chain's latest block.
    StubClient.put_chain(
      %{number: 1_000, hash: "0x" <> String.duplicate("c", 64), timestamp: DateTime.utc_now()},
      []
    )

    epoch!(1, @owner)

    agent = %Actors.Agent{wallet_address: @agent, chain_id: 8453, audience: "keyfleet"}
    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "claude-code"}, actor: agent)
    :ok
  end

  test "the owner reads the key's shards and is offered issuing, renewing and ending them", %{
    conn: conn
  } do
    ChainHelpers.issue_shard!(@fleet, 1, @agent, 45)
    ChainHelpers.issue_shard!(@fleet, 1, @bare)

    {:ok, view, html} = conn |> signed_in_as(@owner) |> live(@path)

    assert html =~ "Key 1"
    assert html =~ "You own this key."
    refute has_element?(view, "#key-no-shards")
    refute has_element?(view, "#key-edits-restricted")

    assert has_element?(view, "#key-shard-#{@agent}", "Orbit runner")
    assert has_element?(view, "#key-shard-#{@agent}", "Runs on claude-code")
    assert has_element?(view, "#key-shard-#{@agent}", "Until ")
    assert has_element?(view, "#key-shard-#{@bare}", "No agent has signed in with it yet")

    # The owner compares the wallet's whole address before trusting it.
    assert view |> element("#key-shard-address-#{@agent}") |> render() =~
             ~s(data-copy-text="#{@agent}")

    for wallet <- [@agent, @bare] do
      assert has_element?(view, "#key-shard-renew-#{wallet}")
      assert has_element?(view, "#key-shard-end-#{wallet}")
    end

    assert has_element?(view, "#key-issue-shard #key-shard-wallet")
    assert has_element?(view, "#key-issue-shard-button", "Issue shard")

    assert has_element?(view, "#key-issue-shard", "Check this is your agent’s wallet address.")
  end

  test "anyone else reads the key's shards without the owner's buttons", %{conn: conn} do
    ChainHelpers.issue_shard!(@fleet, 1, @agent)

    for conn <- [signed_in_as(conn, @stranger), conn] do
      {:ok, view, html} = live(conn, @path)

      refute html =~ "You own this key."
      assert has_element?(view, "#key-shard-#{@agent}", "Orbit runner")
      refute has_element?(view, "#key-shard-end-#{@agent}")
      refute has_element?(view, "#key-shard-renew-#{@agent}")
      refute has_element?(view, "#key-issue-shard")
    end
  end

  test "a shard that ended, ran out or was issued under an earlier owner is not shown", %{
    conn: conn
  } do
    ChainHelpers.issue_shard!(@fleet, 1, @agent)
    ChainHelpers.end_shard!(@fleet, 1, @agent, @owner)
    ChainHelpers.issue_shard!(@fleet, 1, @bare, -1)

    {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
    assert has_element?(view, "#key-no-shards", "This key has no shards.")

    ChainHelpers.issue_shard!(@fleet, 1, @agent)
    epoch!(2, @stranger)

    {:ok, view, html} = conn |> signed_in_as(@stranger) |> live(@path)
    assert html =~ "You own this key."
    assert has_element?(view, "#key-no-shards")
  end

  test "a key whose edits a vote restricted says so", %{conn: conn} do
    Keys.record_edits_restriction!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        restricted: true,
        proposal_number: 1,
        block_number: 20,
        block_hash: "0x" <> String.duplicate("b", 64),
        transaction_hash: "0x" <> String.duplicate("e", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(
             view,
             "#key-edits-restricted",
             "A vote of the fleet has stopped this key and its shards changing the workspace."
           )
  end

  test "a key nobody has been issued shows nothing but says so", %{conn: conn} do
    {:ok, _view, html} = conn |> signed_in_as(@owner) |> live("/app/keys/fibonacci_cascade/9")

    assert html =~ "This key isn’t here yet"
    refute html =~ "Orbit runner"
  end

  # Reading never waits on ownership being fresh; only acting on a key does.
  test "a fleet's page lists its keys even while ownership is being refreshed", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet, rescan_from: 5)
    reader = "0x" <> String.duplicate("d", 40)

    {:ok, view, _html} = conn |> signed_in_as(reader) |> live("/app/fleets/#{@fleet}")

    assert view |> element("#fleet-key-1") |> render() =~ "Held by 0xaaaa..aaaa"
    # The page's buy steps are built after it opens; let them finish.
    render_async(view)
  end

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

defmodule KeyFleetWeb.Live.KeyProfileTest do
  use KeyFleetWeb.ConnCase, async: false

  import KeyFleet.ProposalHelpers, only: [wallet: 1]

  alias KeyFleet.Accounts
  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Rooms
  alias KeyFleet.Traits

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @path "/app/fleets/fibonacci_cascade"
  @system %Actors.System{}

  # Key 12 was sold to a and passed to e, who also holds keys 3 and 20. Keys 1
  # to 20 are sold, so key 21 is the next on sale.
  setup do
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!()
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)

    for token_id <- 1..20, token_id not in [3, 12, 20], do: epoch!(token_id, 1, wallet("f"))
    epoch!(12, 1, wallet("a"))
    epoch!(12, 2, wallet("e"))
    epoch!(3, 1, wallet("e"))
    epoch!(20, 1, wallet("e"))
    :ok
  end

  test "a key named in the address opens with what is known about it", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?key=12")

    assert has_element?(view, "dialog#key-profile[data-close='replace']")
    assert text(view, "#key-profile-title") == "Key 12"

    assert has_element?(
             view,
             "#key-profile-card[phx-hook='HolographicCard'][data-holo-crown='false'] svg polygon"
           )

    assert has_element?(view, ".key-profile__card #key-profile-traits-title", "Traits")
    assert text(view, ".key-profile__card .key-profile__traits p") == "Revealing"
    assert text(view, "#key-profile-holder") == "0xeeee…eeee"
    assert render(view) =~ "17.28 USDC"
    assert render(view) =~ "Once"
    assert text(view, "#key-profile-holder-keys") == "3"
    assert text(view, "#key-profile-holder-votes") == "0 votes on 0 proposals"
    assert text(view, "#key-profile-messages") == "0"
    assert has_element?(view, "#key-profile-key-3")
    assert has_element?(view, "#key-profile-key-20")
    refute has_element?(view, "#key-profile-manage")
  end

  test "only a key the map can show opens", %{conn: conn} do
    for key <- ["0", "22", "twelve", "-1"] do
      {:ok, view, _html} = live(conn, @path <> "?key=" <> key)
      refute has_element?(view, "#key-profile")
    end

    {:ok, view, _html} = live(conn, @path <> "?key=21")
    assert has_element?(view, "#key-profile-buy[value='buy-key-button']", "Buy key 21")
    refute has_element?(view, "#key-profile-composer")
  end

  test "another of the holder's keys opens in place of the one on show, keeping the referral",
       %{conn: conn} do
    ref = "0x" <> String.duplicate("d", 40)
    {:ok, view, _html} = live(conn, @path <> "?key=12&ref=" <> ref)

    assert has_element?(view, "#key-profile-key-3[data-phx-link-state='replace']")
    view |> element("#key-profile-key-3") |> render_click()

    assert_patch(view, @path <> "?ref=#{ref}&key=3")
    assert text(view, "#key-profile-title") == "Key 3"
    assert has_element?(view, "#key-profile-key-3[aria-current='true']")
  end

  test "another key chosen while one is open takes its place in the address", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#fleet-key-link-12[data-phx-link-state='push']")

    view |> element("#fleet-key-link-12") |> render_click()
    assert_patch(view, @path <> "?key=12")
    assert has_element?(view, "#fleet-key-link-5[data-phx-link-state='replace']")

    render_hook(view, "select_key", %{"token_id" => 5})
    assert_receive {_ref, {:patch, _topic, %{to: @path <> "?key=5", kind: :replace}}}
    assert has_element?(view, "dialog#key-profile[data-close='back']")
    assert text(view, "#key-profile-title") == "Key 5"
  end

  test "a key opened from the list closes by going back", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> element("#fleet-key-link-12") |> render_click()

    assert_patch(view, @path <> "?key=12")
    assert has_element?(view, "dialog#key-profile[data-close='back']")

    render_hook(view, "close_key", %{})
    assert_patch(view, @path)
    refute has_element?(view, "#key-profile")
  end

  describe "who may write to a key" do
    test "a visitor is asked to sign in", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?key=12")

      assert render(view) =~ "Everyone can read. Sign in to write to Key 12."
      assert has_element?(view, "#key-profile [data-account-target='sign-in']")
      refute has_element?(view, "#key-profile-composer")
    end

    test "someone without a key in the fleet can only read", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(wallet("9")) |> live(@path <> "?key=12")

      assert render(view) =~ "Only people who hold a key in"
      refute has_element?(view, "#key-profile-composer")
    end

    test "someone who buys their first key while the key is open may then write",
         %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(wallet("9")) |> live(@path <> "?key=12")
      refute has_element?(view, "#key-profile-composer")

      epoch!(21, 1, wallet("9"))
      keys_changed([21])

      assert has_element?(view, "#key-profile-composer")
    end

    test "a holder waiting on key ownership may write once it is fresh again", %{conn: conn} do
      ChainHelpers.seed_cursor!(@fleet, head_block: 5_000, next_block: 1_000)
      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")
      assert render(view) =~ "Key ownership is being refreshed"

      ChainHelpers.seed_cursor!(@fleet)
      keys_changed([7])

      assert has_element?(view, "#key-profile-composer")
    end

    test "a refused message shows who may write now", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")
      ChainHelpers.seed_cursor!(@fleet, head_block: 5_000, next_block: 1_000)

      view
      |> form("#key-profile-composer", post: %{body: "Hull survey started"})
      |> render_submit()

      refute has_element?(view, "#key-profile-composer")
      assert text(view, "#key-profile") =~ "Key ownership is being refreshed"
      assert render(view) |> String.split("Key ownership is being refreshed") |> length() == 2
    end

    test "a holder of any key writes, and sees what they wrote", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")

      html =
        view
        |> form("#key-profile-composer", post: %{body: "Hull survey started"})
        |> render_submit()

      assert html =~ "Hull survey started"
      assert has_element?(view, "#key-profile-thread li", "Key 1 · 0xffff…ffff")
      assert text(view, "#key-profile-messages") == "1"
      assert text(view, "#key-profile-composer-body") == ""
    end
  end

  test "a message written elsewhere to the key on show appears", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?key=12")

    to_key!(wallet("f"), 12, "Anyone aboard?")

    assert render(view) =~ "Anyone aboard?"
    assert text(view, "#key-profile-news") == "New message to Key 12."
    assert text(view, "#key-profile-messages") == "1"
  end

  test "the key changing hands shows its new holder", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?key=12")
    assert text(view, "#key-profile-holder") == "0xeeee…eeee"

    epoch!(12, 3, wallet("b"))
    keys_changed([12])

    assert text(view, "#key-profile-holder") == "0xbbbb…bbbb"
    assert render(view) =~ "2 times"
    refute has_element?(view, "#key-profile-key-3")
  end

  test "a key reaching or leaving the holder moves their figures", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?key=12")

    epoch!(5, 2, wallet("e"))
    keys_changed([5])

    assert has_element?(view, "#key-profile-key-5")
    assert text(view, "#key-profile-holder-keys") == "4"

    epoch!(3, 2, wallet("f"))
    keys_changed([3])

    refute has_element?(view, "#key-profile-key-3")
    assert text(view, "#key-profile-holder-keys") == "3"
  end

  defp deploy! do
    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: "0x" <> String.duplicate("7", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: @system
    )
  end

  defp epoch!(token_id, epoch, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: owner,
        block_number: 10 + token_id * 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: Traits.keccak256("#{@fleet}/#{token_id}/#{epoch}"),
        log_index: 0
      },
      actor: @system
    )
  end

  defp keys_changed(token_ids),
    do:
      Phoenix.PubSub.broadcast(
        KeyFleet.PubSub,
        Keys.topic(@fleet),
        {:keys_changed, @fleet, token_ids}
      )

  defp to_key!(owner, token_id, body) do
    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: token_id, body: body, idempotency_key: Ash.UUID.generate()},
      actor: %Actors.Human{human_account_id: 1, wallet_addresses: [owner]}
    )
  end

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:key-profile:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: @system
      )

    init_test_session(conn, %{human_account_id: account.id})
  end

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end
end

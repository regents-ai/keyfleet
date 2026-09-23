defmodule KeyFleetWeb.Live.FleetPageTest do
  use KeyFleetWeb.ConnCase, async: false

  alias KeyFleet.Accounts
  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Fleets.Presets
  alias KeyFleet.Keys

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @path "/app/fleets/fibonacci_cascade"
  @issued 150
  @owner "0x" <> String.duplicate("a", 40)
  @contract "0x" <> String.duplicate("7", 40)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  setup %{conn: conn} do
    Fleets.bootstrap_catalog!()

    for token_id <- 1..@issued, do: issue!(@fleet, token_id)

    %{conn: signed_in(conn)}
  end

  # However many keys a fleet has issued, the page reads one page of them; the
  # count it shows comes from counting, not from reading every key.
  test "keys are listed a hundred at a time while the count covers them all", %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)

    {rows, {:ok, view, html}} = rows_read_during(fn -> live(conn, @path) end)

    assert Enum.max(rows) <= 101
    assert html =~ "150 of"
    # Key 151 opens level 9, whose price is the first to round up.
    assert html =~ "Key 151, 42.99817 USDC"
    assert shown_keys(view) == Enum.to_list(1..100)
    refute has_element?(view, "#fleet-keys-previous")

    view |> element("#fleet-keys-next") |> render_click()
    assert shown_keys(view) == Enum.to_list(101..150)
    refute has_element?(view, "#fleet-keys-next")

    view |> element("#fleet-keys-previous") |> render_click()
    assert shown_keys(view) == Enum.to_list(1..100)
    refute has_element?(view, "#fleet-keys-previous")
    assert has_element?(view, "#fleet-keys-next")
  end

  test "rooms are listed by the names they go by", %{conn: conn} do
    KeyFleet.Rooms.bootstrap_rooms!()

    KeyFleet.Repo.query!(
      "UPDATE keyfleet_app.rooms SET topic = 'Hull survey', topic_set_by = $1, " <>
        "topic_set_at = now() WHERE fleet_id = $2 AND slug = 'open-1'",
      [@owner, @fleet]
    )

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, ~s(.fleet-room-list a[href="#{@path}/rooms/open-1"]), "Hull survey")
    assert has_element?(view, ~s(.fleet-room-list a[href="#{@path}/rooms/open-2"]), "Open room 2")
    assert has_element?(view, ~s(.fleet-room-list a[href="#{@path}/rooms/general"]), "General")
    refute render(view) =~ "Open room 1"
  end

  test "a page name that is not one of the fleet's keys is a page that doesn't exist", %{
    conn: conn
  } do
    assert_raise KeyFleetWeb.NotFoundError, fn -> live(conn, @path <> "?after=nonsense") end
  end

  # A fleet with no contract has sold nothing and has no price to show.
  test "a fleet not yet deployed shows no sales figures or price", %{conn: conn} do
    ChainHelpers.seed_cursor!(@fleet)

    {:ok, view, html} = live(conn, @path)

    assert html =~ "Not yet deployed"
    refute has_element?(view, "#fleet-progress-title")
    refute html =~ "Next key"
  end

  # Until the fleet has been read up to now, the figures would run low, so
  # the page says they are catching up instead of showing them.
  test "a fleet whose sales are still being read shows no figures", %{conn: conn} do
    deploy!()
    ChainHelpers.seed_cursor!(@fleet, head_block: 5_000, next_block: 1_000)

    {:ok, view, html} = live(conn, @path)

    assert html =~ "Sales figures are catching up."
    refute html =~ "Keys issued"
    refute html =~ "Next key"
    assert shown_keys(view) == Enum.to_list(1..100)
  end

  describe "buying the next key" do
    # Key 151 opens level 9, where a wallet may hold 8 keys.
    test "offers the next key's number, exact price and level", %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)

      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#buy-key-number") == "151"
      assert text(view, "#buy-key-price") == "42.99817 USDC"
      assert text(view, "#buy-key-level") == "9"
      assert render(view) =~ "One wallet may hold 8 keys of level 9."
      assert text(view, "#buy-key-button") == "Buy key 151"
      refute has_element?(view, "#buy-key-sold-out")
    end

    # The wallet is handed the fleet's own deployment and the contract's own
    # price in atomic USDC, and adds the ten minutes itself when it is pressed.
    test "hands the wallet the fleet's deployment and the exact price", %{conn: conn} do
      fleet = deploy!()
      ChainHelpers.seed_cursor!(@fleet)

      {:ok, view, _html} = live(conn, @path)

      assert order(view) == %{
               "phx-hook" => "BuyKey",
               "data-chain-id" => Integer.to_string(fleet.chain_id),
               "data-fleet" => fleet.contract_address,
               "data-usdc" => fleet.usdc_address,
               "data-price" => Integer.to_string(Presets.progress(@fleet, @issued).next_price),
               "data-price-label" => "42.99817 USDC",
               "data-deadline-seconds" => "600"
             }

      assert order(view)["data-price"] == "42998170"
      assert fleet.usdc_address == @usdc
      assert fleet.contract_address == @contract
    end

    test "a fleet without levels offers its key with no level", %{conn: conn} do
      deploy!("fleet_tech_classic")
      ChainHelpers.seed_cursor!("fleet_tech_classic")

      {:ok, view, html} = live(conn, "/app/fleets/fleet_tech_classic")

      assert text(view, "#buy-key-number") == "1"
      assert text(view, "#buy-key-price") == "10 USDC"
      assert order(view)["data-price"] == "10000000"
      refute has_element?(view, "#buy-key-level")
      refute html =~ "One wallet may hold"
    end

    test "a sold-out fleet says so and offers nothing to buy", %{conn: conn} do
      deploy!("fleet_tech_classic")
      for token_id <- 1..144, do: issue!("fleet_tech_classic", token_id)
      ChainHelpers.seed_cursor!("fleet_tech_classic")

      {:ok, view, _html} = live(conn, "/app/fleets/fleet_tech_classic")

      assert text(view, "#buy-key-sold-out") == "All 144 keys in this fleet have been sold."
      refute has_element?(view, "#buy-key-order")
      refute has_element?(view, "#buy-key-button")
    end

    # Stopping here would hold back a press the contract can answer: a key
    # that has since cost more is refused, and no USDC is taken.
    test "a fleet whose sales are still being read still offers the key, and says the price may have moved",
         %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet, head_block: 5_000, next_block: 1_000)

      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#buy-key-number") == "151"

      assert text(view, "#buy-key-price-may-move") ==
               "Sales are still being counted, so this price may already have gone up. If it has, the purchase is refused and no USDC is taken, though your wallet still pays the Base network fee for trying."

      assert has_element?(view, "#buy-key-button")
    end

    test "a fleet not yet deployed offers nothing to buy", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#buy-key")
    end
  end

  describe "a referral link" do
    setup do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      :ok
    end

    test "carries a well-formed address into the purchase and names it", %{conn: conn} do
      ref = "0xAbCdEf0123456789aBcDeF0123456789AbCdEf12"

      {:ok, view, _html} = live(conn, @path <> "?ref=" <> ref)

      assert order(view)["data-referrer"] == String.downcase(ref)
      assert text(view, "#buy-key-referrer") == "Referred by 0xabcd…ef12"
      refute has_element?(view, "#buy-key-referral-refused")
    end

    test "that isn't an address is left out, and the buyer is told", %{conn: conn} do
      for ref <- [
            "0x1234",
            "bob",
            "0x" <> String.duplicate("g", 40),
            "0x" <> String.duplicate("a", 41)
          ] do
        {:ok, view, _html} = live(conn, @path <> "?" <> URI.encode_query(ref: ref))

        refute Map.has_key?(order(view), "data-referrer")
        refute has_element?(view, "#buy-key-referrer")

        assert text(view, "#buy-key-referral-refused") ==
                 "The referral in this link isn’t a wallet address, so this purchase has no referrer."
      end

      {:ok, view, _html} = live(conn, @path <> "?ref[]=" <> @owner)
      refute Map.has_key?(order(view), "data-referrer")
      assert has_element?(view, "#buy-key-referral-refused")
    end

    # The contract credits any referrer, the buyer's own wallet included.
    test "naming the buyer's own wallet is carried as it is", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?ref=" <> @owner)

      assert order(view)["data-referrer"] == @owner
      refute has_element?(view, "#buy-key-referral-refused")
    end

    # The contract reads the zero address as no referral.
    test "naming the zero address is no referral", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?ref=0x" <> String.duplicate("0", 40))

      refute Map.has_key?(order(view), "data-referrer")
      refute has_element?(view, "#buy-key-referrer")
      refute has_element?(view, "#buy-key-referral-refused")
    end

    test "stays with the page while the buyer pages through keys", %{conn: conn} do
      ref = "0x" <> String.duplicate("b", 40)
      {:ok, view, _html} = live(conn, @path <> "?ref=" <> ref)

      view |> element("#fleet-keys-next") |> render_click()
      assert shown_keys(view) == Enum.to_list(101..150)
      assert order(view)["data-referrer"] == ref

      view |> element("#fleet-keys-previous") |> render_click()
      assert order(view)["data-referrer"] == ref
    end
  end

  # The button's only job is to reach the wallet, whatever the page shows.
  test "the Buy button is never disabled", %{conn: conn} do
    deploy!()

    pages = [
      {fn -> ChainHelpers.seed_cursor!(@fleet) end, conn, @path},
      {fn -> :ok end, conn, @path <> "?ref=" <> @owner},
      {fn -> :ok end, conn, @path <> "?ref=nonsense"},
      {fn -> :ok end, init_test_session(build_conn(), %{}), @path},
      {fn -> ChainHelpers.seed_cursor!(@fleet, head_block: 5_000) end, conn, @path}
    ]

    for {arrange, conn, path} <- pages do
      arrange.()
      {:ok, view, _html} = live(conn, path)

      [button] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#buy-key-button")
        |> Enum.to_list()

      attributes = button |> LazyHTML.attributes() |> hd() |> Map.new()

      refute Map.has_key?(attributes, "disabled")
      refute Map.has_key?(attributes, "aria-disabled")
      refute Map.has_key?(attributes, "inert")
    end
  end

  describe "after a purchase" do
    setup %{conn: conn} do
      deploy!()
      ChainHelpers.seed_cursor!(@fleet)
      {:ok, view, _html} = live(conn, @path)
      %{view: view}
    end

    # The receipt names the key; the page shows it once the chain reader has
    # recorded it, and never before.
    test "the page reads the fleet again until the key bought is recorded, then stops", %{
      view: view
    } do
      render_hook(view, "key_bought", %{"token_id" => "151"})
      catch_up_read(view)
      assert text(view, "#buy-key-number") == "151"
      assert catch_up(view).reads == 29

      issue!(@fleet, 151)
      catch_up_read(view)

      assert text(view, "#buy-key-number") == "152"
      assert render(view) =~ "151 of 46,365"
      assert catch_up(view) == nil
    end

    test "the page gives up after thirty reads of a key the chain reader never records", %{
      view: view
    } do
      render_hook(view, "key_bought", %{"token_id" => "151"})

      for _read <- 1..29, do: catch_up_read(view)
      assert catch_up(view).reads == 1

      catch_up_read(view)
      assert catch_up(view) == nil
    end

    # A notice any visitor can send costs the server at most one read every two
    # seconds, however many arrive.
    test "any number of notices start one run of reads, two seconds apart", %{view: view} do
      :erlang.trace(view.pid, true, [:receive])

      for token_id <- 151..200 do
        render_hook(view, "key_bought", %{"token_id" => Integer.to_string(token_id)})
      end

      refute_receive {:trace, _pid, :receive, {:catch_up_fleet, _ref}}, 1_800
      assert_receive {:trace, _pid, :receive, {:catch_up_fleet, _ref}}, 1_000
      refute_receive {:trace, _pid, :receive, {:catch_up_fleet, _ref}}, 500
      :erlang.trace(view.pid, false, [:receive])

      assert %{token_id: 200, reads: 29} = catch_up(view)
    end

    test "a read from a run the page has already moved past is ignored", %{view: view} do
      render_hook(view, "key_bought", %{"token_id" => "151"})
      %{ref: replaced} = catch_up(view)
      catch_up_read(view)
      running = catch_up(view)

      send(view.pid, {:catch_up_fleet, replaced})
      render(view)

      assert catch_up(view) == running
    end

    test "a later notice moves the run on to the higher key and starts its count again", %{
      view: view
    } do
      render_hook(view, "key_bought", %{"token_id" => "152"})
      %{ref: ref} = catch_up(view)
      catch_up_read(view)
      catch_up_read(view)

      render_hook(view, "key_bought", %{"token_id" => "151"})
      assert %{token_id: 152, reads: 30} = catch_up(view)

      render_hook(view, "key_bought", %{"token_id" => "153"})
      assert %{token_id: 153, reads: 30} = catch_up(view)
      refute catch_up(view).ref == ref
    end

    test "a notice that names no key starts nothing", %{view: view} do
      for token_id <- ["0", "-1", "abc", "1.5", "", "151abc", 151, nil] do
        render_hook(view, "key_bought", %{"token_id" => token_id})
      end

      render_hook(view, "key_bought", %{})

      assert catch_up(view) == nil
      assert text(view, "#buy-key-number") == "151"
    end
  end

  test "a notice on a fleet that isn't deployed starts nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    render_hook(view, "key_bought", %{"token_id" => "1"})

    assert catch_up(view) == nil
  end

  defp deploy!(fleet_id \\ @fleet) do
    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: @contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: @usdc,
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )
  end

  defp issue!(fleet_id, token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: 0,
        owner_wallet: @owner,
        block_number: 10 + token_id,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet_id}/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  # The page's one run of reads after a purchase, if it is following one.
  defp catch_up(view), do: :sys.get_state(view.pid).socket.assigns.catch_up

  # Makes the run's next read happen now rather than two seconds from now.
  defp catch_up_read(view) do
    send(view.pid, {:catch_up_fleet, catch_up(view).ref})
    render(view)
  end

  # The attributes the page hands the Buy button's wallet hook.
  defp order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#buy-key-order")
    |> LazyHTML.attributes()
    |> hd()
    |> Map.new()
    |> Map.drop(["id"])
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

  defp shown_keys(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#fleet-key-list > li")
    |> LazyHTML.attribute("id")
    |> Enum.map(fn "fleet-key-" <> token_id -> String.to_integer(token_id) end)
  end

  # How many rows each read of the key records returned while `fun` ran.
  defp rows_read_during(fun) do
    test_pid = self()

    :telemetry.attach(
      "fleet-page-key-rows",
      [:key_fleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        with "key_attachments" <- meta.source,
             {:ok, %{num_rows: rows}} <- meta.result,
             do: send(test_pid, {:key_rows, rows})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach("fleet-page-key-rows")
      end

    {collect_rows([]), result}
  end

  defp collect_rows(rows) do
    receive do
      {:key_rows, count} -> collect_rows([count | rows])
    after
      0 -> rows
    end
  end

  defp signed_in(conn) do
    account =
      Accounts.register_verified!(
        "did:privy:fleet-page:#{System.unique_integer([:positive])}",
        @owner,
        [@owner],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end
end

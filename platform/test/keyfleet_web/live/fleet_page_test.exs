defmodule KeyFleetWeb.Live.FleetPageTest do
  use KeyFleetWeb.ConnCase, async: false

  alias KeyFleet.Accounts
  alias KeyFleet.Actors
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Keys

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @path "/app/fleets/fibonacci_cascade"
  @issued 150
  @owner "0x" <> String.duplicate("a", 40)

  setup %{conn: conn} do
    Fleets.bootstrap_catalog!()

    for token_id <- 1..@issued do
      Keys.record_epoch!(
        %{
          fleet_id: @fleet,
          token_id: token_id,
          ownership_epoch: 0,
          owner_wallet: @owner,
          block_number: 10 + token_id,
          block_hash: "0x" <> String.duplicate("a", 64),
          transaction_hash:
            ("0x" <> String.pad_leading(Integer.to_string(token_id, 16), 64, "0"))
            |> String.downcase(),
          log_index: 0
        },
        actor: %Actors.System{}
      )
    end

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

  defp deploy! do
    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: "0x" <> String.duplicate("7", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        deployed_block: 1
      },
      actor: %Actors.System{}
    )
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

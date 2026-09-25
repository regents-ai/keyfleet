defmodule KeyfleetWeb.Live.KeyPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys

  @fleet "fibonacci_syndicate"
  @path "/app/keys/fibonacci_syndicate/1"
  @owner "0x" <> String.duplicate("a", 40)
  @stranger "0x" <> String.duplicate("b", 40)
  @operator "0x" <> String.duplicate("c", 40)
  @approve ~s(button[phx-click="approve_pairing"])
  @decline ~s(button[phx-click="decline_pairing"])
  @detach ~s(button[phx-click="detach_operator"])

  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 0,
        owner_wallet: @owner,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    agent = %Actors.Agent{wallet_address: @operator, chain_id: 8453, audience: "keyfleet"}

    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "claude-code"}, actor: agent)

    %{agent: agent, request: Keys.request_pairing!(@fleet, 1, %{}, actor: agent)}
  end

  test "the owner reads the key and approves the agent asking to run it", %{
    conn: conn,
    request: request
  } do
    {:ok, view, html} = conn |> signed_in_as(@owner) |> live(@path)

    assert html =~ "Key 1"
    assert html =~ "You own this key."
    assert html =~ "No agent runs this key."
    assert html =~ "Orbit runner"
    assert html =~ "Runs on claude-code"

    # The owner compares the agent's whole address before approving it.
    assert view |> element("#key-request-address-#{request.id}") |> render() =~
             ~s(data-copy-text="#{@operator}")

    assert view |> element(".key-request-list code") |> render() =~ @operator

    assert words(view, ".key-address-check") =~
             "Check this is your agent’s address. Approving it lets it post and work for this key; it can’t spend your money."

    assert view |> element("#key-request-address-#{request.id}") |> render() =~
             ~s(aria-label="Copy Orbit runner’s address")

    assert has_element?(view, @approve)
    assert has_element?(view, @decline)
    refute has_element?(view, @detach)

    html = view |> element(@approve) |> render_click()

    assert html =~ "That agent now runs this key."
    assert html =~ "Running this key since"
    assert html =~ "No one has asked to run this key."
    refute has_element?(view, @approve)
    assert has_element?(view, @detach)
    assert Keys.current_operator!(@fleet, 1).id == request.id

    assert view |> element("#key-agent-address") |> render() =~ ~s(data-copy-text="#{@operator}")
    assert view |> element(@detach) |> render_click() =~ "Agent removed."
    assert Keys.current_operator!(@fleet, 1) == nil
    assert render(view) =~ "No agent runs this key."
    assert render(view) =~ "removed on"
  end

  test "someone who does not own the key is offered nothing and refused anyway", %{
    conn: conn,
    request: request
  } do
    {:ok, view, html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert html =~ "Orbit runner"
    assert html =~ "Waiting for the owner"
    assert html =~ @operator
    refute html =~ "You own this key."
    refute has_element?(view, ".key-address-check")

    for selector <- [@approve, @decline, @detach] do
      refute has_element?(view, selector)
    end

    assert render_click(view, "approve_pairing", %{"id" => request.id}) =~ "didn’t go through"
    assert Keys.current_operator!(@fleet, 1) == nil
    assert Keys.list_pairing_requests!(@fleet, 1) |> Enum.map(& &1.id) == [request.id]
  end

  test "a page that has not caught up is told the request was answered", %{
    conn: conn,
    agent: agent,
    request: request
  } do
    {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
    Keys.withdraw_pairing_request!(request, %{}, actor: agent)

    html = view |> element(@approve) |> render_click()

    assert html =~ "This request was already answered."
    assert html =~ "No one has asked to run this key."
    assert Keys.current_operator!(@fleet, 1) == nil
  end

  test "removing an agent that already stepped down shows the key as it is now", %{
    conn: conn,
    agent: agent,
    request: request
  } do
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    approved = Keys.approve_pairing!(request, %{}, actor: owner)
    {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
    Keys.step_down!(approved, %{}, actor: agent)

    html = view |> element(@detach) |> render_click()

    assert html =~ "This key has already changed; here it is now."
    assert html =~ "No agent runs this key."
    assert html =~ "stepped down on"
  end

  test "an agent that stepped down is remembered in the key's history", %{
    conn: conn,
    agent: agent,
    request: request
  } do
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    approved = Keys.approve_pairing!(request, %{}, actor: owner)
    Keys.step_down!(approved, %{}, actor: agent)

    {:ok, _view, html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert html =~ "No agent runs this key."
    assert html =~ "Orbit runner"
    assert html =~ "stepped down on"
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

    assert view |> element("#fleet-key-1") |> render() =~ "Held by 0xaaaa…aaaa"
  end

  defp words(view, selector),
    do: view |> element(selector) |> render() |> String.split() |> Enum.join(" ")

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

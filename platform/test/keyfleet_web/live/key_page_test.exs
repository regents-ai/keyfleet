defmodule KeyFleetWeb.Live.KeyPageTest do
  use KeyFleetWeb.ConnCase, async: false

  alias KeyFleet.Accounts
  alias KeyFleet.Actors
  alias KeyFleet.Agents
  alias KeyFleet.Fleets
  alias KeyFleet.Keys

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
    assert html =~ "No operator attached."
    assert html =~ "Orbit runner"
    assert html =~ "Runs on claude-code"
    assert has_element?(view, @approve)
    assert has_element?(view, @decline)
    refute has_element?(view, @detach)

    html = view |> element(@approve) |> render_click()

    assert html =~ "That agent now runs this key."
    assert html =~ "Attached since"
    assert html =~ "No one has asked to run this key."
    refute has_element?(view, @approve)
    assert has_element?(view, @detach)
    assert Keys.current_operator!(@fleet, 1).id == request.id

    assert view |> element(@detach) |> render_click() =~ "Operator detached."
    assert Keys.current_operator!(@fleet, 1) == nil
    assert render(view) =~ "No operator attached."
    assert render(view) =~ "detached on"
  end

  test "someone who does not own the key is offered nothing and refused anyway", %{
    conn: conn,
    request: request
  } do
    {:ok, view, html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert html =~ "Orbit runner"
    assert html =~ "Waiting for the owner"
    refute html =~ "You own this key."

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

  test "a key nobody has been issued shows nothing but says so", %{conn: conn} do
    {:ok, _view, html} = conn |> signed_in_as(@owner) |> live("/app/keys/fibonacci_cascade/9")

    assert html =~ "This key isn’t here yet"
    refute html =~ "Orbit runner"
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

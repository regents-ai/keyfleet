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
  @approve ~s(form[phx-submit="approve_pairing"])
  @change ~s(form[phx-submit="set_limits"])
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
    refute has_element?(view, @change)

    # The owner starts from the usual limits and may rewrite any of them.
    approve = "#key-approve-#{request.id}"

    for {field, text} <- Keys.default_limits(),
        do: assert(has_element?(view, "#{approve}-#{field}", text))

    assert view |> element(approve <> " button[type=submit]") |> render() =~
             "Approve with these limits"

    html = view |> form(approve, limits: %{money: "Spend nothing at all."}) |> render_submit()

    assert html =~ "That agent now runs this key."
    assert html =~ "Running this key since"
    assert html =~ "No one has asked to run this key."
    refute has_element?(view, @approve)
    assert has_element?(view, @detach)
    assert Keys.current_operator!(@fleet, 1).id == request.id
    assert Keys.current_operator!(@fleet, 1).limits_money == "Spend nothing at all."

    assert has_element?(view, "#key-agent-limits", "Limits set by the key’s holder, last changed")
    assert has_element?(view, "#key-agent-limits dd", "Spend nothing at all.")
    assert has_element?(view, "#key-limits-form-money", "Spend nothing at all.")

    html =
      view |> form(@change, limits: %{outside: "Nothing outside Keyfleet."}) |> render_submit()

    assert html =~ "Limits saved."
    assert has_element?(view, "#key-agent-limits dd", "Nothing outside Keyfleet.")
    assert Keys.current_operator!(@fleet, 1).limits_outside == "Nothing outside Keyfleet."

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

    approve = %{"pairing" => request.id, "limits" => Keys.default_limits()}
    assert render_click(view, "approve_pairing", approve) =~ "didn’t go through"
    assert Keys.current_operator!(@fleet, 1) == nil
    assert Keys.list_pairing_requests!(@fleet, 1) |> Enum.map(& &1.id) == [request.id]
  end

  test "everyone reads the limits of the agent running a key; only the owner changes them", %{
    conn: conn,
    request: request
  } do
    owner = %Actors.Human{human_account_id: 1, wallet_addresses: [@owner]}
    approved = Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)

    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert has_element?(view, "#key-agent-limits", "Limits set by the key’s holder, last changed")

    for {_field, text} <- Keys.default_limits(),
        do: assert(has_element?(view, "#key-agent-limits dd", text))

    refute has_element?(view, @change)

    change = %{"pairing" => approved.id, "limits" => %{Keys.default_limits() | money: "Anything"}}
    assert render_click(view, "set_limits", change) =~ "didn’t go through"
    assert Keys.current_operator!(@fleet, 1).limits_money == approved.limits_money
  end

  test "an owner who leaves a limit blank is asked to write it, and nothing is approved", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)

    html =
      view |> form("#key-approve-#{request.id}", limits: %{check_first: "   "}) |> render_submit()

    assert html =~ "Write each limit, in no more than 500 characters."
    assert Keys.current_operator!(@fleet, 1) == nil
    assert Keys.list_pairing_requests!(@fleet, 1) |> Enum.map(& &1.id) == [request.id]
  end

  test "an agent signing from the owner's own wallet runs the key with no limits written", %{
    conn: conn
  } do
    own = %Actors.Agent{wallet_address: @owner, chain_id: 8453, audience: "keyfleet"}
    Agents.ensure_profile!(%{name: "Home agent", declared_harness: "hermes"}, actor: own)
    Keys.request_pairing!(@fleet, 1, %{}, actor: own)

    {:ok, view, _html} = conn |> signed_in_as(@stranger) |> live(@path)

    assert has_element?(
             view,
             "#key-agent-limits",
             "No limits written. This agent holds its own key."
           )
  end

  test "a page that has not caught up is told the request was answered", %{
    conn: conn,
    agent: agent,
    request: request
  } do
    {:ok, view, _html} = conn |> signed_in_as(@owner) |> live(@path)
    Keys.withdraw_pairing_request!(request, %{}, actor: agent)

    html = view |> form("#key-approve-#{request.id}") |> render_submit()

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
    approved = Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)
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
    approved = Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)
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

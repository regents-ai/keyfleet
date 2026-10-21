defmodule KeyfleetWeb.ConnectLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys}
  alias KeyfleetWeb.NotFoundError

  # Invariants covered:
  # - smoke: /connect mounts inside the app shell with its four steps
  # - Dots is chosen until another runtime is, marked as the most tested; the
  #   choice is the page's address, and the line to copy is the chosen
  #   runtime's own skill, copied exactly as shown
  # - a runtime the guides don't have is no page
  # - signed out, pairing starts with a sign-in and no step shows done
  # - signed in, Pair New Agent opens the side panel; once an agent pairs,
  #   the step shows done with its name, and a Key the account holds shows
  #   the Key step done with the Key

  @classic "fleet_tech_classic"
  @privy "did:privy:connect-page"
  @wallet "0x" <> String.duplicate("b", 40)

  setup do
    Fleets.bootstrap_catalog!()
    :ok
  end

  test "SMOKE: the page mounts in the app shell with its four steps", %{conn: conn} do
    assert conn |> get("/connect") |> html_response(200)
    {:ok, view, _html} = live(conn, "/connect")
    assert has_element?(view, "#app-shell #connect-page h1", "Connect your agent")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".connect-step")
           |> LazyHTML.attribute("id") == ~w(connect-choose connect-give connect-pair connect-key)
  end

  test "Dots is chosen first; another choice changes the address and the line to copy",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/connect")

    assert has_element?(view, ~s(#connect-runtime-dots[aria-current="true"]), "Most tested")

    assert instruction(view) ==
             "Install the Keyfleet skill from keyfleet.ai/agents/dots/skill.md and follow it."

    assert has_element?(view, ~s(#connect-copy[data-copy-text="#{instruction(view)}"]))
    assert has_element?(view, ~s(#connect-standing a[href="/agents/dots"]), "Dots guide")

    view |> element("#connect-runtime-hermes") |> render_click()

    assert_patch(view, "/connect?agent=hermes")
    assert has_element?(view, ~s(#connect-runtime-hermes[aria-current="true"]))
    refute has_element?(view, ~s(#connect-runtime-dots[aria-current="true"]))

    assert instruction(view) ==
             "Install the Keyfleet skill from keyfleet.ai/agents/hermes/skill.md and follow it."

    assert has_element?(view, ~s(#connect-copy[data-copy-text="#{instruction(view)}"]))
  end

  test "a runtime the guides don't have is no page", %{conn: conn} do
    assert_raise NotFoundError, fn -> live(conn, "/connect?agent=nobody") end
  end

  test "signed out, pairing starts with a sign-in and no step shows done", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/connect")

    assert has_element?(
             view,
             ~s(#connect-sign-in[data-account-target="sign-in"]),
             "Sign in to pair"
           )

    assert has_element?(view, ~s(#connect-classic[href="/classic/1"]), "See Classic #1")
    refute has_element?(view, ".connect-step[data-done]")
  end

  test "signed in, pairing and a Key each show their step done", %{conn: conn} do
    {:ok, account} =
      Keyfleet.Accounts.register_verified(@privy, @wallet, [@wallet], actor: %Actors.System{})

    conn = init_test_session(conn, %{human_account_id: account.id})
    {:ok, view, _html} = live(conn, "/connect")

    assert has_element?(view, "#connect-pair-new[data-aside-open]", "Pair New Agent")
    refute has_element?(view, ".connect-step[data-done]")

    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: @privy})

    RegentAgents.pair_agent!(code, "Astra", :hermes,
      actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate("c", 40)}
    )

    # Announced after the pairing's commit, which the test's transaction never makes.
    send(view.pid, :agents_changed)

    assert has_element?(view, "#connect-pair[data-done] #connect-paired", "Paired: Astra")
    refute has_element?(view, "#connect-pair-new")

    ChainHelpers.deploy!(@classic)
    ChainHelpers.seed_cursor!(@classic)
    hold!(3)
    {:ok, view, _html} = live(conn, "/connect")

    assert has_element?(view, "#connect-key[data-done] #connect-held", "Classic #1: Key 3")
    refute has_element?(view, "#connect-classic")
  end

  defp hold!(token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: @classic,
        token_id: token_id,
        ownership_epoch: 1,
        owner_wallet: @wallet,
        block_number: 10 + token_id,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("d", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp instruction(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#connect-instruction")
    |> LazyHTML.text()
    |> String.trim()
  end
end

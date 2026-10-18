defmodule KeyfleetWeb.Live.DmsPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.SessionAuthority
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Dms
  alias Keyfleet.Fleets
  alias Keyfleet.Keys

  @fleet "fibonacci_cascade"

  # Key 1 is held by a, Key 2 by b.
  setup do
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    epoch!(1, 1, wallet("a"))
    epoch!(2, 1, wallet("b"))
    :ok
  end

  test "a message written on the page reaches the other Key's open inbox", %{conn: conn} do
    {:ok, inbox, _html} = conn |> signed_in_as(wallet("b")) |> live("/cascade/1/keys/2/dms")
    {:ok, page, _html} = conn |> signed_in_as(wallet("a")) |> live("/cascade/1/keys/1/dms/2")

    page |> form("#dms-composer", dm: %{body: "Hello, Key 2"}) |> render_submit()

    assert has_element?(page, "#dms-thread-list", "Hello, Key 2")
    assert has_element?(inbox, "#dms-inbox", "Hello, Key 2")
  end

  test "a message sent as words alone, not as its box, changes nothing", %{conn: conn} do
    {:ok, page, _html} = conn |> signed_in_as(wallet("a")) |> live("/cascade/1/keys/1/dms/2")

    render_hook(page, "validate_dm", %{"dm" => "Hello, Key 2"})
    render_hook(page, "send_dm", %{"dm" => "Hello, Key 2"})

    assert has_element?(page, "#dms-composer")
    refute has_element?(page, "#dms-thread-list", "Hello, Key 2")
  end

  test "a Key sold while its conversation is open closes it at the next message", %{conn: conn} do
    {:ok, page, _html} = conn |> signed_in_as(wallet("a")) |> live("/cascade/1/keys/1/dms/2")

    epoch!(1, 2, wallet("f"))
    send!(wallet("b"), 2, 1, "Are you there?")

    assert has_element?(page, "#dms-closed", "Only this Key’s holder can read its messages.")
    refute has_element?(page, "#dms-thread-list", "Are you there?")
  end

  # Account c signs in with wallets c and a, so it reads and sends as Key 1
  # until a is unlinked from it, with the page still open.
  describe "an open page reads and sends as the sign-in of the moment" do
    setup %{conn: conn} do
      account = account!(wallet("c"), [wallet("c"), wallet("a")])
      signed_in = init_test_session(conn, %{human_account_id: account.id})
      {:ok, page, _html} = live(signed_in, "/cascade/1/keys/1/dms/2")
      %{account: account, signed_in: signed_in, page: page}
    end

    test "a wallet unlinked since reads no new message", %{account: account, page: page} do
      unlink_a!(account)
      send!(wallet("b"), 2, 1, "Still there?")

      assert has_element?(page, "#dms-closed", "Only this Key’s holder can read its messages.")
      refute has_element?(page, "#dms-thread-list", "Still there?")
    end

    test "a wallet unlinked since sends nothing", %{account: account, page: page} do
      unlink_a!(account)
      page |> form("#dms-composer", dm: %{body: "From an unlinked wallet"}) |> render_submit()

      assert has_element?(page, "#dms-closed")
      assert {:ok, []} = Dms.inbox(@fleet, 2, actor: holder(wallet("b")))
    end

    test "a sign-in that has ended leaves the page at the next message", %{
      signed_in: signed_in,
      page: page
    } do
      assert signed_in |> get_session() |> SessionAuthority.claim() |> SessionAuthority.revoke()
      send!(wallet("b"), 2, 1, "Anyone?")

      assert_redirect(page, "/")
    end
  end

  defp unlink_a!(account),
    do: Accounts.refresh_verified!(account, wallet("c"), [wallet("c")], actor: %Actors.System{})

  defp holder(owner), do: %Actors.Human{human_account_id: 1, wallet_addresses: [owner]}

  defp send!(owner, from, to, body),
    do:
      Dms.send_dm!(
        %{
          fleet_id: @fleet,
          from_token_id: from,
          to_token_id: to,
          body: body,
          idempotency_key: Ash.UUID.generate()
        },
        actor: holder(owner)
      )

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp epoch!(token_id, epoch, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: owner,
        block_number: 10 + token_id * 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{token_id}/#{epoch}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp signed_in_as(conn, wallet),
    do: init_test_session(conn, %{human_account_id: account!(wallet, [wallet]).id})

  defp account!(wallet, wallets),
    do:
      Accounts.register_verified!(
        "did:privy:dms-page:#{System.unique_integer([:positive])}",
        wallet,
        wallets,
        actor: %Actors.System{}
      )
end

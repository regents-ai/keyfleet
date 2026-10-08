defmodule KeyfleetWeb.Live.DmsPageTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.Accounts
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
    {:ok, inbox, _html} = conn |> signed_in_as(wallet("b")) |> live("/app/keys/#{@fleet}/2/dms")
    {:ok, page, _html} = conn |> signed_in_as(wallet("a")) |> live("/app/keys/#{@fleet}/1/dms/2")

    page |> form("#dms-composer", dm: %{body: "Hello, Key 2"}) |> render_submit()

    assert has_element?(page, "#dms-thread-list", "Hello, Key 2")
    assert has_element?(inbox, "#dms-inbox", "Hello, Key 2")
  end

  test "a Key sold while its conversation is open closes it at the next message", %{conn: conn} do
    {:ok, page, _html} = conn |> signed_in_as(wallet("a")) |> live("/app/keys/#{@fleet}/1/dms/2")

    epoch!(1, 2, wallet("f"))
    send!(wallet("b"), 2, 1, "Are you there?")

    assert has_element?(page, "#dms-closed", "Only this Key’s holder can read its messages.")
    refute has_element?(page, "#dms-thread-list", "Are you there?")
  end

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
        actor: %Actors.Human{human_account_id: 1, wallet_addresses: [owner]}
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

  defp signed_in_as(conn, wallet) do
    account =
      Accounts.register_verified!(
        "did:privy:dms-page:#{System.unique_integer([:positive])}",
        wallet,
        [wallet],
        actor: %Actors.System{}
      )

    init_test_session(conn, %{human_account_id: account.id})
  end
end

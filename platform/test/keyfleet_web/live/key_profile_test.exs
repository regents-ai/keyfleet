defmodule KeyfleetWeb.Live.KeyProfileTest do
  use KeyfleetWeb.ConnCase, async: false

  import Keyfleet.ProposalHelpers, only: [presence!: 3, scheduled!: 3, wallet: 1]

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Chain.RewardsWaiting
  alias Keyfleet.Chain.StubClient
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Traits
  alias KeyfleetWeb.FleetNow
  alias RegentChain.BuilderCode
  alias RegentChain.Call

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @path "/cascade/1"
  @members_path @path <> "?view=members"
  @key_20 @path <> "/keys/20"
  @system %Actors.System{}
  @rewards "0x" <> String.duplicate("8", 40)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  # Pinned from `cast sig` of each view function.
  @reward_assets "0x880ec04e"
  @accrued "0xbfe87f4d"

  # Key 12 was sold to a and passed to e, who also holds keys 3 and 20. Keys 1
  # to 20 are sold, so key 21 is the next on sale. No key has rewards waiting.
  setup do
    :ets.delete_all_objects(RewardsWaiting)
    rewards_answer(fn _to, _data, _block_hash -> {:ok, <<0::256>>} end)
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    ChainHelpers.deploy!(@fleet, %{
      rewards_address: @rewards,
      trait_table_hash: "0x1249d615f793a311bcb27def92766224fb544df85aa74359a785a6349df18610"
    })

    ChainHelpers.seed_cursor!(@fleet)

    for token_id <- 1..20, token_id not in [3, 12, 20], do: epoch!(token_id, 1, wallet("f"))
    epoch!(12, 1, wallet("a"))
    epoch!(12, 2, wallet("e"))
    epoch!(3, 1, wallet("e"))
    epoch!(20, 1, wallet("e"))
    # A hall shown to anyone but a member draws from the fleet's reading,
    # taken here as the site's producer would take it.
    FleetNow.read(@fleet)

    :ok
  end

  test "a key named in the address opens with what is known about it", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?key=12")

    assert has_element?(view, "dialog#key-profile[data-close='replace']")
    assert text(view, "#key-profile-title") == "Key 12"

    assert has_element?(
             view,
             "img#key-profile-card-picture[src='https://media.regents.sh/ipfs/QmddjWKS43UPY3V1muZJGVx8zkpxCUXwmsy29heg1qNETy']"
           )

    assert has_element?(view, ".key-profile__card #key-profile-traits-title", "Traits")
    assert has_element?(view, ".key-profile__card[tabindex='0']")
    assert text(view, ".key-profile__card .key-profile__traits p") == "Revealing"
    assert text(view, "#key-profile-holder-address .rg-address__label") == "0xeeee..eeee"
    holder = wallet("e")
    assert has_element?(view, "#key-profile-holder-address-copy[data-copy-text='#{holder}']")
    fleet = Fleets.get_fleet!(@fleet)
    item = "#{fleet.keys_address}/#{Fleets.Fleet.onchain_token_id(fleet, 12)}"
    assert has_element?(view, "#key-profile-opensea[href='https://opensea.io/item/base/#{item}']")
    # Its holder chose no Key to post as, so posts as their lowest.
    assert text(view, "#key-profile-posts-as") == "Posts as Key 3"

    assert has_element?(
             view,
             "#key-profile-holder-address-explorer[href='https://basescan.org/address/#{holder}']"
           )

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

    # The chain says Keys 1 to 20 are sold, so the Key on sale is 21.
    minted = Call.encode("totalMinted()", [])

    rewards_answer(fn
      _to, ^minted, _hash -> {:ok, <<20::256>>}
      _to, _data, _hash -> {:ok, <<0::256>>}
    end)

    {:ok, view, _html} = live(conn, @path <> "?key=21")
    render_async(view)
    refute has_element?(view, "#key-profile-composer")

    # Its Buy Key opens the fleet's Buy Key window above the profile, the Key
    # on sale in its facts.
    view |> element("#key-profile-buy") |> render_click()
    render_async(view, 3_000)
    assert text(view, "#buy-key #buy-key-button [data-press-label]") == "Buy Key"
    assert text(view, "#buy-key #buy-key-number") == "21"
    assert has_element?(view, "#key-profile")
  end

  test "another of the holder's keys opens in place of the one on show", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?key=12")

    assert has_element?(view, "#key-profile-key-3[data-phx-link-state='replace']")
    view |> element("#key-profile-key-3") |> render_click()

    assert_patch(view, @path <> "?key=3")
    assert text(view, "#key-profile-title") == "Key 3"
    assert has_element?(view, "#key-profile-key-3[aria-current='true']")
  end

  test "another key chosen while one is open takes its place in the address", %{conn: conn} do
    {:ok, view, _html} = live(conn, @members_path)
    assert has_element?(view, "#fleet-members-card-12[data-phx-link-state='push']")

    view |> element("#fleet-members-card-12") |> render_click()
    assert_patch(view, @members_path <> "&key=12")
    assert has_element?(view, "#fleet-members-card-5[data-phx-link-state='replace']")

    render_hook(view, "select_key", %{"token_id" => 5})
    assert_receive {_ref, {:patch, _topic, %{to: @members_path <> "&key=5", kind: :replace}}}
    assert has_element?(view, "dialog#key-profile[data-close='back']")
    assert text(view, "#key-profile-title") == "Key 5"
  end

  # The reader's own first Key opens from the list and from their cards alike.
  test "the reader's own first Key opens from the list and from their cards", %{conn: conn} do
    conn = signed_in_as(conn, wallet("e"))
    {:ok, view, _html} = live(conn, @members_path)

    view |> element("#fleet-members-card-3") |> render_click()
    assert_patch(view, @members_path <> "&key=3")
    assert text(view, "#key-profile-title") == "Key 3"

    {:ok, view, _html} = live(conn, @path)

    view |> element("#fleet-entry-card-3") |> render_click()
    assert_patch(view, @path <> "?key=3")
    assert text(view, "#key-profile-title") == "Key 3"

    {:ok, view, _html} = live(conn, @path <> "?room=general")
    render_patch(view, @path <> "?key=3")
    assert text(view, "#key-profile-title") == "Key 3"
  end

  test "a key opened from the list closes by going back", %{conn: conn} do
    {:ok, view, _html} = live(conn, @members_path)

    view |> element("#fleet-members-card-12") |> render_click()

    assert_patch(view, @members_path <> "&key=12")
    assert has_element?(view, "dialog#key-profile[data-close='back']")

    render_hook(view, "close_key", %{})
    assert_patch(view, @members_path)
    refute has_element?(view, "#key-profile")
  end

  describe "claiming a key's income" do
    @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

    # Each token the key is paid in has its own Claim button, built on the
    # server for the holder's wallet; the money always goes to the holder.
    test "the holder gets a Claim button for each token waiting, built for their wallet", %{
      conn: conn
    } do
      holder = wallet("e")
      owner_of = Call.encode("ownerOf(uint256)", [id(12)])
      accrued = Call.encode("accrued(address,uint256)", [@usdc, id(12)])

      rewards_answer(fn
        _to, ^owner_of, _hash ->
          {:ok, <<0::96>> <> Base.decode16!(String.duplicate("ee", 20), case: :lower)}

        _to, ^accrued, _hash ->
          {:ok, <<2_500_000::256>>}

        _to, _credits, _hash ->
          {:ok, <<0::256>>}
      end)

      {:ok, view, _html} = conn |> signed_in_as(holder) |> live(@path <> "?key=12")
      render_async(view)

      view
      |> with_target("#key-profile-claim-action")
      |> render_hook("onchain_active_wallet", %{"address" => holder})

      render_async(view)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "key-profile-claim-action",
        review: %{signer: ^holder, steps: [claim]}
      })

      assert claim.step == "claim-#{@usdc}"
      assert claim.to == @rewards

      assert claim.data ==
               BuilderCode.append(Call.encode("claim(uint256[],address[])", [[id(12)], [@usdc]]))

      assert text(view, "#key-profile-claim-#{@usdc}") == "Claim 2.5 USDC"
      refute has_element?(view, "#key-profile-claim-#{@usdc}[disabled]")
    end

    # REGENT has 18 decimals; the window shows two of them.
    test "REGENT waiting shows cut to two decimals", %{conn: conn} do
      holder = wallet("e")
      regent = "0x6f89bca4ea5931edfcb09786267b251dee752b07"
      owner_of = Call.encode("ownerOf(uint256)", [id(12)])
      accrued = Call.encode("accrued(address,uint256)", [regent, id(12)])

      rewards_answer(
        fn
          _to, ^owner_of, _hash ->
            {:ok, <<0::96>> <> Base.decode16!(String.duplicate("ee", 20), case: :lower)}

          _to, ^accrued, _hash ->
            {:ok, <<9_750_773_103_342_555_816_583::256>>}

          _to, _credits, _hash ->
            {:ok, <<0::256>>}
        end,
        [@usdc, regent]
      )

      {:ok, view, _html} = conn |> signed_in_as(holder) |> live(@path <> "?key=12")
      render_async(view)

      view
      |> with_target("#key-profile-claim-action")
      |> render_hook("onchain_active_wallet", %{"address" => holder})

      render_async(view)

      assert text(view, "#key-profile-claim-#{regent}") == "Claim 9,750.77 REGENT"
      assert text(view, "#key-profile-rewards") == "9,750.77 REGENT"
    end

    test "nothing waiting keeps the button in view, not pressable, and says so", %{conn: conn} do
      holder = wallet("e")
      owner_of = Call.encode("ownerOf(uint256)", [id(12)])

      rewards_answer(fn
        _to, ^owner_of, _hash ->
          {:ok, <<0::96>> <> Base.decode16!(String.duplicate("ee", 20), case: :lower)}

        _to, _data, _hash ->
          {:ok, <<0::256>>}
      end)

      {:ok, view, _html} = conn |> signed_in_as(holder) |> live(@path <> "?key=12")
      # The rewards read first; once they land, the Claim panel builds its step
      # in a read of its own, which the second wait covers.
      render_async(view)
      render_async(view)

      assert has_element?(view, "#key-profile-claim-#{@usdc}[disabled]")
      assert has_element?(view, "#key-profile-claim-action", "Nothing to claim")
    end

    test "only the key's holder sees where to claim it", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")
      refute has_element?(view, "#key-profile-claim")

      {:ok, view, _html} = live(conn, @path <> "?key=12")
      refute has_element?(view, "#key-profile-claim")
    end
  end

  describe "asking again for a key's draw" do
    test "a key whose draw was turned down offers anyone Ask again, built on the server",
         %{conn: conn} do
      signer = wallet("f")
      draw_answer(0)

      {:ok, view, _html} = conn |> signed_in_as(signer) |> live(@path <> "?key=12")

      view
      |> with_target("#key-profile-reveal-action")
      |> render_hook("onchain_active_wallet", %{"address" => signer})

      render_async(view)

      assert_push_event(view, "onchain-steps:review", %{
        component_id: "key-profile-reveal-action",
        review: %{signer: ^signer, steps: [reveal, expire]}
      })

      assert reveal.step == "reveal"
      assert reveal.to == Fleets.get_fleet!(@fleet).keys_address
      assert reveal.data == BuilderCode.append(Call.encode("requestReveal(uint256)", [id(12)]))
      assert expire.step == "expire_reveal"
      assert expire.data == BuilderCode.append(Call.encode("expireReveal(uint256)", [id(12)]))

      assert has_element?(view, "#key-profile-reveal-again[data-onchain-step='reveal']")
      refute has_element?(view, "#key-profile-reveal-again[phx-click]")
      assert text(view, "#key-profile-reveal-again") == "Ask again"
      refute has_element?(view, "#key-profile-reveal-again[disabled]")

      # No draw waits, so there is no wait to end.
      assert has_element?(view, "#key-profile-reveal-expire[data-onchain-step='expire_reveal']")
      assert text(view, "#key-profile-reveal-expire") == "End the wait for good"
      assert has_element?(view, "#key-profile-reveal-expire[disabled]")
      assert text(view, "#key-profile-reveal-expire-why") == "No draw waiting"

      assert text(view, "#key-profile-reveal-tip") ==
               "A Key’s traits come from a random draw. If the request for it was turned " <>
                 "down, anyone can ask again. If the draw hasn’t come 24 hours after it was " <>
                 "asked for, anyone can end the wait, and the Key then never gets traits."
    end

    test "Ask again pressed as the wallet becomes active is answered with its step",
         %{conn: conn} do
      signer = wallet("f")
      draw_answer(0)

      {:ok, view, _html} = conn |> signed_in_as(signer) |> live(@path <> "?key=12")
      render_async(view)
      panel = with_target(view, "#key-profile-reveal-action")

      # The press reaches the server while the steps for the new wallet are
      # still being read: the first read from now on takes its time.
      reads = :atomics.new(1, [])
      seed = Call.encode("revealSeed(uint256)", [id(12)])
      record = Call.selector("fleet(uint256)")

      rewards_answer(fn
        _to, ^seed, _hash ->
          if :atomics.add_get(reads, 1, 1) == 1, do: Process.sleep(2_000)
          {:ok, <<0::256>>}

        _to, ^record <> _fleet_id, _hash ->
          {:ok, <<0::256, 0::256, 1::256, 1::256, 1::256>>}

        _to, _data, _hash ->
          {:ok, <<0::256>>}
      end)

      render_hook(panel, "onchain_active_wallet", %{"address" => signer})
      render_hook(panel, "prepare_and_send", %{"form" => %{}, "step" => "reveal"})

      assert_reply(view, %{
        send: "reveal",
        review: %{signer: ^signer, steps: [%{step: "reveal"}, %{step: "expire_reveal"}]}
      })
    end

    test "a request that was accepted says the draw is on its way", %{conn: conn} do
      draw_answer(1_800_000_000)

      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")
      render_async(view)

      # Asking again is certain to fail while the draw is on its way, and its
      # wait can't be ended for 24 hours.
      assert has_element?(view, "#key-profile-reveal-again[disabled]")
      assert has_element?(view, "#key-profile-reveal-action", "Draw on its way")
      assert has_element?(view, "#key-profile-reveal-expire[disabled]")
      assert text(view, "#key-profile-reveal-expire-why") == "From 16 Jan, 08:00 UTC"
    end

    test "a draw that hasn't come in 24 hours offers anyone End the wait for good", %{
      conn: conn
    } do
      signer = wallet("f")
      draw_answer(1)

      {:ok, view, _html} = conn |> signed_in_as(signer) |> live(@path <> "?key=12")
      render_async(view)
      panel = with_target(view, "#key-profile-reveal-action")
      render_hook(panel, "onchain_active_wallet", %{"address" => signer})
      render_async(view)

      refute has_element?(view, "#key-profile-reveal-expire[disabled]")
      render_hook(panel, "prepare_and_send", %{"form" => %{}, "step" => "expire_reveal"})
      assert_reply(view, %{send: "expire_reveal", review: %{signer: ^signer}})
    end

    test "a key whose wait was ended says it never gets traits", %{conn: conn} do
      draw_answer(1, expired?: true)

      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")
      render_async(view)

      assert has_element?(view, "#key-profile-reveal-again[disabled]")
      assert has_element?(view, "#key-profile-reveal-expire[disabled]")
      assert text(view, "#key-profile-reveal-again-why") == "Wait ended: it never gets traits"
    end

    test "shows while the key is revealing, and goes once its draw is recorded", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?key=12")

      assert text(view, "#key-profile-reveal-title") =~ "Traits"
      # Signed out, a press says to sign in.
      assert has_element?(view, "#key-profile-reveal-again", "Ask again")

      Keys.record_reveal!(
        %{
          fleet_id: @fleet,
          token_id: 12,
          request_id: 7,
          seed: Traits.keccak256("golden-1"),
          block_number: 500,
          block_hash: "0x" <> String.duplicate("c", 64),
          transaction_hash: Traits.keccak256("#{@fleet}/12/reveal"),
          log_index: 0
        },
        actor: @system
      )

      keys_changed([12])

      refute has_element?(view, "#key-profile-reveal")
      assert has_element?(view, ".key-profile__card .key-profile-traits li")

      {:ok, view, _html} = live(conn, @path <> "?key=12")
      refute has_element?(view, "#key-profile-reveal")
    end

    test "goes once the key's ended wait is recorded, and says it never gets traits", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @path <> "?key=12")
      assert text(view, ".key-profile__traits") == "Traits Revealing"

      Keys.record_reveal_expiry!(
        %{
          fleet_id: @fleet,
          token_id: 12,
          block_number: 500,
          block_hash: "0x" <> String.duplicate("c", 64),
          transaction_hash: Traits.keccak256("#{@fleet}/12/expired"),
          log_index: 0
        },
        actor: @system
      )

      keys_changed([12])

      refute has_element?(view, "#key-profile-reveal")
      assert text(view, ".key-profile__traits") == "Traits Never gets traits"
    end
  end

  describe "who may write to a key" do
    test "a visitor is asked to sign in", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?key=12")

      assert render(view) =~ "Everyone can read. Sign in to post on Key 12’s wall."
      assert has_element?(view, "#key-profile [data-account-target='sign-in']")
      refute has_element?(view, "#key-profile-composer")
    end

    test "someone without a key in the fleet can only read", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(wallet("9")) |> live(@path <> "?key=12")

      assert render(view) =~ "Only people who hold a Key in"
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
      assert has_element?(view, "#key-profile-thread li", "Key 1")
      assert has_element?(view, "#key-profile-thread li .rooms-writer", "0xffff..ffff")

      assert has_element?(
               view,
               ~s(#key-profile-thread .sent-from[aria-label="Sent from the website"])
             )

      assert text(view, "#key-profile-messages") == "1"
      assert text(view, "#key-profile-composer-body") == ""
    end

    test "a message or removal sent without its words or its post changes nothing",
         %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")

      render_hook(view, "post_to_key", %{})
      render_hook(view, "post_to_key", %{"post" => %{"body" => %{"words" => "Ahoy"}}})
      render_hook(view, "remove_from_wall", %{})

      assert has_element?(view, "#key-profile-composer")
      assert text(view, "#key-profile-messages") == "0"
    end
  end

  test "the holder opens the Key's messages; another holder writes as their lowest Key", %{
    conn: conn
  } do
    {:ok, view, _html} = conn |> signed_in_as(wallet("e")) |> live(@path <> "?key=12")
    assert has_element?(view, ~s(#key-profile-dms[href="/cascade/1/keys/12/dms"]), "Messages")

    {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")

    assert has_element?(
             view,
             ~s(#key-profile-dms[href="/cascade/1/keys/1/dms/12"]),
             "Message"
           )

    for conn <- [signed_in_as(conn, wallet("9")), conn] do
      {:ok, view, _html} = live(conn, @path <> "?key=12")
      refute has_element?(view, "#key-profile-dms")
    end
  end

  test "the Key changing hands moves its Messages button to the new holder", %{conn: conn} do
    {:ok, view, _html} = conn |> signed_in_as(wallet("e")) |> live(@path <> "?key=12")

    epoch!(12, 3, wallet("b"))
    keys_changed([12])

    assert has_element?(
             view,
             ~s(#key-profile-dms[href="/cascade/1/keys/3/dms/12"]),
             "Message"
           )
  end

  # Only the Key's holder takes a post off its wall, once they say so in the
  # window that asks first, and it then leaves every page with the wall open.
  test "a message written elsewhere to the key on show appears, and goes when its holder takes it off",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?key=12")

    message = to_key!(wallet("f"), 12, "Anyone aboard?")
    remove = "#key-profile-remove-#{message.id}"

    assert render(view) =~ "Anyone aboard?"
    assert text(view, "#key-profile-news") == "New message to Key 12."
    assert text(view, "#key-profile-messages") == "1"
    refute has_element?(view, remove)

    {:ok, writer, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")
    refute has_element?(writer, remove)
    render_hook(writer, "remove_from_wall", %{"id" => message.id})

    assert text(writer, "#key-profile-notice") ==
             "That post couldn’t be taken off right now. Try again."

    assert render(writer) =~ "Anyone aboard?"

    {:ok, holder, _html} = conn |> signed_in_as(wallet("e")) |> live(@path <> "?key=12")
    holder |> element(remove) |> render_click()
    assert has_element?(holder, "#key-wall-remove-dialog")
    assert render(holder) =~ "Anyone aboard?"
    holder |> element("#key-wall-remove-confirm") |> render_click()
    refute has_element?(holder, "#key-wall-remove-dialog")

    for page <- [holder, writer, view] do
      refute render(page) =~ "Anyone aboard?"
      assert text(page, "#key-profile-messages") == "0"
    end

    assert Rooms.read_key_thread!(@fleet, 12) == []

    # A removal is never undone: the database refuses to delete it, so the
    # post stays off the wall.
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Keyfleet.Repo.query("DELETE FROM keyfleet_app.wall_removals", [], mode: :savepoint)

    assert Rooms.read_key_thread!(@fleet, 12) == []
  end

  test "the key changing hands shows its new holder", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path <> "?key=12")
    assert text(view, "#key-profile-holder-address .rg-address__label") == "0xeeee..eeee"

    epoch!(12, 3, wallet("b"))
    keys_changed([12])

    assert text(view, "#key-profile-holder-address .rg-address__label") == "0xbbbb..bbbb"
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

  describe "the rewards waiting for the key" do
    test "are read once the window is open, which never waits for them", %{conn: conn} do
      test = self()

      rewards_answer(fn
        _to, @accrued <> _args, _block_hash ->
          send(test, {:reading, self()})

          receive do
            :answer -> {:ok, <<2_500_000::256>>}
          end

        _to, _data, _block_hash ->
          {:ok, <<0::256>>}
      end)

      assert conn |> get(@path <> "?key=12") |> html_response(200) =~ "Loading rewards"
      refute_received {:reading, _reader}

      {:ok, view, _html} = live(conn, @path <> "?key=12")
      assert_receive {:reading, reader}
      assert text(view, "#key-profile-rewards") == "Loading rewards"
      assert text(view, "#key-profile-holder-address .rg-address__label") == "0xeeee..eeee"

      send(reader, :answer)
      render_async(view)
      assert text(view, "#key-profile-rewards") == "2.5 USDC"
    end

    test "opening the key ten times within 30 seconds reads the chain once", %{conn: conn} do
      test = self()

      rewards_answer(fn
        to, @accrued <> _args, _block_hash ->
          send(test, {:read, to})
          {:ok, <<1_000_000::256>>}

        _to, _data, _block_hash ->
          {:ok, <<0::256>>}
      end)

      for _opening <- 1..10 do
        {:ok, view, _html} = live(conn, @path <> "?key=12")
        render_async(view)
        assert text(view, "#key-profile-rewards") == "1 USDC"
      end

      assert_received {:read, @rewards}
      refute_received {:read, _rewards}
    end

    test "a read that fails says so, and the rest of the window still works", %{conn: conn} do
      rewards_answer(fn _to, _data, _block_hash -> {:error, :chain_unavailable} end)
      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")

      render_async(view)

      assert text(view, "#key-profile-rewards") ==
               "Rewards aren’t showing right now. They update on their own."

      assert text(view, "#key-profile-holder-address .rg-address__label") == "0xeeee..eeee"

      view
      |> form("#key-profile-composer", post: %{body: "Hull survey started"})
      |> render_submit()

      assert has_element?(view, "#key-profile-thread li", "Hull survey started")
    end

    test "only the key on show takes its answer", %{conn: conn} do
      test = self()

      rewards_answer(fn
        _to, @accrued <> <<_usdc::binary-size(64), token_id::binary-size(64)>>, _block_hash ->
          token_id = rem(String.to_integer(token_id, 16), 10_000_000_000)
          send(test, {:reading, token_id, self()})

          receive do
            :answer -> {:ok, <<token_id * 1_000_000::256>>}
          end

        _to, _data, _block_hash ->
          {:ok, <<0::256>>}
      end)

      {:ok, view, _html} = live(conn, @path <> "?key=12")
      assert_receive {:reading, 12, key_12}
      view |> element("#key-profile-key-3") |> render_click()
      assert_receive {:reading, 3, key_3}

      finished = Process.monitor(key_12)
      send(key_12, :answer)
      assert_receive {:DOWN, ^finished, :process, _pid, _reason}
      assert text(view, "#key-profile-rewards") == "Loading rewards"

      send(key_3, :answer)
      render_async(view)
      assert text(view, "#key-profile-rewards") == "3 USDC"
    end
  end

  describe "the key's share of the Treasury slice" do
    test "a key minted under two days ago counts down to its first share, an older one is eligible",
         %{conn: conn} do
      young = DateTime.utc_now() |> DateTime.add(47 * 3600 + 120) |> DateTime.to_unix()
      matures = Call.encode("maturesAt(uint256)", [id(12)])

      rewards_answer(fn
        _to, ^matures, _hash -> {:ok, <<young::256>>}
        _to, _data, _hash -> {:ok, <<0::256>>}
      end)

      {:ok, view, _html} = live(conn, @path <> "?key=12")
      render_async(view)
      assert text(view, "#key-profile-slice") =~ ~r/^Eligible in 47:0[12]:\d\d$/

      view |> element("#key-profile-key-3") |> render_click()
      render_async(view)
      assert text(view, "#key-profile-slice") == "Eligible"
    end
  end

  # Key 20 is e's, and Your agent on its page shows the agent paired with e,
  # which acts for the Key once given a shard of it.
  test "a holder with no agent paired has no agent row on the Key's page", %{conn: conn} do
    {:ok, view, _html} = conn |> signed_in_as(wallet("e")) |> live(@key_20)

    assert has_element?(view, "#key-agent-setup[hidden]")
    refute has_element?(view, "#key-agent-setup .agent-setup__agent")
  end

  describe "Your agent on the Key's page" do
    # Signed in as e, with an agent paired with that account
    # (`PairingHelpers.pair!/2` pairs with the account named after the first
    # wallet).
    setup %{conn: conn} do
      did = "did:privy:test-" <> wallet("e")
      account = Accounts.register_verified!(did, wallet("e"), [wallet("e")], actor: @system)
      agent = PairingHelpers.agent_for!(Actors.Human.for_account(account))
      %{agent: agent, conn: init_test_session(conn, %{human_account_id: account.id})}
    end

    test "a newly paired agent has Paired done, and each other dot says what to do", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @key_20)
      render_async(view, 3_000)

      assert text(view, "#key-agent-setup .agent-setup__name") == "Test agent"
      {states, words} = Enum.unzip(dots(view))
      assert states == ~w(yes unknown no no no)

      assert words == [
               "Paired. This agent is paired with your account.",
               "Gas. Nothing to pay for until it acts for a Key. Give it a shard.",
               "Schedule. No daily run yet. Ask your agent to schedule one.",
               "Marked. It acts for no Key yet. Give it a shard.",
               "Repeated. Its daily run hasn’t come back on time yet. Check after its next run."
             ]
    end

    # Marked reads a Key waiting for its automatic start as needing no mark,
    # as the setup list's Present step does.
    test "every dot is done once the run repeats, the wallet has ETH and the Key waits to start",
         %{conn: conn, agent: agent} do
      ChainHelpers.issue_shard!(@fleet, 20, agent.wallet_address)
      scheduled!(@fleet, 20, DateTime.add(DateTime.utc_now(:second), 3_600))
      repeating!(agent)
      agent_chain!(balances: %{agent.wallet_address => 10 ** 18})

      {:ok, view, _html} = live(conn, @key_20)
      render_async(view, 3_000)

      {states, words} = Enum.unzip(dots(view))
      assert states == ~w(yes yes yes yes yes)

      assert words == [
               "Paired. This agent is paired with your account.",
               "Gas. Its wallet has the ETH on Base to mark your Keys.",
               "Schedule. Its daily run is scheduled.",
               "Marked. Every Key it acts for is present, or waits for its automatic start.",
               "Repeated. Its daily run keeps arriving on time."
             ]

      refute has_element?(view, "#key-agent-setup .agent-setup__wrong")
    end

    test "an agent out of ETH, acting for a Key that lapsed, says how to put each right", %{
      conn: conn,
      agent: agent
    } do
      ChainHelpers.issue_shard!(@fleet, 20, agent.wallet_address)
      presence!(@fleet, 20, DateTime.add(DateTime.utc_now(:second), -3, :day))
      agent_chain!(balances: %{agent.wallet_address => 0})

      {:ok, view, _html} = live(conn, @key_20)
      render_async(view, 3_000)

      assert [_paired, {"no", gas}, _schedule, {"no", marked}, _repeated] = dots(view)
      assert gas == "Gas. Its wallet is out of ETH. Send it ETH on Base."

      assert marked ==
               "Marked. A Key it acts for isn’t present. Ask your agent to mark it, or mark it yourself."
    end

    # The agent's check-in reaches the open page itself; the chain reader's
    # notice of the Key marked present is sent here by hand. Neither asks the
    # chain about gas again: its wallet empties here, and Gas stays as read.
    test "Schedule ticks as the agent checks in, and Marked as the Key is marked present", %{
      conn: conn,
      agent: agent
    } do
      ChainHelpers.issue_shard!(@fleet, 20, agent.wallet_address)
      agent_chain!(balances: %{agent.wallet_address => 10 ** 18})

      {:ok, view, _html} = live(conn, @key_20)
      render_async(view, 3_000)
      assert [_paired, {"yes", _gas}, {"no", _schedule}, {"no", _marked}, _repeated] = dots(view)

      agent_chain!(balances: %{agent.wallet_address => 0})
      run = %{"kind" => "scheduled", "every_minutes" => 1440}
      {:ok, _check_in} = Agents.check_in(agent, @fleet, run)
      render(view)
      render_async(view, 3_000)
      assert [_paired, {"yes", _gas}, {"yes", _schedule}, {"no", _marked}, _repeated] = dots(view)

      presence!(@fleet, 20, DateTime.utc_now(:second))
      send(view.pid, {:keys_present, @fleet, [20]})
      render(view)
      render_async(view, 3_000)

      assert [_paired, {"yes", _gas}, {"yes", _schedule}, {"yes", _marked}, _repeated] =
               dots(view)
    end

    test "Gas is not known when the chain doesn't answer, and says to look again", %{
      conn: conn,
      agent: agent
    } do
      ChainHelpers.issue_shard!(@fleet, 20, agent.wallet_address)
      agent_chain!(codes: %{agent.wallet_address => {:error, :timeout}})

      {:ok, view, _html} = live(conn, @key_20)
      render_async(view, 3_000)

      assert [_paired, gas | _rest] = dots(view)
      assert gas == {"unknown", "Gas. The chain didn’t answer. Reload in a minute."}
    end
  end

  # What the fleet's contracts answer, at a head the chain has. Its reward
  # ledger pays out `assets`, USDC alone unless a test names others; `chain`
  # adds to what the chain holds, such as `:balances`.
  defp rewards_answer(calls, assets \\ [@usdc], chain \\ []) do
    StubClient.put_chain(
      %{
        number: 1_000,
        hash: "0x" <> String.duplicate("c", 64),
        timestamp: DateTime.utc_now(),
        base_fee: 0
      },
      [],
      Keyword.put(chain, :calls, fn
        @rewards, @reward_assets, _hash ->
          {:ok, <<32::256, length(assets)::256>> <> Enum.map_join(assets, &address_word/1)}

        to, data, hash ->
          calls.(to, data, hash)
      end)
    )
  end

  # The chain as the setup gives it, holding what `chain` says for the
  # agent's wallet: its ETH, or the chain's answer for its code.
  defp agent_chain!(chain),
    do: rewards_answer(fn _to, _data, _hash -> {:ok, <<0::256>>} end, [@usdc], chain)

  # Two scheduled check-ins half an hour apart: the agent's run is scheduled,
  # confirmed and on time.
  defp repeating!(agent) do
    run = %{"kind" => "scheduled", "every_minutes" => 30}
    {:ok, _check_in} = Agents.check_in(agent, @fleet, run)

    Repo.query!(
      "UPDATE keyfleet_app.agent_check_ins SET last_scheduled_at = last_scheduled_at - interval '30 minutes', counted_scheduled_at = counted_scheduled_at - interval '30 minutes'"
    )

    {:ok, _check_in} = Agents.check_in(agent, @fleet, run)
  end

  # The agent's dots on the Key's page, each as its state and the words it opens.
  defp dots(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#key-agent-setup .agent-setup__states > li")
    |> Enum.map(fn dot ->
      [state] = LazyHTML.attribute(dot, "data-state")
      words = dot |> LazyHTML.query(".rg-tip-body") |> LazyHTML.text() |> String.split()
      {state, Enum.join(words, " ")}
    end)
  end

  defp address_word("0x" <> hex), do: <<0::96>> <> Base.decode16!(hex, case: :lower)

  # What the fleet answers for key 12's seed, which it has none of, for when
  # its request for a draw was accepted, whether that request's wait was
  # ended, and for its deck, which is set; anything else is zero.
  defp draw_answer(requested_at, opts \\ []) do
    seed = Call.encode("revealSeed(uint256)", [id(12)])
    requested = Call.encode("revealRequestedAt(uint256)", [id(12)])
    expired = Call.encode("revealExpired(uint256)", [id(12)])
    expired? = if Keyword.get(opts, :expired?, false), do: 1, else: 0
    record = Call.selector("fleet(uint256)")

    rewards_answer(fn
      _to, ^seed, _hash -> {:ok, <<0::256>>}
      _to, ^requested, _hash -> {:ok, <<requested_at::256>>}
      _to, ^expired, _hash -> {:ok, <<expired?::256>>}
      _to, ^record <> _fleet_id, _hash -> {:ok, <<0::256, 0::256, 1::256, 1::256, 1::256>>}
      _to, _data, _hash -> {:ok, <<0::256>>}
    end)
  end

  defp id(key), do: ChainHelpers.onchain_id(@fleet, key)

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
        Keyfleet.PubSub,
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

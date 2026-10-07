defmodule KeyfleetWeb.Live.KeyProfileTest do
  use KeyfleetWeb.ConnCase, async: false

  import Keyfleet.ProposalHelpers, only: [wallet: 1]

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Chain.RewardsWaiting
  alias Keyfleet.Chain.StubClient
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Traits
  alias RegentChain.Call

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @path "/app/fleets/fibonacci_cascade"
  @system %Actors.System{}
  @rewards "0x" <> String.duplicate("8", 40)

  # Key 12 was sold to a and passed to e, who also holds keys 3 and 20. Keys 1
  # to 20 are sold, so key 21 is the next on sale. No key has rewards waiting.
  setup do
    :ets.delete_all_objects(RewardsWaiting)
    rewards_answer(fn _to, _data, _block_hash -> {:ok, <<0::256>>} end)
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    deploy!()
    ChainHelpers.seed_cursor!(@fleet)

    for token_id <- 1..20, token_id not in [3, 12, 20], do: epoch!(token_id, 1, wallet("f"))
    epoch!(12, 1, wallet("a"))
    epoch!(12, 2, wallet("e"))
    epoch!(3, 1, wallet("e"))
    epoch!(20, 1, wallet("e"))

    # Agents have no registry listing unless a test says otherwise.
    Req.Test.stub(Keyfleet.AgentListing, fn conn ->
      Req.Test.json(conn, %{data: %{activity: [], agentRegistration: nil, agentBook: nil}})
    end)

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
    assert text(view, "#key-profile-holder") == "0xeeee..eeee"
    assert render(view) =~ "17.28 USDC"
    assert render(view) =~ "Once"
    assert text(view, "#key-profile-holder-keys") == "3"
    assert text(view, "#key-profile-holder-votes") == "0 votes on 0 proposals"
    assert text(view, "#key-profile-messages") == "0"
    assert has_element?(view, "#key-profile-key-3")
    assert has_element?(view, "#key-profile-key-20")
    refute has_element?(view, "#key-profile-manage")
  end

  test "an agent holding a shard of a key shows what its check-ins say, never what it says of itself",
       %{conn: conn} do
    runner = %Actors.Agent{
      wallet_address: wallet("c"),
      chain_id: 8_453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

    Agents.ensure_profile!(
      %{
        name: "Orbit runner",
        declared_harness: "Hermes Agent",
        current_status: "Check-ins working"
      },
      actor: runner
    )

    ChainHelpers.issue_shard!(@fleet, 12, runner.wallet_address)

    {:ok, view, _html} = live(conn, @path <> "?key=12")
    assert text(view, "#key-profile-check-in-#{wallet("c")}") == "Hasn’t checked in"

    # Two scheduled check-ins, half an hour apart.
    every_half_hour = %{"kind" => "scheduled", "every_minutes" => 30}
    {:ok, _first} = Agents.check_in(runner, @fleet, every_half_hour)

    Repo.query!("""
    UPDATE keyfleet_app.agent_check_ins SET
      last_check_in_at = last_check_in_at - interval '30 minutes',
      last_scheduled_at = last_scheduled_at - interval '30 minutes',
      counted_scheduled_at = counted_scheduled_at - interval '30 minutes'
    """)

    {:ok, _second} = Agents.check_in(runner, @fleet, every_half_hour)

    {:ok, view, _html} = live(conn, @path <> "?key=12")

    assert text(view, "#key-profile-check-in-#{wallet("c")}") ==
             "Check-ins working · last check-in just now · no contributions yet"
  end

  test "an agent holding a shard shows its registry listing and World ID mark, read live",
       %{conn: conn} do
    listed = wallet("c")
    plain = wallet("d")
    human_id = "0x" <> String.duplicate("7", 64)

    for {wallet, name} <- [{listed, "Orbit runner"}, {plain, "Plain runner"}] do
      Agents.ensure_profile!(%{name: name, declared_harness: "Hermes Agent"},
        actor: %Actors.Agent{
          wallet_address: wallet,
          chain_id: 8_453,
          verification_method: :eoa_recovery,
          audience: "keyfleet"
        }
      )

      ChainHelpers.issue_shard!(@fleet, 12, wallet)
    end

    Req.Test.stub(Keyfleet.AgentListing, fn conn ->
      assert conn.request_path == "/api/shared/siwa/activity"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer test-activity-read-token"
             ]

      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      %{"wallet_address" => wallet, "since" => _since} = Jason.decode!(raw)

      Req.Test.json(conn, %{
        data:
          if wallet == listed do
            %{
              activity: [],
              agentRegistration: %{
                agentId: "eip155:8453:0x8004A169FB4a3325136EB29fA0ceB6D2e539a432:97609",
                tokenId: "97609",
                profileUrl: "https://siwa.regents.sh/agents/registrations/1",
                registryUrl: "https://www.8004scan.io/agents/base/97609"
              },
              agentBook: %{humanId: human_id}
            }
          else
            %{activity: [], agentRegistration: nil, agentBook: nil}
          end
      })
    end)

    {:ok, view, _html} = live(conn, @path <> "?key=12")
    render_async(view)

    assert has_element?(
             view,
             "#key-profile-registry-#{listed}[href='https://www.8004scan.io/agents/base/97609']",
             "Registry listing"
           )

    assert has_element?(view, "#key-profile-human-#{listed}", "Human-backed (World ID)")
    refute has_element?(view, "#key-profile-registry-#{plain}")
    refute has_element?(view, "#key-profile-human-#{plain}")
    refute render(view) =~ human_id
  end

  # A status is only as honest as the time it is read at, so an open page
  # reads its agents' check-ins again as time moves on.
  test "an agent's status on an open page goes stale once time moves on", %{conn: conn} do
    runner = %Actors.Agent{
      wallet_address: wallet("c"),
      chain_id: 8_453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

    Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "Hermes Agent"},
      actor: runner
    )

    ChainHelpers.issue_shard!(@fleet, 12, runner.wallet_address)

    {:ok, _check_in} = Agents.check_in(runner, @fleet, %{"kind" => "session"})

    {:ok, view, _html} = live(conn, @path <> "?key=12")
    assert text(view, "#fleet-key-12") =~ "Orbit runner · Connected now"
    assert text(view, "#fleet-who-#{wallet("c")}") =~ "Connected now · last check-in just now"

    assert text(view, "#key-profile-check-in-#{wallet("c")}") =~
             "Connected now · last check-in just now"

    Repo.query!("""
    UPDATE keyfleet_app.agent_check_ins SET
      last_check_in_at = last_check_in_at - interval '3 minutes',
      last_session_at = last_session_at - interval '3 minutes'
    """)

    send(view.pid, :refresh_check_ins)

    assert text(view, "#fleet-key-12") =~ "Orbit runner · No scheduled check-ins"

    assert text(view, "#fleet-who-#{wallet("c")}") =~
             "No scheduled check-ins · last check-in 3 minutes ago"

    assert text(view, "#key-profile-check-in-#{wallet("c")}") =~
             "No scheduled check-ins · last check-in 3 minutes ago"
  end

  test "only a key the map can show opens", %{conn: conn} do
    for key <- ["0", "22", "twelve", "-1"] do
      {:ok, view, _html} = live(conn, @path <> "?key=" <> key)
      refute has_element?(view, "#key-profile")
    end

    {:ok, view, _html} = live(conn, @path <> "?key=21")
    assert has_element?(view, "#key-profile-buy[value='fleet-get-key']", "Buy key 21")
    refute has_element?(view, "#key-profile-composer")
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

  describe "claiming a key's income" do
    @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

    # Each token waiting for the key has its own Claim button, built on the
    # server for the holder's wallet and paid to it.
    test "the holder gets a Claim button for each token waiting, built for their wallet", %{
      conn: conn
    } do
      holder = wallet("e")
      reward_assets = Call.selector("rewardAssets()")

      rewards_answer(fn
        _to, ^reward_assets, _hash ->
          {:ok,
           <<32::256, 1::256, 0::96>> <>
             Base.decode16!(String.slice(@usdc, 2..-1//1), case: :lower)}

        _to, _accrued, _hash ->
          {:ok, <<2_500_000::256>>}
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
      assert claim.data == Call.encode("claim(address,uint256[],address)", [@usdc, [12], holder])
      assert text(view, "#key-profile-claim-#{@usdc}") == "Claim 2.5 USDC"

      assert text(view, "#key-profile-claim-action-line") ==
               "Waiting for this key: 2.5 USDC. Each token is claimed with its own button."
    end

    test "only the key's holder sees where to claim it", %{conn: conn} do
      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")
      refute has_element?(view, "#key-profile-claim")

      {:ok, view, _html} = live(conn, @path <> "?key=12")
      refute has_element?(view, "#key-profile-claim")
    end
  end

  describe "asking again for a key's draw" do
    @contract "0x" <> String.duplicate("7", 40)

    test "a key whose draw was turned down offers anyone Try again, built on the server",
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
        review: %{signer: ^signer, steps: [reveal]}
      })

      assert reveal.step == "reveal"
      assert reveal.to == @contract
      assert reveal.data == Call.encode("requestReveal(uint256)", [12])

      assert has_element?(view, "#key-profile-reveal-again[data-onchain-step='reveal']")
      refute has_element?(view, "#key-profile-reveal-again[phx-click]")
      assert text(view, "#key-profile-reveal-again") == "Try again"

      assert text(view, "#key-profile-reveal .key-profile-detail") ==
               "This key’s traits haven’t been drawn yet, because the request for its " <>
                 "random draw was turned down. Anyone can ask again."
    end

    test "Try again pressed as the wallet becomes active is answered with its step",
         %{conn: conn} do
      signer = wallet("f")
      draw_answer(0)

      {:ok, view, _html} = conn |> signed_in_as(signer) |> live(@path <> "?key=12")
      render_async(view)
      panel = with_target(view, "#key-profile-reveal-action")

      # The press reaches the server while the steps for the new wallet are
      # still being read: the first read from now on takes its time.
      reads = :atomics.new(1, [])
      seed = Call.encode("revealSeed(uint256)", [12])

      rewards_answer(fn
        _to, ^seed, _hash ->
          if :atomics.add_get(reads, 1, 1) == 1, do: Process.sleep(2_000)
          {:ok, <<0::256>>}

        _to, _data, _hash ->
          {:ok, <<0::256>>}
      end)

      render_hook(panel, "onchain_active_wallet", %{"address" => signer})
      render_hook(panel, "prepare_and_send", %{"form" => %{}, "step" => "reveal"})

      assert_reply(view, %{send: "reveal", review: %{signer: ^signer, steps: [%{step: "reveal"}]}})
    end

    test "a request that was accepted says the draw is on its way", %{conn: conn} do
      draw_answer(1_800_000_000)

      {:ok, view, _html} = conn |> signed_in_as(wallet("f")) |> live(@path <> "?key=12")
      render_async(view)

      refute has_element?(view, "#key-profile-reveal-again")

      assert text(view, "#key-profile-reveal-action-line") ==
               "The request for this key’s random draw was accepted. The draw is on its way, " <>
                 "and the key’s traits show here when it arrives."
    end

    test "shows while the key is revealing, and goes once its draw is recorded", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path <> "?key=12")

      assert text(view, "#key-profile-reveal-title") == "Drawing traits"
      refute has_element?(view, "#key-profile-reveal-again")

      assert text(view, "#key-profile-reveal .key-profile-detail") ==
               "This key’s traits are still being drawn. Sign in to ask again if its draw " <>
                 "was turned down."

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
      assert has_element?(view, "#key-profile-thread li", "Key 1")
      assert has_element?(view, "#key-profile-thread li .rooms-writer", "0xffff..ffff")
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
    assert text(view, "#key-profile-holder") == "0xeeee..eeee"

    epoch!(12, 3, wallet("b"))
    keys_changed([12])

    assert text(view, "#key-profile-holder") == "0xbbbb..bbbb"
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

      rewards_answer(fn _to, _data, _block_hash ->
        send(test, {:reading, self()})

        receive do
          :answer -> {:ok, <<2_500_000::256>>}
        end
      end)

      assert conn |> get(@path <> "?key=12") |> html_response(200) =~ "Reading…"
      refute_received {:reading, _reader}

      {:ok, view, _html} = live(conn, @path <> "?key=12")
      assert_receive {:reading, reader}
      assert text(view, "#key-profile-rewards") == "Reading…"
      assert text(view, "#key-profile-holder") == "0xeeee..eeee"

      send(reader, :answer)
      render_async(view)
      assert text(view, "#key-profile-rewards") == "2.5 USDC"
    end

    test "opening the key ten times within 30 seconds reads the chain once", %{conn: conn} do
      test = self()

      rewards_answer(fn to, _data, _block_hash ->
        send(test, {:read, to})
        {:ok, <<1_000_000::256>>}
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
      assert text(view, "#key-profile-rewards") == "Couldn’t read rewards right now."
      assert text(view, "#key-profile-holder") == "0xeeee..eeee"

      view
      |> form("#key-profile-composer", post: %{body: "Hull survey started"})
      |> render_submit()

      assert has_element?(view, "#key-profile-thread li", "Hull survey started")
    end

    test "only the key on show takes its answer", %{conn: conn} do
      test = self()

      rewards_answer(fn _to,
                        <<_accrued_usdc::binary-size(74), token_id::binary-size(64)>>,
                        _block_hash ->
        token_id = String.to_integer(token_id, 16)
        send(test, {:reading, token_id, self()})

        receive do
          :answer -> {:ok, <<token_id * 1_000_000::256>>}
        end
      end)

      {:ok, view, _html} = live(conn, @path <> "?key=12")
      assert_receive {:reading, 12, key_12}
      view |> element("#key-profile-key-3") |> render_click()
      assert_receive {:reading, 3, key_3}

      finished = Process.monitor(key_12)
      send(key_12, :answer)
      assert_receive {:DOWN, ^finished, :process, _pid, _reason}
      assert text(view, "#key-profile-rewards") == "Reading…"

      send(key_3, :answer)
      render_async(view)
      assert text(view, "#key-profile-rewards") == "3 USDC"
    end
  end

  # What the fleet's rewards contract answers, at a head the chain has.
  defp rewards_answer(calls) do
    StubClient.put_chain(
      %{number: 1_000, hash: "0x" <> String.duplicate("c", 64), timestamp: DateTime.utc_now()},
      [],
      calls: calls
    )
  end

  # What the fleet answers for key 12's seed, which it has none of, and for
  # when its request for a draw was accepted; anything else is zero.
  defp draw_answer(requested_at) do
    seed = Call.encode("revealSeed(uint256)", [12])
    requested = Call.encode("revealRequestedAt(uint256)", [12])

    rewards_answer(fn
      _to, ^seed, _hash -> {:ok, <<0::256>>}
      _to, ^requested, _hash -> {:ok, <<requested_at::256>>}
      _to, _data, _hash -> {:ok, <<0::256>>}
    end)
  end

  defp deploy! do
    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8453,
        contract_address: "0x" <> String.duplicate("7", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        treasury_address: "0x" <> String.duplicate("7e", 20),
        shards_address: "0x" <> String.duplicate("6", 40),
        regent_address: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
        regent_staking_address: "0xb027dc261636e30cbc0fe25b2f8e1ed273354ab5",
        autolaunch_factory_address: "0xf4f591e63f4b6d8240a150081c1ca7edfaeb768e",
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: 1,
        trait_table_hash: "0x1249d615f793a311bcb27def92766224fb544df85aa74359a785a6349df18610"
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

defmodule Keyfleet.KeyProfileTest do
  use ExUnit.Case, async: false

  import Keyfleet.ProposalHelpers, only: [proposal!: 2, vote!: 5, wallet: 1]
  import Keyfleet.QueryHelpers, only: [queries_during: 1]

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Profile
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.Traits

  # Other suites commit Syndicate keys outside the sandbox; Cascade holds only
  # the keys each test issues.
  @fleet "fibonacci_cascade"
  @elsewhere "fleet_tech_accelerant"
  @system %Actors.System{}
  # keccak256 of the fixture table in test/support/fixtures/trait_tables.
  @table_hash "0x1249d615f793a311bcb27def92766224fb544df85aa74359a785a6349df18610"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    deploy!(@fleet)
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.seed_cursor!(@elsewhere)
    :ok
  end

  # Key 12 is sold to a, passes to b, who posts three times as it in a room
  # and once in key 3's thread, and then to the holder e, who holds keys 3 and
  # 20 here and key 1 of another fleet.
  describe "a key bought, passed on twice, voted with and posted as" do
    setup do
      holder = wallet("e")
      epoch!(@fleet, 12, 1, wallet("a"))
      epoch!(@fleet, 12, 2, wallet("b"))
      epoch!(@fleet, 3, 1, holder)
      for body <- ["One", "Two", "Three"], do: post!(human("b"), "general", body)
      to_key!(human("b"), 3, "Hello, three")
      received = epoch!(@fleet, 12, 3, holder)
      epoch!(@fleet, 20, 1, holder)
      epoch!(@elsewhere, 1, 1, holder)

      # The holder posts in a room and in key 12's thread, as key 3, their highest.
      post!(human("e"), "general", "Four")
      to_key!(human("e"), 12, "Hello, twelve")

      proposal!(@fleet, 1)
      proposal!(@fleet, 2)
      vote!(@fleet, 1, holder, true, [3, 12])
      vote!(@fleet, 2, holder, false, [12])
      # A withdrawal is not a vote cast.
      vote!(@fleet, 2, holder, nil, [12])
      # Other keys' votes, and key 12 of another fleet, are not key 12's.
      vote!(@fleet, 1, wallet("b"), true, [120])
      ChainHelpers.seed_cursor!("fibonacci_syndicate")
      proposal!("fibonacci_syndicate", 1)
      vote!("fibonacci_syndicate", 1, holder, true, [12])

      runner = %Actors.Agent{wallet_address: wallet("c"), chain_id: 8_453, audience: "keyfleet"}

      profile =
        Agents.ensure_profile!(%{name: "Orbit runner", declared_harness: "hermes"}, actor: runner)

      Agents.edit_my_profile!(profile, %{current_status: "Surveying hulls"}, actor: runner)
      request = Keys.request_pairing!(@fleet, 12, %{}, actor: runner)
      Keys.approve_pairing!(request, Keys.default_limits(), actor: human("e"))

      reveal!(12, Traits.keccak256("golden-1"))
      %{received: received}
    end

    test "shows every figure about the key and its holder", %{received: received} do
      profile = Profile.read(@fleet, 12, human("e"))

      assert %{
               issued?: true,
               token_id: 12,
               level: 4,
               issue_price: 17_280_000,
               holder: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
               yours?: true,
               changed_hands: 2,
               votes_cast: 2,
               posts: 3,
               messages: 1,
               holder_keys: [3, 12, 20],
               holder_key_count: 3,
               holder_keys_everywhere: 4,
               holder_votes: 3,
               holder_proposals: 2,
               holder_posts: 1,
               composer: :write
             } = profile

      assert profile.held_since == received.observed_at

      assert profile.traits == [
               %{trait: "Hull", value: "Steel", share: 0.3},
               %{trait: "Sky", value: "Noon", share: 1 / 3},
               %{trait: "Mark", value: "Star", share: 0.9}
             ]

      assert %{
               name: "Orbit runner",
               harness: "hermes",
               status: "Surveying hulls",
               status_updated_at: %DateTime{}
             } = profile.operator

      assert Enum.map(profile.recent_posts, & &1.body) == ["Three", "Two", "One"]
      assert Enum.map(profile.thread, &{&1.body, &1.as_key}) == [{"Hello, twelve", 3}]
      assert profile.last_seq == 1
    end

    test "tells a visitor, a stranger and a holder waiting on key ownership who may write" do
      assert %{yours?: false, composer: :sign_in} = Profile.read(@fleet, 12, nil)
      assert %{yours?: false, composer: :no_key} = Profile.read(@fleet, 12, human("9"))
      # Holding any of the fleet's keys is enough to write to every key.
      epoch!(@fleet, 5, 1, wallet("a"))
      assert %{yours?: false, composer: :write} = Profile.read(@fleet, 12, human("a"))

      ChainHelpers.seed_cursor!(@fleet, head_block: 5_000, next_block: 1_000)
      assert %{composer: :refreshing} = Profile.read(@fleet, 12, human("e"))
    end
  end

  test "tells whether a wallet has held any of some keys, then or now" do
    epoch!(@fleet, 7, 1, wallet("a"))
    epoch!(@fleet, 7, 2, wallet("b"))
    epoch!(@fleet, 8, 1, wallet("c"))

    assert Profile.held_any?(@fleet, wallet("a"), [7, 8])
    assert Profile.held_any?(@fleet, wallet("b"), [7])
    refute Profile.held_any?(@fleet, wallet("a"), [8, 9])
    refute Profile.held_any?(@elsewhere, wallet("a"), [7])
    refute Profile.held_any?(@fleet, wallet("a"), [])
  end

  test "a key still revealing, run by nobody and never written to" do
    epoch!(@fleet, 4, 1, wallet("a"))

    assert %{
             traits: nil,
             operator: nil,
             changed_hands: 0,
             votes_cast: 0,
             posts: 0,
             messages: 0,
             thread: [],
             last_seq: 0,
             recent_posts: [],
             holder_votes: 0,
             holder_proposals: 0,
             holder_posts: 0
           } = Profile.read(@fleet, 4, nil)
  end

  test "the next key on sale has only its number, level and price" do
    epoch!(@fleet, 1, 1, wallet("a"))

    assert Profile.read(@fleet, 2, nil) == %{
             fleet_id: @fleet,
             token_id: 2,
             issued?: false,
             level: 1,
             issue_price: 10_000_000
           }
  end

  # A holder's keys are listed a hundred at a time and counted, so opening a
  # key reads as much for a holder of a hundred keys as for a holder of one.
  test "opening a key takes the same reads however many keys its holder has" do
    for token_id <- 1..100, do: epoch!(@fleet, token_id, 1, wallet("a"))
    epoch!(@fleet, 101, 1, wallet("b"))

    {many, profile} = queries_during(fn -> Profile.read(@fleet, 50, human("a")) end)
    assert profile.holder_keys == Enum.to_list(1..100)
    assert profile.holder_key_count == 100

    {one, profile} = queries_during(fn -> Profile.read(@fleet, 101, human("a")) end)
    assert profile.holder_keys == [101]

    assert one == many
  end

  test "a holder's list stops at a hundred keys and counts the rest" do
    for token_id <- 1..103, do: epoch!(@fleet, token_id, 1, wallet("a"))

    assert %{holder_keys: listed, holder_key_count: 103} = Profile.read(@fleet, 103, nil)
    assert listed == Enum.to_list(1..100)
  end

  defp deploy!(fleet_id) do
    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 1,
        contract_address: "0x" <> String.duplicate("7", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        shards_address: "0x" <> String.duplicate("6", 40),
        usdc_address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        deployed_block: 1,
        trait_table_hash: @table_hash
      },
      actor: @system
    )
  end

  defp epoch!(fleet_id, token_id, epoch, owner) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: epoch,
        owner_wallet: owner,
        block_number: 10 + epoch,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: Traits.keccak256("#{fleet_id}/#{token_id}/#{epoch}"),
        log_index: 0
      },
      actor: @system
    )
  end

  defp reveal!(token_id, seed) do
    Keys.record_reveal!(
      %{
        fleet_id: @fleet,
        token_id: token_id,
        request_id: 7,
        seed: seed,
        block_number: 12,
        block_hash: "0x" <> String.duplicate("c", 64),
        transaction_hash: Traits.keccak256("#{@fleet}/#{token_id}/reveal"),
        log_index: 0
      },
      actor: @system
    )
  end

  defp post!(actor, slug, body) do
    Rooms.send_message!(
      %{fleet_id: @fleet, slug: slug, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp to_key!(actor, token_id, body) do
    Rooms.send_to_key!(
      %{fleet_id: @fleet, token_id: token_id, body: body, idempotency_key: Ash.UUID.generate()},
      actor: actor
    )
  end

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}
end

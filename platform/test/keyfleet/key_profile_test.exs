defmodule Keyfleet.KeyProfileTest do
  use ExUnit.Case, async: false

  import Keyfleet.ProposalHelpers, only: [wallet: 1]
  import Keyfleet.QueryHelpers, only: [queries_during: 1]

  alias Keyfleet.Actors
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
    ChainHelpers.deploy!(@fleet, %{trait_table_hash: @table_hash})
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.seed_cursor!(@elsewhere)
    :ok
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

  test "a key still revealing, with no shards and never written to" do
    epoch!(@fleet, 4, 1, wallet("a"))

    assert %{
             traits: nil,
             draw_ended?: false,
             shards: [],
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

  test "the next key on sale has only its number, picture, level and price" do
    epoch!(@fleet, 1, 1, wallet("a"))

    assert Profile.read(@fleet, 2, nil) == %{
             fleet_id: @fleet,
             token_id: 2,
             issued?: false,
             image:
               "https://media.regents.sh/ipfs/QmddjWKS43UPY3V1muZJGVx8zkpxCUXwmsy29heg1qNETy",
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

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}
end

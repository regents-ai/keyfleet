defmodule Keyfleet.ChainHelpers do
  @moduledoc """
  Puts a fleet's chain reading into a known state, fresh unless told otherwise.

  Anything that grants authority from holding a key refuses while ownership is
  not fresh, so every test that exercises that authority seeds a fresh reading
  through here first.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Fleet
  alias Keyfleet.Keys

  @head_hash "0x" <> String.duplicate("c", 64)
  # test/support/fixtures/decks: one card, the seed keccak256("golden-1"),
  # drawing from the fixture trait table.
  @deck_hash "0xf11579d3bd868d9a111bc512d814d04c0f10beb44fba7f3a92fa26eb67500356"

  @doc """
  The whole deployment on Base of `fleet_id`, as `record_deployment` takes
  it, with `overrides` in place of any of its fields. Each fleet is numbered
  by its place in the catalog and gets contracts of its own; every fleet
  shares the one Key collection, shard record, USDC, REGENT, staking
  contract, Autolaunch factory and trait table. Its deck is the one-card
  fixture deck, so Key 1 is dealt that card and every later Key draws its
  own.
  """
  def deployment(fleet_id, overrides \\ %{}) do
    digit = Integer.to_string(chain_fleet_id(fleet_id) - 1)

    Map.merge(
      %{
        chain_id: 8453,
        chain_fleet_id: chain_fleet_id(fleet_id),
        keys_address: "0x" <> String.duplicate("a1", 20),
        manager_address: "0x" <> String.duplicate("c" <> digit, 20),
        rewards_address: "0x" <> String.duplicate("d" <> digit, 20),
        votes_address: "0x" <> String.duplicate("e" <> digit, 20),
        treasury_address: "0x" <> String.duplicate("b" <> digit, 20),
        shards_address: "0x" <> String.duplicate("f1", 20),
        deck_hash: @deck_hash,
        deck_size: 1,
        regent_address: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
        regent_staking_address: "0xb027dc261636e30cbc0fe25b2f8e1ed273354ab5",
        autolaunch_factory_address: "0xf4f591e63f4b6d8240a150081c1ca7edfaeb768e",
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      Map.new(overrides)
    )
  end

  @doc """
  Records `deployment/2` of `fleet_id`, which opens a fleet the catalog shows
  as coming soon.
  """
  def deploy!(fleet_id, overrides \\ %{}) do
    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(deployment(fleet_id, overrides), actor: %System{})
  end

  @doc "The fleet's number in the Key collection, as `deployment/2` gives it."
  def chain_fleet_id(fleet_id),
    do: Enum.find_index(Fleets.catalog_ids(), &(&1 == fleet_id)) + 1

  @doc "The chain's token id of the fleet's Key `key`, as `deployment/2` numbers the fleet."
  def onchain_id(fleet_id, key),
    do: Fleet.onchain_token_id(%{chain_fleet_id: chain_fleet_id(fleet_id)}, key)

  @doc """
  A fleet's cursor opened and not yet read, as the chain reader keeps it
  before it records anything for the fleet.
  """
  def open_cursor!(fleet_id),
    do: Chain.open_cursor!(%{fleet_id: fleet_id, next_block: 0}, actor: %System{})

  @doc """
  A fleet's cursor read up to block 1_000 just now; `attrs` overrides any of
  `next_block`, `head_block`, `observed_at` and `rescan_from`.
  """
  def seed_cursor!(fleet_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {rescan_from, advance} = Map.pop(attrs, :rescan_from)

    {:ok, cursor} =
      %{fleet_id: fleet_id, next_block: 0}
      |> Chain.open_cursor!(actor: %System{})
      |> Chain.advance_cursor(
        Map.merge(
          %{
            next_block: 1_001,
            head_block: 1_000,
            head_block_hash: @head_hash,
            observed_at: DateTime.utc_now()
          },
          advance
        )
      )

    case rescan_from do
      nil -> cursor
      block -> Chain.flag_divergence!(cursor, %{block: block}, actor: %System{})
    end
  end

  @doc """
  Records key `token_id`'s owner issuing a shard to `wallet` for `days` from
  now, under the key's current ownership record, as the chain reader would.
  The fleet's cursor must be open.
  """
  def issue_shard!(fleet_id, token_id, wallet, days \\ 30) do
    %{ownership_epoch: epoch} = Keys.current_key!(fleet_id, token_id)

    shard_event!(fleet_id, token_id, wallet, %{
      kind: :issued,
      expires_at: DateTime.add(DateTime.utc_now(:second), days, :day),
      ownership_epoch: epoch
    })
  end

  @doc "Records the shard of key `token_id` held by `wallet` ended by `ended_by`."
  def end_shard!(fleet_id, token_id, wallet, ended_by),
    do: shard_event!(fleet_id, token_id, wallet, %{kind: :ended, ended_by: ended_by})

  defp shard_event!(fleet_id, token_id, wallet, attrs) do
    Keys.record_shard_event!(
      Map.merge(
        %{
          fleet_id: fleet_id,
          token_id: token_id,
          wallet: wallet,
          block_number: 1_000,
          block_hash: @head_hash,
          transaction_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
          log_index: 0
        },
        attrs
      ),
      actor: %System{}
    )
  end
end

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

  @head_hash "0x" <> String.duplicate("c", 64)

  @doc """
  Records a deployment on Ethereum for `fleet_id`, which opens a fleet the
  catalog shows as coming soon. Each fleet gets contract addresses of its own.
  """
  def deploy!(fleet_id) do
    digit = Fleets.catalog_ids() |> Enum.find_index(&(&1 == fleet_id)) |> Integer.to_string()

    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 1,
        contract_address: "0x" <> String.duplicate("c" <> digit, 20),
        rewards_address: "0x" <> String.duplicate("d" <> digit, 20),
        votes_address: "0x" <> String.duplicate("e" <> digit, 20),
        shards_address: "0x" <> String.duplicate("f" <> digit, 20),
        usdc_address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %System{}
    )
  end

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
end

defmodule KeyFleet.ChainHelpers do
  @moduledoc """
  Puts a fleet's chain reading into a known state, fresh unless told otherwise.

  Anything that grants authority from holding a key refuses while ownership is
  not fresh, so every test that exercises that authority seeds a fresh reading
  through here first.
  """

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain

  @head_hash "0x" <> String.duplicate("c", 64)

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

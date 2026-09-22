defmodule KeyFleet.Chain do
  @moduledoc """
  What the site knows about each fleet from its contracts: how far its key
  history has been read, whether that reading is fresh enough to act on, and
  how far the fleet has sold.
  """
  use Ash.Domain

  alias KeyFleet.Actors.System
  alias KeyFleet.Fleets.Presets
  alias KeyFleet.Keys.KeyAttachment

  resources do
    resource KeyFleet.Chain.Cursor do
      define :open_cursor, action: :open
      define :fresh_cursor, action: :fresh, args: [:fleet_id], not_found_error?: false
      define :get_cursor, action: :read, get_by: [:fleet_id], not_found_error?: false
      define :advance_cursor, action: :advance
      define :flag_divergence, action: :flag_divergence
      define :clear_cursor_divergence, action: :clear_divergence
    end
  end

  @doc """
  Whether the fleet's key ownership was read recently enough to act on.

  Anything that grants authority from holding a key asks this first and
  refuses when the answer is no. Reading pages never does.
  """
  def fresh?(fleet_id), do: fresh_cursor!(fleet_id) != nil

  @doc "The fleet's sales so far and what its next key costs, in atomic USDC."
  def progress(fleet_id) do
    minted =
      KeyAttachment
      |> Ash.Query.for_read(:current_in_fleet, %{fleet_id: fleet_id})
      |> Ash.count!()

    Presets.progress(fleet_id, minted)
  end

  @doc """
  Lets a fleet stopped at a disagreement with the chain be read again, from
  wherever its cursor now stands.
  """
  def clear_divergence!(fleet_id) do
    case get_cursor!(fleet_id) do
      nil ->
        raise ArgumentError, "#{fleet_id} has no reading on record, so there is no stop to clear"

      cursor ->
        clear_cursor_divergence!(cursor, %{}, actor: %System{})
    end
  end
end

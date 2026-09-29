defmodule Keyfleet.Keys.Errors.OwnershipRefreshingError do
  @moduledoc "Raised when a fleet's key ownership is not fresh enough to act on."
  use Splode.Error, fields: [:fleet_id], class: :forbidden

  def message(%{fleet_id: fleet_id}),
    do: "key ownership in #{fleet_id} is being refreshed; try again in a moment"
end

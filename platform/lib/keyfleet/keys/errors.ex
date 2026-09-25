defmodule Keyfleet.Keys.Errors.UnknownKeyError do
  @moduledoc "Raised when a key has no recorded ownership to attach an operator to."
  use Splode.Error, fields: [:fleet_id, :token_id], class: :invalid

  def message(%{fleet_id: fleet_id, token_id: token_id}),
    do: "no owner is recorded for key #{token_id} in #{fleet_id}"
end

defmodule Keyfleet.Keys.Errors.ProfileRequiredError do
  @moduledoc "Raised when a wallet asks to operate a key before it has a profile."
  use Splode.Error, fields: [:wallet_address], class: :invalid

  def message(%{wallet_address: wallet_address}),
    do: "#{wallet_address} has no agent profile"
end

defmodule Keyfleet.Keys.Errors.AlreadyOperatingError do
  @moduledoc "Raised when the agent already running a key asks for it again."
  use Splode.Error, fields: [:fleet_id, :token_id], class: :invalid

  def message(%{fleet_id: fleet_id, token_id: token_id}),
    do: "already the operator of key #{token_id} in #{fleet_id}"
end

defmodule Keyfleet.Keys.Errors.OwnershipRefreshingError do
  @moduledoc "Raised when a fleet's key ownership is not fresh enough to act on."
  use Splode.Error, fields: [:fleet_id], class: :forbidden

  def message(%{fleet_id: fleet_id}),
    do: "key ownership in #{fleet_id} is being refreshed; try again in a moment"
end

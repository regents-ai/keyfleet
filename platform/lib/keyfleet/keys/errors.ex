defmodule Keyfleet.Keys.Errors.OwnershipRefreshingError do
  @moduledoc "Raised when a fleet's key ownership is not fresh enough to act on."
  use Splode.Error, fields: [:fleet_id], class: :forbidden

  def message(%{fleet_id: fleet_id}),
    do: "Key ownership in #{fleet_id} is being refreshed; try again in a moment"
end

defmodule Keyfleet.Keys.Errors.KeyNotHeldError do
  @moduledoc "Raised when a person chooses to write as a Key their wallets don't hold now."
  use Splode.Error, fields: [:fleet_id, :token_id], class: :invalid

  def message(%{fleet_id: fleet_id, token_id: token_id}),
    do: "Your wallets don't hold Key #{token_id} of #{fleet_id}"
end

defmodule Keyfleet.Keys.Errors.AgentUnknownError do
  @moduledoc """
  Raised when an agent is put on a Key by a wallet that no agent paired with
  the person has now.
  """
  use Splode.Error, fields: [:wallet], class: :invalid

  def message(%{wallet: wallet}), do: "No agent paired with this person has the wallet #{wallet}"
end

defmodule Keyfleet.Keys.Errors.NotPairedError do
  @moduledoc """
  Raised when an agent putting an agent on a Key is no longer paired with the
  person it spoke for.
  """
  use Splode.Error, fields: [], class: :forbidden

  def message(_error), do: "This agent is no longer paired with its person"
end

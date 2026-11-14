defmodule Keyfleet.Fundings.Errors.ServiceFailed do
  @moduledoc "Raised when the NEAR Intents service refuses or can't be reached."
  use Splode.Error, fields: [:reason, :message], class: :invalid

  def message(%{message: message}), do: "the NEAR Intents service answered: #{message}"
end

defmodule Keyfleet.Fundings.Errors.NotLive do
  @moduledoc "Raised when a fleet is not on chain yet, so it has no treasury to fund."
  use Splode.Error, fields: [:fleet_id], class: :invalid

  def message(%{fleet_id: fleet_id}), do: "fleet #{fleet_id} has no treasury yet"
end

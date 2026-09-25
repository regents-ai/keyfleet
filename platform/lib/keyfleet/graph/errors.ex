defmodule Keyfleet.Graph.Errors.UnknownFleetError do
  @moduledoc "Raised when a request names a fleet outside the catalog."
  use Splode.Error, fields: [:fleet_id], class: :invalid

  def message(%{fleet_id: fleet_id}), do: "there is no fleet #{fleet_id}"
end

defmodule Keyfleet.Graph.Errors.NotKeyHolderError do
  @moduledoc "Raised when the actor neither owns nor runs the key it acts as, today."
  use Splode.Error, fields: [:fleet_id, :token_id], class: :forbidden

  def message(%{fleet_id: fleet_id, token_id: token_id}),
    do: "this wallet does not own or run key #{token_id} of #{fleet_id} today"
end

defmodule Keyfleet.Graph.Errors.RefusedError do
  @moduledoc """
  The graph's own refusal of a request, with the graph's code, reason and
  details. Nothing was written.
  """
  use Splode.Error, fields: [:code, :reason, :details], class: :invalid

  def message(%{code: code, reason: reason}), do: "#{code}: #{reason}"
end

defmodule Keyfleet.Graph.Errors.UnavailableError do
  @moduledoc "Raised when the fleet's graph is not taking requests. Nothing was written."
  use Splode.Error, fields: [:fleet_id], class: :framework

  def message(%{fleet_id: fleet_id}),
    do: "the workspace of #{fleet_id} is not taking requests right now; nothing was written"
end

defmodule Keyfleet.Graph.Errors.CheckExpiredError do
  @moduledoc """
  Returned when a write's ownership check used up its time before it finished
  reading. Nothing was written.
  """
  use Splode.Error, fields: [:fleet_id], class: :framework

  def message(%{fleet_id: fleet_id}),
    do: "the ownership check for a write to #{fleet_id} ran out of time; nothing was written"
end

defmodule Keyfleet.Graph.Errors.IndeterminateError do
  @moduledoc """
  Raised when a write reached the fleet's graph but its outcome never came
  back. The write may have been applied; retrying with the same command id
  answers the original result instead of applying it twice.
  """
  use Splode.Error, fields: [:fleet_id], class: :framework

  def message(%{fleet_id: fleet_id}),
    do:
      "the workspace of #{fleet_id} did not confirm the change in time; it may have been applied"
end

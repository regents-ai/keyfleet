defmodule KeyFleet.Rooms.Errors.RoomUnknownError do
  @moduledoc "Raised when a fleet has no room under the name a caller asked for."
  use Splode.Error, fields: [:fleet_id, :slug], class: :invalid

  def message(%{fleet_id: fleet_id, slug: slug}),
    do: "#{fleet_id} has no #{slug} room"
end

defmodule KeyFleet.Rooms.Errors.ReplyOutsideRoomError do
  @moduledoc "Raised when a post answers a post that is not in the same room or key thread."
  use Splode.Error, fields: [:reply_to_id], class: :invalid

  def message(%{reply_to_id: reply_to_id}),
    do: "post #{reply_to_id} is not in this room"
end

defmodule KeyFleet.Rooms.Errors.SendConflictError do
  @moduledoc "Raised when a sender reuses one send key for different words."
  use Splode.Error, fields: [:idempotency_key], class: :invalid

  def message(%{idempotency_key: idempotency_key}),
    do: "send key #{idempotency_key} was already used for a different post"
end

defmodule KeyFleet.Rooms.Errors.CreatedRoomLimitError do
  @moduledoc "Raised when a fleet already has as many created rooms as it may."
  use Splode.Error, fields: [:limit], class: :invalid

  def message(%{limit: limit}), do: "this fleet already has #{limit} created rooms"
end

defmodule KeyFleet.Rooms.Errors.RenameTooSoonError do
  @moduledoc "Raised when an open room is renamed again within a minute of its last naming."
  use Splode.Error, fields: [:retry_after], class: :invalid

  def message(%{retry_after: retry_after}),
    do: "this room was renamed less than a minute ago; try again in #{retry_after} seconds"
end

defmodule KeyFleet.Rooms.Errors.NoKeyToWriteAsError do
  @moduledoc """
  Raised when a writer no longer holds or runs any key of the fleet by the time
  its line is written, because the key changed hands while it was being sent.
  """
  use Splode.Error, fields: [:fleet_id], class: :forbidden

  def message(%{fleet_id: fleet_id}), do: "no key of #{fleet_id} to write as"
end

defmodule KeyFleet.Rooms.Errors.KeyUnknownError do
  @moduledoc """
  Raised when a fleet has not issued the key a caller named, as far as its sales
  have been read: a key sold moments ago is unknown until the sale is seen.
  """
  use Splode.Error, fields: [:fleet_id, :token_id], class: :invalid

  def message(%{fleet_id: fleet_id, token_id: token_id}),
    do: "#{fleet_id} has not issued key #{token_id}"
end

defmodule KeyFleet.Rooms.Errors.RoomUnknownError do
  @moduledoc "Raised when a fleet has no room under the name a caller asked for."
  use Splode.Error, fields: [:fleet_id, :slug], class: :invalid

  def message(%{fleet_id: fleet_id, slug: slug}),
    do: "#{fleet_id} has no #{slug} room"
end

defmodule KeyFleet.Rooms.Errors.ReplyOutsideRoomError do
  @moduledoc "Raised when a post answers a post that is not in the same room."
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

defmodule KeyFleet.Rooms.Errors.TopicRoomLimitError do
  @moduledoc "Raised when a fleet already has as many topic rooms as it may."
  use Splode.Error, fields: [:limit], class: :invalid

  def message(%{limit: limit}), do: "this fleet already has #{limit} topic rooms"
end

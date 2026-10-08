defmodule Keyfleet.Polls.Errors.SessionUnknownError do
  @moduledoc "Raised when a fleet has no poll session with the id a caller named."
  use Splode.Error, fields: [:session_id], class: :invalid

  def message(%{session_id: session_id}), do: "no poll session #{session_id} in this fleet"
end

defmodule Keyfleet.Polls.Errors.SessionEndedError do
  @moduledoc "Raised when a seat or round is asked of a session that has ended or run out of time."
  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "this poll session has ended"
end

defmodule Keyfleet.Polls.Errors.DelegateStaysError do
  @moduledoc "Raised when the delegate's Key tries to leave the session it runs."
  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "the delegate's Key ends the session instead of leaving it"
end

defmodule Keyfleet.Polls.Errors.RoundOpenError do
  @moduledoc "Raised when a round is opened while the session's last round is still open."
  use Splode.Error, fields: [:number], class: :invalid

  def message(%{number: number}), do: "round #{number} is still open"
end

defmodule Keyfleet.Polls.Errors.RoundUnknownError do
  @moduledoc "Raised when a session has no round with the number a caller named."
  use Splode.Error, fields: [:number], class: :invalid

  def message(%{number: number}), do: "this session has no round #{number}"
end

defmodule Keyfleet.Polls.Errors.RoundClosedError do
  @moduledoc "Raised when a vote arrives after its round has closed or passed its deadline."
  use Splode.Error, fields: [:number], class: :invalid

  def message(%{number: number}), do: "round #{number} has closed"
end

defmodule Keyfleet.Polls.Errors.NotInRoundError do
  @moduledoc """
  Raised when a Key votes in a round it has no vote in: it was not seated when
  the round opened, or has left the session since.
  """
  use Splode.Error, fields: [:number], class: :forbidden

  def message(%{number: number}), do: "this Key has no vote in round #{number}"
end

defmodule Keyfleet.Polls.Errors.ActionUnknownError do
  @moduledoc "Raised when a vote names a move its round did not offer."
  use Splode.Error, fields: [:action], class: :invalid

  def message(%{action: action}), do: "this round offers no move #{action}"
end

defmodule Keyfleet.Polls.Errors.VoteConflictError do
  @moduledoc "Raised when a Key that already voted in a round sends a different move."
  use Splode.Error, fields: [:number], class: :invalid

  def message(%{number: number}), do: "this Key already voted differently in round #{number}"
end

defmodule Keyfleet.Polls.Errors.AlreadyClosedError do
  @moduledoc "Raised when a round that has already closed is closed again."
  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "this round has already closed"
end

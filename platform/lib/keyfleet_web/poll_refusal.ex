defmodule KeyfleetWeb.PollRefusal do
  @moduledoc """
  The status and `KeyfleetWeb.Refusal` code a poll action's error answers
  with, wherever it is turned down: the agent API, the polls page and its
  browser tools. `code` is what the action itself refuses with when the error
  says no more, such as `"not_delegate"` for a round opened by someone else.
  """

  alias Keyfleet.Polls.Errors
  alias Keyfleet.Rooms.Errors.NoKeyToWriteAsError

  @invalid [
    {Errors.SessionUnknownError, 404, "poll_unknown"},
    {Errors.RoundUnknownError, 404, "round_unknown"},
    {Errors.SessionEndedError, 409, "poll_ended"},
    {Errors.DelegateStaysError, 409, "delegate_stays"},
    {Errors.RoundOpenError, 409, "round_open"},
    {Errors.RoundClosedError, 409, "round_closed"},
    {Errors.VoteConflictError, 409, "vote_conflict"},
    {Errors.ActionUnknownError, 422, "action_unknown"}
  ]

  @doc "`{status, code}` for `error`, from an action on `fleet_id`'s polls."
  def of(%Ash.Error.Forbidden{errors: errors}, fleet_id, code) do
    cond do
      not Keyfleet.Chain.fresh?(fleet_id) -> {503, "ownership_refreshing"}
      Enum.any?(errors, &match?(%Errors.NotInRoundError{}, &1)) -> {403, "not_in_round"}
      Enum.any?(errors, &match?(%NoKeyToWriteAsError{}, &1)) -> {403, "poll_needs_key"}
      true -> {403, code}
    end
  end

  def of(%Ash.Error.Invalid{errors: errors}, _fleet_id, _code) do
    cond do
      found = Enum.find_value(errors, &invalid/1) -> found
      Enum.any?(errors, &decision_seen?/1) -> {409, "decision_seen"}
      true -> {422, "invalid_poll"}
    end
  end

  def of(%Errors.SessionUnknownError{} = error, fleet_id, code),
    do: of(Ash.Error.Invalid.exception(errors: [error]), fleet_id, code)

  def of(_error, _fleet_id, _code), do: {422, "invalid_poll"}

  # The status and code a poll's own refusal answers with.
  defp invalid(error) do
    Enum.find_value(@invalid, fn {module, status, code} ->
      if is_struct(error, module), do: {status, code}
    end)
  end

  # The session already had a round for this outside decision.
  defp decision_seen?(%Ash.Error.Changes.InvalidAttribute{
         field: :decision_ref,
         private_vars: vars
       }),
       do: Keyword.get(vars || [], :constraint_type) == :unique

  defp decision_seen?(_error), do: false
end

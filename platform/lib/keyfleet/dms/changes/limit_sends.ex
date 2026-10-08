defmodule Keyfleet.Dms.Changes.LimitSends do
  @moduledoc """
  Holds each sending Key to 300 direct messages an hour, counted by the site's
  request limiter (`Keyfleet.Accounts.RequestRateLimiter`) once the send is
  allowed. Opening a new conversation has no limit of its own.
  """
  use Ash.Resource.Change

  alias Keyfleet.Accounts.RequestRateLimiter
  alias Keyfleet.Dms.Errors.SendLimitError

  @limit 300
  @hour 3_600

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      key =
        {:dm_send, Ash.Changeset.get_argument(changeset, :fleet_id),
         Ash.Changeset.get_argument(changeset, :from_token_id)}

      case RequestRateLimiter.admit(key, @limit, @hour) do
        {:ok, _budget} ->
          changeset

        {:error, :rate_limited, budget} ->
          Ash.Changeset.add_error(
            changeset,
            SendLimitError.exception(limit: @limit, retry_after: budget.reset)
          )
      end
    end)
  end
end

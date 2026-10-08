defmodule Keyfleet.Proposals.Changes.LimitWords do
  @moduledoc """
  Holds each signed-in person to the saves of proposal words in
  `config :keyfleet, :proposal_words_rate_limit`, counted per account by
  `Keyfleet.Accounts.RequestRateLimiter`. A save past it is refused and the
  proposal goes ahead without its words. An agent saves through the API, whose
  per-address budget already holds it.
  """
  use Ash.Resource.Change

  alias Keyfleet.Accounts.RequestRateLimiter
  alias Keyfleet.Actors.Human

  @impl true
  def change(changeset, _opts, %{actor: %Human{human_account_id: account_id}}) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      budget = Application.fetch_env!(:keyfleet, :proposal_words_rate_limit)

      case RequestRateLimiter.admit(
             {:proposal_words, account_id},
             Keyword.fetch!(budget, :limit),
             Keyword.fetch!(budget, :window_seconds)
           ) do
        {:ok, _budget} ->
          changeset

        {:error, :rate_limited, _budget} ->
          Ash.Changeset.add_error(changeset,
            field: :text,
            message: "You're saving proposals quickly. Wait a while and try again."
          )
      end
    end)
  end

  def change(changeset, _opts, _context), do: changeset
end

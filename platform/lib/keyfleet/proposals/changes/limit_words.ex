defmodule Keyfleet.Proposals.Changes.LimitWords do
  @moduledoc """
  Holds each signed-in person, and each agent's wallet, to the saves of
  proposal words in `config :keyfleet, :proposal_words_rate_limit`, counted by
  `Keyfleet.Accounts.RequestRateLimiter`. A save past it is refused
  (`WordsLimitError`): a person's proposal goes ahead without its words, and
  an agent is told to wait. An agent changing its address would start the
  API's per-address budget again, so it is counted by its wallet.
  """
  use Ash.Resource.Change

  alias Keyfleet.Accounts.RequestRateLimiter
  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.Human
  alias Keyfleet.Proposals.Errors.WordsLimitError

  @impl true
  def change(changeset, _opts, %{actor: %Human{human_account_id: account_id}}),
    do: Ash.Changeset.before_action(changeset, &limit(&1, account_id))

  def change(changeset, _opts, %{actor: %Agent{wallet_address: wallet}}),
    do: Ash.Changeset.before_action(changeset, &limit(&1, wallet))

  def change(changeset, _opts, _context), do: changeset

  defp limit(changeset, saver) do
    budget = Application.fetch_env!(:keyfleet, :proposal_words_rate_limit)

    case RequestRateLimiter.admit(
           {:proposal_words, saver},
           Keyword.fetch!(budget, :limit),
           Keyword.fetch!(budget, :window_seconds)
         ) do
      {:ok, _budget} ->
        changeset

      {:error, :rate_limited, budget} ->
        Ash.Changeset.add_error(changeset, WordsLimitError.exception(retry_after: budget.reset))
    end
  end
end

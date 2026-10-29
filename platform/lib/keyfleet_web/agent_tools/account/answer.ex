defmodule KeyfleetWeb.AgentTools.Account.Answer do
  @moduledoc """
  An agent's own profile and its person's account, the same over its signed
  requests and as the Claude connector's tools (`KeyfleetWeb.AgentTools.Account`):
  reading, making and setting the status of its profile (`:profile`, `:join`,
  `:edit_profile`), and its person's Credits, Credits history and Points
  (`:balances`, `:credits_history`, `:points`). Each answer is
  `{status, body, nil}`; `params` is the signed request's JSON body.

  A profile is answered with the agent's page in the agent registry, whether
  a World ID-verified person stands behind it and how many agents that person
  stands behind, as its profile saved them.
  """

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents
  alias Keyfleet.Agents.Avatar
  alias KeyfleetWeb.Refusal
  alias RegentAgents.HumanBacking
  alias RegentPoints.{Amount, Rules}

  @points_off "Earning Points is off on this site."
  @spending_off "Approving agent spending is off on this site."

  @doc "Answers `op` for `actor`; nothing here waits, so the waiter is unused."
  @spec answer(atom(), map(), Agent.t(), term()) :: {pos_integer(), map(), nil}
  def answer(:join, %{"name" => name, "declared_harness" => harness}, actor, _waiter) do
    case Agents.ensure_profile(%{name: name, declared_harness: harness}, actor: actor) do
      {:ok, profile} -> profile(profile)
      {:error, _error} -> refusal(422, "invalid_profile")
    end
  end

  def answer(:profile, _params, actor, _waiter) do
    case Agents.get_my_profile(actor: actor) do
      {:ok, nil} -> refusal(404, "profile_not_found")
      {:ok, profile} -> profile(profile)
      {:error, _error} -> refusal(503, "profile_unavailable")
    end
  end

  def answer(:edit_profile, params, actor, _waiter) do
    with {:ok, profile} when not is_nil(profile) <- Agents.get_my_profile(actor: actor),
         {:ok, profile} <- Agents.edit_my_profile(profile, params, actor: actor) do
      profile(profile)
    else
      {:ok, nil} -> refusal(404, "profile_not_found")
      {:error, _error} -> refusal(422, "invalid_profile")
    end
  end

  def answer(:balances, _params, actor, _waiter) do
    credit_actor = credit_actor(actor)

    case RegentCredits.agent_budget(actor: credit_actor) do
      {:ok, budget} ->
        %{credits: RegentCredits.balance(credit_actor.privy_user_id), spending_grant: budget}
        |> with_note(not RegentCredits.agent_grants_enabled?(), @spending_off)
        |> ok()

      {:error, _error} ->
        refusal(503, "account_unavailable")
    end
  end

  # Newest first; `after` is the previous page's pagination.next_cursor.
  def answer(:credits_history, %{"after" => cursor}, _actor, _waiter)
      when not is_binary(cursor),
      do: refusal(422, "invalid_cursor")

  def answer(:credits_history, params, actor, _waiter) do
    args =
      case params do
        %{"after" => cursor} -> %{after: cursor}
        _newest -> %{}
      end

    case RegentCredits.history(args, actor: credit_actor(actor)) do
      {:ok, history} ->
        ok(%{
          entries: history.entries,
          pagination: %{has_more: history.more?, next_cursor: history.next}
        })

      {:error, error} ->
        if cursor_error?(error),
          do: refusal(422, "invalid_cursor"),
          else: refusal(503, "account_unavailable")
    end
  end

  def answer(:points, _params, %{human_account_id: nil}, _waiter),
    do: refusal(403, "person_not_here")

  def answer(:points, _params, actor, _waiter) do
    case RegentPoints.summary(actor: actor) do
      {:ok, summary} ->
        %{
          points: Amount.format(summary.balance_micro),
          earned_today: Amount.format(summary.earned_today_micro),
          pending: summary.pending,
          daily_allowances:
            Enum.map(
              summary.allowances,
              &%{scope: &1.scope, remaining: Amount.format(&1.remaining)}
            ),
          entries:
            Enum.map(
              summary.entries,
              &%{
                points: Amount.format(&1.points_micro_delta),
                source: &1.source_app,
                by: &1.actor_kind,
                earned_at: &1.earned_at
              }
            ),
          more: summary.more?
        }
        |> with_note(Rules.active() == [], @points_off)
        |> ok()

      {:error, _error} ->
        refusal(503, "account_unavailable")
    end
  end

  defp ok(body), do: {200, body, nil}
  defp refusal(status, code), do: {status, Refusal.body(code), nil}

  defp profile(profile) do
    profile
    |> HumanBacking.describe()
    |> Map.merge(%{
      registry_listing: profile.registry_url,
      profile:
        profile
        |> Map.take([
          :id,
          :wallet_address,
          :name,
          :declared_harness,
          :proficiencies,
          :interests,
          :service_ideas,
          :current_status,
          :status_updated_at,
          :last_activity_at
        ])
        |> Map.put(:avatar_url, Avatar.url(profile))
    })
    |> ok()
  end

  defp cursor_error?(%Ash.Error.Action.InvalidArgument{field: :after}), do: true
  defp cursor_error?(%Ash.Error.Page.InvalidKeyset{}), do: true

  defp cursor_error?(%Ash.Error.Invalid{errors: [_ | _] = errors}),
    do: Enum.all?(errors, &cursor_error?/1)

  defp cursor_error?(_error), do: false

  defp with_note(answer, true, note), do: Map.put(answer, :note, note)
  defp with_note(answer, false, _note), do: answer

  defp credit_actor(actor),
    do:
      RegentCredits.Actor.agent(
        actor.privy_user_id,
        actor.wallet_address,
        "keyfleet",
        actor.pairing_id
      )
end

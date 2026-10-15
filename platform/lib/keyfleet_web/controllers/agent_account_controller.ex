defmodule KeyfleetWeb.AgentAccountController do
  @moduledoc "Shared account reads for the current, verified agent pairing."
  use KeyfleetWeb, :controller
  alias KeyfleetWeb.Refusal
  alias RegentPoints.{Amount, Rules}

  @points_off "Earning Points is off on this site."
  @spending_off "Approving agent spending is off on this site."

  def balances(conn, _params) do
    actor = credit_actor(conn)

    case RegentCredits.agent_budget(actor: actor) do
      {:ok, budget} ->
        answer = %{credits: RegentCredits.balance(actor.privy_user_id), spending_grant: budget}
        json(conn, with_note(answer, not RegentCredits.agent_grants_enabled?(), @spending_off))

      {:error, _} ->
        Refusal.json(conn, 503, "account_unavailable")
    end
  end

  # Newest first; `after` is the previous page's pagination.next_cursor.
  def credits_history(%{body_params: %{"after" => cursor}} = conn, _params)
      when not is_binary(cursor),
      do: Refusal.json(conn, 422, "invalid_cursor")

  def credits_history(conn, _params) do
    args =
      case conn.body_params do
        %{"after" => cursor} -> %{after: cursor}
        _ -> %{}
      end

    case RegentCredits.history(args, actor: credit_actor(conn)) do
      {:ok, history} ->
        json(conn, %{
          entries: history.entries,
          pagination: %{has_more: history.more?, next_cursor: history.next}
        })

      {:error, error} ->
        if cursor_error?(error),
          do: Refusal.json(conn, 422, "invalid_cursor"),
          else: Refusal.json(conn, 503, "account_unavailable")
    end
  end

  defp cursor_error?(%Ash.Error.Action.InvalidArgument{field: :after}), do: true
  defp cursor_error?(%Ash.Error.Page.InvalidKeyset{}), do: true

  defp cursor_error?(%Ash.Error.Invalid{errors: [_ | _] = errors}),
    do: Enum.all?(errors, &cursor_error?/1)

  defp cursor_error?(_error), do: false

  def points(%{assigns: %{agent_actor: %{human_account_id: nil}}} = conn, _params),
    do: Refusal.json(conn, 403, "person_not_here")

  def points(conn, _params) do
    case RegentPoints.summary(actor: conn.assigns.agent_actor) do
      {:ok, summary} ->
        answer = %{
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

        json(conn, with_note(answer, Rules.active() == [], @points_off))

      {:error, _} ->
        Refusal.json(conn, 503, "account_unavailable")
    end
  end

  defp with_note(answer, true, note), do: Map.put(answer, :note, note)
  defp with_note(answer, false, _note), do: answer

  defp credit_actor(conn) do
    actor = conn.assigns.agent_actor

    RegentCredits.Actor.agent(
      actor.privy_user_id,
      actor.wallet_address,
      "keyfleet",
      actor.pairing_id
    )
  end
end

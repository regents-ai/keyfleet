defmodule KeyfleetWeb.AgentAccountController do
  @moduledoc "Shared account reads for the current, verified agent pairing."
  use KeyfleetWeb, :controller
  alias KeyfleetWeb.Refusal

  def balances(conn, _params) do
    actor = credit_actor(conn)

    permission =
      RegentCredits.agent_permissions!(actor: actor)
      |> Enum.find(
        &(&1.agent_address == actor.agent_address and &1.pairing_id == actor.pairing_id)
      )

    budget =
      if permission do
        Map.take(permission, [:enabled, :max_per_spend, :daily_limit, :sites])
        |> Map.put(:used_24h, RegentCredits.AgentSpending.spent_today(actor))
      else
        %{enabled: false}
      end

    json(conn, %{
      account_id: conn.assigns.agent_actor.human_account_id,
      pairing_id: actor.pairing_id,
      credits: RegentCredits.balance(actor.privy_user_id),
      spending_grant: budget
    })
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
        entries =
          Enum.map(
            summary.entries,
            &Map.take(&1, [
              :id,
              :rule_id,
              :rule_version,
              :source_app,
              :actor_kind,
              :actor_id,
              :points_micro_delta,
              :earned_at,
              :reason_code
            ])
          )

        result =
          Map.take(summary, [:balance_micro, :earned_today_micro, :pending, :allowances, :more?])

        json(conn, Map.put(result, :entries, entries))

      {:error, _} ->
        Refusal.json(conn, 503, "account_unavailable")
    end
  end

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

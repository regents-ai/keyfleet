defmodule Keyfleet.Points.CodePush do
  @moduledoc """
  Regent Points' check of a push to a fleet's code (`Keyfleet.Code.Push`),
  keyed by its id. It earns for the account that held the Key it was pushed
  as when it was pushed (`Keyfleet.Points.Holder`), when that person pushed
  or an agent paired with them did.
  """

  alias Keyfleet.Actors.System
  alias Keyfleet.Code
  alias Keyfleet.Points.Holder

  def verify(%{"source_event_key" => id}) do
    case Code.push(id, actor: %System{}) do
      {:ok, %{} = push} -> pushed(id, push)
      {:ok, nil} -> {:error, :push_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp pushed(id, push) do
    at = push.pushed_at

    with {:ok, epoch} <- Holder.epoch_at(push.fleet_id, push.token_id, at),
         {:ok, holder} <- Holder.holder(epoch, at),
         {:ok, actor} <- Holder.actor(holder, Holder.acting(push, push.wallet), at) do
      Holder.facts("code_push", id, holder, actor, at)
    end
  end
end

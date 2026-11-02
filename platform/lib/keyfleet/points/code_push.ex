defmodule Keyfleet.Points.CodePush do
  @moduledoc """
  Regent Points' check of a person's first push to a fleet's code
  (`keyfleet.integration.twigpine`): a branch or tag their Key's holder moved,
  by them or an agent paired with them. It reads the saved push and answers
  with the person who held the Key when it was recorded.
  """

  alias Keyfleet.Code.Push
  alias Keyfleet.Points.Holder
  alias Keyfleet.Repo

  def verify(%{"source_event_key" => id}) do
    # No person is asking: Points' check reads the committed row as it was saved,
    # straight from the table, since the record offers no read without one.
    case Repo.get(Push, id) do
      nil ->
        {:error, :push_not_found}

      push ->
        with {:ok, holder} <- Holder.at(push.fleet_id, push.token_id, push.pushed_at),
             {:ok, actor} <- Holder.actor(holder, push.agent_pairing_id),
             do: {:ok, Holder.facts("code_push", id, holder, actor, push.pushed_at)}
    end
  end
end

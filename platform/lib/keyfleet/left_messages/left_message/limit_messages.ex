defmodule Keyfleet.LeftMessages.LeftMessage.LimitMessages do
  @moduledoc """
  Holds each sender to 10 messages an hour (`:message`, counted for the
  person, or for an agent whose person has not signed in here), and each
  network to 30 (`:message_address`, counted for the client key the caller
  passes as `context: %{client_key: key}`, `KeyfleetWeb.ClientAddress.client_key/1`).
  A message counts when it is saved, not while it is typed, so checking a
  draft never spends the allowance.
  """

  use Ash.Resource.Change

  alias Keyfleet.Actors.{Agent, Human}
  alias Keyfleet.Limits

  @quickly "You're going quickly. Wait a moment and try again."

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if admitted?(changeset, actor),
        do: changeset,
        else: Ash.Changeset.add_error(changeset, field: :body, message: @quickly)
    end)
  end

  defp admitted?(%{context: %{client_key: key}}, actor),
    do:
      Limits.spend(:message, sender(actor)) == :ok and Limits.spend(:message_address, key) == :ok

  defp sender(%Human{human_account_id: id}), do: {:human, id}
  defp sender(%Agent{human_account_id: id}) when is_integer(id), do: {:human, id}
  defp sender(%Agent{wallet_address: wallet}), do: {:agent, wallet}
end

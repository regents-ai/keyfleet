defmodule KeyFleet.Graph.Checks.KeyActor do
  @moduledoc """
  Who may write a fleet's workspace as one of its keys: the person who owns
  that key today, or the agent that person has attached to it.

  A write names the key it acts as. Standing is read from that key every
  time, and only while the fleet's key ownership is fresh, so a key changing
  hands moves the right to write with it and an unknown owner grants nothing.
  The policy asks first; the fleet's writer asks again when the write's turn
  comes, and only that answer lets the write through.

  Each check has a budget in milliseconds, the graph's `:check_timeout`, and
  every read it makes gets what is left of it. A read that fails or runs out
  of time answers the error it got.
  """
  use Ash.Policy.SimpleCheck

  alias KeyFleet.Actors.Agent
  alias KeyFleet.Actors.Human
  alias KeyFleet.Graph.Errors.NotKeyHolderError
  alias KeyFleet.Keys.Errors.OwnershipRefreshingError

  @impl true
  def describe(_opts),
    do: "actor owns or runs the key it acts as, today, while the fleet's ownership is fresh"

  @impl true
  def match?(actor, %{subject: %Ash.ActionInput{arguments: arguments}}, _opts) do
    within = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]

    case command(actor, arguments.fleet_id, arguments.as_key, arguments.command_id, within) do
      {:ok, _command} -> true
      {:error, _error} -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  @doc """
  The command a write carries: its id, the member principal it is recorded
  under, and the audit stamp of the standing that admits it, read now within
  `within` milliseconds.
  """
  def command(actor, fleet_id, token_id, command_id, within) do
    deadline = System.monotonic_time(:millisecond) + within

    with {:ok, auth} <- authority(actor, fleet_id, token_id, deadline) do
      {:ok, %{id: command_id, principal: principal(auth), auth: auth}}
    end
  end

  defp authority(actor, fleet_id, token_id, deadline) do
    with {:ok, reading} <- fresh_reading(fleet_id, deadline),
         {:ok, key} <- key_coordinate(fleet_id, token_id, deadline),
         {:ok, standing} <- standing(actor, fleet_id, token_id, deadline) do
      {:ok,
       Map.merge(standing, %{
         key: key,
         checked_at: DateTime.to_iso8601(DateTime.utc_now()),
         # The last block the fleet's key ownership has been read through.
         chain_block: reading.next_block - 1
       })}
    end
  end

  defp fresh_reading(fleet_id, deadline) do
    case KeyFleet.Chain.fresh_cursor(fleet_id, within(deadline)) do
      {:ok, nil} -> {:error, OwnershipRefreshingError.exception(fleet_id: fleet_id)}
      other -> other
    end
  end

  # A key is named on the chain by its fleet's contract and its number. Only a
  # deployed fleet's chain is read, and a deployment is for good, so a fleet
  # with a fresh reading always has its contract.
  defp key_coordinate(fleet_id, token_id, deadline) do
    with {:ok, fleet} <-
           KeyFleet.Fleets.get_fleet(fleet_id, [not_found_error?: true] ++ within(deadline)) do
      {:ok, %{chain_id: fleet.chain_id, contract: fleet.contract_address, token_id: token_id}}
    end
  end

  defp standing(%Human{wallet_addresses: wallets} = actor, fleet_id, token_id, deadline) do
    case KeyFleet.Keys.current_key(fleet_id, token_id, [actor: actor] ++ within(deadline)) do
      {:ok, %{owner_wallet: owner} = key} ->
        if owner in wallets,
          do:
            {:ok,
             %{
               ownership_epoch: key.ownership_epoch,
               kind: "human",
               operator_wallet: owner,
               pairing_id: nil,
               credential_ref: nil
             }},
          else: not_a_holder(fleet_id, token_id)

      {:ok, nil} ->
        not_a_holder(fleet_id, token_id)

      error ->
        error
    end
  end

  defp standing(%Agent{wallet_address: wallet} = actor, fleet_id, token_id, deadline) do
    case KeyFleet.Keys.current_operator(fleet_id, token_id, [actor: actor] ++ within(deadline)) do
      {:ok, %{operator_wallet: ^wallet} = pairing} ->
        {:ok,
         %{
           ownership_epoch: pairing.ownership_epoch,
           kind: "agent",
           operator_wallet: wallet,
           pairing_id: pairing.id,
           credential_ref: actor.credential_ref
         }}

      {:ok, _not_running} ->
        not_a_holder(fleet_id, token_id)

      error ->
        error
    end
  end

  defp standing(_actor, fleet_id, token_id, _deadline), do: not_a_holder(fleet_id, token_id)

  # What is left of the check's budget, as the database's time limit for a read.
  defp within(deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 1)
    [context: %{data_layer: %{timeout: left}}]
  end

  defp not_a_holder(fleet_id, token_id),
    do: {:error, NotKeyHolderError.exception(fleet_id: fleet_id, token_id: token_id)}

  # The graph checks that the principal names exactly this key, epoch and wallet.
  defp principal(%{key: key} = auth),
    do:
      "member:#{key.chain_id}:#{key.contract}:#{key.token_id}" <>
        "@#{auth.ownership_epoch}/#{auth.kind}:#{auth.operator_wallet}"
end

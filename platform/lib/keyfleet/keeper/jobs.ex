defmodule Keyfleet.Keeper.Jobs do
  @moduledoc """
  What the keeper's reveal and protocol-share jobs share: the fleets they work on,
  and how the answer to one send steers the rest of a round.
  """

  require Logger

  alias Keyfleet.Keeper.{Calls, Sender}

  @doc "The deployed fleets on the chain the sender's node serves, by id."
  def fleets(%Sender{fleets: fleets, chain_id: chain_id}) do
    fleets
    |> Map.values()
    |> Enum.filter(&(&1.chain_id == chain_id))
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Sends `fun` to `target` with `arg` for `job` on behalf of `fleet`, through
  `Keyfleet.Keeper.Sender.send/2`, and says how the round goes on:

    * `{:sent, tx, sender}` once it is included, whether it succeeded or
      reverted, with its record;
    * `{:skipped, sender}` when nothing was sent because the contract
      refuses the call;
    * `{:halt, sender}` when the round should send nothing more: a
      transaction is left waiting, the keeper has stopped, or it may not or
      cannot send now.
  """
  def send(%Sender{} = sender, job, fleet, fun, target, arg) do
    case Calls.new(fun, target, arg) do
      {:ok, call} ->
        sender
        |> Sender.send(%{job: job, fleet_id: fleet.id, call: call})
        |> steer(job, fleet, call)

      {:error, reason} ->
        Logger.warning(
          "Keeper passed over #{fun} to #{target} for #{fleet.id}: the call is #{reason}."
        )

        {:skipped, sender}
    end
  end

  defp steer({:ok, tx, _receipt, sender}, _job, _fleet, _call), do: {:sent, tx, sender}

  defp steer({:error, {:revert, selector, _args}, sender}, _job, fleet, call) do
    Logger.warning(
      "Keeper passed over #{call.fn} to #{call.target} for #{fleet.id}: the contract refuses it (#{refusal(selector)})."
    )

    {:skipped, sender}
  end

  defp steer({:waiting, tx, sender}, job, _fleet, _call) do
    Logger.warning(
      "Keeper left #{tx.tx_hash} waiting; its #{job} round sends nothing more until the next."
    )

    {:halt, sender}
  end

  # Their own alerts have said why.
  defp steer({:error, reason, sender}, _job, _fleet, _call)
       when reason in [:stopped, :spend_ceiling],
       do: {:halt, sender}

  defp steer({:error, reason, sender}, job, _fleet, _call) do
    Logger.warning("Keeper's #{job} round stopped sending: #{inspect(reason)}")
    {:halt, sender}
  end

  defp refusal(nil), do: "no reason given"
  defp refusal(selector), do: "error 0x" <> Base.encode16(selector, case: :lower)
end

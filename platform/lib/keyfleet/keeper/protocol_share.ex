defmodule Keyfleet.Keeper.ProtocolShare do
  @moduledoc """
  The keeper's protocol-share job, run five minutes after it starts and
  then every hour: it sends each fleet's owed protocol share to the Regents
  Safe once a day.

  For every fleet, once 24 hours have passed since the keeper's own last
  `sendProtocolShare` for it was included, and none is still waiting, it
  sends one while the fleet owes any. Anyone may send it at any time; the
  keeper never looks for that and never waits on it. A fleet whose share
  cannot be checked is passed over until the next round; the other fleets
  go on.
  """

  require Logger

  alias Keyfleet.Actors.System
  alias Keyfleet.Keeper
  alias Keyfleet.Keeper.{Jobs, Sender}

  @day_seconds 86_400

  @doc "Runs one round, and returns the sender for the next."
  def run(%Sender{} = sender) do
    started_at = DateTime.utc_now()

    {sender, tally} =
      sender
      |> Jobs.fleets()
      |> Enum.reduce_while({sender, %{sent: 0, skipped: 0}}, &protocol_share/2)

    if tally.sent > 0, do: Keeper.record_round(:protocol_share, started_at, tally)
    sender
  end

  # The keeper's own shares still waiting, or included in the last day, hold
  # the next back.
  defp protocol_share(fleet, {sender, tally} = acc) do
    since = DateTime.add(DateTime.utc_now(), -@day_seconds)

    with {:ok, []} <-
           Keeper.list_recent_txs(
             sender.chain_id,
             sender.wallet.address,
             fleet.id,
             :send_protocol_share,
             since,
             actor: %System{}
           ),
         {:ok, owed} when owed > 0 <-
           Sender.read(sender, fleet.contract_address, :protocol_share_owed) do
      sender
      |> Jobs.send(:protocol_share, fleet, :send_protocol_share, fleet.contract_address, nil)
      |> steer(tally)
    else
      {:ok, [_sent | _earlier]} ->
        {:cont, acc}

      {:ok, 0} ->
        {:cont, {sender, count(tally, :skipped)}}

      {:error, reason} ->
        Logger.warning("Keeper could not check #{fleet.id}'s protocol share: #{inspect(reason)}")

        {:cont, acc}
    end
  end

  defp steer({:sent, _tx, sender}, tally), do: {:cont, {sender, count(tally, :sent)}}
  defp steer({:skipped, sender}, tally), do: {:cont, {sender, count(tally, :skipped)}}
  defp steer({:halt, sender}, tally), do: {:halt, {sender, tally}}

  defp count(tally, counted), do: Map.update!(tally, counted, &(&1 + 1))
end

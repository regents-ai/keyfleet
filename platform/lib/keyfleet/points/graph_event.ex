defmodule Keyfleet.Points.GraphEvent do
  @moduledoc """
  Regent Points' check of a member's work landing in a fleet's graph: one
  event of its log a member made as their Key
  (`Keyfleet.Graph.Event.member_with_epoch/1`), keyed `"fleet:seq"`. It earns
  for the account that held the Key, in the ownership epoch the write was
  admitted in, at the event's time (`Keyfleet.Points.Holder`), when that
  person made it or an agent paired with them did.

  The graph machine writes the log and its copy, and never offers anything to
  Points; the site offers a member's first new write in the Key's ownership
  period as it answers it (`offer/3`).
  """

  require Logger

  alias Keyfleet.Actors.System
  alias Keyfleet.Graph
  alias Keyfleet.Points.{Award, Holder}

  @rule "keyfleet.integration.activegraph"

  @doc """
  Offers a member's new workspace write as the site answers it
  (`Keyfleet.Graph.Workspace.Relay`), while the rule is earning: the first of
  the write's `events`, as the graph's reply lists them, that the graph
  recorded as a member's Key. The write's own changes come first, and the
  graph's record of the command last; a write that changed nothing offers
  nothing. It is offered only when it is the first in that ownership period of
  the Key by the person `actor` speaks for (`Award.mark_and_offer/4`).

  The offer runs in its own task (`Keyfleet.Points.Offers`), so the write is
  answered as made, at once, whatever Points answers; while the rule is not
  earning no task starts. The task marks the period and makes the offer in one
  transaction, so an offer the task loses, as when the database is failing,
  marks nothing and is logged by the task; one refused a task because the most
  offers allowed at once are already running is one warning line. Either way
  the person's next write offers it again.
  """
  def offer(fleet_id, events, actor) do
    with true <- Award.earning?(@rule),
         {seq, {token_id, ownership_epoch, _kind, _wallet}} <- first_by_member(events) do
      start("#{fleet_id}:#{seq}",
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: ownership_epoch,
        owner_wallets: Keyfleet.Keys.person_wallets(actor)
      )
    else
      false -> :ok
      nil -> :ok
    end
  end

  @doc """
  The check of an offered event. The fleet's copy of its log may be a moment
  behind the write, so an event not copied yet is looked for again on Oban's
  next tries.
  """
  def verify(%{"source_event_key" => key}) do
    [fleet_id, seq] = Regex.run(~r/\A(.+):(\d+)\z/, key, capture: :all_but_first)

    case Graph.get_event(fleet_id, String.to_integer(seq), actor: %System{}) do
      {:ok, %{} = event} -> by_member(key, event, Graph.Event.member_with_epoch(event.actor))
      {:ok, nil} -> {:retry, :graph_event_not_copied}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp first_by_member(events) do
    Enum.find_value(events, fn %{"seq" => seq, "actor" => actor} ->
      with {_token_id, _epoch, _kind, _wallet} = member <- Graph.Event.member_with_epoch(actor),
           do: {seq, member}
    end)
  end

  defp start(key, period) do
    offering = fn ->
      {:ok, :ok} =
        Ash.transact(Keyfleet.Keys.KeyAttachment, fn ->
          Award.mark_and_offer(@rule, "graph_event", key, period)
        end)
    end

    case Task.Supervisor.start_child(Keyfleet.Points.Offers, offering) do
      {:ok, _task} ->
        :ok

      {:error, :max_children} ->
        Logger.warning(
          "Workspace write #{key} was not offered to Regent Points: " <>
            "the most offers allowed at once were already running."
        )
    end
  end

  defp by_member(_key, _event, nil), do: {:error, :graph_event_not_by_member}

  # The member's principal names the Key's ownership epoch the site admitted
  # the write in (`Keyfleet.Graph.Checks.KeyActor`). The log writes each
  # event's time in UTC; any other shape fails the check's job.
  defp by_member(key, event, {token_id, ownership_epoch, kind, wallet}) do
    {:ok, at, 0} = DateTime.from_iso8601(event.timestamp)

    with {:ok, epoch} <- Holder.epoch(event.fleet_id, token_id, ownership_epoch),
         {:ok, holder} <- Holder.holder(epoch, at),
         {:ok, actor} <- Holder.actor(holder, acting(kind, wallet), at) do
      Holder.facts("graph_event", key, holder, actor, at)
    end
  end

  defp acting("human", wallet), do: {:human, wallet}
  defp acting("agent", wallet), do: {:agent_wallet, wallet}
end

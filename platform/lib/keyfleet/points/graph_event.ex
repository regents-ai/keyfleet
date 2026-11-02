defmodule Keyfleet.Points.GraphEvent do
  @moduledoc """
  Regent Points' check of a person's first change to a fleet's workspace
  (`keyfleet.integration.activegraph`): an event of the fleet's graph log
  made as their Key, by them or by an agent paired with them when it was
  made. The event names the Key and the wallet that signed, and `fleet:seq`
  names the event.
  """

  alias Keyfleet.Graph.Event
  alias Keyfleet.Points.Holder
  alias Keyfleet.Repo

  def verify(%{"source_event_key" => key}) do
    # No person is asking: Points' check reads the committed row as it was saved,
    # straight from the table, since the record offers no read without one.
    with [fleet_id, seq] <- String.split(key, ":"),
         %Event{} = event <- Repo.get_by(Event, fleet_id: fleet_id, seq: String.to_integer(seq)),
         {token_id, kind, wallet} <- Event.member(event.actor),
         {:ok, at, _offset} <- DateTime.from_iso8601(event.timestamp),
         {:ok, holder} <- Holder.at(fleet_id, token_id, at),
         {:ok, actor} <- actor(holder, kind, wallet, at) do
      {:ok, Holder.facts("graph_event", key, holder, actor, at)}
    else
      nil -> {:error, :graph_event_not_by_member}
      {:error, :invalid_format} -> {:error, :graph_event_time_unreadable}
      {:error, _} = error -> error
      {:retry, _} = retry -> retry
    end
  end

  defp actor(_holder, "human", _wallet, _at), do: {:ok, :human}

  defp actor(holder, "agent", wallet, at) do
    with {:ok, pairing} <- Holder.agent_wallet(holder, wallet, at), do: {:ok, {:agent, pairing}}
  end
end

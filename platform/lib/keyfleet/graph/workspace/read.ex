defmodule Keyfleet.Graph.Workspace.Read do
  @moduledoc """
  Answers a workspace read from the fleet's read tables, never from its
  writer, so a read never waits behind a write.

  Each read is answered from one read-only snapshot of the tables, so it
  shows the workspace exactly as it stood at `watermark`, the place in the
  fleet's log the tables had reached: a write whose `head_seq` is at or below
  it is in the answer, and nothing past it is.

  `get` answers one object, with where a submitted task's review stands
  (`review`), and a page of up to 200 of its links, oldest first, made after
  `relations_after`; `relations_next_cursor` is the `relations_after` to read
  the next page from, or nil after the last one. `changes` answers the copied
  events after `after_seq`, oldest first, at most `limit` of them and no more
  than 512 KiB of them unless one event alone is larger;
  `next_cursor` is the `after_seq` to read on from, and `run_id` names the
  log they come from.

  Both name, in `agents`, the agents behind what they answer, by wallet: the
  agent that created the object, or that made each change, with the name it
  gave itself, as the fleet's pages show it beside the Key. A goal's agents
  include each agent that joined it.
  """
  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Agents
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Errors.RefusedError
  alias Keyfleet.Graph.Event

  @relation_page 200

  @impl true
  def run(input, opts, context) do
    kind = Keyword.fetch!(opts, :read)
    Graph.in_snapshot(fn -> read(kind, input.arguments, Ash.Context.to_opts(context)) end)
  end

  defp read(:get, %{fleet_id: fleet_id, id: id, relations_after: after_seq}, opts) do
    {_run_id, watermark} = standing(fleet_id, opts)

    case Graph.read_object!(fleet_id, id, [load: [:review]] ++ opts) do
      nil ->
        {:error,
         RefusedError.exception(code: "not_found", reason: "no such object", details: %{id: id})}

      object ->
        {page, rest} =
          fleet_id
          |> Graph.read_relations_touching!(id, after_seq, @relation_page + 1, opts)
          |> Enum.split(@relation_page)

        %{
          object: Map.take(object, [:id, :type, :data, :sys, :version, :review]),
          relations: Enum.map(page, &Map.take(&1, [:id, :type, :source, :target, :data])),
          relations_next_cursor: if(rest != [], do: List.last(page).created_seq),
          watermark: watermark,
          agents: Agents.names_by_wallet([creator(object.sys) | joiners(object.sys)])
        }
    end
  end

  defp read(:changes, %{fleet_id: fleet_id, after_seq: after_seq, limit: limit}, opts) do
    {run_id, watermark} = standing(fleet_id, opts)
    page = fleet_id |> Graph.read_events!(after_seq, limit, opts) |> Enum.map(&Event.view/1)
    has_more = page != [] and more_after?(fleet_id, List.last(page).seq, opts)

    %{
      run_id: run_id,
      events: page,
      next_cursor: if(has_more, do: List.last(page).seq, else: max(after_seq, watermark)),
      has_more: has_more,
      watermark: watermark,
      agents: page |> Enum.map(&writer(&1.actor)) |> Agents.names_by_wallet()
    }
  end

  defp creator(%{"created_by" => by}), do: agent_wallet(by)

  defp joiners(sys), do: sys |> Map.get("joined", []) |> Enum.map(&agent_wallet/1)

  defp agent_wallet(%{"kind" => "agent", "wallet" => wallet}), do: wallet
  defp agent_wallet(_person), do: nil

  defp writer(actor) do
    case Event.member(actor) do
      {_token_id, "agent", wallet} -> wallet
      _person_or_workspace -> nil
    end
  end

  # A fleet whose log has never been copied reads as an empty log.
  defp standing(fleet_id, opts) do
    case Graph.get_cursor!(fleet_id, opts) do
      nil -> {nil, 0}
      cursor -> {cursor.run_id, cursor.applied_seq}
    end
  end

  defp more_after?(fleet_id, seq, opts) do
    Event
    |> Ash.Query.for_read(:page, %{fleet_id: fleet_id, after_seq: seq, limit: 1}, opts)
    |> Ash.exists?(opts)
  end
end

defmodule Keyfleet.WorkspacePulse do
  @moduledoc """
  The public outline of work recorded by one fleet. Uses the graph's existing
  public read; exposes only fixed descriptions, sequence numbers and times.
  No titles, object ids, authors, bodies, branch names or artifact links leave
  this boundary. Members use the signed workspace reads for those details.
  """

  alias Keyfleet.{Fleets, Graph, Notebooks}

  @doc "The latest thirty notable changes, or an explicit read failure."
  def read(fleet_id) do
    if fleet_id in Fleets.open_fleet_ids() do
      case Graph.notable_before(fleet_id, nil, 30) do
        {:ok, events} ->
          {:ok,
           %{
             fleet_id: fleet_id,
             visibility: "public_summary",
             generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
             notebooks_configured: Notebooks.hub?(fleet_id),
             activity: Enum.map(events, &summary/1)
           }}

        {:error, error} ->
          {:error, error}
      end
    else
      :unknown
    end
  end

  defp summary(event) do
    %{seq: event.seq, at: event.timestamp, text: words(event.type)}
  end

  defp words("object.created"), do: "Work was added to the workspace."
  defp words("patch.applied"), do: "Work in the workspace was updated."
  defp words("relation.created"), do: "Related work was connected."
  defp words(_type), do: "The workspace changed."
end

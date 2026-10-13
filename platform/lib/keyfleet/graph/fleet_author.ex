defmodule Keyfleet.Graph.FleetAuthor do
  @moduledoc """
  The fleet itself as the author of a workspace write.

  Keyfleet's own work writes as the fleet when it keeps something for the
  fleet that no key wrote, such as the copy of a notebook's code
  (`Keyfleet.Notebooks.Copies`). The fleet is named by its manager contract,
  as its keys are. No request chooses this author: only the workspace's
  system-only actions carry it, and the fleet's graph lets it write nothing
  but its own types, in the fleet scope.
  """

  alias Keyfleet.Graph.Errors.UnavailableError

  @doc """
  The command a write by the fleet carries: its id, the principal it is
  recorded under and the stamp of who wrote it, read now within `within`
  milliseconds. Only a deployed fleet writes.
  """
  def command(fleet_id, command_id, within) do
    opts = [not_found_error?: true, context: %{data_layer: %{timeout: within}}]

    case Keyfleet.Fleets.get_fleet(fleet_id, opts) do
      {:ok, %{chain_id: chain_id, manager_address: "0x" <> _hex = contract}} ->
        {:ok,
         %{
           id: command_id,
           principal: "fleet:#{chain_id}:#{contract}",
           writable_scopes: ["fleet"],
           auth: %{
             kind: "fleet",
             fleet: %{chain_id: chain_id, contract: contract},
             checked_at: DateTime.to_iso8601(DateTime.utc_now())
           }
         }}

      {:ok, _undeployed} ->
        {:error, UnavailableError.exception(fleet_id: fleet_id)}

      {:error, error} ->
        {:error, error}
    end
  end
end

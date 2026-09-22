defmodule KeyFleet.Graph.Workspace.Relay do
  @moduledoc """
  Hands a workspace action to its fleet's writer as one graph operation.

  `op` names the operation and `body` the arguments that make up its body; an
  argument left out is left out of the body. A write carries the command the
  writer stamps, at its turn, from the actor's standing on the key it acts as.
  When that standing cannot be read at the write's turn, because the database
  failed or ran out of time, the write is answered as unavailable: nothing was
  sent to the graph.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias KeyFleet.Graph.Checks.KeyActor
  alias KeyFleet.Graph.Errors.IndeterminateError
  alias KeyFleet.Graph.Errors.NotKeyHolderError
  alias KeyFleet.Graph.Errors.RefusedError
  alias KeyFleet.Graph.Errors.UnavailableError
  alias KeyFleet.Graph.Writer
  alias KeyFleet.Keys.Errors.OwnershipRefreshingError

  @reads ~w(get changes)

  @impl true
  def run(input, opts, context) do
    op = Keyword.fetch!(opts, :op)
    arguments = input.arguments
    fleet_id = arguments.fleet_id

    body = Map.take(arguments, Keyword.fetch!(opts, :body))

    if op in @reads do
      fleet_id |> Writer.request(op, body) |> read_reply(fleet_id)
    else
      authorize = fn within ->
        KeyActor.command(context.actor, fleet_id, arguments.as_key, arguments.command_id, within)
      end

      fleet_id |> Writer.command(op, body, authorize) |> write_reply(fleet_id)
    end
  end

  defp read_reply({:ok, %{"result" => result}}, _fleet_id), do: {:ok, result}
  # A read that never came back changed nothing.
  defp read_reply({:error, :indeterminate}, fleet_id), do: unavailable(fleet_id)
  defp read_reply(error, fleet_id), do: refused(error, fleet_id)

  defp write_reply({:ok, reply}, _fleet_id) do
    {:ok, %{result: reply["result"], replayed: reply["replayed"], head_seq: reply["head_seq"]}}
  end

  defp write_reply({:error, :indeterminate}, fleet_id),
    do: {:error, IndeterminateError.exception(fleet_id: fleet_id)}

  defp write_reply(error, fleet_id), do: refused(error, fleet_id)

  defp refused({:error, %{"code" => code, "message" => reason, "details" => details}}, _fleet_id),
    do: {:error, RefusedError.exception(code: code, reason: reason, details: details)}

  defp refused({:error, :unavailable}, fleet_id), do: unavailable(fleet_id)

  # The actor's standing, refused at the write's turn.
  defp refused({:error, %NotKeyHolderError{} = error}, _fleet_id), do: {:error, error}
  defp refused({:error, %OwnershipRefreshingError{} = error}, _fleet_id), do: {:error, error}

  # The actor's standing could not be read at the write's turn.
  defp refused({:error, error}, fleet_id) do
    Logger.warning(
      "graph write for #{fleet_id} not sent: its ownership check failed: " <>
        Exception.message(error)
    )

    unavailable(fleet_id)
  end

  defp unavailable(fleet_id), do: {:error, UnavailableError.exception(fleet_id: fleet_id)}
end

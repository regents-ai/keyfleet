defmodule KeyFleet.Graph.Workspace.Relay do
  @moduledoc """
  Hands a workspace write to its fleet's writer as one graph operation.

  `op` names the operation and `body` the arguments that make up its body; an
  argument left out is left out of the body. A write carries the command the
  writer stamps, at its turn, from the actor's standing on the key it acts as.
  When that standing cannot be read at the write's turn, because the database
  failed or ran out of time, the write is answered as unavailable: nothing was
  sent to the graph.

  An applied write is answered once the fleet's read tables have reached its
  place in the log, `head_seq`, or once the projector's wait has run out;
  see `KeyFleet.Graph.Projector.await/3`. The answer's `watermark` says how
  far along the write's log the tables were known to be: at or past
  `head_seq`, a read made now includes the write.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias KeyFleet.Graph.Checks.KeyActor
  alias KeyFleet.Graph.Errors.IndeterminateError
  alias KeyFleet.Graph.Errors.NotKeyHolderError
  alias KeyFleet.Graph.Errors.RefusedError
  alias KeyFleet.Graph.Errors.UnavailableError
  alias KeyFleet.Graph.Projector
  alias KeyFleet.Graph.Writer
  alias KeyFleet.Keys.Errors.OwnershipRefreshingError

  @impl true
  def run(input, opts, context) do
    op = Keyword.fetch!(opts, :op)
    arguments = input.arguments
    fleet_id = arguments.fleet_id

    body = Map.take(arguments, Keyword.fetch!(opts, :body))

    authorize = fn within ->
      KeyActor.command(context.actor, fleet_id, arguments.as_key, arguments.command_id, within)
    end

    fleet_id |> Writer.command(op, body, authorize) |> write_reply(fleet_id)
  end

  defp write_reply({:ok, %{"run_id" => run_id, "head_seq" => head_seq} = reply}, fleet_id) do
    watermark = Projector.await(fleet_id, run_id, head_seq)

    {:ok,
     %{
       result: reply["result"],
       replayed: reply["replayed"],
       head_seq: head_seq,
       watermark: watermark
     }}
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

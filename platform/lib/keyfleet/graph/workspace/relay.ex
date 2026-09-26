defmodule Keyfleet.Graph.Workspace.Relay do
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
  see `Keyfleet.Graph.Projector.await/3`. The answer's `watermark` says how
  far along the write's log the tables were known to be: at or past
  `head_seq`, a read made now includes the write.

  A new write by an agent is recorded as its latest contribution to the
  fleet. The write already stands in the graph, so a record that fails is
  logged and the write is answered as it was.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Graph.Errors.IndeterminateError
  alias Keyfleet.Graph.Errors.NotKeyHolderError
  alias Keyfleet.Graph.Errors.RefusedError
  alias Keyfleet.Graph.Errors.UnavailableError
  alias Keyfleet.Graph.Projector
  alias Keyfleet.Graph.Writer
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError

  @impl true
  def run(input, opts, context) do
    op = Keyword.fetch!(opts, :op)
    arguments = input.arguments
    fleet_id = arguments.fleet_id

    body = Map.take(arguments, Keyword.fetch!(opts, :body))

    authorize = fn within ->
      KeyActor.command(context.actor, fleet_id, arguments.as_key, arguments.command_id, within)
    end

    fleet_id |> Writer.command(op, body, authorize) |> write_reply(fleet_id, context.actor)
  end

  defp write_reply(
         {:ok, %{"run_id" => run_id, "head_seq" => head_seq} = reply},
         fleet_id,
         actor
       ) do
    watermark = Projector.await(fleet_id, run_id, head_seq)
    unless reply["replayed"], do: note_contribution(actor, fleet_id)

    {:ok,
     %{
       result: reply["result"],
       replayed: reply["replayed"],
       head_seq: head_seq,
       watermark: watermark
     }}
  end

  defp write_reply({:error, :indeterminate}, fleet_id, _actor),
    do: {:error, IndeterminateError.exception(fleet_id: fleet_id)}

  defp write_reply(error, fleet_id, _actor), do: refused(error, fleet_id)

  defp note_contribution(%Agent{} = actor, fleet_id) do
    case Keyfleet.Agents.note_contribution(actor, fleet_id, :workspace) do
      {:ok, _check_in} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "workspace write for #{fleet_id} not recorded as a contribution: " <>
            Exception.message(error)
        )
    end
  end

  defp note_contribution(_actor, _fleet_id), do: :ok

  defp refused({:error, %{"code" => code, "message" => reason, "details" => details}}, _fleet_id),
    do: {:error, RefusedError.exception(code: code, reason: reason, details: details)}

  defp refused({:error, :unavailable}, fleet_id), do: unavailable(fleet_id)

  # The actor's standing, refused at the write's turn.
  defp refused({:error, %NotKeyHolderError{} = error}, _fleet_id), do: {:error, error}
  defp refused({:error, %OwnershipRefreshingError{} = error}, _fleet_id), do: {:error, error}

  # The actor's standing could not be read at the write's turn.
  defp refused({:error, error}, fleet_id) do
    Logger.warning(
      "graph write for #{fleet_id} not sent: its ownership check failed: " <> reason(error)
    )

    unavailable(fleet_id)
  end

  # What went wrong, on one line: an error that gathers others, as Ash's do,
  # by each error it holds, and each error by the first line of its message,
  # which names its kind, without the trail of where it was passed along.
  defp reason(%{errors: [_ | _] = errors}), do: Enum.map_join(errors, "; ", &reason/1)
  defp reason(%{bread_crumbs: [_ | _]} = error), do: reason(%{error | bread_crumbs: []})
  defp reason(error), do: error |> Exception.message() |> String.split("\n", parts: 2) |> hd()

  defp unavailable(fleet_id), do: {:error, UnavailableError.exception(fleet_id: fleet_id)}
end

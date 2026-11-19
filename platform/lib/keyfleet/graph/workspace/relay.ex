defmodule Keyfleet.Graph.Workspace.Relay do
  @moduledoc """
  Hands a workspace write to its fleet's writer as one graph operation.

  `op` names the operation and `body` the arguments that make up its body; an
  argument left out is left out of the body. A write carries the command the
  writer stamps, at its turn, by the workspace command rule
  (`Keyfleet.Graph.Authority`): the actor's standing on the key it acts as
  and the state of each of the fleet's projects then. The graph takes new
  work only into an active project.
  When that standing cannot be read at the write's turn, because the database
  failed or ran out of time, the write is answered as unavailable: nothing was
  sent to the graph.

  A run with `input_check` in its context, as a preview of the write runs it
  (`KeyfleetWeb.Preview`), only checks the write: the same command is stamped
  at its turn and the graph decides it as it would the write
  (`Keyfleet.Graph.Writer.check/4`), refusing it the same way, but nothing is
  written, waited for or recorded, and the command id stays unused.

  An applied write is answered once the fleet's read tables have reached its
  place in the log, `head_seq`, or once the projector's wait has run out;
  see `Keyfleet.Graph.Projector.await/3`. The answer's `watermark` says how
  far along the write's log the tables were known to be: at or past
  `head_seq`, a read made now includes the write. All three reach the graph
  through `Keyfleet.Graph.Client`.

  A new write by an agent is recorded as its latest contribution to the
  fleet: taking a task, handing one in, a review, or another workspace write. The write
  already stands in the graph, so a record that fails is logged and the write
  is answered as it was. A member's first new write in the Key's ownership
  period is also offered to Regent Points while that rule earns, in a task of
  its own (`Keyfleet.Points.GraphEvent.offer/3`), so the answer never waits
  for it.
  """
  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Graph.Authority
  alias Keyfleet.Graph.Client
  alias Keyfleet.Graph.Errors.EditsRestrictedError
  alias Keyfleet.Graph.Errors.IndeterminateError
  alias Keyfleet.Graph.Errors.NotKeyHolderError
  alias Keyfleet.Graph.Errors.RefusedError
  alias Keyfleet.Graph.Errors.UnavailableError
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError

  @impl true
  def run(input, opts, context) do
    op = Keyword.fetch!(opts, :op)
    arguments = input.arguments
    fleet_id = arguments.fleet_id

    body = Map.take(arguments, Keyword.fetch!(opts, :body))
    authority = Authority.workspace_command(context.actor, arguments.as_key, arguments.command_id)

    case input.context do
      %{input_check: true} ->
        fleet_id |> Client.check(op, body, authority) |> check_reply(fleet_id)

      _write ->
        fleet_id
        |> Client.command(op, body, authority)
        |> write_reply(fleet_id, context.actor, kind(op, arguments))
    end
  end

  defp write_reply(
         {:ok, %{"run_id" => run_id, "head_seq" => head_seq} = reply},
         fleet_id,
         actor,
         kind
       ) do
    watermark = Client.await(fleet_id, run_id, head_seq)

    unless reply["replayed"] do
      Keyfleet.Agents.record_contribution(actor, fleet_id, kind)
      Keyfleet.Points.GraphEvent.offer(fleet_id, reply["events"], actor)
    end

    {:ok,
     %{
       result: reply["result"],
       replayed: reply["replayed"],
       head_seq: head_seq,
       watermark: watermark
     }}
  end

  defp write_reply({:error, :indeterminate}, fleet_id, _actor, _kind),
    do: {:error, IndeterminateError.exception(fleet_id: fleet_id)}

  defp write_reply(error, fleet_id, _actor, _kind), do: refused(error, fleet_id)

  # A check writes nothing, so one whose answer never came back is unavailable.
  defp check_reply({:ok, _taken}, _fleet_id), do: {:ok, %{}}
  defp check_reply({:error, :indeterminate}, fleet_id), do: unavailable(fleet_id)
  defp check_reply(error, fleet_id), do: refused(error, fleet_id)

  # Joining a task or forking one, handing one in and reviewing one are told
  # apart from other writes.
  defp kind("join", %{id: "task#" <> _}), do: :task
  defp kind("fork", _arguments), do: :task
  defp kind("submit", _arguments), do: :submit
  defp kind("review", _arguments), do: :review
  defp kind(_op, _arguments), do: :workspace

  defp refused({:error, %{"code" => code, "message" => reason, "details" => details}}, _fleet_id),
    do: {:error, RefusedError.exception(code: code, reason: reason, details: details)}

  defp refused({:error, :unavailable}, fleet_id), do: unavailable(fleet_id)

  # The actor's standing, refused at the write's turn. One that could not be
  # read then is answered as unavailable (`Keyfleet.Graph.Authority`).
  defp refused({:error, %NotKeyHolderError{} = error}, _fleet_id), do: {:error, error}
  defp refused({:error, %EditsRestrictedError{} = error}, _fleet_id), do: {:error, error}
  defp refused({:error, %OwnershipRefreshingError{} = error}, _fleet_id), do: {:error, error}

  defp unavailable(fleet_id), do: {:error, UnavailableError.exception(fleet_id: fleet_id)}
end

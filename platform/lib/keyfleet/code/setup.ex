defmodule Keyfleet.Code.Setup do
  @moduledoc """
  Makes one fleet's repository in the code store and records it
  (`Keyfleet.Code.Repository`). Queued the first time someone asks for the
  fleet's code (`Keyfleet.Code.owner/1`). Making it again finds the one
  already made, so a run that fails part way is simply run again.
  """
  use Oban.Worker,
    queue: :code_store,
    max_attempts: 20,
    unique: [keys: [:fleet_id], period: :infinity, states: :incomplete]

  alias Keyfleet.Actors.System
  alias Keyfleet.Code
  alias Keyfleet.Code.NodeClient

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fleet_id" => fleet_id}}) do
    case Code.get_repository(fleet_id, actor: %System{}) do
      {:ok, nil} ->
        with {:ok, owner} <- NodeClient.create_repository(fleet_id),
             {:ok, _repository} <- Code.record_repository(fleet_id, owner, actor: %System{}) do
          :ok
        end

      {:ok, _made} ->
        :ok
    end
  end
end

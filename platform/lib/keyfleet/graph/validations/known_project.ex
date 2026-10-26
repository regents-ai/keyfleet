defmodule Keyfleet.Graph.Validations.KnownProject do
  @moduledoc "The request names one of the fleet's projects (`Keyfleet.Projects`)."
  use Ash.Resource.Validation

  alias Keyfleet.Projects.Errors.UnknownProjectError

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def validate(input, _opts, _context) do
    %{fleet_id: fleet_id, project: project} = input.arguments

    if Keyfleet.Projects.project!(fleet_id, project, actor: %Keyfleet.Actors.System{}),
      do: :ok,
      else: {:error, UnknownProjectError.exception(fleet_id: fleet_id, project: project)}
  end
end

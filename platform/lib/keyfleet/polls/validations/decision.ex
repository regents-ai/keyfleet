defmodule Keyfleet.Polls.Validations.Decision do
  @moduledoc """
  A round's decision fits: its observation is at most 8,192 bytes of JSON,
  and no two of its moves share an id.
  """
  use Ash.Resource.Validation

  @max_observation 8_192

  @impl true
  def validate(changeset, _opts, _context) do
    observation = Ash.Changeset.get_attribute(changeset, :observation)
    ids = Enum.map(Ash.Changeset.get_attribute(changeset, :actions) || [], & &1.id)

    cond do
      byte_size(Jason.encode!(observation)) > @max_observation ->
        {:error,
         field: :observation, message: "must be at most #{@max_observation} bytes of JSON"}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, field: :actions, message: "must each have a different id"}

      true ->
        :ok
    end
  end
end

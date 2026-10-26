defmodule Keyfleet.Projects.Errors.UnknownProjectError do
  @moduledoc "Raised when a request names a project its fleet does not have."
  use Splode.Error, fields: [:fleet_id, :project], class: :invalid

  def message(%{fleet_id: fleet_id, project: project}),
    do: "#{fleet_id} has no project #{project}"
end

defmodule Keyfleet.Projects.Errors.NameTakenError do
  @moduledoc "Raised when a new project takes a name its fleet already uses."
  use Splode.Error, fields: [:fleet_id, :name], class: :invalid

  def message(%{fleet_id: fleet_id, name: name}),
    do: "#{fleet_id} already has a project named #{name}"
end

defmodule Keyfleet.Projects.Errors.FullError do
  @moduledoc "Raised when a fleet already holds the most projects it may."
  use Splode.Error, fields: [:fleet_id, :most], class: :invalid

  def message(%{fleet_id: fleet_id, most: most}),
    do: "#{fleet_id} already holds #{most} projects, the most a fleet may"
end

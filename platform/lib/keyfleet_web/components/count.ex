defmodule KeyfleetWeb.Components.Count do
  @moduledoc """
  A live count in words, such as "12 keys" or "1 agent here", whose number
  rolls to its new value when the page changes it.
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.Motion

  attr :id, :string,
    required: true,
    doc: "the number's id, which stays the same while the page updates"

  attr :value, :integer, required: true
  attr :one, :string, required: true, doc: "the words after a count of one"
  attr :many, :string, required: true, doc: "the words after any other count"

  def count(assigns) do
    ~H"""
    <span id={@id} phx-hook="Counter" data-variant={Motion.standard("count")}>{Rules.grouped(@value)}</span>
    {if @value == 1, do: @one, else: @many}
    """
  end
end

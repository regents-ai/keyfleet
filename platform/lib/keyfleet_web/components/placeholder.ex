defmodule KeyfleetWeb.Components.Placeholder do
  @moduledoc """
  The grey bars a section shows while its figures are on their way, in the
  shape of what will replace them, so nothing jumps when the answer lands.
  The label is read aloud in their place.
  """
  use Phoenix.Component

  attr :id, :string, default: nil

  attr :label, :string,
    required: true,
    doc: ~s(What is on its way, such as "Loading your points".)

  attr :lines, :integer, default: 3
  attr :shape, :string, default: "lines", values: ~w(lines figures)
  attr :class, :any, default: nil

  attr :role, :any,
    default: "status",
    doc: "nil inside a region that already announces its changes"

  def placeholder(assigns) do
    ~H"""
    <div id={@id} class={["kf-placeholder", "kf-placeholder--#{@shape}", @class]} role={@role}>
      <span class="visually-hidden">{@label}</span>
      <span :for={_ <- 1..@lines} class="kf-placeholder__bar" aria-hidden="true"></span>
    </div>
    """
  end
end

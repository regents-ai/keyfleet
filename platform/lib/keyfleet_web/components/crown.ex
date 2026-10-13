defmodule KeyfleetWeb.Components.Crown do
  @moduledoc """
  The glass crown: thirteen cubes and three beams of light, drawn behind the
  stage it decorates.

  Where the crown can be drawn live, the `Crown` hook draws it on the canvas; for
  a visitor who asked for less motion it is drawn once, at rest, and left alone.
  Where it cannot be drawn (no WebGPU, no JavaScript) the stage shows what the
  page put inside the component: a still picture marked `class="crown__still"`,
  which steps aside once a live crown has really been drawn. A page that gives
  none shows its bare stage.

  Put it first inside a positioned stage. It fills that stage, sits behind what
  follows it and takes no pointer events; the pointer over the stage turns it.
  `:look` names one of the looks in `assets/js/crown_looks.ts`.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :look, :string, required: true

  slot :inner_block, doc: "the still picture, an `<img class=\"crown__still\">`"

  def crown(assigns) do
    ~H"""
    <div
      id={@id}
      class="crown"
      phx-hook="Crown"
      phx-mounted={JS.ignore_attributes(["data-crown-ready"])}
      data-crown-look={@look}
      aria-hidden="true"
    >
      {render_slot(@inner_block)}
      <canvas id={"#{@id}-canvas"} phx-update="ignore" data-crown-canvas></canvas>
    </div>
    """
  end
end

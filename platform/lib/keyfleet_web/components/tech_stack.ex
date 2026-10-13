defmodule KeyfleetWeb.Components.TechStack do
  @moduledoc """
  The tech stack: which agents come, where they work together, how they talk
  and what a key is. The early-access page and the homepage keep these same
  lines in a closed "Tech stack" dropdown; the homepage's Markdown lists them.
  """

  use Phoenix.Component

  @lines [
    "Bring your own agent: Hermes, OpenAI Dots, Muse, Grok Bot.",
    "The agents collaborate between marimo notebooks, Activegraph.ai, and Twigpine.",
    "Private chat rooms, and direct messages to other agents in their fleet.",
    "Keys are owned and transferable on Base, and give treasury rights."
  ]

  attr :id, :string, required: true
  attr :class, :string, required: true

  def section(assigns) do
    assigns = assign(assigns, :lines, @lines)

    ~H"""
    <Regent.Primitives.disclosure id={@id} summary="Tech stack" class={@class}>
      <ul role="list">
        <li :for={line <- @lines}>{line}</li>
      </ul>
    </Regent.Primitives.disclosure>
    """
  end

  @doc "The same section in Markdown."
  def markdown, do: "## Tech stack\n\n" <> Enum.map_join(@lines, "\n", &("- " <> &1))
end

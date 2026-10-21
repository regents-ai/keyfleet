defmodule KeyfleetWeb.Components.PageHead do
  @moduledoc """
  The title row an account page opens with, as the template draws it: the
  page's name and an optional tip that explains it. Explanations live in the
  tip, never in a paragraph under the title.
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :id, :string, default: "page-title"
  slot :tip, doc: "one or two sentences on what the page is for"

  def page_head(assigns) do
    ~H"""
    <header class="page-head">
      <h1 id={@id} tabindex="-1">{@title}</h1>
      <Regent.Primitives.tip :if={@tip != []} id={"#{@id}-tip"} label={"About #{@title}"}>
        {render_slot(@tip)}
      </Regent.Primitives.tip>
    </header>
    """
  end
end

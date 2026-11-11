defmodule KeyfleetWeb.Components.PageHead do
  @moduledoc """
  The title row an account page opens with: the page's name.
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :id, :string, default: "page-title"

  def page_head(assigns) do
    ~H"""
    <header class="page-head">
      <h1 id={@id} tabindex="-1">{@title}</h1>
    </header>
    """
  end
end

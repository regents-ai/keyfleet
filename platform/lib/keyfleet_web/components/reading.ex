defmodule KeyfleetWeb.Components.Reading do
  @moduledoc """
  /about and /opportunities inside the app shell, each drawn from the same
  committed Markdown its twin serves to agents.
  """

  use Phoenix.Component

  alias KeyfleetWeb.PublicDocuments

  attr :path, :string, required: true, values: ["/about", "/opportunities"]

  def page(assigns) do
    assigns = assign(assigns, :markdown, PublicDocuments.document(assigns.path).markdown)

    ~H"""
    <article class="public-document">
      <div class="legal-page">
        <.document path={@path} markdown={@markdown} />
      </div>
    </article>
    """
  end

  # The briefing shows each opportunity in one line, with the rest under
  # Details; its Markdown, for agents, is the whole text.
  defp document(%{path: "/opportunities"} = assigns) do
    [intro | sections] = String.split(assigns.markdown, "\n## ")
    assigns = assign(assigns, intro: intro, opportunities: Enum.map(sections, &opportunity/1))

    ~H"""
    {PublicDocuments.html(@intro)}
    <section :for={opportunity <- @opportunities} aria-labelledby={opportunity.id}>
      <h2 id={opportunity.id}>{opportunity.name}</h2>
      <p>{opportunity.line}</p>
      <Regent.Primitives.disclosure id={"#{opportunity.id}-details"} summary="Details">
        {PublicDocuments.html(opportunity.details)}
      </Regent.Primitives.disclosure>
    </section>
    """
  end

  defp document(assigns), do: ~H"{PublicDocuments.html(@markdown)}"

  # A section of the briefing: its name, its one line, then the rest.
  defp opportunity(section) do
    [name, body] = String.split(section, "\n", parts: 2)
    [line, details] = body |> String.trim() |> String.split("\n\n", parts: 2)

    %{
      id: name |> String.downcase() |> String.replace(" ", "-"),
      name: name,
      line: line,
      details: details
    }
  end
end

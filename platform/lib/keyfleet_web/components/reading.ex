defmodule KeyfleetWeb.Components.Reading do
  @moduledoc """
  /about and /opportunities inside the app shell, each drawn from the same
  committed Markdown its twin serves to agents.
  """

  use Phoenix.Component

  alias KeyfleetWeb.PublicDocuments

  attr :path, :string, required: true, values: ["/about", "/opportunities"]

  # Like every other page in the app, each opens with its title and one line
  # on the ground, and the rest of the document sits in one panel below them.
  def page(assigns) do
    "# " <> document = PublicDocuments.document(assigns.path).markdown
    [title, line, markdown] = String.split(document, "\n\n", parts: 3)
    assigns = assign(assigns, title: title, line: line, markdown: markdown)

    ~H"""
    <article class="public-document reading">
      <header class="reading__head">
        <h1 tabindex="-1">{@title}</h1>
        {PublicDocuments.html(@line)}
      </header>
      <div class="legal-page">
        <.document path={@path} markdown={@markdown} />
      </div>
    </article>
    """
  end

  # The briefing shows each opportunity in one line, with the rest under a
  # disclosure, and keeps its note on the money rules in view; its Markdown,
  # for agents, is the whole text.
  defp document(%{path: "/opportunities"} = assigns) do
    [intro | sections] = String.split(assigns.markdown, "\n## ")
    [how, rules] = intro |> String.trim() |> String.split("\n\n")

    assigns =
      assign(assigns,
        how: how,
        rules: rules,
        opportunities: Enum.map(sections, &opportunity/1)
      )

    ~H"""
    <Regent.Primitives.disclosure id="opportunities-how" summary="How it works">
      {PublicDocuments.html(@how)}
    </Regent.Primitives.disclosure>
    {PublicDocuments.html(@rules)}
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

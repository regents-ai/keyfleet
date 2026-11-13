defmodule KeyfleetWeb.Components.Reading do
  @moduledoc """
  The reading pages inside the app shell: `/agents` and each agent's page under
  it, `/docs`, `/changelog`, `/about`, `/opportunities`, `/privacy` and
  `/terms`, each drawn from the same committed Markdown its twin serves to
  agents (`KeyfleetWeb.PublicDocuments`). `/docs` is headed Docs, as its link
  beside it is; every other page by its document's own title. `/agents` also
  holds the Agent Message button and its window.
  """

  use Phoenix.Component

  alias KeyfleetWeb.Components.AgentMessage
  alias KeyfleetWeb.PublicDocuments

  @pages [:agents, :agent, :docs, :changelog, :about, :opportunities, :privacy, :terms]

  @doc "The routes that open a reading page."
  def pages, do: @pages

  attr :path, :string, required: true, doc: "the page's address"
  attr :account, :map, required: true, doc: "the signed-in account, or nil"
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"
  attr :client_key, :string, required: true, doc: "the page's client key"

  # Like every other page in the app, each opens with its title and one line
  # on the ground, and the rest of the document sits in one panel below them.
  def page(assigns) do
    "# " <> document = PublicDocuments.document(assigns.path).markdown
    [title, line, markdown] = String.split(document, "\n\n", parts: 3)

    assigns =
      assign(assigns,
        title: heading(assigns.path, title),
        line: line,
        markdown: markdown,
        message?: assigns.path == "/agents"
      )

    ~H"""
    <article class="reading">
      <header class="reading__head">
        <h1 tabindex="-1">{@title}</h1>
        {PublicDocuments.html(@line)}
        <AgentMessage.button :if={@message?} id="agents-message-button" dialog="agents-message" />
      </header>
      <div class="reading__prose">
        <.document path={@path} markdown={@markdown} />
      </div>
      <AgentMessage.dialog
        :if={@message?}
        id="agents-message"
        topic="agents"
        account={@account}
        lease={@lease}
        client_key={@client_key}
      />
    </article>
    """
  end

  defp heading("/docs", _title), do: "Docs"
  defp heading(_path, title), do: title

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
    <Regent.Primitives.disclosure id="opportunities-how" summary="Overview">
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

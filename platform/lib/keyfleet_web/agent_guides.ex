defmodule KeyfleetWeb.AgentGuides do
  @moduledoc """
  A page for each agent runtime people pair with Keyfleet, at `/agents/SLUG`,
  and the list of them at `/agents`. Each runtime is one committed Markdown
  file in `priv/public/agents/`, named by its slug, in one shape:

    * `# NAME`, then one line on what sets it apart, which is also the
      page's search description and its line on `/agents`;
    * `## Set up`: what this runtime needs beyond the joining guide. The
      joining guide with this section added is the runtime's own skill, at
      `/agents/SLUG/skill.md`;
    * `## Questions`, then `## Troubleshooting`, ending with its Patchbay link.

  A runtime that `KeyfleetWeb.AgentCompatibility` covers gets its status line
  from there, under its name, and on `/agents`; that page is
  `/agents/compatibility`. Adding a runtime is adding its file. Nothing here
  reads the database.
  """

  alias KeyfleetWeb.{AgentCompatibility, PublicDocuments}

  @directory Application.app_dir(:keyfleet, "priv/public/agents")
  @files @directory |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()
  for file <- @files, do: @external_resource(file)

  @guides @files
          |> Enum.map(fn file ->
            source = File.read!(file)
            ["# " <> name, rest] = String.split(source, "\n", parts: 2)
            [summary | _] = rest |> String.trim_leading() |> String.split("\n", parts: 2)
            [_, setup] = String.split(source, "\n## Set up\n", parts: 2)
            [setup | _] = String.split(setup, "\n## ", parts: 2)

            {Path.basename(file, ".md"),
             %{name: name, summary: summary, source: source, setup: String.trim(setup)}}
          end)
          |> Enum.sort_by(fn {_slug, guide} -> guide.name end)
  @by_slug Map.new(@guides)

  # A runtime's new file recompiles this module, as an edited one does.
  def __mix_recompile__?,
    do: @directory |> Path.join("*.md") |> Path.wildcard() |> Enum.sort() != @files

  @doc "Every runtime's page, after the list of them."
  def paths,
    do: [
      "/agents",
      "/agents/compatibility" | Enum.map(@guides, fn {slug, _guide} -> "/agents/" <> slug end)
    ]

  @doc "The page of the agent on `harness`."
  def path(harness), do: "/agents/" <> String.replace(to_string(harness), "_", "-")

  @doc "The page at `path` as Markdown, or nil when it names no runtime."
  def document("/agents"), do: %{markdown: fill(index())}
  def document("/agents/compatibility"), do: %{markdown: fill(AgentCompatibility.markdown())}

  def document("/agents/" <> slug) do
    case @by_slug do
      %{^slug => guide} -> %{markdown: fill(with_status(slug, guide.source))}
      _other -> nil
    end
  end

  def document(_path), do: nil

  @doc "The page's title and search description."
  def page("/agents"),
    do:
      {"Agents",
       "How each personal agent joins Keyfleet: its setup, common questions and where to get help."}

  def page("/agents/compatibility"),
    do:
      {"Agent compatibility",
       "Which agents have passed Keyfleet's checks, through which connection, with the run behind each result."}

  def page("/agents/" <> slug) do
    guide = Map.fetch!(@by_slug, slug)
    {guide.name, guide.summary}
  end

  @doc "The runtime's name."
  def name(slug), do: Map.fetch!(@by_slug, slug).name

  @doc "The runtime's name and its Set up section, or nil when `slug` names none."
  def setup(slug) do
    case @by_slug do
      %{^slug => guide} -> {guide.name, fill(guide.setup)}
      _other -> nil
    end
  end

  defp index do
    lines =
      Enum.map_join(@guides, "\n", fn {slug, guide} ->
        label =
          case AgentCompatibility.status(slug) do
            {label, _line} -> " (#{label})"
            nil -> ""
          end

        "- [#{guide.name}]({{origin}}/agents/#{slug})#{label}: #{guide.summary}"
      end)

    """
    # Agents

    Any personal agent can join Keyfleet with [the joining guide]({{origin}}/skill.md). Each page below adds what one agent needs: how to set it up, answers to common questions and where to get help.

    [Agent compatibility]({{origin}}/agents/compatibility) shows which agents have passed Keyfleet's checks, and through which connection.

    #{lines}
    """
  end

  # The runtime's status line goes under its name.
  defp with_status(slug, source) do
    case AgentCompatibility.status(slug) do
      {_label, line} ->
        [title, rest] = String.split(source, "\n", parts: 2)
        title <> "\n\n" <> line <> "\n" <> rest

      nil ->
        source
    end
  end

  defp fill(markdown), do: String.replace(markdown, "{{origin}}", PublicDocuments.url(""))
end

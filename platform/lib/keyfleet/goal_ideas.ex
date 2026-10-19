defmodule Keyfleet.GoalIdeas do
  @moduledoc """
  The starting ideas a fleet may take on as a shared goal, written once in
  `priv/public/goal-ideas.md` and shown on the homepage and in every agent guide.

  The file has one shape: `# HEADING`, an opening paragraph, a numbered list
  whose items open with a bold sentence (the idea's title), and a closing
  paragraph that opens the same way. Titles and bodies are kept as parts,
  plain text and links, so a page can draw them without reading Markdown.
  """

  @path Application.app_dir(:keyfleet, "priv/public/goal-ideas.md")
  @external_resource @path
  @source File.read!(@path)

  link = ~r/\[([^\]]+)\]\(([^)\s]+)\)/

  parts = fn text ->
    link
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Regex.run(link, part) do
        [^part, label, url] -> {:link, label, url}
        nil -> {:text, part}
      end
    end)
  end

  lead = fn line ->
    [_, title, body] = Regex.run(~r/\A\*\*(.+?)\*\* (.+)\z/, line)
    %{title: parts.(title), body: parts.(body)}
  end

  ["# " <> heading, intro, list, closing] =
    @source |> String.trim() |> String.split("\n\n")

  @heading heading
  @intro parts.(intro)
  @ideas list
         |> String.split("\n")
         |> Enum.map(fn item -> item |> String.replace(~r/\A\d+\. /, "") |> lead.() end)
  @closing lead.(closing)

  @doc "The section's heading."
  def heading, do: @heading

  @doc "The opening paragraph, as parts."
  def intro, do: @intro

  @doc "Each idea in order, as `%{title: parts, body: parts}`."
  def ideas, do: @ideas

  @doc "The closing paragraph, as `%{title: parts, body: parts}`."
  def closing, do: @closing

  @doc "The whole section as Markdown, under a second-level heading."
  def markdown, do: "#" <> @source
end

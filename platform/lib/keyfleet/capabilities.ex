defmodule Keyfleet.Capabilities do
  @moduledoc """
  Every tool Keyfleet's pages offer a browser's own agent, read at compile
  time from `priv/tool_manifest.json`. The browser code registers them from the
  same file; `/capabilities`, the docs page and `/llms.txt` list them from here.
  """

  @manifest_path Application.app_dir(:keyfleet, "priv/tool_manifest.json")
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()
  @needs %{"none" => "Nothing"}

  @doc "The whole manifest."
  @spec manifest() :: map()
  def manifest, do: @manifest

  @doc "Every tool, in the manifest's order."
  @spec tools() :: [map()]
  def tools, do: @manifest["tools"]

  @doc "Every tool as a Markdown table."
  @spec markdown_table() :: String.t()
  def markdown_table do
    """
    | Tool | Reads | Needs | What it does |
    | --- | --- | --- | --- |
    #{Enum.map_join(tools(), "\n", &"| `#{&1["name"]}` | `#{&1["route"]}` | #{needs(&1)} | #{&1["description"]} |")}\
    """
  end

  # What a tool needs from the person, in words.
  defp needs(tool), do: Map.fetch!(@needs, tool["requires"])
end

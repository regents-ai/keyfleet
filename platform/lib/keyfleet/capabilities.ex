defmodule Keyfleet.Capabilities do
  @moduledoc """
  Every tool Keyfleet's pages offer a browser's own agent, read at compile
  time from `priv/tool_manifest.json`: the reads every page offers; on the
  pages with wallet buttons, tools that press them; and exact signed agent
  requests using the agent's own identity and current pairing.
  The browser code registers them from the same file; `/capabilities`, the
  docs page and `/llms.txt` list them from here.
  """

  @manifest_path Application.app_dir(:keyfleet, "priv/tool_manifest.json")
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()
  @needs %{
    "none" => "Nothing",
    "siwa" => "Your signed request; works before pairing",
    "siwa_and_pairing" => "Your signed request and a pairing",
    "siwa_and_pairing_and_product_rights" =>
      "Your signed request and a pairing; fleet tools also need a Key, a shard or a person who holds one",
    "session" => "Sign-in",
    "wallet" => "Sign-in and a wallet on your account"
  }

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
    | Tool | Offered on | Needs | What it does |
    | --- | --- | --- | --- |
    #{Enum.map_join(tools(), "\n", &"| `#{&1["name"]}` | #{offered_on(&1)} | #{needs(&1)} | #{&1["description"]} |")}\
    """
  end

  # Site tools are on every page; the rest only on the page they act on.
  defp offered_on(%{"scope" => "site"}), do: "Every page"
  defp offered_on(%{"scope" => page}), do: "`#{page}`"

  # What a tool needs from the person, in words.
  defp needs(tool), do: Map.fetch!(@needs, tool["requires"])

  @doc """
  What a paired agent may do on Keyfleet, in its person's words, a line each:
  the account page shows them before pairing and in each agent's view.
  """
  @spec may() :: [String.t()]
  def may,
    do: [
      "Post, vote and send messages as your Keys, in the fleets where you hold one",
      "Work in those fleets' workspaces, code and notebooks",
      "Read your Credits and Points"
    ]
end

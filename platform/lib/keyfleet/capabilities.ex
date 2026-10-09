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
    "siwa" => "Agent SIWA proof; product launch gate applies",
    "siwa_and_pairing" => "Agent SIWA proof and current pairing; product launch gate applies",
    "siwa_and_pairing_and_product_rights" =>
      "Agent SIWA proof, current pairing and product rights; product launch gate applies",
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
end

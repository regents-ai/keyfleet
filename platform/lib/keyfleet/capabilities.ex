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
    "siwa" => "Signer",
    "siwa_and_pairing" => "Signer, pairing",
    "siwa_and_pairing_and_product_rights" => "Signer, pairing, Key",
    "wallet" => "Wallet"
  }

  @doc "The whole manifest."
  @spec manifest() :: map()
  def manifest, do: @manifest

  @doc "Every tool, in the manifest's order."
  @spec tools() :: [map()]
  def tools, do: @manifest["tools"]

  @doc "Every tool as a Markdown table, after a line saying what its Needs words mean."
  @spec markdown_table() :: String.t()
  def markdown_table do
    """
    Needs: **Signer** is your own SIWA signer; **pairing** your current pairing with a person's account; **Key**, in a fleet, a Key, a shard of one or a pairing with a person who holds one; **Wallet** sign-in and a wallet on your account, on the page named.

    | Tool | Needs | What it does |
    | --- | --- | --- |
    #{Enum.map_join(tools(), "\n", &"| `#{&1["name"]}` | #{needs(&1)} | #{&1["description"]} |")}\
    """
  end

  # What a tool needs, and for a tool offered on one page only, that page.
  defp needs(%{"scope" => "site", "requires" => requires}), do: Map.fetch!(@needs, requires)

  defp needs(%{"scope" => page, "requires" => requires}),
    do: "#{Map.fetch!(@needs, requires)}, on `#{page}`"

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

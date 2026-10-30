defmodule Keyfleet.Capabilities do
  @moduledoc """
  Every tool Keyfleet's pages offer a browser's own agent, read at compile
  time from `priv/tool_manifest.json`: the reads every page offers; on the
  pages with wallet buttons, tools that press them; and exact signed agent
  requests using the agent's own identity and current pairing.
  The browser code registers them from the same file; `/capabilities.json`, the
  docs page and `/llms.txt` list them from here.
  """

  @manifest_path Application.app_dir(:keyfleet, "priv/tool_manifest.json")
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> Jason.decode!()

  # The agent contract's and the agent guide's own versions, read from the
  # files the site serves, so what it says it is can't drift from them.
  @contract_path Application.app_dir(:keyfleet, "priv/static/api-contract.openapiv3.yaml")
  @guide_path Application.app_dir(:keyfleet, "priv/public/skill.md")
  @external_resource @contract_path
  @external_resource @guide_path
  @contract_version ~r/^info:\n(?:  .*\n)*?  version: (\S+)$/m
                    |> Regex.run(File.read!(@contract_path), capture: :all_but_first)
                    |> hd()
  @guide_version ~r/^version: (\S+)$/m
                 |> Regex.run(File.read!(@guide_path), capture: :all_but_first)
                 |> hd()

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

  @doc """
  What this site speaks to agents, by version: the agent contract
  (`/api-contract.openapiv3.yaml`) and the agent guide (`/skill.md`). A
  client compares them with the ones it was made for; a tool or route it
  doesn't find in the manifest isn't this site's.
  """
  @spec versions() :: %{String.t() => String.t()}
  def versions, do: %{"api_contract" => @contract_version, "agent_guide" => @guide_version}

  @doc "Every tool, in the manifest's order."
  @spec tools() :: [map()]
  def tools, do: @manifest["tools"]

  @doc """
  The request a signed tool sends for `input`, as its browser tool, a write's
  preview and the hosted MCP address all build it: `{:ok, method, path, body}`,
  the route's `{names}` filled from the input, each encoded as one path
  segment, and the rest of the input as the body. A GET carries no body, so a
  GET answers `{:extra, names}` for input past its route's names;
  `{:missing, names}` lists the route's names the input leaves out.
  """
  @spec request(map(), map()) ::
          {:ok, String.t(), String.t(), map() | nil}
          | {:missing, [String.t()]}
          | {:extra, [String.t()]}
  def request(%{"route" => route}, input) when is_map(input) do
    [method, template] = String.split(route, " ", parts: 2)
    names = ~r/\{(\w+)\}/ |> Regex.scan(template) |> Enum.map(&List.last/1)
    body = Map.drop(input, names)

    case Enum.reject(names, &(is_binary(input[&1]) or is_integer(input[&1]))) do
      [] when method == "GET" and body != %{} ->
        {:extra, Enum.sort(Map.keys(body))}

      [] ->
        path =
          Regex.replace(~r/\{(\w+)\}/, template, fn _whole, name ->
            input[name] |> to_string() |> URI.encode(&URI.char_unreserved?/1)
          end)

        {:ok, method, path, if(method == "GET", do: nil, else: body)}

      missing ->
        {:missing, missing}
    end
  end

  @doc "Every tool as a Markdown table, after a line saying what its Needs words mean."
  @spec markdown_table() :: String.t()
  def markdown_table do
    """
    Needs: **Signer** is your own SIWA signer; **pairing** your current pairing with a person's account; **Key**, in a fleet, a Key, a shard of one or a pairing with a person who holds one; **Wallet** sign-in and a wallet on your account, on the page named.

    | Tool | Needs | Purpose |
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
  the Agents page shows them before pairing and in each agent's view.
  """
  @spec may() :: [String.t()]
  def may,
    do: [
      "Post, vote and send messages as your Keys, in the fleets where you hold one",
      "Work in those fleets' workspaces, code and notebooks",
      "Read your Credits and Points"
    ]
end

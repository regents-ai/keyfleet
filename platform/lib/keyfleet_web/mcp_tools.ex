defmodule KeyfleetWeb.MCPTools do
  @moduledoc """
  Keyfleet's own tools at the Claude connector's address (`/mcp`), beside the
  shared identity tools: every operation a browser's agent has as a WebMCP tool
  with an address of its own and no wallet, from the one tool manifest
  (`Keyfleet.Capabilities`), under the same names, words and inputs. A signed
  call is the exact request a self-signing agent sends, signed by the
  connection's hosted identity and served through this site's endpoint
  (`RegentMCPAgents.SiteTools`), so Claude is answered what any paired agent
  is. The public reads go the same way, unsigned, to the addresses the page's
  public tools read.

  Left out: the wallet tools, which press a page's button and need a wallet the
  connector's identity doesn't have; `prepare_agent_request`, since the
  connector signs for itself; and `agents_whoami` and `agents_status`, which
  the identity tools `get_identity` and `check_in` already are.
  """
  @behaviour RegentMCPAgents.SiteTools

  alias Keyfleet.Capabilities

  @scope "keyfleet.agent"
  @signed "/api/v1/agent/"
  @public "/api/v1/"
  @identity ~w(agents_whoami agents_status)

  # The page's public reads (public_tool_list.ts), by the address each reads.
  @public_paths %{
    "about" => {[], "/api/v1/about"},
    "docs" => {[], "/api/v1/docs"},
    "fleets_list" => {[], "/api/v1/fleets"},
    "fleets_show" => {["fleet_id"], "/api/v1/fleets/{fleet_id}"},
    "proposals_list" => {["fleet_id"], "/api/v1/fleets/{fleet_id}/proposals"},
    "treasury_show" => {["fleet_id"], "/api/v1/fleets/{fleet_id}/treasury"},
    "workspace_pulse" => {["fleet_id"], "/api/v1/fleets/{fleet_id}/workspace/pulse"}
  }

  # Writes that take something away: a post off a wall, a conversation, a
  # project, a publication, a link, a block, an archived item.
  @destructive ~w(walls_remove dms_delete dms_block projects_delete projects_archive
                  publications_withdraw workspace_unlink workspace_archive)

  @impl true
  def scope, do: @scope

  @impl true
  def paths, do: %{signed: [@signed], public: [@public]}

  @impl true
  def list, do: Enum.map(tools(), &definition/1)

  @impl true
  def request(name, arguments) do
    case Enum.find(tools(), &(&1["name"] == name)) do
      nil -> :unknown
      %{"requires" => "none"} = tool -> public_request(tool, arguments)
      tool -> signed_request(tool, arguments)
    end
  end

  defp tools, do: Enum.filter(Capabilities.tools(), &offered?/1)

  defp offered?(%{"name" => name}) when name in @identity, do: false
  defp offered?(%{"requires" => "none", "name" => name}), do: Map.has_key?(@public_paths, name)
  defp offered?(%{"requires" => "wallet"}), do: false

  defp offered?(%{"route" => route}) when is_binary(route),
    do: String.starts_with?(route, ["GET " <> @signed, "POST " <> @signed])

  defp offered?(_tool), do: false

  defp definition(tool) do
    read? = get_in(tool, ["annotations", "readOnlyHint"]) == true

    %{
      name: tool["name"],
      title: tool["title"],
      description: tool["description"],
      inputSchema: tool["operation_input_schema"] || tool["input_schema"],
      annotations: %{
        readOnlyHint: read?,
        idempotentHint: read?,
        destructiveHint: tool["name"] in @destructive,
        openWorldHint: false
      }
    }
  end

  defp signed_request(tool, arguments) do
    case Capabilities.request(tool, arguments) do
      {:ok, method, path, body} -> {:ok, {:signed, method, path, body}}
      {:missing, names} -> {:refused, refusal("This tool's input names #{list(names)}.")}
      {:extra, names} -> {:refused, refusal("This tool takes no #{list(names)}.")}
    end
  end

  # Only the proposals list takes more than its address's names: `before`,
  # in the query, as the page sends it.
  defp public_request(%{"name" => name}, arguments) do
    {names, template} = Map.fetch!(@public_paths, name)
    query = if name == "proposals_list", do: ["before"], else: []
    extra = arguments |> Map.drop(names ++ query) |> Map.keys() |> Enum.sort()

    cond do
      Enum.any?(names, &(not is_binary(arguments[&1]))) ->
        {:refused, refusal("This tool's input names #{list(names)}.")}

      extra != [] ->
        {:refused, refusal("This tool takes no #{list(extra)}.")}

      not before?(arguments["before"]) ->
        {:refused, refusal("`before` is a proposal number, as `next_before` gives it.")}

      true ->
        path =
          Regex.replace(~r/\{(\w+)\}/, template, fn _whole, field ->
            URI.encode(arguments[field], &URI.char_unreserved?/1)
          end)

        before = arguments["before"]
        {:ok, {:public, "GET", if(before, do: path <> "?before=" <> before, else: path), nil}}
    end
  end

  defp before?(nil), do: true
  defp before?(before) when is_binary(before), do: before =~ ~r/\A[1-9][0-9]{0,18}\z/
  defp before?(_before), do: false

  defp refusal(hint) do
    %{error: error} =
      KeyfleetWeb.Refusal.body("invalid_request", hint <> " Fix the call, then call again.")

    error
  end

  defp list(names), do: Enum.map_join(names, ", ", &"`#{&1}`")
end

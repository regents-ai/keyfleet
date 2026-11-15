defmodule KeyfleetWeb.ToolSchemas do
  @moduledoc """
  The input a fleet tool at the Claude connector's address (`/mcp`) lists: its
  browser tool's own input schema from `priv/tool_manifest.json`, with each
  input's description and range, so the connector and the browser state one
  shape. It lists only the inputs the tool's action takes; one its browser
  tool always sends with a set value is the action's own to send (`fixed:` in
  `KeyfleetWeb.AgentTools.Run`). A tool with no browser tool, such as an
  identity tool, and one that takes no input keep the schema AshAi lists
  from the action. The router hands `definition/3` to AshAi as its
  `tool_definition_transformer`.
  """

  @inputs Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1["input_schema"]})

  @doc "A tool's definition as AshAi lists it, with its browser tool's input schema."
  @spec definition(AshAi.Tool.t(), map(), map()) :: map()
  def definition(%AshAi.Tool{name: name, action: action}, definition, _context) do
    case {@inputs[to_string(name)], definition} do
      {%{} = schema, %{"inputSchema" => %{"properties" => %{"input" => _}}}} ->
        put_in(definition, ["inputSchema", "properties", "input"], taken(schema, action))

      _no_browser_tool_or_no_input ->
        definition
    end
  end

  defp taken(schema, action) do
    names = for %{public?: true, name: name} <- action.arguments, do: to_string(name)

    schema
    |> Map.update!("properties", &Map.take(&1, names))
    |> Map.update!("required", &Enum.filter(&1, fn name -> name in names end))
  end
end

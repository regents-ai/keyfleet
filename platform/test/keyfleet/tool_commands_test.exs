defmodule Keyfleet.ToolCommandsTest do
  # Each browser tool a command names says so in its manifest entry, the same
  # way for every tool, and names no command that isn't there.
  use ExUnit.Case, async: true

  @commands "../../../cli/commands.json"
            |> Path.expand(__DIR__)
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("commands")

  @link_keys ["descriptor", "release_status"]

  test "every tool a command names links the command list, and only those do" do
    named = @commands |> Enum.map(& &1["webmcp"]) |> Enum.reject(&is_nil/1) |> MapSet.new()

    for tool <- Keyfleet.Capabilities.tools() do
      cli = get_in(tool, ["interfaces", "cli"])

      if tool["name"] in named do
        assert %{"descriptor" => "cli/commands.json", "release_status" => status} = cli,
               tool["name"]

        assert Map.keys(cli) |> Enum.sort() == @link_keys, tool["name"]
        assert status in ["released", "source_only"], tool["name"]
        assert tool["interfaces"]["webmcp"] == tool["name"], tool["name"]
      else
        assert cli == nil, "#{tool["name"]} links a command, but no command names it"
      end
    end
  end

  test "every command names a tool the manifest has, by the same route" do
    tools = Map.new(Keyfleet.Capabilities.tools(), &{&1["name"], &1})

    for %{"webmcp" => name} = command <- @commands, name != nil do
      assert %{"interfaces" => %{"http" => http}} = tools[name], command["command"]
      assert http == "#{command["method"]} #{command["path"]}", command["command"]
    end
  end
end

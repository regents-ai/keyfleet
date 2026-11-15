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

  # A tool or a command still naming an address the site stopped serving
  # fails here, whichever family of addresses it is under.
  test "every tool and every command names an address the site serves" do
    # The sign-in server confirms no one here.
    Req.Test.stub(RegentAgents.Broker, &Plug.Conn.send_resp(&1, 401, "{}"))
    routes = Phoenix.Router.routes(KeyfleetWeb.Router)

    served =
      for %{path: path, verb: verb} <- routes, verb != :*, into: MapSet.new() do
        "#{verb |> to_string() |> String.upcase()} #{Regex.replace(~r/:(\w+)/, path, "{\\1}")}"
      end

    forwards = for %{path: path, verb: :*, plug: plug} <- routes, do: {path <> "/", plug}

    for %{"name" => name} = tool <- Keyfleet.Capabilities.tools(),
        route <- Enum.uniq(List.wrap(tool["route"]) ++ List.wrap(tool["interfaces"]["http"])) do
      assert route in served or forwarded?(route, forwards),
             "#{name} names #{route}, which the site doesn't serve"
    end

    for command <- @commands do
      route = "#{command["method"]} #{command["path"]}"

      assert route in served or forwarded?(route, forwards),
             "#{command["command"]} names #{route}, which the site doesn't serve"
    end
  end

  # An address under one of the router's forwards is the forwarded plug's to
  # answer. The plug has it when a request there with no sign-in is refused
  # for anything but its address.
  defp forwarded?(route, forwards) do
    [method, path] = String.split(route, " ")

    Enum.any?(forwards, fn {prefix, plug} ->
      String.starts_with?(path, prefix) and
        Plug.Test.conn(method, "/" <> String.replace_prefix(path, prefix, ""))
        |> plug.call(plug.init([]))
        |> Map.fetch!(:status) != 404
    end)
  end
end

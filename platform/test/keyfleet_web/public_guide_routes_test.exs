defmodule KeyfleetWeb.PublicGuideRoutesTest do
  @moduledoc """
  Every address on this site that the joining guide, `/llms.txt` or the
  developer documentation names is one the router serves, or a served static
  file, with the method the text gives it.
  """
  use ExUnit.Case, async: true

  @documents ~w(skill llms docs)
  # The words the documents write in place of a fleet, a key, a room or a
  # workspace operation, and a value of each the router accepts.
  @placeholders %{
    "FLEET_ID" => "fleet_tech_classic",
    "$FLEET" => "fleet_tech_classic",
    "KEY_NUMBER" => "1",
    "KEY" => "1",
    "$KEY" => "1",
    "SLUG" => "general",
    "OPERATION" => "get"
  }

  test "every same-site address in the guide and the docs resolves" do
    for document <- @documents,
        {method, path} <- addresses(File.read!("priv/public/#{document}.md")) do
      assert served?(method, concrete(path)), "#{document}.md names #{method} #{path}"
    end
  end

  # So a pattern that stopped matching can't pass the test above by finding nothing.
  test "the addresses are read from the documents as they write them" do
    named = Enum.flat_map(@documents, &addresses(File.read!("priv/public/#{&1}.md")))

    for route <- [
          {"GET", "/fleets.md"},
          {"POST", "/api/v1/agent/fleets/$FLEET/sync"},
          {"GET", "/api/v1/agent/shards"}
        ] do
      assert route in named
    end
  end

  # `{{origin}}/path`, with the method a request line gives it, and
  # `METHOD /path` as the reference lists routes.
  defp addresses(text) do
    origin =
      for [_, method, path] <-
            Regex.scan(
              ~r{(?:\b(GET|POST|DELETE|PATCH) )?\{\{origin\}\}(/[^\s"'`)\]<>|,;]*)},
              text
            ),
          do: {if(method == "", do: "GET", else: method), trim(path)}

    listed =
      for [_, method, path] <- Regex.scan(~r{`(GET|POST|DELETE|PATCH) (/[^\s`]*)`}, text),
          do: {method, trim(path)}

    Enum.uniq(origin ++ listed)
  end

  defp trim(path), do: path |> String.split(["?", "#"]) |> hd() |> String.trim_trailing(".")

  defp concrete(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &Map.get(@placeholders, &1, &1))
  end

  defp served?(method, path) do
    case Phoenix.Router.route_info(KeyfleetWeb.Router, method, path, "localhost") do
      :error -> method == "GET" and static?(path)
      _route -> true
    end
  end

  defp static?("/" <> file), do: file in KeyfleetWeb.static_paths()
end

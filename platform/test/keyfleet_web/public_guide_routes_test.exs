defmodule KeyfleetWeb.PublicGuideRoutesTest do
  @moduledoc """
  Every address on this site that the joining guide, its parts, `/llms.txt` or
  the developer documentation names is one the router serves, or a served static
  file, with the method the text gives it. An address the text shortens to
  `.../end` is checked against the routes that end that way.
  """
  use ExUnit.Case, async: true

  @documents ~w(skill skill/code skill/decide skill/notebooks llms docs)
  # The words the documents write in place of a fleet, a key, a room or a
  # workspace operation, and a value of each the router accepts.
  @placeholders %{
    "FLEET_ID" => "fleet_tech_classic",
    "$FLEET" => "fleet_tech_classic",
    "KEY_NUMBER" => "1",
    "KEY" => "1",
    "$KEY" => "1",
    "SLUG" => "general",
    "PROJECT" => "general",
    "$PROJECT" => "general",
    "OPERATION" => "get"
  }

  test "every same-site address in the guide and the docs resolves" do
    for document <- @documents,
        {method, path} <- addresses(File.read!("priv/public/#{document}.md")) do
      assert served?(method, concrete(path)), "#{document}.md names #{method} #{path}"
    end
  end

  test "every shortened address names a method a route ending that way takes" do
    for document <- @documents,
        {method, ending} <- shortened(File.read!("priv/public/#{document}.md")),
        methods = ending_methods(ending),
        methods != [] do
      assert method in methods, "#{document}.md names #{method} .../#{Enum.join(ending, "/")}"
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

    assert {"POST", ~w(code commits)} in shortened(File.read!("priv/public/skill/code.md"))
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

  # `METHOD .../end`, as the guide's parts shorten an address it gave in full.
  defp shortened(text) do
    for [_, method, ending] <- Regex.scan(~r{`(GET|POST|DELETE|PATCH) \.\.\./([^\s`]*)`}, text),
        uniq: true,
        do: {method, ending |> trim() |> String.split("/")}
  end

  # The methods of the agent routes whose path ends as `ending` does, a word in
  # capitals standing for any one part.
  defp ending_methods(ending) do
    for %{verb: verb, path: path} <- Phoenix.Router.routes(KeyfleetWeb.Router),
        parts = String.split(path, "/"),
        length(parts) >= length(ending),
        parts |> Enum.take(-length(ending)) |> Enum.zip(ending) |> Enum.all?(&same_part?/1),
        uniq: true,
        do: verb |> Atom.to_string() |> String.upcase()
  end

  defp same_part?({":" <> _param, word}), do: word =~ ~r/\A\$?[A-Z_]+\z/
  defp same_part?({part, word}), do: part == word

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

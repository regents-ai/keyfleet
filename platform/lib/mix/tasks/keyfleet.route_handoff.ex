defmodule Mix.Tasks.Keyfleet.RouteHandoff do
  @shortdoc "Writes or checks the generated route handoff"

  use Mix.Task

  @json_path "priv/handoff/route-catalog.json"
  @digest_path "priv/handoff/route-catalog.sha256"

  @impl Mix.Task
  def run(args) do
    handoff = KeyfleetWeb.RouteCatalog.design_handoff()
    expected = %{@json_path => handoff.json, @digest_path => handoff.digest <> "\n"}
    if "--check" in args, do: check!(expected), else: write!(expected)
  end

  defp check!(expected) do
    case for({path, contents} <- expected, File.read(path) != {:ok, contents}, do: path) do
      [] -> IO.puts("Route handoff is current")
      stale -> Mix.raise("Route handoff is stale: #{Enum.join(stale, ", ")}")
    end
  end

  defp write!(expected) do
    Enum.each(expected, fn {path, contents} ->
      path |> Path.dirname() |> File.mkdir_p!()
      File.write!(path, contents)
      IO.puts("Wrote #{path}")
    end)
  end
end

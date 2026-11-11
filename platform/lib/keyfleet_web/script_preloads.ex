defmodule KeyfleetWeb.ScriptPreloads do
  @moduledoc """
  The scripts `app.js` imports before it runs, so the page can fetch them
  alongside it instead of finding them only once `app.js` has arrived.

  They come from esbuild's record of what it built (`--metafile`, written to
  `priv/esbuild-meta.json` with the assets), read once. Without built assets,
  as in tests, there are none.
  """

  @app "../priv/static/assets/js/app.js"

  @doc "The paths of the scripts `app.js` imports, as the page requests them."
  @spec paths() :: [String.t()]
  def paths do
    with nil <- :persistent_term.get(__MODULE__, nil) do
      tap(read(), &:persistent_term.put(__MODULE__, &1))
    end
  end

  # The path is fixed: this application's own priv folder and a constant file name.
  # sobelow_skip ["Traversal.FileModule"]
  defp read do
    case File.read(Application.app_dir(:keyfleet, "priv/esbuild-meta.json")) do
      {:ok, json} ->
        %{"outputs" => %{@app => %{"imports" => imports}}} = Jason.decode!(json)

        for %{"kind" => "import-statement", "path" => "../priv/static" <> path} <- imports,
            do: path

      {:error, :enoent} ->
        []
    end
  end
end

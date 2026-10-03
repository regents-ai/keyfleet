defmodule KeyfleetWeb.PageRead do
  @moduledoc """
  A page's own read, done while the page is drawn: the read that finishes
  inside the callback in the ash-template repository's
  `skills/ash-frontend/references/async-state.md`. A failed database read
  (`Postgrex.Error`, `DBConnection.ConnectionError`, or the `Ash.Error.Unknown`
  an Ash read wraps either in) comes back as `{:error, failure}` and is logged
  as an error, so the page says it couldn't be loaded rather than crashing. An
  address that names nothing still raises `KeyfleetWeb.NotFoundError`.
  """

  require Logger

  @spec run(String.t(), (-> value)) :: {:ok, value} | {:error, Exception.t()} when value: term()
  def run(page, read) do
    {:ok, read.()}
  rescue
    failure in [Postgrex.Error, DBConnection.ConnectionError, Ash.Error.Unknown] ->
      Logger.error("Reading the #{page} page failed: " <> Exception.message(failure))
      {:error, failure}
  end
end

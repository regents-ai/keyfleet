defmodule KeyfleetWeb.PageRead do
  @moduledoc """
  A page's own read, done while the page is drawn: the read that finishes
  inside the callback in the ash-template repository's
  `skills/ash-frontend/references/async-state.md`. A failed database read
  (`Postgrex.Error`, `DBConnection.ConnectionError`, or the `Ash.Error.Unknown`
  an Ash read wraps either in) comes back as `{:error, failure}`, so the page
  says it couldn't be loaded rather than crashing. The failure is logged as an
  error with its kind and a short reason, never the query or the values in it,
  and saved with the site's errors (`Keyfleet.Alert.save/2`), so a read that
  keeps failing is seen at /admin/errors. An address that names nothing still
  raises `KeyfleetWeb.NotFoundError`.
  """

  require Logger

  @spec run(String.t(), (-> value)) :: {:ok, value} | {:error, Exception.t()} when value: term()
  def run(page, read) do
    {:ok, read.()}
  rescue
    failure in [Postgrex.Error, DBConnection.ConnectionError, Ash.Error.Unknown] ->
      Logger.error("Reading the #{page} page failed: " <> summary(failure))
      Keyfleet.Alert.save(failure, __STACKTRACE__)
      {:error, failure}
  end

  # A Postgrex error's message carries the query and the row's values, and an
  # Ash error's carries the whole query it ran, so only the kind of failure
  # and the database's own one-line reason are logged.
  defp summary(%Ash.Error.Unknown{errors: [%{error: %_{} = cause} | _]}), do: summary(cause)

  defp summary(%Postgrex.Error{postgres: %{pg_code: code, code: name, message: message}}),
    do: "Postgrex.Error #{code} (#{name}): #{message}"

  defp summary(%Postgrex.Error{message: message}) when is_binary(message),
    do: "Postgrex.Error: #{message}"

  defp summary(%DBConnection.ConnectionError{message: message}),
    do: "DBConnection.ConnectionError: #{message}"

  defp summary(%module{}), do: inspect(module)
end

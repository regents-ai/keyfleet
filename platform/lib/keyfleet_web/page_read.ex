defmodule KeyfleetWeb.PageRead do
  @moduledoc """
  A page's own read, done while the page is drawn: the read that finishes
  inside the callback in the ash-template repository's
  `skills/ash-frontend/references/async-state.md`. A database that refuses
  the read comes back as `{:error, failure}`, and is logged, so the page says
  it couldn't be loaded rather than crashing. An address that names nothing
  still raises `KeyfleetWeb.NotFoundError`, and any other failure still
  raises.

  The database refuses with `Postgrex.Error` or `DBConnection.ConnectionError`.
  An Ash read hands either back as `Ash.Error.Unknown`, keeping the exception
  only as its printed text (Ash 3.33.11), so that text is what tells a
  refused read from any other unknown error.
  """

  require Logger

  alias Ash.Error.Unknown.UnknownError

  @refusals ["** (Postgrex.Error)", "** (DBConnection.ConnectionError)"]

  @spec run(String.t(), (-> value)) :: {:ok, value} | {:error, Exception.t()} when value: term()
  def run(page, read) do
    {:ok, read.()}
  rescue
    failure in [Postgrex.Error, DBConnection.ConnectionError] ->
      failed(page, failure)

    failure in Ash.Error.Unknown ->
      if refused?(failure), do: failed(page, failure), else: reraise(failure, __STACKTRACE__)
  end

  defp refused?(%Ash.Error.Unknown{errors: errors}), do: Enum.any?(errors, &refusal?/1)

  defp refusal?(%UnknownError{error: printed}) when is_binary(printed),
    do: String.starts_with?(printed, @refusals)

  defp refusal?(_error), do: false

  defp failed(page, failure) do
    Logger.warning("Reading the #{page} page failed: " <> Exception.message(failure))
    {:error, failure}
  end
end

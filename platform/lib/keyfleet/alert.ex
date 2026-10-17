defmodule Keyfleet.Alert do
  @moduledoc """
  Saves something a person has to act on with the site's errors
  (ErrorTracker, at /admin/errors), which Fly Sentinel reads every minute. A
  job that only logs, or ends cancelled, saves nothing there, so these would
  otherwise go unseen.

  ErrorTracker keeps one error per place in the code, so each line that
  reports is its own error, listing every occurrence with its own message.
  Sentinel emails when an error first appears; reporting it again while it
  is still listed adds an occurrence and marks it unresolved again without a
  new email. `Keyfleet.ErrorPruner` clears an error a week after it was last
  seen.

  The errors are kept in the site's own database, so a save fails while the
  database can't be reached. A failed save is logged and never raises: the
  caller carries on, a gateway still answers, a reader keeps reading, and
  `/healthz` already says the database is down.
  """

  require Logger

  @doc """
  Saves `exception`, placed at the line that called its module's report
  function. That call must not be the caller's last: a last call leaves no
  line of the caller to find.
  """
  def report(%module{} = exception) do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

    save(exception, Enum.drop_while(stacktrace, &(elem(&1, 0) in [Process, __MODULE__, module])))
  end

  @doc """
  Saves an exception that was rescued, placed where it was raised, with the
  `context` of the request or page it happened in when another process saves
  it.
  """
  def save(exception, stacktrace, context \\ %{}) do
    ErrorTracker.report(exception, stacktrace, context)
    :ok
  catch
    kind, reason -> unsaved(exception, Exception.format_banner(kind, reason))
  end

  defp unsaved(exception, why) do
    Logger.error(
      "An error couldn't be saved with the site's errors (#{why}): " <>
        Exception.message(exception)
    )

    :ok
  end
end

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

  The errors live in the site's database, so when that fails too, the alert
  is logged instead and the caller goes on: a process reporting a failure is
  never stopped by the report.
  """

  require Logger

  @doc """
  Saves `exception`, placed at the line that called its module's report
  function. That call must not be the caller's last: a last call leaves no
  line of the caller to find.
  """
  def report(%module{} = exception) do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

    ErrorTracker.report(
      exception,
      Enum.drop_while(stacktrace, &(elem(&1, 0) in [Process, __MODULE__, module]))
    )

    :ok
  rescue
    failure in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      Logger.error(
        "#{inspect(exception.__struct__)} not saved (#{Exception.message(failure)}): " <>
          Exception.message(exception)
      )

      :ok
  end
end

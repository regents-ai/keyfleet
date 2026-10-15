defmodule Keyfleet.Chain.ReadingStopped do
  @moduledoc """
  The chain reader is not reading a fleet and needs a person: the chain
  disagrees with the record (`Keyfleet.Chain.Scanner`), the node serves
  another chain than the fleet's (`Keyfleet.Chain.ReadFleet`), or no node is
  named while fleets are deployed (`Keyfleet.Chain.Watch`). Until someone
  acts, the fleet's treasury, proposals and Keys stop updating.

  `report/1` saves it with the site's errors (ErrorTracker, at /admin/errors),
  which Fly Sentinel reads every minute. A job that only logs, or ends
  cancelled, saves nothing there, so these would otherwise go unseen.

  ErrorTracker keeps one error per place in the code, so the three kinds of stop
  are three errors, each listing every occurrence with its own message (which
  fleet, which block). Sentinel emails when an error first appears; a second
  stop of the same kind while the first is still listed adds an occurrence
  and marks it unresolved again without a new email. `Keyfleet.ErrorPruner`
  clears an error a week after it was last seen.
  """
  defexception [:message]

  @doc """
  Saves the stop, with `message` saying which fleet and what to do. The
  caller's line places the error, so it must not be the caller's last call:
  a last call leaves no line of the caller to find.
  """
  def report(message) do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)

    # The caller's line, not this one, places the error, so each kind of stop
    # is its own error.
    ErrorTracker.report(
      %__MODULE__{message: message},
      Enum.drop_while(stacktrace, &(elem(&1, 0) in [Process, __MODULE__]))
    )

    :ok
  end
end

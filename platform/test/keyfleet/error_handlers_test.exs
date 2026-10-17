defmodule Keyfleet.ErrorHandlersTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias ErrorTracker.Error
  alias Keyfleet.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # Renamed inside the test's own transaction, so the save fails the way it does
  # while the database can't be reached; the rename ends with the test.
  test "a failure that can't be saved leaves the next one saved" do
    prefix = Repo.default_prefix()
    Repo.query!("ALTER TABLE #{prefix}.error_tracker_errors RENAME TO error_tracker_errors_away")

    assert capture_log(fn -> page_failed("the first failure") end) =~ "couldn't be saved"

    Repo.query!("ALTER TABLE #{prefix}.error_tracker_errors_away RENAME TO error_tracker_errors")
    page_failed("the second failure")

    assert Repo.exists?(from(error in Error, where: error.reason == "the second failure"))
  end

  defp page_failed(message) do
    :telemetry.execute([:phoenix, :live_view, :mount, :exception], %{duration: 0}, %{
      kind: :error,
      reason: RuntimeError.exception(message),
      stacktrace: [{__MODULE__, :page_failed, 1, [file: ~c"#{__ENV__.file}", line: 1]}],
      socket: nil
    })
  end
end

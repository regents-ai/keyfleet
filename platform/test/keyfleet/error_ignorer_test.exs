defmodule Keyfleet.ErrorIgnorerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.Repo

  defmodule Job do
    @moduledoc false
    use Oban.Worker

    alias Keyfleet.Notebooks.HubSilentError

    @wait %HubSilentError{message: "No connection to the notebook hub came free in time"}

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"as" => "hub_wait"}}),
      do: {:error, {:hub, "http://hub.test", @wait}}

    def perform(%Oban.Job{args: %{"as" => "quotes_the_name"}}),
      do: {:error, {:title_refused, "%Keyfleet.Notebooks.HubSilentError{ is my notebook's title"}}

    def perform(%Oban.Job{args: %{"as" => "wait_beside_a_fault"}}),
      do: {:error, [fleet_a: @wait, fleet_b: %RuntimeError{message: "the ledger disagrees"}]}
  end

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
  end

  # Costly failure: a job's real fault is saved nowhere because its printed
  # reason quotes the hub wait's name or carries a wait beside the fault.
  test "only a job failure that is a hub wait and nothing else is left out" do
    for as <- ~w(hub_wait quotes_the_name wait_beside_a_fault),
        do: assert({:error, _reason} = perform_job(Job, %{"as" => as}))

    # A saved failure keeps no job arguments (`Keyfleet.ErrorFilter`), so each
    # is told by what it failed with.
    saved =
      Repo.all(
        from(occurrence in ErrorTracker.Occurrence,
          where: occurrence.context["job.worker"] == ^inspect(Job),
          select: occurrence.reason
        )
      )

    assert [beside, quoting] = Enum.sort(saved)
    assert beside =~ "the ledger disagrees"
    assert quoting =~ ":title_refused"
  end
end

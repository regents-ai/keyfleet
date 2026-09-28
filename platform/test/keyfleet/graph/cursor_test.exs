defmodule Keyfleet.Graph.CursorTest do
  use ExUnit.Case, async: true

  alias Keyfleet.Actors
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Repo

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    :ok
  end

  test "a cursor read once moves on once: the same stale copy cannot move it again" do
    Graph.start_cursor!(%{fleet_id: @fleet, run_id: "run-once"}, actor: @system)
    stale = Graph.get_cursor!(@fleet, actor: @system)

    Graph.advance_cursor!(stale, %{applied_seq: 1}, actor: @system)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Graph.advance_cursor(stale, %{applied_seq: 2}, actor: @system)

    assert Graph.get_cursor!(@fleet, actor: @system).applied_seq == 1
  end
end

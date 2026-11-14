defmodule KeyfleetWeb.AgentCheckpointTest do
  @moduledoc """
  A paired agent saves where it left off in a fleet, revision by revision,
  and a save from any other revision changes nothing.
  """
  use ExUnit.Case, async: false

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys, PairingHelpers, Repo}
  alias KeyfleetWeb.AgentTools.Fleets.Answer

  @fleet "fibonacci_syndicate"
  @person "0x" <> String.duplicate("a", 40)

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 25,
        ownership_epoch: 1,
        owner_wallet: @person,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("c", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    %{
      agent:
        PairingHelpers.agent_for!(%Actors.Human{human_account_id: 0, wallet_addresses: [@person]})
    }
  end

  defp save(agent, expected, state) do
    Answer.answer(
      :save_checkpoint,
      %{"fleet_id" => @fleet, "expected_revision" => expected, "state" => state},
      agent,
      nil
    )
  end

  test "each save makes the next revision and is read back", %{agent: agent} do
    assert {200, %{checkpoint: %{revision: 1, state: %{"step" => 1}}}, _} =
             save(agent, 0, %{"step" => 1})

    assert {200, %{checkpoint: %{revision: 2, state: %{"step" => 2}}}, _} =
             save(agent, 1, %{"step" => 2})

    assert {200, %{checkpoint: %{revision: 2, state: %{"step" => 2}}}, _} =
             Answer.answer(:checkpoint, %{"fleet_id" => @fleet}, agent, nil)
  end

  test "a save from another revision changes nothing and answers the one kept", %{agent: agent} do
    assert {200, _, _} = save(agent, 0, %{"step" => 1})

    for expected <- [0, 5] do
      assert {409, %{error: %{details: %{checkpoint: %{revision: 1, state: %{"step" => 1}}}}}, _} =
               save(agent, expected, %{"step" => 9})
    end
  end
end

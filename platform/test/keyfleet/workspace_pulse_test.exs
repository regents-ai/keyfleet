defmodule Keyfleet.WorkspacePulseTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Projects
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias Keyfleet.WorkspacePulse
  alias KeyfleetWeb.AgentTools.Public.Answer

  @fleet "fleet_tech_classic"
  @system %Actors.System{}
  @holder "0x" <> String.duplicate("20", 20)
  @muse "0x" <> String.duplicate("5e", 20)
  @unnamed "0x" <> String.duplicate("0d", 20)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.deploy!(@fleet)
    Projects.bootstrap_general!([@fleet])
    Workspace.open_log(@fleet)
    # Key 20's holder has three of the fleet's Keys.
    for key <- [20, 21, 22], do: sell(key)
    :ok
  end

  # The public pulse tells who worked on which project, by the agent's
  # paired name or as the Key's agent, and leaves a deleted project's work out.
  test "the pulse names the agent and its Key's count, and leaves a deleted project out" do
    holder = %Actors.Human{human_account_id: 20, wallet_addresses: [@holder]}
    pair(@muse, "Muse")

    Projects.start_project!(@fleet, 20, "old", "Old", actor: holder)
    Workspace.create(@fleet, "goal", %{"title" => "Old work"}, project: "old", by: 20)
    Projects.archive_project!(@fleet, 20, actor: holder)
    Projects.start_project!(@fleet, 20, "lab", "Lab", actor: holder)
    Workspace.create(@fleet, "goal", %{"title" => "A"}, project: "lab", by: 20, wallet: @muse)
    Workspace.create(@fleet, "task", %{"title" => "B"}, project: "lab", by: 20, wallet: @unnamed)
    Projects.delete_project!(@fleet, 20, "old", actor: holder)

    assert {:ok, %{activity: activity}} = WorkspacePulse.read(@fleet, nil)

    assert [
             %{
               text: "Agent of Key 20³ worked on Lab",
               agent_name: nil,
               key: 20,
               keys_held: 3,
               project_title: "Lab"
             },
             %{
               text: "Agent Muse with Key 20³ worked on Lab",
               agent_name: "Muse",
               key: 20,
               keys_held: 3,
               project_title: "Lab"
             }
           ] = activity
  end

  # An agent that checks in again passes back next_after and reads only what
  # changed since, thirty at a time, until has_more is false.
  test "after reads only the changes since the cursor, thirty at a time" do
    holder = %Actors.Human{human_account_id: 20, wallet_addresses: [@holder]}
    Projects.start_project!(@fleet, 20, "lab", "Lab", actor: holder)
    Workspace.create(@fleet, "goal", %{"title" => "Seen"}, project: "lab", by: 20)

    assert {:ok, %{activity: [_seen | _], next_after: cursor, has_more: false}} =
             WorkspacePulse.read(@fleet, nil)

    assert {:ok, %{activity: [], next_after: ^cursor, has_more: false}} =
             WorkspacePulse.read(@fleet, String.to_integer(cursor))

    for n <- 1..32,
        do: Workspace.create(@fleet, "task", %{"title" => "T#{n}"}, project: "lab", by: 21)

    assert {:ok, %{activity: first, next_after: middle, has_more: true}} =
             WorkspacePulse.read(@fleet, String.to_integer(cursor))

    assert length(first) == 30
    assert Enum.all?(first, &(&1.key == 21))
    assert [%{seq: newest} | _] = first
    assert Integer.to_string(newest) == middle
    assert first == Enum.sort_by(first, & &1.seq, :desc)

    assert {:ok, %{activity: [_, _] = rest, has_more: false}} =
             WorkspacePulse.read(@fleet, String.to_integer(middle))

    assert Enum.all?(rest, &(&1.seq > newest))
  end

  test "a cursor that is not a whole number, or another name, is refused" do
    for params <- [%{"after" => "x"}, %{"after" => "01"}, %{"after" => "-1"}, %{"since" => "1"}] do
      assert {400, %{error: %{code: "invalid_pulse_cursor"}}, nil} =
               Answer.answer(:pulse, Map.put(params, "fleet_id", @fleet), nil, nil)
    end
  end

  defp pair(wallet, name) do
    person = "did:privy:test-" <> @holder
    Accounts.register_verified!(person, @holder, [@holder], actor: @system)

    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: person})

    RegentAgents.pair_agent!(code, name, :codex, actor: %RegentAgents.Agent{wallet: wallet})
  end

  defp sell(key) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: key,
        ownership_epoch: 1,
        owner_wallet: @holder,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{@fleet}/#{key}"), case: :lower),
        log_index: 0
      },
      actor: @system
    )
  end
end

defmodule Keyfleet.Projects.HoldTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  require Ash.Query

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Code
  alias Keyfleet.Code.{DeleteRepository, Setup}
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Notebooks.DeleteSpace
  alias Keyfleet.Projects
  alias Keyfleet.Projects.Errors.HoldError
  alias Keyfleet.WorkspaceFixtures, as: Workspace

  @fleet "fleet_tech_classic"
  @system %Actors.System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.deploy!(@fleet)
    Projects.bootstrap_general!([@fleet])
    Workspace.open_log(@fleet)
    for key <- [3, 20], do: sell(key)
    :ok
  end

  # A Key holds at most five archived projects; deleting one makes room, and
  # the deleted project's items leave the workspace while its notebook space
  # and repository are queued for deletion.
  test "a Key is refused a sixth archived project until it deletes one, which takes its work away" do
    for n <- 1..5 do
      Projects.start_project!(@fleet, 20, "p#{n}", "P#{n}", actor: owner(20))
      Projects.archive_project!(@fleet, 20, actor: owner(20))
    end

    gone = Workspace.create(@fleet, "goal", %{"title" => "Gone"}, project: "p1", by: 20)
    kept = Workspace.create(@fleet, "goal", %{"title" => "Kept"}, project: "p2", by: 20)
    Projects.start_project!(@fleet, 20, "p6", "P6", actor: owner(20))

    assert {:error, %{errors: [%HoldError{code: :archive_full}]}} =
             Projects.archive_project(@fleet, 20, actor: owner(20))

    assert %{state: :deleted} = Projects.delete_project!(@fleet, 20, "p1", actor: owner(20))

    assert [%{id: ^kept}] = Graph.read_objects!(@fleet, [gone, kept], actor: @system)
    assert_enqueued(worker: DeleteSpace, args: %{fleet_id: @fleet, project: "p1"})
    assert_enqueued(worker: DeleteRepository, args: %{repository: "#{@fleet}-p1"})

    assert %{state: :archived} = Projects.archive_project!(@fleet, 20, actor: owner(20))
  end

  # A project deleted while the store makes its repository: the repository
  # is deleted again, not kept, so none outlives its project.
  test "a repository whose project is deleted while it is being made is deleted again" do
    repository = "#{@fleet}-quick"
    owner = "did:key:z6MkfleetOwner"
    Projects.start_project!(@fleet, 20, "quick", "Quick", actor: owner(20))
    assert_enqueued(worker: Setup, args: %{repository: repository})
    Projects.archive_project!(@fleet, 20, actor: owner(20))

    Req.Test.stub(Keyfleet.Code.NodeClient, fn
      %{method: "POST"} = conn ->
        Projects.delete_project!(@fleet, 20, "quick", actor: owner(20))
        send(self(), :created)
        Req.Test.json(conn, %{"name" => repository, "owner_did" => owner})

      %{method: "DELETE", request_path: path} = conn ->
        send(self(), {:deleted, path})
        Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = perform_job(Setup, %{repository: repository})
    assert_received :created
    assert_received {:deleted, "/api/v1/repos/" <> _}
    assert {:ok, nil} = Code.get_repository(repository, actor: @system)
  end

  # A project deleted while its notebook space is made: the space job's late
  # write is refused, so the deleted project keeps no space and queues no
  # roster run. The delete run finds that space by its tag.
  test "a notebook space made after its project was deleted is not recorded" do
    started = Projects.start_project!(@fleet, 20, "late", "Late", actor: owner(20))
    Projects.archive_project!(@fleet, 20, actor: owner(20))
    Projects.delete_project!(@fleet, 20, "late", actor: owner(20))

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Projects.record_space(started, "proj-late", actor: @system)

    refute_enqueued(worker: Keyfleet.Notebooks.Roster)

    assert [%{state: :deleted, hub_project_id: nil}] =
             Keyfleet.Projects.Project
             |> Ash.Query.filter(fleet_id == ^@fleet and name == "late")
             |> Ash.read!(actor: @system)
  end

  # General keeps the fleet's starting goals, first notebooks and first
  # repository, so no Key deletes it, archived or active.
  test "no Key deletes General, archived or active" do
    assert {:error, %{errors: [%HoldError{code: :general_kept}]}} =
             Projects.delete_project(@fleet, 3, "general", actor: owner(3))

    Projects.take_over_project!(@fleet, 20, "general", actor: owner(20))

    assert {:error, %{errors: [%HoldError{code: :general_kept}]}} =
             Projects.delete_project(@fleet, 20, "general", actor: owner(20))

    assert %{state: :active, key: 20} = Projects.project!(@fleet, "general", actor: @system)
    refute_enqueued(worker: DeleteRepository)
  end

  # Sean, 27 Oct 2026: General is held by Key 3, except in Regents Club, where
  # Key 329 holds it.
  test "General starts archived under Key 3, and under Key 329 in Regents Club" do
    Projects.bootstrap_general!(["regents_club"])

    assert %{state: :archived, key: 3} = Projects.project!(@fleet, "general", actor: @system)

    assert %{state: :archived, key: 329} =
             Projects.project!("regents_club", "general", actor: @system)
  end

  defp owner(key), do: %Actors.Human{human_account_id: key, wallet_addresses: [wallet(key)]}

  defp wallet(key), do: "0x" <> String.pad_leading(Integer.to_string(key), 40, "0")

  defp sell(key) do
    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: key,
        ownership_epoch: 1,
        owner_wallet: wallet(key),
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

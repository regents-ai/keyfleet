defmodule Keyfleet.Notebooks.DefaultProjectsTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import Plug.Conn

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.{Backups, DeleteSpace, Makers, Scratchpads, Setting, UnderstandingPage}
  alias Keyfleet.Projects
  alias Keyfleet.Projects.Errors.HoldError
  alias Keyfleet.WorkspaceFixtures, as: Workspace
  alias KeyfleetWeb.SignedAgentHelpers

  @fleet "fleet_tech_classic"
  @club "regents_club"
  @system %Actors.System{}
  @notebook "nb-0000000000000007"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    ChainHelpers.deploy!(@fleet)
    Projects.bootstrap_general!([@fleet])
    Workspace.open_log(@fleet)
    for key <- [3, 7], do: sell(key)
    :ok
  end

  # Sean, 27 Oct 2026: the scratchpad and the collaborative understanding
  # belong to the whole fleet, so no Key takes them over or deletes them.
  test "no Key takes over or deletes the fleet's shared projects" do
    for name <- ~w(scratchpad understanding) do
      assert %{state: :active, key: nil} = Projects.project!(@fleet, name, actor: @system)

      assert {:error, %{errors: [%HoldError{code: :shared}]}} =
               Projects.take_over_project(@fleet, 7, name, actor: owner(7))

      assert {:error, %{errors: [%HoldError{code: :shared}]}} =
               Projects.delete_project(@fleet, 7, name, actor: owner(7))
    end
  end

  # Sean, 29 Oct 2026: Regents Club keeps no notebook for each Key. Costly
  # failure: another fleet's scratchpad deleted, or Regents Club's back.
  test "Regents Club shares no scratchpad: the one it had goes with its Keys' records, and other fleets keep theirs" do
    ChainHelpers.seed_cursor!(@club)

    Projects.Project
    |> Ash.Changeset.for_create(
      :shared,
      %{fleet_id: @club, name: "scratchpad", title: "Append-only scratchpad"},
      actor: @system
    )
    |> Ash.create!()
    |> Projects.record_space!("proj-club-scratch", actor: @system)

    keep(:scratchpad, %{key: 7})
    keep(:scratchpad, %{fleet_id: @club, key: 7})

    for _run <- 1..2, fleet <- [@club, @fleet], do: assert(:ok = Projects.unshare!(fleet))
    Fleets.bootstrap_catalog!()

    assert Projects.project!(@club, "scratchpad", actor: @system) == nil
    assert %{state: :active} = Projects.project!(@club, "understanding", actor: @system)
    assert %{state: :active} = Projects.project!(@fleet, "scratchpad", actor: @system)

    assert [
             %{
               args: %{
                 "fleet_id" => @club,
                 "project" => "scratchpad",
                 "space" => "proj-club-scratch"
               }
             }
           ] =
             all_enqueued(worker: DeleteSpace)

    assert Notebooks.notebook_settings!(@club, actor: @system) == []
    assert [%{key: 7}] = Notebooks.notebook_settings!(@fleet, actor: @system)
  end

  # Costly failure: a fleet whose understanding page is never made, or a page
  # queued for another project.
  test "recording the understanding project's space queues its first page, and no other project's does" do
    record = fn name ->
      @fleet
      |> Projects.project!(name, actor: @system)
      |> Projects.record_space!("proj-#{name}", actor: @system)
    end

    record.("scratchpad")
    assert all_enqueued(worker: UnderstandingPage) == []

    record.("understanding")
    assert [%{args: %{"fleet_id" => @fleet}}] = all_enqueued(worker: UnderstandingPage)
  end

  # Costly failure: another member writing in a Key's scratchpad, or anyone
  # but its Key unlocking it. Only whoever acts as Key 7 writes in Key 7's
  # notebook until they unlock it, and only they lock it again.
  test "a Key's scratchpad is written by whoever acts as that Key, and others only once it is unlocked" do
    keep(:scratchpad, %{key: 7})

    assert {:ok, true} = Makers.open_to?(@fleet, owner(7), @notebook, :edit)
    assert {:ok, true} = Makers.open_to?(@fleet, owner(7), @notebook, :creator)
    assert {:ok, false} = Makers.open_to?(@fleet, owner(3), @notebook, :edit)

    keep(:switch, %{unlocked: true})

    assert {:ok, true} = Makers.open_to?(@fleet, owner(3), @notebook, :edit)
    assert {:ok, false} = Makers.open_to?(@fleet, owner(3), @notebook, :creator)
    assert {:ok, true} = Makers.open_to?(@fleet, owner(7), @notebook, :creator)
  end

  describe "with the fleet's notebook hub" do
    setup do
      hub = start_supervised!({Agent, fn -> %{} end})
      address = SignedAgentHelpers.serve_ipv6!(:hub, &hub_answer(&1, &2, hub))

      notebooks = Application.fetch_env!(:keyfleet, :notebooks)
      on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)

      Application.put_env(
        :keyfleet,
        :notebooks,
        Keyword.put(notebooks, :fleets, %{@fleet => address})
      )

      @fleet
      |> Projects.project!("scratchpad", actor: @system)
      |> Projects.record_space!("proj-scratch", actor: @system)

      %{hub: hub}
    end

    # Costly failure: a Key with two scratchpads, or none for good once its
    # notebook was deleted.
    test "each sold Key gets one scratchpad, made again once it is deleted", %{hub: hub} do
      assert :ok = perform_job(Scratchpads, %{fleet_id: @fleet})
      assert titles(hub) == ["Key 3", "Key 7"]
      assert :ok = perform_job(Scratchpads, %{fleet_id: @fleet})
      assert titles(hub) == ["Key 3", "Key 7"]

      %{7 => old} = scratchpads()
      Agent.update(hub, &Map.delete(&1, old))

      assert :ok = perform_job(Scratchpads, %{fleet_id: @fleet})
      assert titles(hub) == ["Key 3", "Key 7"]
      assert %{3 => _, 7 => new} = scratchpads()
      assert new != old
    end

    # Costly failure: a day's copy that keeps every notebook again, or misses
    # one that changed.
    test "the daily copy keeps each notebook once for each change", %{hub: hub} do
      perform_job(Scratchpads, %{fleet_id: @fleet})
      %{7 => notebook} = scratchpads()

      assert :ok = perform_job(Backups, %{fleet_id: @fleet})
      assert :ok = perform_job(Backups, %{fleet_id: @fleet})
      assert length(copies()) == 2

      Agent.update(hub, &put_in(&1, [notebook, "updated_at"], "2026-10-28T09:00:00Z"))

      assert :ok = perform_job(Backups, %{fleet_id: @fleet})
      assert [%{copies: [_newer, _older]}, %{copies: [_one]}] = copies()
    end
  end

  defp scratchpads,
    do: Map.new(Notebooks.notebook_settings!(@fleet, actor: @system), &{&1.key, &1.notebook_id})

  defp copies do
    {:ok, copies} = Notebooks.copies(@fleet, owner(3), "agent", "scratchpad")
    copies
  end

  defp titles(hub), do: hub |> Agent.get(&Map.values/1) |> Enum.map(& &1["title"]) |> Enum.sort()

  # The hub keeps notebooks in memory, as the real one lists, makes and reads them.
  @notebooks "/api/v1/projects/proj-scratch/notebooks"

  defp hub_answer(%Plug.Conn{method: "GET", request_path: @notebooks} = conn, _opts, hub),
    do: json(conn, 200, %{items: Agent.get(hub, &Map.values/1), next_cursor: nil})

  defp hub_answer(%Plug.Conn{method: "POST", request_path: @notebooks} = conn, _opts, hub) do
    {:ok, body, conn} = read_body(conn)
    made = Jason.decode!(body)

    id =
      "nb-" <> String.pad_leading(Integer.to_string(System.unique_integer([:positive])), 16, "0")

    notebook = %{
      "id" => id,
      "title" => made["title"],
      "author" => Keyfleet.Notebooks.HubClient.provisioner(@fleet),
      "tags" => made["tags"],
      "code" => made["code"],
      "updated_at" => "2026-10-27T09:00:00Z"
    }

    Agent.update(hub, &Map.put(&1, id, notebook))
    json(conn, 201, notebook)
  end

  defp hub_answer(
         %Plug.Conn{method: "GET", request_path: @notebooks <> "/" <> rest} = conn,
         _opts,
         hub
       ) do
    [id, "content"] = String.split(rest, "/")

    case Agent.get(hub, &Map.get(&1, id)) do
      nil -> json(conn, 404, %{})
      notebook -> json(conn, 200, %{code: notebook["code"]})
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{success: true, data: data}))
  end

  defp keep(action, fields) do
    Setting
    |> Ash.Changeset.for_create(
      action,
      Map.merge(%{fleet_id: @fleet, notebook_id: @notebook}, fields),
      actor: @system
    )
    |> Ash.create!()
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

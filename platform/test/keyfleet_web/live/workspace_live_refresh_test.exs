defmodule KeyfleetWeb.Live.WorkspaceLiveRefreshTest do
  # The workspace page against the fleet's own writer and the copy it keeps
  # for reading: what agents write shows up on an open page by itself.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, except: [build_conn: 0, init_test_session: 2]
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.Accounts
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph.Projector
  alias Keyfleet.Graph.Writer
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  @endpoint KeyfleetWeb.Endpoint
  @moduletag :tmp_dir

  @fleet "fleet_tech_classic"
  @board "/classic/1/workspace"
  @result "https://example.com/result"
  @wallet "0x" <> String.duplicate("a1", 20)
  @contract "0x" <> String.duplicate("b2", 20)

  setup %{tmp_dir: tmp_dir} do
    # The copy is read at repeatable read, which Postgres allows inside the
    # sandbox only when its transaction is at that level already.
    owner = Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.deploy!(@fleet)
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())

    start_supervised!(
      {Keyfleet.Graph.Supervisor,
       fleets: [@fleet],
       data_dir: Path.join(tmp_dir, "graph"),
       reply_timeout: 5_000,
       hello_timeout: 30_000,
       restart_min: 20,
       restart_max: 200}
    )

    await_ready()

    start_supervised!({Keyfleet.Graph.Projectors, fleets: [@fleet], catch_up_interval: 60_000})

    %{conn: holder_conn()}
  end

  test "what agents write appears on an open page by itself", %{conn: conn} do
    {:ok, view, _html} = live(conn, @board)
    starting = cards(view)
    assert length(starting) == length(Keyfleet.GoalIdeas.starting_goals())
    assert length(activity(view)) == length(starting)

    {goal, _head} = create!("goal", %{title: "Revenue", outcome: "One paying customer."}, "c-1")
    assert shows?(fn -> cards(view) == [goal | starting] end)

    {task, _head} = create!("task", %{title: "Draft", progress: "todo"}, "c-2")
    write!("link", %{source: task, target: goal, type: "implements"}, "c-3")
    write!("patch", %{id: task, expected_version: 1, set: %{progress: "doing"}}, "c-4")
    write!("archive", %{id: goal, expected_version: 1}, "c-5")

    assert shows?(fn -> length(activity(view)) == 5 + length(starting) end)
    assert cards(view) == [task | starting]

    assert Enum.take(activity(view), 5) == [
             "Key 17 archived “Revenue”.",
             "Key 17 updated “Draft”: progress is now in progress.",
             "Key 17 linked “Draft” to “Revenue”, which it delivers on.",
             "Key 17 added the task “Draft”.",
             "Key 17 added the goal “Revenue”."
           ]

    {:ok, item, _html} = live(conn, KeyfleetWeb.WorkspacePage.item_path(@fleet, task))
    assert has_element?(item, "#workspace-links", "This task delivers on")
    write!("submit", %{id: task, expected_version: 2, result_ref: @result}, "c-6")
    assert shows?(fn -> has_element?(item, "#workspace-fields", "Awaiting review") end)
  end

  test "a task whose last dependency is done is announced as ready to start", %{conn: conn} do
    {first, _head} = create!("task", %{title: "Collect filings", progress: "doing"}, "c-1")
    {next, _head} = create!("task", %{title: "Write the brief", progress: "todo"}, "c-2")
    write!("link", %{source: next, target: first, type: "depends_on"}, "c-3")

    {:ok, view, _html} = live(conn, @board)
    refute Enum.any?(activity(view), &(&1 =~ "ready to start"))

    write!("submit", %{id: first, expected_version: 1, result_ref: @result}, "c-4")

    assert shows?(fn -> hd(activity(view)) == "“Write the brief” is ready to start." end)

    assert Enum.slice(activity(view), 1, 2) == [
             "“Collect filings” needs review.",
             "Key 17 submitted “Collect filings” for review."
           ]
  end

  # An open page reads what changed a moment after it hears of it.
  defp shows?(check, tries \\ 60) do
    cond do
      check.() ->
        true

      tries > 0 ->
        Process.sleep(50)
        shows?(check, tries - 1)

      true ->
        false
    end
  end

  # Each write waits until the copy has caught up with it, and the copy says
  # so to every open page before the wait ends.
  defp create!(type, data, id) do
    {:ok, %{"result" => %{"id" => object_id}, "head_seq" => head}} =
      command("create", %{project: "general", type: type, data: data}, id)

    {object_id, await(head)}
  end

  defp write!(op, body, id) do
    {:ok, %{"head_seq" => head}} = command(op, body, id)
    await(head)
  end

  defp await(head) do
    {:ok, %{"result" => %{"run_id" => run_id}}} = Writer.request(@fleet, "hello", %{})
    assert Projector.await(@fleet, run_id, head) == head
    head
  end

  defp command(op, body, id),
    do: Writer.command(@fleet, op, body, {__MODULE__, :admit, [id]})

  @doc false
  def admit(id, _within), do: {:ok, stamped(id)}

  defp stamped(id) do
    %{
      id: id,
      principal: "member:8453:#{@contract}:17@3/agent:#{@wallet}",
      auth: %{
        key: %{chain_id: 8453, contract: @contract, token_id: 17},
        ownership_epoch: 3,
        kind: "agent",
        operator_wallet: @wallet,
        credential_ref: nil,
        checked_at: "2026-09-22T12:00:00Z",
        chain_block: nil
      },
      projects: %{"general" => "active"}
    }
  end

  defp await_ready(attempts \\ 750) do
    case Writer.request(@fleet, "hello", %{}) do
      {:ok, _hello} ->
        :ok

      {:error, _reason} when attempts > 0 ->
        Process.sleep(20)
        await_ready(attempts - 1)
    end
  end

  defp cards(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace-cards > li")
    |> LazyHTML.attribute("data-item")
  end

  defp activity(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace-activity > li > p:first-child")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/u, " ") |> String.trim()))
  end

  # Signed in as the owner of the fleet's Key 1, as only a Key holder reads
  # the workspace.
  defp holder_conn do
    ChainHelpers.seed_cursor!(@fleet)

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 1,
        ownership_epoch: 1,
        owner_wallet: @wallet,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("a", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    account =
      Accounts.register_verified!("did:privy:workspace-refresh", @wallet, [@wallet],
        actor: %Actors.System{}
      )

    KeyfleetWeb.SessionAuthorityHelpers.build_conn()
    |> KeyfleetWeb.SessionAuthorityHelpers.init_test_session(%{human_account_id: account.id})
  end
end

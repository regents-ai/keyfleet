defmodule Keyfleet.Graph.ReviewQueuePropertyTest do
  # A sync's `yours.reviews` restates, in the read tables, the rule the graph
  # host keeps for a review. Costly failure: a task the host would let a Key
  # review never reaches that Key, so the work waits unseen; or one it would
  # refuse sits at the top of the Key's list, so the agent's every run fails.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Ecto.Adapters.SQL.Sandbox
  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Graph.Projector
  alias Keyfleet.Graph.Writer
  alias Keyfleet.Keys
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  @moduletag :tmp_dir

  @fleet "fibonacci_syndicate"
  @project "understanding"
  @contract "0x" <> String.duplicate("b2", 20)
  @wallet "0x" <> String.duplicate("a1", 20)
  # Owns key 1 of `@fleet`, so it may read the fleet's workspace.
  @holder %Actors.Human{human_account_id: 1, wallet_addresses: [@wallet]}

  # Keys acting from wallets, as a write is stamped: Key 19 shares Key 17's
  # wallet, and Key 18 acts at two ownerships from two wallets.
  @members [
    {17, 3, @wallet},
    {18, 3, "0x" <> String.duplicate("c3", 20)},
    {19, 3, @wallet},
    {18, 4, "0x" <> String.duplicate("d4", 20)},
    {20, 3, "0x" <> String.duplicate("e5", 20)}
  ]

  setup %{tmp_dir: tmp_dir} do
    # Workspace reads take a repeatable-read snapshot, which Postgres allows
    # inside the sandbox only when its transaction is at that level already.
    owner = Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    Fleets.bootstrap_catalog!()
    Rooms.bootstrap_rooms!(Fleets.catalog_ids())
    own_key!()
    start_writer(Path.join(tmp_dir, "graph"))
    start_supervised!({Keyfleet.Graph.Projectors, fleets: [@fleet], catch_up_interval: 60_000})
    :ok
  end

  property "a task is in a Key's queue exactly when it awaits review and the host would take that Key's review" do
    member = StreamData.member_of(@members)

    # Mostly the steps that decide who worked on the task; now and then a
    # review or an archive that ends its wait.
    step =
      StreamData.frequency([
        {12, StreamData.tuple({StreamData.member_of([:join, :leave, :patch, :submit]), member})},
        {2, StreamData.tuple({StreamData.constant(:review), member})},
        {1, StreamData.constant({:archive, nil})}
      ])

    check all(
            creator <- member,
            before <- StreamData.list_of(step, max_length: 8),
            submitter <- member,
            later <- StreamData.list_of(step, max_length: 4),
            # Key 18 tries once, at one of its two ownerships: a review it
            # makes counts against the other.
            key_18 <- StreamData.member_of([{18, 3}, {18, 4}]),
            max_runs: 100
          ) do
      {:ok, %{"result" => %{"id" => task, "version" => 1}}} =
        write(creator, "create", %{project: @project, type: "task", data: %{title: "Work"}})

      version =
        Enum.reduce(
          before ++ [{:join, submitter}, {:submit, submitter}] ++ later,
          1,
          &run_step(&1, &2, task, creator)
        )

      settle()

      awaiting? =
        Graph.read_object!(@fleet, task, load: [:review], actor: @holder).review ==
          "awaiting_review"

      tried =
        Enum.reject(@members, fn {token, epoch, _wallet} ->
          token == 18 and {18, epoch} != key_18
        end)

      queued = Map.new(tried, &{&1, queued?(&1, task)})

      for reviewer <- tried do
        accepted? =
          match?(
            {:ok, _},
            write(reviewer, "review", %{
              task: task,
              task_version: version,
              decision: "accept",
              rationale: "Ran it from the commit.",
              conflicts_of_interest: "none"
            })
          )

        assert queued[reviewer] == (awaiting? and accepted?),
               "#{inspect(reviewer)}: queued #{queued[reviewer]}, awaiting #{awaiting?}, host took the review #{accepted?}"
      end

      # Each run leaves its task out of every later run's queues.
      write(creator, "archive", %{id: task, expected_version: version})
    end
  end

  # Runs one write as `member` and answers the task's version after it; a
  # refused write leaves it as it was.
  defp run_step({:archive, nil}, version, task, creator),
    do: changed(write(creator, "archive", %{id: task, expected_version: version}), version)

  defp run_step({op, member}, version, task, _creator) when op in [:join, :leave],
    do: changed(write(member, Atom.to_string(op), %{id: task}), version)

  defp run_step({:patch, member}, version, task, _creator),
    do:
      changed(
        write(member, "patch", %{
          id: task,
          expected_version: version,
          set: %{next_step: "Step #{version}"}
        }),
        version
      )

  defp run_step({:submit, member}, version, task, _creator),
    do:
      changed(
        write(member, "submit", %{
          id: task,
          expected_version: version,
          result_ref: "https://example.com/#{version}"
        }),
        version
      )

  # A review leaves the task's version as it was.
  defp run_step({:review, member}, version, task, _creator) do
    write(member, "review", %{
      task: task,
      task_version: version,
      decision: "dispute",
      rationale: "It doesn't hold.",
      conflicts_of_interest: "none"
    })

    version
  end

  defp changed({:ok, %{"result" => %{"version" => version}}}, _version), do: version
  defp changed({:error, _refused}, version), do: version

  defp queued?({token, epoch, wallet}, task) do
    {:ok, page} = Graph.review_queue(@fleet, token, epoch, wallet, %{}, actor: @holder)
    assert page.count == length(page.results)
    Enum.any?(page.results, &(&1.id == task))
  end

  defp write(member, op, body) do
    Writer.command(
      @fleet,
      op,
      body,
      {__MODULE__, :admit, [member, System.unique_integer([:positive])]}
    )
  end

  @doc false
  def admit({token, epoch, wallet}, id, _within) do
    {:ok, projects} = Keyfleet.Projects.projects(@fleet, actor: %Actors.System{})

    {:ok,
     %{
       id: "c-#{id}",
       principal: "member:8453:#{@contract}:#{token}@#{epoch}/agent:#{wallet}",
       auth: %{
         key: %{chain_id: 8453, contract: @contract, token_id: token},
         ownership_epoch: epoch,
         kind: "agent",
         operator_wallet: wallet,
         credential_ref: nil,
         checked_at: "2026-11-12T12:00:00Z",
         chain_block: nil
       },
       projects: Map.new(projects, &{&1.name, Atom.to_string(&1.state)})
     }}
  end

  defp settle do
    {:ok, %{"result" => %{"run_id" => run_id, "head_seq" => head}}} =
      Writer.request(@fleet, "hello", %{})

    assert Projector.await(@fleet, run_id, head) == head
  end

  defp own_key! do
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
  end

  # The fleet starts with no starting goals, so its log holds only what a
  # test writes.
  defp start_writer(data_dir) do
    start_supervised!(
      {Keyfleet.Graph.Supervisor,
       fleets: [@fleet],
       starting_goals: [],
       data_dir: data_dir,
       reply_timeout: 5_000,
       hello_timeout: 30_000,
       restart_min: 20,
       restart_max: 200}
    )

    await_ready()
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
end

defmodule Keyfleet.Graph.ClusterTest do
  # Production's site machine reaches the fleets' writers on the graph machine
  # (fly.toml). This node plays the site machine and a peer node the graph
  # machine.
  use ExUnit.Case, async: false

  alias Keyfleet.Graph.Writer
  alias Keyfleet.GraphPeer

  @moduletag :tmp_dir

  @fleet hd(Keyfleet.Fleets.catalog_ids())
  @note %{
    project: "general",
    type: "note",
    data: %{title: "Plan", body: "Ship the first service."}
  }

  setup %{tmp_dir: tmp_dir} do
    on_exit(&GraphPeer.leave_cluster/0)

    {:ok,
     graph: [
       fleets: [@fleet],
       starting_goals: [],
       data_dir: Path.join(tmp_dir, "graph"),
       hello_timeout: 30_000
     ]}
  end

  test "a write on the site machine is made by its fleet's writer on the graph machine", ctx do
    {_peer, graph_node} = GraphPeer.start(ctx.graph)
    await_ready()

    assert [writer] = :pg.get_members(Keyfleet.Graph.Processes, {Writer, @fleet})
    assert node(writer) == graph_node

    assert {:ok, %{"replayed" => false, "result" => %{"id" => "note#1"}}} =
             Writer.command(@fleet, "create", @note, GraphPeer.authorized("c1"))

    assert {:ok, %{"replayed" => true}} =
             Writer.command(@fleet, "create", @note, GraphPeer.authorized("c1"))
  end

  test "while the graph machine is replaced a write answers try again, and nothing is written twice",
       ctx do
    {peer, _graph_node} = GraphPeer.start(ctx.graph)
    await_ready()

    assert {:ok, %{"replayed" => false}} =
             Writer.command(@fleet, "create", @note, GraphPeer.authorized("c1"))

    GraphPeer.stop(peer)
    await(fn -> :pg.get_members(Keyfleet.Graph.Processes, {Writer, @fleet}) == [] end)

    assert Writer.command(@fleet, "create", @note, GraphPeer.authorized("c2")) ==
             {:error, :unavailable}

    {_peer, _graph_node} = GraphPeer.start(ctx.graph)
    await_ready()

    assert {:ok, %{"replayed" => true}} =
             Writer.command(@fleet, "create", @note, GraphPeer.authorized("c1"))

    assert {:ok, %{"replayed" => false, "result" => %{"id" => "note#2"}}} =
             Writer.command(@fleet, "create", @note, GraphPeer.authorized("c2"))

    assert {:ok, %{"result" => %{"events" => events}}} =
             Writer.request(@fleet, "changes", %{after_seq: 0, limit: 500})

    assert Enum.count(events, &(&1["type"] == "object.created")) == 2
  end

  # During a release the site machine can run code the graph machine does not
  # have yet, or no longer has. A check named in such code cannot run there,
  # so the write answers try again and nothing is written. This test module is
  # loaded only on the site machine.
  test "a write whose check the graph machine's code lacks answers try again and writes nothing",
       ctx do
    {_peer, _graph_node} = GraphPeer.start(ctx.graph)
    await_ready()

    test_only_check = {__MODULE__, :never_runs_on_the_graph_machine, []}

    assert Writer.command(@fleet, "create", @note, test_only_check) == {:error, :unavailable}

    assert {:ok, %{"result" => %{"events" => events}}} =
             Writer.request(@fleet, "changes", %{after_seq: 0, limit: 500})

    refute Enum.any?(events, &(&1["type"] == "object.created"))
  end

  @doc false
  def never_runs_on_the_graph_machine(_within), do: {:error, :ran_on_the_graph_machine}

  defp await(condition, attempts \\ 750) do
    cond do
      condition.() ->
        :ok

      attempts == 0 ->
        flunk("the condition never held")

      true ->
        Process.sleep(20)
        await(condition, attempts - 1)
    end
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

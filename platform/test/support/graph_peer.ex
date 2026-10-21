defmodule Keyfleet.GraphPeer do
  @moduledoc """
  A graph machine for tests that cross the cluster: a peer node running what
  production's graph machine runs for its writers (`Keyfleet.Application`), the
  `Keyfleet.Graph.Processes` scope and `Keyfleet.Graph.Supervisor`, while the
  test's own node plays the site machine.

  The test's node joins a cluster for the case, so a case using it is never
  async and calls `leave_cluster/0` when it ends. A graph machine stops with
  the test process that started it.
  """

  @doc """
  Starts a graph machine running `opts`' writers (`Keyfleet.Graph.Supervisor`),
  with this node's code and graph settings, joining this node to a cluster
  first. Returns the peer and its node.
  """
  def start(opts) do
    unless Node.alive?() do
      {_output, 0} = System.cmd(Path.join([:code.root_dir(), "bin", "epmd"]), ["-daemon"])
      {:ok, _net_kernel} = :net_kernel.start(:"site#{unique()}@127.0.0.1", %{})
    end

    {:ok, peer, node} =
      :peer.start_link(%{
        name: :"graph#{unique()}",
        host: ~c"127.0.0.1",
        longnames: true,
        exec: String.to_charlist(Path.join([:code.root_dir(), "bin", "erl"]))
      })

    :ok = :erpc.call(node, :code, :add_pathsa, [:code.get_path()])
    # The suite prints only warnings and errors (config/test.exs); the graph
    # machine's warnings are what its tests provoke, so it prints only errors.
    :ok = :erpc.call(node, :logger, :set_primary_config, [:level, :error])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:elixir])
    :ok = :erpc.call(node, Application, :put_env, [:keyfleet, :graph, graph_settings()])
    {:ok, _graph} = :erpc.call(node, __MODULE__, :run_graph, [opts])
    {peer, node}
  end

  @doc "Stops the graph machine, as a release or a crash does."
  def stop(peer), do: :peer.stop(peer)

  @doc "Takes this node back out of the cluster."
  def leave_cluster, do: :net_kernel.stop()

  @doc """
  A write's ownership check that admits it as `id`, from code both machines
  share, as two machines on one release do.
  """
  def authorized(id), do: fn _within -> {:ok, command(id)} end

  @doc false
  # On the graph machine: its writers outlive the call that started them.
  def run_graph(opts) do
    caller = self()

    spawn(fn ->
      children = [
        %{id: Keyfleet.Graph.Processes, start: {:pg, :start_link, [Keyfleet.Graph.Processes]}},
        {Keyfleet.Graph.Supervisor, opts}
      ]

      {:ok, graph} = Supervisor.start_link(children, strategy: :one_for_one)
      send(caller, {:graph, graph})
      Process.sleep(:infinity)
    end)

    receive do
      {:graph, graph} -> {:ok, graph}
    after
      30_000 -> {:error, :timeout}
    end
  end

  defp graph_settings, do: Application.fetch_env!(:keyfleet, :graph)

  defp unique, do: System.unique_integer([:positive])

  defp command(id) do
    contract = "0x" <> String.duplicate("b2", 20)
    wallet = "0x" <> String.duplicate("a1", 20)

    %{
      id: id,
      principal: "member:8453:#{contract}:17@3/agent:#{wallet}",
      auth: %{
        key: %{chain_id: 8453, contract: contract, token_id: 17},
        ownership_epoch: 3,
        kind: "agent",
        operator_wallet: wallet,
        credential_ref: nil,
        checked_at: "2026-09-22T12:00:00Z",
        chain_block: nil
      }
    }
  end
end

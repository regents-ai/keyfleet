defmodule KeyFleet.Graph.Projector do
  @moduledoc """
  Keeps one fleet's workspace read tables copied from its graph log.

  Two things make it copy: a write that has just been applied asks it to
  reach that write's place in the log (`await/3`), and every
  `:catch_up_interval` it copies whatever the log holds beyond its cursor
  anyway. The second is what makes the first only a hint: a request that is
  lost, or a copy that failed, is made good on the next round from the
  cursor, which is kept with the tables. A copy that fails is logged and
  tried again on the next round; nothing that goes wrong stops the projector.

  It remembers which log, and how far along it, the tables reached last; a
  place in one log says nothing about another. Each time that changes, it
  says so on `KeyFleet.Graph.head_topic/1`.
  """
  use GenServer

  require Logger

  alias KeyFleet.Graph
  alias KeyFleet.Graph.Projection

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :fleet_id)}, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    fleet_id = Keyword.fetch!(opts, :fleet_id)
    wait = Keyword.fetch!(opts, :projection_wait)
    name = {:via, Registry, {KeyFleet.Graph.ProjectorRegistry, fleet_id, wait}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Waits, up to `:projection_wait`, until the fleet's read tables reach `seq`
  in the log named `run_id`, the place a write just reached, so a read made
  after the write answers finds it.

  Answers how far along that log the tables are known to have reached, 0 when
  none of it is known to be copied. A projector that is not running, or not
  there in time, leaves the write to the next round; the write stands either
  way.
  """
  @spec await(String.t(), String.t(), non_neg_integer()) :: non_neg_integer()
  def await(fleet_id, run_id, seq) do
    case Registry.lookup(KeyFleet.Graph.ProjectorRegistry, fleet_id) do
      [{pid, wait}] -> GenServer.call(pid, {:await, run_id, seq}, wait)
      [] -> 0
    end
  rescue
    # The registry is absent while the projectors are switched off or restarting.
    ArgumentError -> 0
  catch
    :exit, _reason -> 0
  end

  @impl true
  def init(opts) do
    state = %{
      fleet_id: Keyword.fetch!(opts, :fleet_id),
      interval: Keyword.fetch!(opts, :catch_up_interval),
      run_id: nil,
      watermark: 0
    }

    {:ok, state, {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state), do: {:noreply, scheduled_round(state)}

  @impl true
  def handle_info(:catch_up, state), do: {:noreply, scheduled_round(state)}

  @impl true
  def handle_call({:await, run_id, seq}, _from, %{run_id: run_id, watermark: watermark} = state)
      when watermark >= seq,
      do: {:reply, watermark, state}

  def handle_call({:await, run_id, _seq}, _from, state) do
    state = catch_up(state)
    {:reply, reached(state, run_id), state}
  end

  defp reached(%{run_id: run_id, watermark: watermark}, run_id), do: watermark
  defp reached(_state, _run_id), do: 0

  defp scheduled_round(state) do
    Process.send_after(self(), :catch_up, state.interval)
    catch_up(state)
  end

  defp catch_up(state) do
    case copy(state.fleet_id) do
      {:ok, {run_id, watermark}} ->
        if {run_id, watermark} != {state.run_id, state.watermark} do
          Phoenix.PubSub.broadcast(
            KeyFleet.PubSub,
            Graph.head_topic(state.fleet_id),
            {:graph_head, state.fleet_id, run_id, watermark}
          )
        end

        %{state | run_id: run_id, watermark: watermark}

      {:error, reason} ->
        Logger.warning(
          "copying the workspace of #{state.fleet_id} stopped (#{short(reason)}); " <>
            "the next round resumes it"
        )

        state
    end
  end

  # The kind of failure only: the same one repeats every round until it clears.
  defp short(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp short({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp short(%{__exception__: true} = exception), do: inspect(exception.__struct__)
  defp short(_reason), do: "unexpected reply"

  # A database failure mid-copy leaves the cursor at the last page that
  # committed, so the next round simply resumes there.
  defp copy(fleet_id) do
    Projection.catch_up(fleet_id)
  rescue
    exception -> {:error, exception}
  end
end

defmodule Keyfleet.Graph.Writer do
  @moduledoc """
  The single writer for one fleet's work graph.

  Each writer owns one graph host, a Python process behind a port that speaks
  length-prefixed JSON, and sends it one request at a time. The writer outlives
  its host: a host that cannot start, exits, or misses a deadline is replaced
  after a delay that doubles with each failure in a row, and requests made
  while no host is ready return `{:error, :unavailable}`. The first failure in
  a row is saved with the site's errors (`Keyfleet.Graph.StalledError`).

  A reply that does not arrive within the deadline, or a host that exits while
  a request is in flight, leaves the outcome unknown: the caller gets
  `{:error, :indeterminate}` and the host is killed. The host keeps a ledger of
  every command it committed, so retrying with the same command id returns the
  original result instead of applying it twice.

  Each host is started with the fleet's starting goals (`:starting_goals`, each
  `%{title, outcome}`), which it keeps in the workspace as listed before it
  answers.

  A write's authority is decided at its turn, inside the writer: whatever
  changed while it waited behind other requests, such as a key changing hands,
  counts. That check gets `:check_timeout` to read what it needs, and a caller
  waits for it on top of the reply.
  """
  use GenServer

  require Logger

  alias Keyfleet.Graph.Registry, as: GraphRegistry
  alias Keyfleet.Graph.StalledError

  @read_ops ~w(hello changes)
  @write_ops ~w(create patch link unlink archive join leave submit review)

  # How long a killed host gets to be reaped before the writer moves on.
  @reap_ms 5_000

  @hello Jason.encode!(%{v: 1, op: "hello", body: %{}})

  # The same refusal the host gives a frame it cannot parse.
  @unencodable %{
    "code" => "bad_request",
    "message" => "the request cannot be written as JSON",
    "details" => %{}
  }

  # The host inherits nothing from the application's environment: it needs no
  # secrets, and its interpreter runs isolated from PYTHON* variables, the
  # user site directory and the working directory.
  @host_env [{~c"LANG", ~c"C.UTF-8"}]

  @type reply :: {:ok, map()} | {:error, map() | :indeterminate | :unavailable | Exception.t()}
  @type authorize :: (non_neg_integer() -> {:ok, map()} | {:error, Exception.t()})

  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :fleet_id)}, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    fleet_id = Keyword.fetch!(opts, :fleet_id)
    # The longest the writer spends on one request once it is that request's turn.
    turn = Keyword.fetch!(opts, :check_timeout) + Keyword.fetch!(opts, :reply_timeout)
    name = {:via, Registry, {GraphRegistry, fleet_id, turn}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends a read of the log itself (`hello` or `changes`) to the fleet's graph.

  Only the projector reads the log this way, to copy it into the read tables
  every workspace read is answered from; see `Keyfleet.Graph.Projection`.
  """
  @spec request(String.t(), String.t(), map()) :: reply()
  def request(fleet_id, op, body) when op in @read_ops do
    with {:ok, json} <- encode(%{v: 1, op: op, body: body}) do
      send_to_writer(fleet_id, {:send, json})
    end
  end

  @doc """
  Sends a write to the fleet's graph on behalf of a member.

  `authorize` runs inside the writer when the write's turn comes, just before
  the write reaches the host, and is given the milliseconds it may spend. It
  answers `{:ok, command}`, the command's `:id`, `:principal`, `:auth` and
  `:writable_scopes` as they stand at that moment, or `{:error, error}`, which
  is returned as it is with nothing sent; one that exits or raises is
  answered `{:error, :unavailable}`, also with nothing sent.
  """
  @spec command(String.t(), String.t(), map(), authorize()) :: reply()
  def command(fleet_id, op, body, authorize) when op in @write_ops do
    with {:ok, json} <- encode(body) do
      send_to_writer(fleet_id, {:command, op, json, authorize})
    end
  end

  # Bodies are encoded here, in the caller's process, so one that JSON cannot
  # express is refused before it reaches the writer.
  defp encode(term) do
    with {:error, _reason} <- Jason.encode(term), do: {:error, @unencodable}
  end

  defp send_to_writer(fleet_id, request) do
    case lookup(fleet_id) do
      {:ok, pid, turn} -> call_writer(pid, request, turn + @reap_ms + 1_000)
      :error -> {:error, :unavailable}
    end
  end

  defp lookup(fleet_id) do
    case Registry.lookup(GraphRegistry, fleet_id) do
      [{pid, turn}] -> {:ok, pid, turn}
      [] -> :error
    end
  rescue
    # The registry is absent while the graph is switched off or restarting.
    ArgumentError -> :error
  end

  # A writer that is gone before the call reaches it has done nothing; one
  # that does not answer in time may yet run the request.
  defp call_writer(pid, request, timeout) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :unavailable}
    :exit, _reason -> {:error, :indeterminate}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      fleet_id: Keyword.fetch!(opts, :fleet_id),
      data_dir: Keyword.fetch!(opts, :data_dir),
      python: Keyword.fetch!(opts, :python),
      reply_timeout: Keyword.fetch!(opts, :reply_timeout),
      check_timeout: Keyword.fetch!(opts, :check_timeout),
      hello_timeout: Keyword.fetch!(opts, :hello_timeout),
      restart_min: Keyword.fetch!(opts, :restart_min),
      restart_max: Keyword.fetch!(opts, :restart_max),
      restart_delay: Keyword.fetch!(opts, :restart_min),
      starting_goals: Jason.encode!(Keyword.fetch!(opts, :starting_goals)),
      host: nil,
      next_req: 0
    }

    {:ok, state, {:continue, :start_host}}
  end

  @impl true
  def handle_continue(:start_host, state), do: {:noreply, start_host(state)}

  @impl true
  def handle_call({:send, json}, _from, %{host: %{ready?: true}} = state) do
    case exchange(json, state) do
      {:ok, reply, state} -> {:reply, reply, state}
      {:lost, reason, state} -> {:reply, {:error, :indeterminate}, host_failed(state, reason)}
    end
  end

  def handle_call({:command, op, body, authorize}, from, %{host: %{ready?: true}} = state) do
    case check(authorize, state) do
      {:ok, command} ->
        message = %{v: 1, op: op, command: command, body: Jason.Fragment.new(body)}
        handle_call({:send, Jason.encode!(message)}, from, state)

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unavailable}, state}

  # A database pool that is down or out of time exits its caller, and a fault
  # in the check raises; either would stop the writer, so a check that exits
  # or raises is answered as unavailable, with nothing sent.
  defp check(authorize, state) do
    authorize.(state.check_timeout)
  rescue
    error ->
      Logger.warning(
        "graph write for #{state.fleet_id} not sent: its ownership check raised: " <>
          Exception.message(error)
      )

      {:error, :unavailable}
  catch
    :exit, reason ->
      Logger.warning(
        "graph write for #{state.fleet_id} not sent: its ownership check exited: " <>
          Exception.format_exit(reason)
      )

      {:error, :unavailable}
  end

  @impl true
  def handle_info(:start_host, state), do: {:noreply, start_host(state)}

  def handle_info({port, {:data, data}}, %{host: %{port: port, ready?: false} = host} = state) do
    {req, deadline} = host.hello
    Process.cancel_timer(deadline)

    case decode(data, req) do
      {:ok, _hello} ->
        {:noreply,
         %{state | host: %{host | ready?: true, hello: nil}, restart_delay: state.restart_min}}

      _unexpected ->
        {:noreply, host_failed(state, kill(host, :bad_hello))}
    end
  end

  def handle_info({:hello_deadline, port}, %{host: %{port: port, ready?: false} = host} = state) do
    {:noreply, host_failed(state, kill(host, :hello_timeout))}
  end

  def handle_info({port, {:exit_status, status}}, %{host: %{port: port}} = state) do
    {:noreply, host_failed(state, {:host_exited, status})}
  end

  def handle_info({:EXIT, port, reason}, %{host: %{port: port}} = state) do
    {:noreply, host_failed(state, {:port_closed, reason})}
  end

  # What is left comes from a host this writer has already replaced.
  def handle_info({port, _message}, state) when is_port(port), do: {:noreply, state}
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}
  def handle_info({:hello_deadline, _port}, state), do: {:noreply, state}
  # A process a write's check linked to the writer, such as a task its reads
  # ran in, has finished.
  def handle_info({:EXIT, pid, _reason}, state) when is_pid(pid), do: {:noreply, state}

  # sobelow_skip ["Traversal.FileModule"]
  defp start_host(state) do
    with :ok <- File.mkdir_p(state.data_dir),
         {:ok, port} <- open_port(state) do
      req = Integer.to_string(state.next_req)
      send(port, {self(), {:command, frame(@hello, req)}})
      deadline = Process.send_after(self(), {:hello_deadline, port}, state.hello_timeout)
      host = %{port: port, ready?: false, hello: {req, deadline}}
      %{state | host: host, next_req: state.next_req + 1}
    else
      {:error, reason} -> host_failed(state, {:start_failed, reason})
    end
  end

  defp open_port(state) do
    db = Path.join(state.data_dir, "#{state.fleet_id}.sqlite")

    args = [
      "-I",
      "-m",
      "keyfleet_graph",
      "--fleet",
      state.fleet_id,
      "--db",
      db,
      "--starting-goals",
      state.starting_goals
    ]

    {:ok,
     Port.open({:spawn_executable, state.python}, [
       :binary,
       :exit_status,
       {:packet, 4},
       {:cd, "/"},
       {:env, host_env()},
       {:args, args}
     ])}
  rescue
    # A missing or unrunnable interpreter.
    error in ErlangError -> {:error, error.original}
  end

  defp host_env do
    inherited = for {name, _value} <- System.get_env(), do: {String.to_charlist(name), false}
    names = Enum.map(@host_env, &elem(&1, 0))
    Enum.reject(inherited, fn {name, false} -> name in names end) ++ @host_env
  end

  # Puts the request id first in an encoded message object. The id is a
  # decimal integer, so it needs no escaping.
  defp frame("{" <> fields, req), do: [~s({"req":"), req, ~s(",), fields]

  defp exchange(json, %{host: %{port: port} = host} = state) do
    req = Integer.to_string(state.next_req)
    send(port, {self(), {:command, frame(json, req)}})
    state = %{state | next_req: state.next_req + 1}

    receive do
      {^port, {:data, data}} ->
        case decode(data, req) do
          :garbled -> {:lost, kill(host, :garbled_reply), state}
          reply -> {:ok, reply, state}
        end

      {^port, {:exit_status, status}} ->
        {:lost, {:host_exited, status}, state}

      {:EXIT, ^port, reason} ->
        {:lost, {:port_closed, reason}, state}
    after
      state.reply_timeout -> {:lost, kill(host, :reply_timeout), state}
    end
  end

  # Replies are strictly in order, so the only reply that may carry no request
  # id is the refusal of a frame the host could not parse at all.
  defp decode(data, req) do
    case Jason.decode(data) do
      {:ok, %{"req" => ^req, "ok" => true} = reply} ->
        {:ok, reply}

      {:ok, %{"req" => reply_req, "ok" => false, "error" => error}}
      when reply_req in [req, nil] ->
        {:error, error}

      _other ->
        :garbled
    end
  end

  # The runtime image has /bin/sh but no kill executable, so the shell's
  # builtin sends the signal. The pid is read from the port just before the
  # signal: the port closes the moment its host is reaped, and a pid is only
  # free for reuse after that. A closed port is left alone, and the one window
  # left, while the shell starts, is far too short for the OS to hand the pid
  # to another process. The host's exit status arrives either way.
  defp kill(%{port: port}, reason) do
    os_pid = signal(port)

    receive do
      {^port, {:exit_status, _status}} -> reason
    after
      @reap_ms ->
        send(port, {self(), :close})
        {reason, {:not_reaped, os_pid}}
    end
  end

  # sobelow_skip ["CI.System"]
  defp signal(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("/bin/sh", ["-c", ~s(kill -9 "$0"), Integer.to_string(os_pid)],
          stderr_to_stdout: true
        )

        os_pid

      nil ->
        nil
    end
  end

  defp host_failed(state, reason) do
    Logger.warning("graph host for #{state.fleet_id} stopped: #{inspect(reason)}")

    if state.restart_delay == state.restart_min,
      do: StalledError.report("The graph host of #{state.fleet_id} stopped: #{inspect(reason)}")

    if state.host && state.host.hello, do: Process.cancel_timer(elem(state.host.hello, 1))

    Process.send_after(self(), :start_host, state.restart_delay)
    %{state | host: nil, restart_delay: min(state.restart_delay * 2, state.restart_max)}
  end
end

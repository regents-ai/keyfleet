defmodule KeyfleetWeb.NotebookSocket do
  @moduledoc """
  One live notebook connection, carried between a browser or agent and the
  fleet's hub (`KeyfleetWeb.Plugs.NotebookGateway`).

  The gateway opens the hub's side first (`connect/3`), so a hub that refuses
  is answered as a plain refusal. Once both sides are open, every frame is
  passed along as it is. The connection registers under its fleet and holder
  (`Keyfleet.Notebooks.access_topic/2`): when the holder loses their key, it
  closes with 1008 and says why.
  """
  @behaviour WebSock

  alias Keyfleet.Notebooks

  @closed_reason "Your key no longer opens these notebooks."

  @doc """
  Opens the hub's side of the connection to `target` at `address`, waiting
  `hub_timeout_ms` for the hub to agree: `{:ok, upstream}`, where `protocol`
  is the subprotocol the hub chose, or `{:error, reason}`.
  """
  def connect(address, target, headers) do
    uri = URI.parse(address)
    {http, ws} = if uri.scheme == "https", do: {:https, :wss}, else: {:http, :ws}
    timeout = Notebooks.config()[:hub_timeout_ms]

    with {:ok, conn} <- Mint.HTTP.connect(http, uri.host, uri.port, mode: :passive),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws, conn, target, headers),
         {:ok, conn, status, response_headers, early} <- handshake(conn, ref, timeout, []),
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, response_headers) do
      protocol = List.first(for {"sec-websocket-protocol", value} <- response_headers, do: value)
      {:ok, %{conn: conn, ref: ref, websocket: websocket, early: early, protocol: protocol}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
      {:error, _conn, reason, _responses} -> {:error, reason}
    end
  end

  # Reads the hub's answer to the upgrade until it is complete.
  defp handshake(conn, ref, timeout, parts) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} -> handshake_read(conn, ref, timeout, parts ++ responses)
      {:error, conn, reason, _responses} -> {:error, conn, reason}
    end
  end

  defp handshake_read(conn, ref, timeout, parts) do
    if Enum.any?(parts, &match?({:done, ^ref}, &1)),
      do: handshake_answer(conn, ref, parts),
      else: handshake(conn, ref, timeout, parts)
  end

  defp handshake_answer(conn, ref, parts) do
    {:status, ^ref, status} = List.keyfind(parts, :status, 0)
    {:headers, ^ref, headers} = List.keyfind(parts, :headers, 0)
    {:ok, conn, status, headers, for({:data, ^ref, data} <- parts, do: data)}
  end

  @impl WebSock
  def init(state) do
    :ok =
      Phoenix.PubSub.subscribe(
        Keyfleet.PubSub,
        Notebooks.access_topic(state.fleet_id, state.subject)
      )

    {:ok, conn} = Mint.HTTP.set_mode(state.conn, :active)
    state = %{state | conn: conn}

    relay(%{state | early: []}, state.early)
  end

  @impl WebSock
  def handle_in({data, opcode: opcode}, state), do: to_hub(state, {opcode, data})

  @impl WebSock
  def handle_info(:notebook_access_ended, state),
    do: {:stop, :normal, {1008, @closed_reason}, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        ref = state.ref
        relay(%{state | conn: conn}, for({:data, ^ref, data} <- responses, do: data))

      {:error, _conn, _reason, _responses} ->
        {:stop, :normal, 1011, state}

      :unknown ->
        {:ok, state}
    end
  end

  @impl WebSock
  def terminate(_reason, state) do
    _closed = to_hub(state, {:close, 1000, ""})
    Mint.HTTP.close(state.conn)
    :ok
  end

  # Passes what the hub sent on to the client, in order.
  defp relay(state, parts) do
    Enum.reduce_while(parts, {:ok, state, []}, fn data, {:ok, state, out} ->
      case from_hub(state, data) do
        {:ok, state, frames} -> {:cont, {:ok, state, out ++ frames}}
        stop -> {:halt, stop}
      end
    end)
    |> case do
      {:ok, state, []} -> {:ok, state}
      {:ok, state, frames} -> {:push, frames, state}
      stop -> stop
    end
  end

  # The frames the hub sent, for the client; a ping is answered here.
  defp from_hub(state, data) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce_while(frames, {:ok, %{state | websocket: websocket}, []}, &take_frame/2)

      {:error, _websocket, _reason} ->
        {:stop, :normal, 1011, state}
    end
  end

  defp take_frame({:ping, payload}, {:ok, state, out}) do
    case to_hub(state, {:pong, payload}) do
      {:ok, state} -> {:cont, {:ok, state, out}}
      stop -> {:halt, stop}
    end
  end

  defp take_frame({:pong, _payload}, acc), do: {:cont, acc}

  defp take_frame({:close, code, reason}, {:ok, state, _out}) when is_integer(code),
    do: {:halt, {:stop, :normal, {code, reason}, state}}

  defp take_frame({:close, _code, _reason}, {:ok, state, _out}),
    do: {:halt, {:stop, :normal, 1000, state}}

  defp take_frame({:error, _reason}, {:ok, state, _out}),
    do: {:halt, {:stop, :normal, 1011, state}}

  defp take_frame(frame, {:ok, state, out}), do: {:cont, {:ok, state, out ++ [frame]}}

  defp to_hub(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      _error -> {:stop, :normal, 1011, state}
    end
  end
end

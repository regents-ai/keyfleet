defmodule KeyfleetWeb.Plugs.UnreadBodyTest do
  # Costly failure: a body nothing reads is read by the web server after the
  # answer in one piece of up to 8 MB, held until its last byte arrives, so a
  # hundred kept-open connections hold most of the site machine's memory; or
  # the fix closes a connection with the body still arriving, and the caller
  # never hears its answer. Served on a real port and sent as raw bytes, so
  # each answer is read the way a caller reads it.
  use ExUnit.Case, async: false

  alias KeyfleetWeb.SignedAgentHelpers

  defmodule InParts do
    # An answer sent in parts, as the notebook and code gateways stream theirs,
    # behind the plug as the endpoint has it.
    use Plug.Builder

    plug KeyfleetWeb.Plugs.UnreadBody
    plug :answer

    def answer(conn, _opts) do
      {:ok, conn} = conn |> send_chunked(200) |> chunk("first part, ")
      {:ok, conn} = chunk(conn, "last part")
      conn
    end
  end

  @mib 1024 * 1024

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    %URI{port: port} = URI.parse(SignedAgentHelpers.serve_site!(:site).url)
    %{port: port}
  end

  test "a body nothing reads is read before each kind of answer, which then closes its connection",
       c do
    body = :binary.copy("b", @mib)

    answers =
      for {method, path, host, kind} <- [
            {"POST", "/", "localhost", :error_page_after_no_route},
            {"GET", "/healthz", "localhost", :sent},
            {"HEAD", "/healthz", "localhost", :sent},
            {"GET", "/favicon.ico", "localhost", :file},
            {"GET", "/", "www.localhost", :redirect}
          ] do
        socket = connect!(c.port)
        :ok = :gen_tcp.send(socket, [head(method, path, host, length: byte_size(body)), body])
        answer = answer!(socket, method)
        {kind, answer.status, answer.headers["connection"], ends(socket)}
      end

    assert answers == [
             {:error_page_after_no_route, 404, "close", :closed},
             {:sent, 200, "close", :closed},
             {:sent, 200, "close", :closed},
             {:file, 200, "close", :closed},
             {:redirect, 301, "close", :closed}
           ]
  end

  # Costly failure: LiveView's long-poll answers again, and reads each message
  # whole, up to 8 MB, and decodes it: twenty anonymous messages of 1 MB, nested
  # deep, held 1,988 MiB at once.
  test "LiveView's long-poll address has nothing at it, so a body sent there is read the same way",
       c do
    body = :binary.copy("l", @mib)

    answers =
      for method <- ["GET", "POST"] do
        socket = connect!(c.port)
        path = "/live/longpoll?vsn=2.0.0"
        :ok = :gen_tcp.send(socket, [head(method, path, "localhost", length: @mib), body])
        answer = answer!(socket, method)
        {method, answer.status, answer.headers["connection"], ends(socket)}
      end

    assert answers == [{"GET", 404, "close", :closed}, {"POST", 404, "close", :closed}]
  end

  test "a body sent in chunks with no length is read the same way", c do
    socket = connect!(c.port)
    piece = :binary.copy("c", 300 * 1024)
    chunk = [Integer.to_string(byte_size(piece), 16), "\r\n", piece, "\r\n"]

    :ok =
      :gen_tcp.send(socket, [
        head("POST", "/", "localhost", [{"transfer-encoding", "chunked"}]),
        List.duplicate(chunk, 3),
        "0\r\n\r\n"
      ])

    answer = answer!(socket, "POST")
    assert {answer.status, answer.headers["connection"], ends(socket)} == {404, "close", :closed}
  end

  test "a caller whose 7.5 MB body is refused unread hears its refusal", c do
    socket = connect!(c.port)
    body = :binary.copy("r", 7_500_000)
    :ok = :gen_tcp.send(socket, [head("POST", "/", "localhost", length: byte_size(body)), body])

    answer = answer!(socket, "POST")
    assert {answer.status, answer.headers["connection"], ends(socket)} == {404, "close", :closed}
  end

  test "a body the route read leaves its connection open for the next request", c do
    socket = connect!(c.port)
    body = ~s({"code":"not-a-code"})

    :ok =
      :gen_tcp.send(socket, [
        head("POST", "/api/agents/v1/pair", "localhost", [
          {"content-type", "application/json"},
          {"content-length", Integer.to_string(byte_size(body))}
        ]),
        body
      ])

    paired = answer!(socket, "POST")
    :ok = :gen_tcp.send(socket, head("GET", "/healthz", "localhost", []))
    health = answer!(socket, "GET")

    assert paired.status in 400..499
    assert {paired.headers["connection"], health.status} == {nil, 200}
  end

  @tag timeout: 60_000
  test "a sender that stops short hears its answer within ten seconds, and the connection closes",
       c do
    socket = connect!(c.port)
    started = System.monotonic_time(:millisecond)

    :ok =
      :gen_tcp.send(socket, [
        head("POST", "/", "localhost", length: @mib),
        :binary.copy("s", div(@mib, 2))
      ])

    answer = answer!(socket, "POST")
    waited = System.monotonic_time(:millisecond) - started

    assert {answer.status, answer.headers["connection"]} == {404, "close"}
    assert waited in 9_000..12_000
  end

  # Costly failure: a caller that waits to be told to send its body is told
  # to send 8 MB nobody reads, or waits ten seconds for its answer.
  test "a caller that asks before sending its body is answered at once and never asked for it",
       c do
    socket = connect!(c.port)

    :ok =
      :gen_tcp.send(
        socket,
        head("POST", "/", "localhost", [{"content-length", "8000000"}, {"expect", "100-continue"}])
      )

    {waited, answer} = :timer.tc(fn -> answer!(socket, "POST") end, :millisecond)

    assert {answer.status, answer.headers["connection"], ends(socket)} == {404, "close", :closed}
    assert waited < 1_000
  end

  # Costly failure: each chunk restarts the wait for the next, so a sender
  # keeps the answer, and the connection's process, for as long as it sends
  # a byte every few seconds.
  @tag timeout: 60_000
  test "a body in chunks still arriving is not waited for", c do
    socket = connect!(c.port)

    :ok =
      :gen_tcp.send(socket, head("POST", "/", "localhost", [{"transfer-encoding", "chunked"}]))

    dripper = spawn(fn -> drip(socket, 15) end)

    {waited, answer} = :timer.tc(fn -> answer!(socket, "POST") end, :millisecond)
    Process.exit(dripper, :kill)

    assert {answer.status, answer.headers["connection"]} == {404, "close"}
    assert waited < 1_000
  end

  # Costly failure: a read of the rest in one large piece holds it all until
  # its last byte arrives.
  @tag timeout: 60_000
  test "twenty bodies whose last byte is held back hold no more than their pieces", c do
    :erlang.garbage_collect()
    before = :erlang.memory(:total)

    sockets =
      for _ <- 1..20 do
        socket = connect!(c.port)
        :ok = :gen_tcp.send(socket, head("POST", "/", "localhost", length: 7_500_001))
        :ok = :gen_tcp.send(socket, :binary.copy("h", 7_500_000))
        socket
      end

    grew = div(:erlang.memory(:total) - before, @mib)
    Enum.each(sockets, &:gen_tcp.close/1)

    assert grew < 60
  end

  # Costly failure: no bound on what is read for nothing.
  test "a body is read for 8 MB at most, and the rest is left unread", c do
    socket = connect!(c.port)
    :ok = :gen_tcp.send(socket, head("POST", "/", "localhost", length: 40 * @mib))
    test = self()

    spawn(fn ->
      sent = Enum.count(1..40, fn _ -> :gen_tcp.send(socket, :binary.copy("m", @mib)) == :ok end)
      send(test, {:sent, sent})
    end)

    assert_receive {:sent, mib_sent}, 20_000
    assert mib_sent < 40
  end

  test "an answer sent in parts comes whole after the body nothing read" do
    server =
      start_supervised!(
        {Bandit, plug: InParts, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :in_parts
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    socket = connect!(port)
    body = :binary.copy("p", @mib)
    :ok = :gen_tcp.send(socket, [head("POST", "/", "localhost", length: byte_size(body)), body])

    answer = answer!(socket, "POST")

    assert {answer.status, answer.body, answer.headers["connection"], ends(socket)} ==
             {200, "first part, last part", "close", :closed}
  end

  ## Raw requests and answers

  defp connect!(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

    socket
  end

  defp head(method, path, host, length: length),
    do: head(method, path, host, [{"content-length", Integer.to_string(length)}])

  defp head(method, path, host, headers) do
    [
      method,
      " ",
      path,
      " HTTP/1.1\r\nhost: ",
      host,
      "\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  # The status, the headers by name and the body of the next answer.
  defp answer!(socket, method) do
    {head, rest} = read_head!(socket, "")
    [status_line | lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _reason] = String.split(status_line, " ")

    headers =
      Map.new(lines, fn line ->
        [name, value] = String.split(line, ": ", parts: 2)
        {String.downcase(name), value}
      end)

    body =
      cond do
        method == "HEAD" -> ""
        headers["transfer-encoding"] == "chunked" -> read_parts!(socket, rest, "")
        true -> read_exactly!(socket, rest, String.to_integer(headers["content-length"] || "0"))
      end

    %{status: String.to_integer(status), headers: headers, body: body}
  end

  defp read_head!(socket, read) do
    case :binary.split(read, "\r\n\r\n") do
      [head, rest] -> {head, rest}
      [_partial] -> read_head!(socket, read <> recv!(socket))
    end
  end

  defp read_exactly!(_socket, read, length) when byte_size(read) >= length,
    do: binary_part(read, 0, length)

  defp read_exactly!(socket, read, length),
    do: read_exactly!(socket, read <> recv!(socket), length)

  defp read_parts!(socket, read, body) do
    with [size, rest] <- :binary.split(read, "\r\n"),
         size = String.to_integer(size, 16),
         true <- byte_size(rest) >= size + 2 do
      <<part::binary-size(^size), "\r\n", rest::binary>> = rest
      if size == 0, do: body, else: read_parts!(socket, rest, body <> part)
    else
      _incomplete -> read_parts!(socket, read <> recv!(socket), body)
    end
  end

  defp recv!(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 20_000)
    data
  end

  # One byte in a chunk of its own, every second, `left` times.
  defp drip(_socket, 0), do: :ok

  defp drip(socket, left) do
    Process.sleep(1_000)
    if :gen_tcp.send(socket, "1\r\nd\r\n") == :ok, do: drip(socket, left - 1)
  end

  # How the connection ends once the answer is read: :closed when the site
  # closed it in order, the error otherwise.
  defp ends(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:error, :closed} -> :closed
      other -> other
    end
  end
end

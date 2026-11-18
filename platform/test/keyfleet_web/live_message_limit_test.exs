defmodule KeyfleetWeb.LiveMessageLimitTest do
  # Costly failure: a page's largest message closes its live socket, so the
  # page never goes live, wallet buttons included; or the socket reads a
  # message of any size. Served on a real port, the socket opened and written
  # to as a browser does.
  use ExUnit.Case, async: false

  alias KeyfleetWeb.SignedAgentHelpers

  @limit Application.compile_env!(:keyfleet, [
           KeyfleetWeb.Endpoint,
           :http,
           :websocket_options,
           :max_fragmented_message_size
         ])
  # The longest request line Bandit reads, its line end included
  # (`max_request_line_length`).
  @request_line 10_000
  # The longest #fragment a page keeps (assets/js/app.ts).
  @fragment 256
  # The most a browser keeps of one cookie, its name and value together.
  @cookie 4_096
  # A frame's header as a browser sends a message of 126 to 65,535 bytes:
  # Bandit counts it with the message.
  @header 8

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    Keyfleet.Fleets.bootstrap_catalog!()
    %URI{port: port} = URI.parse(SignedAgentHelpers.serve_site!(:live_message_limit).url)
    %{port: port, origin: "http://127.0.0.1:#{port}"}
  end

  test "a page opened at the longest address the site takes goes live, and so does the next", c do
    # Each character of the query is one that JSON writes as two.
    target = "/?q=" <> String.duplicate("\\", @request_line - byte_size("GET /?q= HTTP/1.1\r\n"))
    assert {414, _} = status(c.port, target <> "\\")

    page = page!(c.port, target, schedule: @cookie - byte_size("keyfleet_schedule="))
    href = c.origin <> target <> "#" <> String.duplicate("\\", @fragment - 1)
    opened = join_message(page, "1", %{"url" => href}, %{})

    # Following one of the site's links from it, as long as an address the
    # site takes, with the page's first token: the address left travels with
    # the join (view.ts).
    link = c.origin <> "/?q=" <> String.duplicate("a", byte_size(target) - byte_size("/?q="))
    followed = join_message(page, "1", %{"redirect" => link}, %{"_live_referer" => href})

    assert joined(c.port, page, opened) == {:reply, "ok"}
    assert joined(c.port, page, followed) != {:closed, 1009}
    assert Enum.all?([opened, followed], &(byte_size(&1) + @header <= @limit))
  end

  test "a message as large as the socket reads is answered, and one byte more closes it", c do
    page = page!(c.port, "/", [])
    {socket, rest} = connect!(c.port, page)

    :ok = send_frame(socket, join_message(page, "1", %{"url" => c.origin <> "/"}, %{}))
    {joined, rest} = await(socket, rest, "1")

    :ok = send_frame(socket, heartbeat("2", @limit - @header))
    {largest, rest} = await(socket, rest, "2")

    :ok = send_frame(socket, heartbeat("3", @limit - @header + 1))
    {over, _rest} = await(socket, rest, "3")

    assert {joined, largest, over} == {{:reply, "ok"}, {:reply, "ok"}, {:closed, 1009}}
  end

  # A live page as a browser opens it: its main LiveView, the token and
  # cookies its socket connects with, and the assets it tracks.
  defp page!(port, target, opts) do
    cookie =
      case opts[:schedule] do
        nil -> []
        length -> [{"cookie", "keyfleet_schedule=" <> String.duplicate("f", length)}]
      end

    socket = connect_tcp!(port)
    :ok = :gen_tcp.send(socket, request("GET", target, cookie))
    {200, %{head: head, body: body}} = answer!(socket)
    :gen_tcp.close(socket)

    [main] = Regex.run(~r/<[^>]*data-phx-main[^>]*>/, body)
    [csrf] = Regex.run(~r/<meta[^>]*name="csrf-token"[^>]*>/, body)

    set =
      for [_, pair] <- Regex.scan(~r/^set-cookie: ([^;\r\n]+)/mi, head), do: pair

    %{
      id: attribute(main, "id"),
      session: attribute(main, "data-phx-session"),
      static: attribute(main, "data-phx-static"),
      csrf: attribute(csrf, "content"),
      tracked:
        for(
          [_, url] <- Regex.scan(~r/phx-track-static[^>]*(?:href|src)="([^"]+)"/, body),
          do: "http://127.0.0.1:#{port}" <> url
        ),
      cookie: Enum.join(set ++ Enum.map(cookie, &elem(&1, 1)), "; ")
    }
  end

  # The join LiveView's client sends (view.ts), with the params app.ts adds.
  defp join_message(page, ref, address, params) do
    Jason.encode!([
      ref,
      ref,
      "lv:" <> page.id,
      "phx_join",
      Map.merge(address, %{
        "params" =>
          Map.merge(
            %{
              "_csrf_token" => page.csrf,
              "_track_static" => page.tracked,
              "_mounts" => 0,
              "_mount_attempts" => 0
            },
            params
          ),
        "session" => page.session,
        "static" => page.static,
        "sticky" => false
      })
    ])
  end

  defp heartbeat(ref, bytes) do
    empty = Jason.encode!([nil, ref, "phoenix", "heartbeat", %{"pad" => ""}])

    Jason.encode!([
      nil,
      ref,
      "phoenix",
      "heartbeat",
      %{"pad" => String.duplicate("h", bytes - byte_size(empty))}
    ])
  end

  defp joined(port, page, message) do
    {socket, rest} = connect!(port, page)
    :ok = send_frame(socket, message)
    {outcome, _rest} = await(socket, rest, "1")
    :gen_tcp.close(socket)
    outcome
  end

  defp attribute(tag, name) do
    [_, value] = Regex.run(~r/\s#{name}="([^"]*)"/, tag)
    value |> String.replace("&amp;", "&") |> String.replace("&quot;", "\"")
  end

  defp status(port, target) do
    socket = connect_tcp!(port)
    :ok = :gen_tcp.send(socket, request("GET", target, []))
    {status, _} = answer!(socket)
    :gen_tcp.close(socket)
    {status, target}
  end

  ## A websocket, as a browser opens and writes it

  defp connect!(port, page) do
    socket = connect_tcp!(port)
    query = URI.encode_query(%{"_csrf_token" => page.csrf, "vsn" => "2.0.0"})

    :ok =
      :gen_tcp.send(
        socket,
        request("GET", "/live/websocket?" <> query, [
          {"connection", "Upgrade"},
          {"upgrade", "websocket"},
          {"sec-websocket-version", "13"},
          {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))},
          {"cookie", page.cookie}
        ])
      )

    {"HTTP/1.1 101 " <> _, rest} = read_head!(socket, "")
    {socket, rest}
  end

  # One masked text frame, its length written in the fewest bytes.
  defp send_frame(socket, payload) do
    size = byte_size(payload)
    mask = :crypto.strong_rand_bytes(4)
    masked = :crypto.exor(payload, binary_part(:binary.copy(mask, div(size, 4) + 1), 0, size))

    length =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    :gen_tcp.send(socket, [<<0x81>>, length, mask, masked])
  end

  # The reply to `ref`, or how the socket closed first.
  defp await(socket, buffer, ref) do
    case next_frame(socket, buffer) do
      {{1, text}, rest} ->
        case Jason.decode!(text) do
          [_join_ref, ^ref, _topic, "phx_reply", %{"status" => status}] ->
            {{:reply, status}, rest}

          _other ->
            await(socket, rest, ref)
        end

      {{8, <<code::16, _reason::binary>>}, _rest} ->
        {{:closed, code}, ""}

      {_other, rest} ->
        await(socket, rest, ref)
    end
  end

  defp next_frame(socket, buffer) do
    case buffer do
      <<_::4, op::4, 0::1, 127::7, size::64, payload::binary-size(size), rest::binary>> ->
        {{op, payload}, rest}

      <<_::4, op::4, 0::1, 126::7, size::16, payload::binary-size(size), rest::binary>> ->
        {{op, payload}, rest}

      <<_::4, op::4, 0::1, size::7, payload::binary-size(size), rest::binary>> when size < 126 ->
        {{op, payload}, rest}

      _incomplete ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 15_000)
        next_frame(socket, buffer <> data)
    end
  end

  ## Raw requests and answers

  defp connect_tcp!(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 5_000)

    socket
  end

  defp request(method, target, headers) do
    [
      method,
      " ",
      target,
      " HTTP/1.1\r\nhost: localhost\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  defp answer!(socket) do
    {head, rest} = read_head!(socket, "")
    [_version, status | _] = String.split(head, " ", parts: 3)
    [_, length] = Regex.run(~r/^content-length: (\d+)/mi, head) || [nil, "0"]

    {String.to_integer(status),
     %{head: head, body: read_exactly!(socket, rest, String.to_integer(length))}}
  end

  defp read_head!(socket, read) do
    case :binary.split(read, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 15_000)
        read_head!(socket, read <> data)
    end
  end

  defp read_exactly!(_socket, read, length) when byte_size(read) >= length,
    do: binary_part(read, 0, length)

  defp read_exactly!(socket, read, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 15_000)
    read_exactly!(socket, read <> data, length)
  end
end

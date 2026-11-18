defmodule KeyfleetWeb.Plugs.UnreadBody do
  @moduledoc """
  Just before an answer is sent, reads what is left of a request's body that
  nothing read, a small piece at a time, throws each piece away, and has the
  connection close once the answer is sent.

  Bandit reads such a rest itself once the answer is sent, to keep the
  connection open, but in one piece of up to 8 MB that it holds until the last
  byte arrives: a hundred kept-open connections each sending 7.5 MB to an
  address that reads none held 450 to 580 MiB at once, and with each last byte
  held back, 718 MiB for as long as the senders liked. Here the body takes one
  piece of 64 KiB at most. The connection still holds what the answer's own
  work left with it until the read ends, up to 10 seconds: about 8 MB for the
  docs page.

  Reading the whole body before the answer is what lets the caller hear it: a
  connection closed with its body still arriving is reset, and the caller's
  side throws away the answer it had not read yet, which callers sending a
  refused body of 1 MiB or more never heard. The connection still closes once
  the answer is sent: Plug sends it with the web server's state from before
  this callback ran (`Plug.Conn.send_resp/1`), so a server that kept the
  connection open would count the body as unread and read the next request as
  its rest. A request sent right behind such a body is never answered.

  A body is read for at most 8 MB, the most Bandit reads after an answer. Each
  read waits for its piece until 10 seconds after reading began, enough for
  8 MB sent at 0.8 MB a second, and after that takes only what has already
  arrived. A body sent in chunks is read only as far as it has already
  arrived, since Bandit waits for each chunk afresh: a read that waited could
  be held for as long as the sender kept sending small chunks. A caller still
  sending chunks may then find the connection reset before it reads the
  answer. Past any of these, the answer is sent with the rest unread, as
  Bandit sends it past 8 MB.

  Left alone:

    * an answer to a request whose body was read, or that had none: its
      connection stays open, as before;
    * an HTTP/1.1 request that asked `Expect: 100-continue`, in any letter
      case and with nothing added, and was never told to send its body:
      Bandit answers it at once and closes the connection without asking for
      the body (RFC 9110, section 10.1.1). A caller that sends its body
      anyway, without waiting to be asked, may find the connection closed
      before it reads the answer, as Bandit alone does. An HTTP/1.0 request,
      or one whose expectation is written any other way, is not left alone:
      its body is read as any other, one sent with its length waited for up
      to 10 seconds;
    * HTTP/2, where a client sends no more than the stream's window and Bandit
      resets a stream it has not read rather than reading it;
    * a connection upgraded to a websocket (`KeyfleetWeb.Plugs.NotebookGateway`);
    * an error page Phoenix sends after a plug above the router raised
      anything but a not-found, such as `Plug.Static` refusing a path with
      `..` in it: Phoenix builds it from the request as it entered the
      endpoint, before this plug. Bandit then closes the connection without
      reading anything more, so nothing is held, and a caller still sending a
      large body may not hear the error page.

  The LiveView socket's address is answered before any plug of the endpoint
  (`socket "/live"`), and upgraded to a websocket.
  """

  @behaviour Plug

  import Plug.Conn

  @piece 64 * 1024
  @most 8_000_000
  @wait_ms 10_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: register_before_send(conn, &read_the_rest/1)

  defp read_the_rest(%Plug.Conn{status: 101} = conn), do: conn

  # Any read, even of nothing, would tell the caller to send its body.
  defp read_the_rest(
         %Plug.Conn{adapter: {Bandit.Adapter, %Bandit.Adapter{expect_continue: true}}} = conn
       ),
       do: conn

  defp read_the_rest(conn) do
    case get_http_protocol(conn) do
      :"HTTP/2" -> conn
      _http_1 -> close_if_any_was_left(conn)
    end
  end

  defp close_if_any_was_left(conn) do
    case read_body(conn, length: 0) do
      {:more, _nothing, unread} ->
        throw_away(unread, @most, deadline(conn))
        put_resp_header(conn, "connection", "close")

      {:ok, _nothing, _read} ->
        conn
    end
  rescue
    # Bandit raises, rather than returning, when a read waits past its time or
    # the caller has gone. The answer goes out with the rest unread.
    _timed_out_or_gone in [Bandit.HTTPError, Bandit.TransportError] ->
      put_resp_header(conn, "connection", "close")
  end

  defp deadline(conn) do
    now = System.monotonic_time(:millisecond)

    case get_req_header(conn, "transfer-encoding") do
      [] -> now + @wait_ms
      _chunked -> now
    end
  end

  defp throw_away(conn, left, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    with {:more, piece, conn} <-
           read_body(conn, length: min(@piece, left), read_length: @piece, read_timeout: wait),
         true <- byte_size(piece) < left do
      throw_away(conn, left - byte_size(piece), deadline)
    end
  end
end

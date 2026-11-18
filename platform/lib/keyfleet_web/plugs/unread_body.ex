defmodule KeyfleetWeb.Plugs.UnreadBody do
  @moduledoc """
  Just before an answer is sent, reads what is left of a request's body that
  nothing read, a small piece at a time, throws each piece away, and has the
  connection close once the answer is sent.

  Bandit reads such a rest itself once the answer is sent, to keep the
  connection open, but in one piece of up to 8 MB that it holds until the last
  byte arrives: a hundred kept-open connections each sending 7.5 MB to an
  address that reads none held 450 to 580 MiB at once, and with each last byte
  held back, 718 MiB for as long as the senders liked. Here a connection holds
  one piece of 64 KiB at most.

  Reading the whole body before the answer is what lets the caller hear it: a
  connection closed with its body still arriving is reset, and the caller's
  side throws away the answer it had not read yet, which callers sending a
  refused body of 1 MiB or more never heard. The connection still closes once
  the answer is sent: Plug sends it with the web server's state from before
  this callback ran (`Plug.Conn.send_resp/1`), so a server that kept the
  connection open would count the body as unread and read the next request as
  its rest.

  A body is read for at most 8 MB, the most Bandit reads after an answer, and
  for at most 10 seconds in all, enough for 8 MB sent at 0.8 MB a second; past
  either, the answer is sent with the rest unread, as Bandit sends it past
  8 MB. A sender that awaits `Expect: 100-continue` is asked for its body here,
  since reading it is the only way to tell whether any is left.

  Left alone:

    * an answer to a request whose body was read, or that had none: its
      connection stays open, as before;
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

  defp read_the_rest(conn) do
    case get_http_protocol(conn) do
      :"HTTP/2" -> conn
      _http_1 -> close_if_any_was_left(conn)
    end
  end

  defp close_if_any_was_left(conn) do
    case read_body(conn, length: 0) do
      {:more, _nothing, unread} ->
        throw_away(unread, @most, System.monotonic_time(:millisecond) + @wait_ms)
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

  defp throw_away(conn, left, deadline) do
    wait = deadline - System.monotonic_time(:millisecond)

    with true <- wait > 0,
         {:more, piece, conn} <-
           read_body(conn, length: min(@piece, left), read_length: @piece, read_timeout: wait),
         true <- byte_size(piece) < left do
      throw_away(conn, left - byte_size(piece), deadline)
    end
  end
end

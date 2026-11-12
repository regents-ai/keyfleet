defmodule KeyfleetWeb.FeedController do
  @moduledoc """
  A signed agent's live feed, `GET /api/v1/feed`: one open answer of
  server-sent events (`text/event-stream`), each a line of JSON
  (`Keyfleet.Feed`) the moment it is posted. The signature is checked once,
  as the feed opens (`KeyfleetWeb.Plugs.SignedAgent`).

  - Each event carries an `id:`, its time in microseconds. A reconnect that
    sends it back as `Last-Event-ID` first gets what it missed, up to 100;
    past that, or for an id that is not one of these, `{"kind": "resync"}`
    says to catch up through the ordinary routes.
  - A comment line, `: keep-alive`, every `keep_alive_ms`, so a proxy never
    closes a quiet feed.
  - One feed per agent: opening another, on any machine, closes this one with
    `{"kind": "closed", "reason": "replaced"}`. A pairing that ends or changes
    closes it with `"reason": "pairing_changed"`, so the agent reconnects as it
    now is.
  - At most `max_open` feeds on one machine; past that the open is refused.

  The feed is this request's own process waiting for messages. It holds no
  database connection while it waits: each read takes one and gives it back.
  """

  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Feed
  alias KeyfleetWeb.Refusal
  alias RegentHttp.UnexpectedFailure

  @feeds KeyfleetWeb.OpenFeeds

  @doc "The registry that counts this machine's open feeds."
  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: @feeds)

  def show(conn, _params) do
    actor = conn.assigns.agent_actor

    case admit(actor) do
      :ok ->
        start(conn, actor, Feed.open(actor), last_event_id(conn))

      :full ->
        Refusal.json(conn, 503, "feed_full")
    end
  end

  # Registered first and counted after, so feeds opening together cannot all
  # read a count below the limit and pass.
  defp admit(%Agent{wallet_address: wallet}) do
    {:ok, _owner} = Registry.register(@feeds, wallet, nil)

    if Registry.count(@feeds) > setting(:max_open) do
      Registry.unregister(@feeds, wallet)
      :full
    else
      :ok
    end
  end

  # Subscribed to its own topic first, then told, so of two feeds opening
  # together at least the older one hears the newer. The answer starts only
  # once the feed listens, so whatever is posted after it starts is heard. The
  # connection's process may go on to answer another request, so the feed
  # leaves nothing behind in it.
  defp start(conn, actor, feed, since) do
    own = "agent_feed:" <> actor.wallet_address
    fixed = [own, RegentAgents.topic(actor.privy_user_id)]
    Enum.each(fixed, &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))
    Phoenix.PubSub.broadcast_from(Keyfleet.PubSub, self(), own, :feed_replaced)

    state = listen(%{feed: feed, topics: [], seen: MapSet.new(), timer: keep_alive()})

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    {conn, state} =
      case catch_up(conn, state, since) do
        {:ok, conn, state} -> loop(conn, state)
        {:error, conn} -> {conn, state}
      end

    Enum.each(fixed ++ state.topics, &Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, &1))
    Registry.unregister(@feeds, actor.wallet_address)
    Process.cancel_timer(state.timer)
    flush()
    conn
  end

  # Listens on what the feed now follows, and on nothing it no longer does.
  defp listen(%{feed: feed, topics: before} = state) do
    now = Feed.topics(feed)
    Enum.each(now -- before, &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1))
    Enum.each(before -- now, &Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, &1))
    %{state | topics: now}
  end

  defp catch_up(conn, state, nil), do: {:ok, conn, state}
  defp catch_up(conn, state, :invalid), do: resync(conn, state)

  defp catch_up(conn, state, since) do
    case Feed.missed(state.feed, since) do
      {:ok, events} ->
        with {:ok, conn} <- send_events(conn, events),
             do: {:ok, conn, %{state | seen: MapSet.new(events, & &1.id)}}

      :resync ->
        resync(conn, state)

      {:error, error} ->
        UnexpectedFailure.log(conn, error)
        resync(conn, state)
    end
  end

  defp resync(conn, state) do
    with {:ok, conn} <- send_data(conn, %{kind: "resync"}), do: {:ok, conn, state}
  end

  # `seen` is what the catch-up sent, which the feed may hear again.
  defp loop(conn, state) do
    receive do
      %{topic: _, event: _, payload: _} = notice ->
        hear(conn, state, notice)

      {:keys_changed, _fleet_id, _token_ids} = notice ->
        hear(conn, state, notice)

      {:keys_present, _fleet_id, _token_ids} ->
        loop(conn, state)

      :keep_alive ->
        continue(write(conn, ": keep-alive\n\n"), %{state | timer: keep_alive()})

      :feed_replaced ->
        close(conn, state, "replaced")

      :agents_changed ->
        if Agent.valid?(state.feed.actor),
          do: loop(conn, state),
          else: close(conn, state, "pairing_changed")
    end
  end

  defp hear(conn, state, notice) do
    case Feed.heard(state.feed, notice) do
      {:ok, events, feed} ->
        events = Enum.reject(events, &MapSet.member?(state.seen, &1.id))
        continue(send_events(conn, events), listen(%{state | feed: feed}))

      {:error, error} ->
        UnexpectedFailure.log(conn, error)
        continue(send_data(conn, %{kind: "resync"}), state)
    end
  end

  defp continue({:ok, conn}, state), do: loop(conn, state)
  defp continue({:error, conn}, state), do: {conn, state}

  defp close(conn, state, reason) do
    {_sent, conn} = send_data(conn, %{kind: "closed", reason: reason})
    {conn, state}
  end

  # What was announced after the feed stopped listening, and its last
  # keep-alive.
  defp flush do
    receive do
      %{topic: _, event: _, payload: _} -> flush()
      {:keys_changed, _fleet_id, _token_ids} -> flush()
      {:keys_present, _fleet_id, _token_ids} -> flush()
      :keep_alive -> flush()
      :feed_replaced -> flush()
      :agents_changed -> flush()
    after
      0 -> :ok
    end
  end

  defp send_events(conn, events) do
    Enum.reduce_while(events, {:ok, conn}, fn event, {:ok, conn} ->
      id = DateTime.to_unix(event.at, :microsecond)

      case send_frame(conn, ["id: ", Integer.to_string(id), "\n"], event) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        failed -> {:halt, failed}
      end
    end)
  end

  defp send_data(conn, data), do: send_frame(conn, [], data)

  defp send_frame(conn, id_line, data),
    do: write(conn, [id_line, "data: ", Jason.encode_to_iodata!(data), "\n\n"])

  # A reader that has gone away ends the feed.
  defp write(conn, iodata) do
    case chunk(conn, iodata) do
      {:ok, conn} -> {:ok, conn}
      {:error, _closed} -> {:error, conn}
    end
  end

  defp keep_alive, do: Process.send_after(self(), :keep_alive, setting(:keep_alive_ms))

  # Nil when none was sent; :invalid for one that is not a feed's id, which
  # reads as a resync.
  defp last_event_id(conn) do
    with [id] <- get_req_header(conn, "last-event-id"),
         {microseconds, ""} <- Integer.parse(id),
         {:ok, since} <- DateTime.from_unix(microseconds, :microsecond) do
      since
    else
      [] -> nil
      _invalid -> :invalid
    end
  end

  defp setting(key), do: :keyfleet |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)
end

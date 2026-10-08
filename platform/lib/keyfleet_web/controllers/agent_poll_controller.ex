defmodule KeyfleetWeb.AgentPollController do
  @moduledoc """
  Fast polls for signed agents (`Keyfleet.Polls`): open sessions, seats,
  rounds, votes, and waiting on a session's log.

  Waiting answers at once when the session's log holds lines after the
  caller's place, and otherwise holds the request open until the next line is
  written or `:agent_wait_ms` passes, so an agent hears of a new round within
  moments and asks again straight away. Only a few waits from one address are
  held open at once (`KeyfleetWeb.AgentWaits`); past that a wait answers at once
  with nothing.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors
  alias Keyfleet.Polls.Round
  alias Keyfleet.Polls.Vote
  alias KeyfleetWeb.AgentWaits
  alias KeyfleetWeb.ClientAddress
  alias KeyfleetWeb.PollJSON
  alias KeyfleetWeb.PollRefusal
  alias KeyfleetWeb.Refusal

  @page 100

  plug :known_fleet

  def index(conn, %{"fleet_id" => fleet_id}) do
    case Polls.open_sessions(fleet_id, actor: actor(conn), authorize_with: :error) do
      {:ok, sessions} -> json(conn, %{sessions: Enum.map(sessions, &PollJSON.session/1)})
      {:error, error} -> refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def open(conn, %{"fleet_id" => fleet_id} = params) do
    input = params |> Map.take(["name", "mode", "minutes"]) |> Map.put("fleet_id", fleet_id)

    case Polls.open_session(input, actor: actor(conn)) do
      {:ok, session} ->
        conn
        |> put_status(201)
        |> json(%{session: PollJSON.session(reload(fleet_id, session.id))})

      {:error, error} ->
        refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def join(conn, %{"fleet_id" => fleet_id, "session_id" => session_id}) do
    case Polls.join(%{fleet_id: fleet_id, session_id: session_id}, actor: actor(conn)) do
      {:ok, seat} ->
        status = if Ash.Resource.get_metadata(seat, :upsert_skipped), do: 200, else: 201
        conn |> put_status(status) |> json(%{seat: PollJSON.seat(seat)})

      {:error, error} ->
        refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def leave(conn, %{"fleet_id" => fleet_id, "session_id" => session_id}) do
    actor = actor(conn)

    with {:ok, _session} <- known(fleet_id, session_id),
         %{} = seat <- own_seat(fleet_id, session_id, actor),
         :ok <- Polls.leave(seat, fleet_id, actor: actor) do
      json(conn, %{seat: PollJSON.seat(seat)})
    else
      nil -> refuse(conn, fleet_id, Ash.Error.Forbidden.exception([]), "not_seated")
      {:error, error} -> refuse(conn, fleet_id, error, "not_seated")
    end
  end

  def end_session(conn, %{"fleet_id" => fleet_id, "session_id" => session_id}) do
    with {:ok, session} <- known(fleet_id, session_id),
         {:ok, ended} <- Polls.end_session(session, fleet_id, actor: actor(conn)) do
      json(conn, %{session: PollJSON.session(reload(fleet_id, ended.id))})
    else
      {:error, error} -> refuse(conn, fleet_id, error, "not_delegate")
    end
  end

  def wait(conn, %{"fleet_id" => fleet_id, "session_id" => session_id, "after_seq" => after_seq}) do
    actor = actor(conn)
    topic = Polls.topic(session_id)
    :ok = Phoenix.PubSub.subscribe(Keyfleet.PubSub, topic)

    try do
      read = fn ->
        Polls.events_after(fleet_id, session_id, after_seq, %{limit: @page},
          actor: actor,
          authorize_with: :error
        )
      end

      with {:ok, _session} <- known(fleet_id, session_id),
           {:ok, session} <-
             Polls.get_session(fleet_id, session_id, actor: actor, authorize_with: :error),
           {:ok, events} <- read.(),
           {:ok, events} <- waited(events, session, read, topic, ClientAddress.key(conn)) do
        json(conn, wait_json(reload(fleet_id, session_id), events, after_seq))
      else
        {:error, error} -> refuse(conn, fleet_id, error, "not_seated")
      end
    after
      Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, topic)
      flush(topic)
    end
  end

  def open_round(conn, %{"fleet_id" => fleet_id, "session_id" => session_id} = params) do
    input =
      params
      |> Map.take(["decision_ref", "observation", "actions", "deadline_seconds"])
      |> Map.merge(%{"fleet_id" => fleet_id, "session_id" => session_id})

    with {:ok, _session} <- known(fleet_id, session_id),
         {:ok, round} <- Polls.open_round(input, actor: actor(conn)) do
      conn |> put_status(201) |> json(%{round: Round.to_map(round)})
    else
      {:error, error} -> refuse(conn, fleet_id, error, "not_delegate")
    end
  end

  def vote(
        conn,
        %{"fleet_id" => fleet_id, "session_id" => session_id, "number" => number} = params
      ) do
    input =
      params
      |> Map.take(["action", "confidence", "reason"])
      |> Map.merge(%{"fleet_id" => fleet_id, "session_id" => session_id, "number" => number})

    case Polls.cast_vote(input, actor: actor(conn)) do
      {:ok, vote} ->
        status = if Ash.Resource.get_metadata(vote, :upsert_skipped), do: 200, else: 201
        conn |> put_status(status) |> json(%{vote: Vote.to_map(vote, String.to_integer(number))})

      {:error, error} ->
        refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  defp actor(conn), do: conn.assigns.agent_actor

  defp known_fleet(conn, _opts) do
    if conn.path_params["fleet_id"] in Keyfleet.Fleets.catalog_ids(),
      do: conn,
      else: conn |> Refusal.json(404, "fleet_unknown") |> halt()
  end

  # Whether the fleet has the session at all, asked before the caller's
  # standing so a session that isn't there is told apart from one the caller
  # has no seat in.
  defp known(fleet_id, session_id) do
    case Polls.get_session!(fleet_id, session_id, actor: %Keyfleet.Actors.System{}) do
      nil -> {:error, Errors.SessionUnknownError.exception(session_id: session_id)}
      session -> {:ok, session}
    end
  end

  defp reload(fleet_id, session_id),
    do: Polls.get_session!(fleet_id, session_id, actor: %Keyfleet.Actors.System{})

  defp own_seat(fleet_id, session_id, actor) do
    case Polls.voter(actor, fleet_id) do
      nil -> nil
      %{key: key} -> Polls.get_seat!(session_id, key, actor: %Keyfleet.Actors.System{})
    end
  end

  # Nothing new yet in an open session: wait for the next line, or for the
  # wait to run out with nothing. Past its address's cap it answers at once.
  defp waited([], session, read, topic, address) do
    if Polls.open?(session) do
      AgentWaits.hold(address, fn
        true -> await(read, topic, System.monotonic_time(:millisecond) + wait_ms())
        false -> {:ok, []}
      end)
    else
      {:ok, []}
    end
  end

  defp waited(events, _session, _read, _topic, _address), do: {:ok, events}

  defp await(read, topic, until) do
    case until - System.monotonic_time(:millisecond) do
      left when left <= 0 ->
        {:ok, []}

      left ->
        receive do
          %Phoenix.Socket.Broadcast{topic: ^topic, event: "poll_event"} ->
            case read.() do
              {:ok, []} -> await(read, topic, until)
              result -> result
            end
        after
          left -> {:ok, []}
        end
    end
  end

  # A connection kept open for the next request must not carry this
  # session's announcements into it.
  defp flush(topic) do
    receive do
      %Phoenix.Socket.Broadcast{topic: ^topic} -> flush(topic)
    after
      0 -> :ok
    end
  end

  defp wait_ms, do: Application.fetch_env!(:keyfleet, :agent_wait_ms)

  defp wait_json(session, events, after_seq) do
    %{
      session: PollJSON.session(session),
      events:
        Enum.map(events, &%{seq: &1.seq, kind: &1.kind, data: &1.payload, at: &1.inserted_at}),
      cursor: if(events == [], do: after_seq, else: List.last(events).seq),
      more: length(events) == @page
    }
  end

  defp refuse(conn, fleet_id, error, code) do
    {status, code} = PollRefusal.of(error, fleet_id, code)
    Refusal.json(conn, status, code)
  end
end

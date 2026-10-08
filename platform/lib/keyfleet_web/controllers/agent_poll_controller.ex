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
  alias Keyfleet.Rooms.Errors.NoKeyToWriteAsError
  alias KeyfleetWeb.AgentWaits
  alias KeyfleetWeb.ClientAddress
  alias KeyfleetWeb.Refusal

  @page 100

  @invalid [
    {Errors.SessionUnknownError, 404, "poll_unknown"},
    {Errors.RoundUnknownError, 404, "round_unknown"},
    {Errors.SessionEndedError, 409, "poll_ended"},
    {Errors.DelegateStaysError, 409, "delegate_stays"},
    {Errors.RoundOpenError, 409, "round_open"},
    {Errors.RoundClosedError, 409, "round_closed"},
    {Errors.VoteConflictError, 409, "vote_conflict"},
    {Errors.ActionUnknownError, 422, "action_unknown"}
  ]

  plug :known_fleet

  def index(conn, %{"fleet_id" => fleet_id}) do
    case Polls.open_sessions(fleet_id, actor: actor(conn), authorize_with: :error) do
      {:ok, sessions} -> json(conn, %{sessions: Enum.map(sessions, &session_json/1)})
      {:error, error} -> refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def open(conn, %{"fleet_id" => fleet_id} = params) do
    input = params |> Map.take(["name", "mode", "minutes"]) |> Map.put("fleet_id", fleet_id)

    case Polls.open_session(input, actor: actor(conn)) do
      {:ok, session} ->
        conn |> put_status(201) |> json(%{session: session_json(reload(fleet_id, session.id))})

      {:error, error} ->
        refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def join(conn, %{"fleet_id" => fleet_id, "session_id" => session_id}) do
    case Polls.join(%{fleet_id: fleet_id, session_id: session_id}, actor: actor(conn)) do
      {:ok, seat} ->
        status = if Ash.Resource.get_metadata(seat, :upsert_skipped), do: 200, else: 201
        conn |> put_status(status) |> json(%{seat: seat_json(seat)})

      {:error, error} ->
        refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def leave(conn, %{"fleet_id" => fleet_id, "session_id" => session_id}) do
    actor = actor(conn)

    with {:ok, _session} <- known(fleet_id, session_id),
         %{} = seat <- own_seat(fleet_id, session_id, actor),
         :ok <- Polls.leave(seat, fleet_id, actor: actor) do
      json(conn, %{seat: seat_json(seat)})
    else
      nil -> refuse(conn, fleet_id, Ash.Error.Forbidden.exception([]), "not_seated")
      {:error, error} -> refuse(conn, fleet_id, error, "not_seated")
    end
  end

  def end_session(conn, %{"fleet_id" => fleet_id, "session_id" => session_id}) do
    with {:ok, session} <- known(fleet_id, session_id),
         {:ok, ended} <- Polls.end_session(session, fleet_id, actor: actor(conn)) do
      json(conn, %{session: session_json(reload(fleet_id, ended.id))})
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
    case Polls.key_of(actor, fleet_id) do
      nil -> nil
      key -> Polls.get_seat!(session_id, key, actor: %Keyfleet.Actors.System{})
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

  defp session_json(session) do
    %{
      id: session.id,
      name: session.name,
      mode: session.mode,
      delegate_key: session.delegate_key,
      seats: session.seat_keys,
      head_seq: session.head_seq,
      open: Polls.open?(session),
      expires_at: session.expires_at,
      ended_at: session.ended_at
    }
  end

  defp seat_json(seat), do: %{key: seat.token_id, joined_at: seat.inserted_at}

  defp wait_json(session, events, after_seq) do
    %{
      session: session_json(session),
      events:
        Enum.map(events, &%{seq: &1.seq, kind: &1.kind, data: &1.payload, at: &1.inserted_at}),
      cursor: if(events == [], do: after_seq, else: List.last(events).seq),
      more: length(events) == @page
    }
  end

  defp refuse(conn, fleet_id, %Ash.Error.Forbidden{errors: errors}, code) do
    cond do
      not Keyfleet.Chain.fresh?(fleet_id) ->
        Refusal.json(conn, 503, "ownership_refreshing")

      Enum.any?(errors, &match?(%Errors.NotInRoundError{}, &1)) ->
        Refusal.json(conn, 403, "not_in_round")

      Enum.any?(errors, &match?(%NoKeyToWriteAsError{}, &1)) ->
        Refusal.json(conn, 403, "poll_needs_key")

      true ->
        Refusal.json(conn, 403, code)
    end
  end

  defp refuse(conn, _fleet_id, %Ash.Error.Invalid{errors: errors}, _code) do
    cond do
      found = Enum.find_value(errors, &invalid/1) ->
        Refusal.json(conn, elem(found, 0), elem(found, 1))

      Enum.any?(errors, &decision_seen?/1) ->
        Refusal.json(conn, 409, "decision_seen")

      true ->
        Refusal.json(conn, 422, "invalid_poll")
    end
  end

  defp refuse(conn, fleet_id, %{__struct__: module} = error, code)
       when module in [Errors.SessionUnknownError],
       do: refuse(conn, fleet_id, Ash.Error.Invalid.exception(errors: [error]), code)

  defp refuse(conn, _fleet_id, _error, _code), do: Refusal.json(conn, 422, "invalid_poll")

  # The status and code a poll's own refusal answers with.
  defp invalid(error) do
    Enum.find_value(@invalid, fn {module, status, code} ->
      if is_struct(error, module), do: {status, code}
    end)
  end

  # The session already had a round for this outside decision.
  defp decision_seen?(%Ash.Error.Changes.InvalidAttribute{
         field: :decision_ref,
         private_vars: vars
       }),
       do: Keyword.get(vars || [], :constraint_type) == :unique

  defp decision_seen?(_error), do: false
end

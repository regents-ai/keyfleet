defmodule KeyfleetWeb.AgentPollController do
  @moduledoc """
  A fleet's polls for signed agents (`Keyfleet.Polls`): list and read them,
  start one, vote, and end one the agent's Key started. Only an agent that
  is one of the fleet's members reads its polls (`Keyfleet.Access`,
  `:polls`); any other is answered `poll_needs_key`.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Errors.PollUnknownError
  alias KeyfleetWeb.PollJSON
  alias KeyfleetWeb.PollRefusal
  alias KeyfleetWeb.Refusal

  plug :known_fleet
  plug :fresh_ownership

  def index(conn, %{"fleet_id" => fleet_id}) do
    case Polls.list_polls(fleet_id, actor: actor(conn), authorize_with: :error) do
      {:ok, polls} -> json(conn, %{polls: Enum.map(polls, &PollJSON.poll/1)})
      {:error, error} -> refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def start(conn, %{"fleet_id" => fleet_id} = params) do
    input =
      params
      |> Map.take(["question", "choices", "notes", "minutes"])
      |> Map.put("fleet_id", fleet_id)

    case Polls.start_poll(input, actor: actor(conn)) do
      {:ok, poll} ->
        conn |> put_status(201) |> json(%{poll: PollJSON.poll(reload(fleet_id, poll.id, conn))})

      {:error, error} ->
        refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  # A member reads the poll with its own Key's vote and, once it closes,
  # every vote.
  def show(conn, %{"fleet_id" => fleet_id, "poll_id" => poll_id}) do
    actor = actor(conn)

    case Polls.get_poll(fleet_id, poll_id, actor: actor, authorize_with: :error) do
      {:ok, nil} ->
        refuse(conn, fleet_id, PollUnknownError.exception(poll_id: poll_id), "poll_unknown")

      {:ok, poll} ->
        json(conn, Map.merge(%{poll: PollJSON.poll(poll)}, votes(fleet_id, poll_id, actor)))

      {:error, error} ->
        refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def vote(conn, %{"fleet_id" => fleet_id, "poll_id" => poll_id} = params) do
    input =
      params
      |> Map.take(["choice", "reason"])
      |> Map.merge(%{"fleet_id" => fleet_id, "poll_id" => poll_id})

    case Polls.cast_vote(input, actor: actor(conn)) do
      {:ok, vote} ->
        status = if Ash.Resource.get_metadata(vote, :upsert_skipped), do: 200, else: 201
        conn |> put_status(status) |> json(%{vote: PollJSON.vote(vote)})

      {:error, error} ->
        refuse(conn, fleet_id, error, "poll_needs_key")
    end
  end

  def end_poll(conn, %{"fleet_id" => fleet_id, "poll_id" => poll_id}) do
    with {:ok, poll} <- known(fleet_id, poll_id),
         {:ok, ended} <- Polls.end_poll(poll, fleet_id, actor: actor(conn)) do
      json(conn, %{poll: PollJSON.poll(reload(fleet_id, ended.id, conn))})
    else
      {:error, error} -> refuse(conn, fleet_id, error, "not_starter")
    end
  end

  defp actor(conn), do: conn.assigns.agent_actor

  defp known_fleet(conn, _opts) do
    if conn.path_params["fleet_id"] in Keyfleet.Fleets.catalog_ids(),
      do: conn,
      else: conn |> Refusal.json(404, "fleet_unknown") |> halt()
  end

  # Who holds which Key decides every answer here, down to whether a read
  # carries the Key's vote, so none is given from ownership that isn't fresh.
  defp fresh_ownership(conn, _opts) do
    if Keyfleet.Chain.fresh?(conn.path_params["fleet_id"]),
      do: conn,
      else: conn |> Refusal.json(503, "ownership_refreshing") |> halt()
  end

  # Whether the fleet has the poll at all, asked before the caller's standing
  # so a poll that isn't there is told apart from one the caller didn't start.
  defp known(fleet_id, poll_id) do
    case Polls.get_poll!(fleet_id, poll_id, actor: %System{}) do
      nil -> {:error, PollUnknownError.exception(poll_id: poll_id)}
      poll -> {:ok, poll}
    end
  end

  defp reload(fleet_id, poll_id, conn), do: Polls.get_poll!(fleet_id, poll_id, actor: actor(conn))

  defp votes(fleet_id, poll_id, actor) do
    with {:ok, mine} <- Polls.my_vote(fleet_id, poll_id, actor: actor, authorize_with: :error),
         {:ok, votes} <-
           Polls.votes_in_poll(fleet_id, poll_id, actor: actor, authorize_with: :error) do
      %{my_vote: mine && PollJSON.vote(mine), votes: Enum.map(votes, &PollJSON.vote/1)}
    else
      {:error, %Ash.Error.Forbidden{}} -> %{}
    end
  end

  defp refuse(conn, fleet_id, error, code) do
    {status, code} = PollRefusal.of(error, fleet_id, code)

    case PollRefusal.retry_after(error) do
      nil ->
        Refusal.json(conn, status, code)

      seconds ->
        conn |> put_resp_header("retry-after", to_string(seconds)) |> Refusal.json(status, code)
    end
  end
end

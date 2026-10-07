defmodule KeyfleetWeb.AgentAvatarController do
  @moduledoc """
  An agent's picture, set in two steps because a picture is larger than a
  signed request can carry.

  `start` is a signed request naming the picture: its SHA-256, its length and
  its type. It answers one upload address, good for ten minutes, carrying a
  ticket signed by this site that binds the agent, its profile and exactly
  that picture. `upload` takes the bytes at that address; the ticket is its
  permission, so it is not signed itself. `remove` is a signed request that
  takes the picture away.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents
  alias Keyfleet.Agents.Avatar
  alias KeyfleetWeb.Refusal

  @salt "agent avatar upload"
  @ticket_seconds 10 * 60
  # The ticket is signed, not sealed, so it names the agent and nothing the
  # SIWA service said about it.
  @ticket_actor_fields [
    :wallet_address,
    :chain_id,
    :verification_method,
    :audience,
    :credential_ref
  ]

  def start(conn, params) do
    actor = conn.assigns.agent_actor

    with {:ok, declared} <- Avatar.declare(params),
         %{id: profile_id} <- Agents.get_my_profile!(actor: actor) do
      ticket =
        Phoenix.Token.sign(conn, @salt, %{
          profile_id: profile_id,
          declared: declared,
          agent: Map.take(actor, @ticket_actor_fields)
        })

      json(conn, %{
        upload_url: url(~p"/api/v1/avatar/upload/#{ticket}"),
        method: "PUT",
        content_type: declared.content_type,
        expires_at: DateTime.utc_now() |> DateTime.add(@ticket_seconds) |> DateTime.to_iso8601()
      })
    else
      :error -> Refusal.json(conn, 422, "invalid_avatar")
      nil -> Refusal.json(conn, 404, "profile_not_found")
    end
  end

  def upload(conn, %{"ticket" => ticket}) do
    case Phoenix.Token.verify(conn, @salt, ticket, max_age: @ticket_seconds) do
      {:ok, %{profile_id: profile_id, declared: declared, agent: agent}} ->
        store(conn, struct!(Agent, agent), profile_id, declared)

      {:error, _reason} ->
        Refusal.json(conn, 401, "avatar_upload_expired")
    end
  end

  def remove(conn, _params) do
    actor = conn.assigns.agent_actor

    case Agents.get_my_profile!(actor: actor) do
      nil ->
        Refusal.json(conn, 404, "profile_not_found")

      profile ->
        json(conn, %{avatar_url: Avatar.url(Agents.remove_avatar!(profile, actor: actor))})
    end
  end

  defp store(conn, actor, profile_id, declared) do
    cap = Avatar.max_bytes()

    with [type] when type == declared.content_type <- get_req_header(conn, "content-type"),
         {:ok, bytes, conn} when byte_size(bytes) <= cap <-
           read_body(conn, length: cap, read_length: cap + 1),
         {:ok, profile} <- Agents.store_avatar(actor, profile_id, declared, bytes) do
      json(conn, %{avatar_url: Avatar.url(profile)})
    else
      {:more, _partial, conn} -> Refusal.json(conn, 413, "request_too_large")
      {:error, :mismatch} -> Refusal.json(conn, 422, "avatar_mismatch")
      {:error, :unreadable} -> Refusal.json(conn, 422, "invalid_avatar")
      {:error, :profile_not_found} -> Refusal.json(conn, 404, "profile_not_found")
      {:error, _reason} -> Refusal.json(conn, 503, "avatar_unavailable")
      _other_type -> Refusal.json(conn, 422, "avatar_mismatch")
    end
  end
end

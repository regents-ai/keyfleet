defmodule KeyfleetWeb.AgentKeyController do
  @moduledoc """
  A Key as its page shows it, for a signed-in agent, and taking a post off the
  wall of a Key the agent acts as.

  The page is what anyone reads on the site: who holds the Key and since when,
  the Key its holder writes as, the other Keys they hold, its card's traits,
  its wall and room posts, its votes, and the agents with a shard of it.
  `yours` says whether the agent acts as the Key now (`Keyfleet.Keys.held_keys/2`).
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Chain
  alias Keyfleet.Dms.Checks.KeyHolder
  alias Keyfleet.Fleets
  alias Keyfleet.Keys.Profile
  alias Keyfleet.Rooms
  alias KeyfleetWeb.Refusal

  @max_token_id 9_223_372_036_854_775_807

  def show(conn, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    actor = conn.assigns.agent_actor

    with %{} <- Fleets.get_fleet!(fleet_id),
         {:ok, token_id} <- token_id(token_id),
         %{issued?: true} = key <- Profile.read(fleet_id, token_id, nil) do
      json(conn, %{key: key_json(key, token_id in KeyHolder.held(actor, fleet_id))})
    else
      nil -> Refusal.json(conn, 404, "fleet_unknown")
      {:error, :invalid_token_id} -> Refusal.json(conn, 422, "invalid_request")
      %{issued?: false, token_id: token_id} -> Refusal.key_unknown(conn, fleet_id, token_id)
    end
  end

  # The post comes off the wall the address names, for everyone who reads it.
  # Taking off a post already taken off keeps the one removal.
  def remove_from_wall(conn, %{
        "fleet_id" => fleet_id,
        "token_id" => token_id,
        "message_id" => message_id
      }) do
    actor = conn.assigns.agent_actor

    with %{} <- Fleets.get_fleet!(fleet_id),
         {:ok, token_id} <- token_id(token_id),
         {:ok, removal} <- Rooms.remove_from_wall(fleet_id, token_id, message_id, actor: actor) do
      json(conn, %{
        removed: %{
          message_id: removal.message_id,
          token_id: removal.token_id,
          removed_at: removal.inserted_at
        }
      })
    else
      nil -> Refusal.json(conn, 404, "fleet_unknown")
      {:error, :invalid_token_id} -> Refusal.json(conn, 422, "invalid_request")
      {:error, %Ash.Error.Forbidden{}} -> refuse_holder(conn, fleet_id)
      {:error, %Ash.Error.Invalid{}} -> Refusal.json(conn, 404, "wall_post_unknown")
    end
  end

  # Only whoever acts as the Key now takes a post off its wall, and nobody does
  # while the fleet's Key ownership is being read.
  defp refuse_holder(conn, fleet_id) do
    if Chain.fresh?(fleet_id),
      do: Refusal.json(conn, 403, "not_your_key"),
      else: Refusal.json(conn, 503, "ownership_refreshing")
  end

  defp token_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 and number <= @max_token_id -> {:ok, number}
      _ -> {:error, :invalid_token_id}
    end
  end

  defp key_json(key, yours?) do
    %{
      fleet_id: key.fleet_id,
      token_id: key.token_id,
      yours: yours?,
      image: key.image,
      level: key.level,
      traits: key.traits,
      holder: key.holder,
      held_since: key.held_since,
      changed_hands: key.changed_hands,
      writes_as: key.posts_as.token_id,
      holder_keys: key.holder_keys,
      holder_key_count: key.holder_key_count,
      wall: %{head_seq: key.wall_head, messages: key.messages},
      room_posts: key.posts,
      votes_cast: key.votes_cast,
      shards: Enum.map(key.shards, &shard_json/1)
    }
  end

  defp shard_json(shard) do
    %{wallet: shard.wallet, expires_at: shard.expires_at, agent: agent_json(shard.agent)}
  end

  defp agent_json(nil), do: nil

  defp agent_json(agent) do
    %{
      name: agent.name,
      harness: agent.harness,
      status: agent.status,
      status_updated_at: agent.status_updated_at,
      registry_url: agent.registry_url
    }
  end
end

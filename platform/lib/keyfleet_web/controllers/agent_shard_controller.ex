defmodule KeyfleetWeb.AgentShardController do
  @moduledoc """
  The signed-in agent's active shards, one per key: the key each lets it act
  as, until when, whether a vote of the fleet has stopped that key
  changing the workspace, and the transaction that ends the shard, for the
  agent's own wallet to send when it steps down.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Fleets.Fleet
  alias Keyfleet.Keys
  alias RegentChain.Call

  def index(conn, _params) do
    %{wallet_address: wallet} = actor = conn.assigns.agent_actor

    shards =
      wallet
      |> Keys.active_shards_held_by!(actor: actor, load: [:fleet])
      |> Enum.map(&shard_json(&1, wallet))

    json(conn, %{shards: shards})
  end

  defp shard_json(shard, wallet) do
    {:ok, restricted} = Keys.edits_restricted?(shard.fleet_id, shard.token_id)

    %{
      fleet_id: shard.fleet_id,
      fleet_name: shard.fleet.name,
      token_id: shard.token_id,
      expires_at: shard.expires_at,
      edits_restricted: restricted,
      shards_contract: shard.fleet.shards_address,
      chain_id: shard.fleet.chain_id,
      step_down: %{
        chain_id: shard.fleet.chain_id,
        to: shard.fleet.shards_address,
        data:
          Call.encode("end(uint256[],address)", [
            [Fleet.onchain_token_id(shard.fleet, shard.token_id)],
            wallet
          ]),
        value: "0"
      }
    }
  end
end

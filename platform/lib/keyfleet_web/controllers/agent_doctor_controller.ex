defmodule KeyfleetWeb.AgentDoctorController do
  @moduledoc """
  An agent's standing in one fleet, in one read, so it learns what it may do
  there and what is still missing before it tries: who it signed in as, its
  pairing and profile, the Key it acts as and the Keys it may act as, whether
  the fleet's key ownership is fresh, what it may read and write by
  `Keyfleet.Access`'s table, and each missing thing with the refusal it would
  meet, in that refusal's own words.

  Nothing is written: no check-in, no presence and no profile. The person's
  World ID number is never answered, only whether a verified person stands
  behind the agent. Rules narrower than the table, such as a poll's starter
  ending it, are each operation's own.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.{Access, Agents, Capabilities, Chain, Fleets, Keys}
  alias Keyfleet.Actors.Human
  alias KeyfleetWeb.Refusal

  def show(conn, %{"fleet_id" => fleet_id}) do
    actor = conn.assigns.agent_actor

    with %{} = fleet <- Fleets.get_fleet!(fleet_id),
         {:ok, profile} <- Agents.get_my_profile(actor: actor) do
      key = key(actor, fleet_id)
      fresh = Chain.fresh?(fleet_id)
      class = Access.class(actor, fleet_id)

      json(conn, %{
        fleet_id: fleet_id,
        fleet_name: fleet.name,
        agent: %{
          wallet_address: actor.wallet_address,
          chain_id: actor.chain_id,
          verification_method: actor.verification_method,
          sign_in_expires_at: actor.receipt_expires_at,
          registry_listing: actor.registry_url,
          human_backed: actor.human_id != nil
        },
        pairing: pairing(actor.pairing),
        profile: profile && Map.take(profile, [:id, :name, :declared_harness]),
        ownership_fresh: fresh,
        key: key,
        keys: actor |> Keys.held_keys(fleet_id) |> Enum.map(& &1.token_id),
        may:
          Map.new(Access.components(), fn {component, _classes} ->
            {component,
             %{
               read: Access.enough?(class, :read, component),
               write: Access.enough?(class, :write, component)
             }}
          end),
        missing: missing(actor, profile, fresh, key),
        versions: Capabilities.versions(),
        build: Application.fetch_env!(:keyfleet, :build)
      })
    else
      nil -> Refusal.json(conn, 404, "fleet_unknown")
      {:error, _error} -> Refusal.json(conn, 503, "profile_unavailable")
    end
  end

  # The Key the agent acts as here, as every write names it, and whether a
  # vote of the fleet has stopped it changing the workspace.
  defp key(actor, fleet_id) do
    with %{token_id: token_id} = identity <- Keys.identity(actor, fleet_id) do
      {:ok, restricted} = Keys.edits_restricted?(fleet_id, token_id)

      %{
        token_id: token_id,
        for_person: Map.get(identity, :for_person, false),
        edits_restricted: restricted
      }
    end
  end

  defp pairing(%Human{}), do: "paired"
  defp pairing(:person_not_here), do: "person_not_here"

  # Each thing between the agent and the fleet's work, in the order to fix
  # them, as the refusal an operation would answer.
  defp missing(actor, profile, fresh, key) do
    [
      actor.pairing == :person_not_here && "person_not_here",
      profile == nil && "profile_not_found",
      not fresh && "ownership_refreshing",
      (fresh and key == nil) && "not_a_member",
      match?(%{edits_restricted: true}, key) && "edits_restricted"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Refusal.body(&1).error)
  end
end

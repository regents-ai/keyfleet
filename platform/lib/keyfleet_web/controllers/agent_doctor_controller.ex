defmodule KeyfleetWeb.AgentDoctorController do
  @moduledoc """
  An agent's standing in one fleet, in one read, so it learns what it may do
  there and what is still missing before it tries: who it signed in as, its
  pairing and profile, the Key it acts as and the Keys it may act as, whether
  the fleet's key ownership is fresh, what it may read and write by
  `Keyfleet.Access`'s table, and each missing thing with the refusal it would
  meet, in that refusal's own words (`KeyfleetWeb.Standing`).

  Nothing is written: no check-in, no presence and no profile. The person's
  World ID number is never answered, only whether a verified person stands
  behind the agent. Rules narrower than the table, such as a poll's starter
  ending it, are each operation's own.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.Human
  alias Keyfleet.{Access, Capabilities, Fleets}
  alias KeyfleetWeb.{Refusal, Standing}

  def show(conn, %{"fleet_id" => fleet_id}) do
    actor = conn.assigns.agent_actor

    with %{} = fleet <- Fleets.get_fleet!(fleet_id),
         {:ok, standing} <- Standing.read(actor, fleet_id) do
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
        profile: standing.profile && Map.take(standing.profile, [:id, :name, :declared_harness]),
        ownership_fresh: standing.fresh,
        key: standing.key,
        keys: Enum.map(standing.keys, & &1.token_id),
        may:
          Map.new(Access.components(), fn {component, _classes} ->
            {component,
             %{
               read: Access.enough?(class, :read, component),
               write: Access.enough?(class, :write, component)
             }}
          end),
        missing: standing.missing,
        versions: Capabilities.versions(),
        build: Application.fetch_env!(:keyfleet, :build)
      })
    else
      nil -> Refusal.json(conn, 404, "fleet_unknown")
      {:error, _error} -> Refusal.json(conn, 503, "profile_unavailable")
    end
  end

  defp pairing(%Human{}), do: "paired"
  defp pairing(:person_not_here), do: "person_not_here"
end

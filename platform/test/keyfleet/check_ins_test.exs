defmodule Keyfleet.CheckInsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.Agents
  alias Keyfleet.Agents.CheckIn
  alias Keyfleet.Fleets
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo

  @fleet "fleet_tech_classic"

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    {actor, profile} = agent("b", "Bosun")
    %{actor: actor, profile: profile}
  end

  test "an agent never writes another agent's check-ins", %{profile: profile} do
    {other, _profile} = agent("c", "Able")

    assert {:error, %Ash.Error.Forbidden{}} =
             CheckIn
             |> Ash.Changeset.for_create(
               :check_in_session,
               %{agent_profile_id: profile.id, fleet_id: @fleet},
               actor: other
             )
             |> Ash.create()

    assert Agents.get_check_in!(profile.id, @fleet) == nil
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp person_wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  defp agent(character, name) do
    actor =
      PairingHelpers.pair!(
        %Actors.Agent{
          wallet_address: wallet(character),
          chain_id: 8453,
          verification_method: :eoa_recovery,
          audience: "keyfleet"
        },
        [person_wallet()]
      )

    profile =
      Agents.ensure_profile!(%{name: name, declared_harness: "Hermes Agent"}, actor: actor)

    {actor, profile}
  end
end

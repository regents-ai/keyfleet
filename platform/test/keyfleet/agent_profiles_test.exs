defmodule Keyfleet.AgentProfilesTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents
  alias Keyfleet.Agents.AgentProfile
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{actor: actor(), input: %{name: "Astra", declared_harness: "Hermes"}}
  end

  test "ensure derives immutable wallet identity and resumes without overwriting", %{
    actor: actor,
    input: input
  } do
    assert {:ok, nil} = Agents.get_my_profile(actor: actor)
    profile = Agents.ensure_profile!(input, actor: actor)
    resumed = Agents.ensure_profile!(%{input | name: "Replacement"}, actor: actor)
    assert resumed.id == profile.id
    assert resumed.name == "Astra"
    assert resumed.wallet_address == actor.wallet_address
    assert resumed.last_activity_at == profile.last_activity_at
    assert resumed.status_updated_at == profile.status_updated_at

    for params <- [
          %{wallet_address: wallet()},
          %{last_activity_at: DateTime.utc_now()},
          %{status_updated_at: DateTime.utc_now()}
        ] do
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.ensure_profile(Map.merge(input, params), actor: actor)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.edit_my_profile(profile, params, actor: actor)
    end

    assert Agents.get_my_profile!(actor: actor).id == profile.id
  end

  test "unverified actors cannot create, read, or edit and rejected writes leave data intact", %{
    actor: actor,
    input: input
  } do
    profile = Agents.ensure_profile!(input, actor: actor)
    count = profile_count()

    for invalid <- [
          nil,
          Map.from_struct(actor),
          %{role: :agent},
          %{actor | wallet_address: "0xAB" <> String.duplicate("0", 38)},
          %{actor | wallet_address: "0x123"},
          %{actor | verification_method: :erc1271, chain_id: 1},
          %{actor | audience: "patchbay"}
        ] do
      assert {:error, error} = Agents.ensure_profile(input, actor: invalid)

      assert match?(%Ash.Error.Forbidden{}, error) or
               match?(
                 %Ash.Error.Invalid{
                   errors: [%Ash.Error.Changes.InvalidAttribute{field: :wallet_address}]
                 },
                 error
               )

      if is_nil(invalid) do
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.ReadActionRequiresActor{}]}} =
                 Agents.get_my_profile(actor: invalid)
      else
        assert {:error, %Ash.Error.Forbidden{}} = Agents.get_my_profile(actor: invalid)
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.edit_my_profile(profile, %{name: "Denied"}, actor: invalid)
    end

    assert Agents.get_my_profile!(actor: actor).name == "Astra"
    assert profile_count() == count
  end

  test "a second verified wallet cannot disclose or edit the first profile", %{
    actor: actor,
    input: input
  } do
    first = Agents.ensure_profile!(input, actor: actor)
    other = actor()
    assert {:ok, nil} = Agents.get_my_profile(actor: other)
    second = Agents.ensure_profile!(input, actor: other)
    assert Agents.get_my_profile!(actor: other).id == second.id

    assert {:error, %Ash.Error.Forbidden{}} =
             Agents.edit_my_profile(first, %{name: "Denied"}, actor: other)

    assert Agents.get_my_profile!(actor: actor).name == "Astra"
    assert {:error, _} = Ash.get(AgentProfile, first.id, actor: other)
  end

  test "database uniqueness rejects a duplicate independently of action checks", %{
    actor: actor,
    input: input
  } do
    profile = Agents.ensure_profile!(input, actor: actor)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               "INSERT INTO keyfleet_app.agent_profiles (id, wallet_address, name, declared_harness, proficiencies, interests, service_ideas, current_status, status_updated_at, last_activity_at) SELECT $1, wallet_address, name, declared_harness, proficiencies, interests, service_ideas, current_status, status_updated_at, last_activity_at FROM keyfleet_app.agent_profiles WHERE id = $2",
               [Ecto.UUID.dump!(Ash.UUID.generate()), Ecto.UUID.dump!(profile.id)],
               mode: :savepoint
             )

    assert Agents.get_my_profile!(actor: actor).id == profile.id
  end

  # An agent paired with a person of its own, as every agent that makes a
  # profile is.
  defp actor do
    PairingHelpers.pair!(
      %Agent{
        wallet_address: wallet(),
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      },
      [wallet()]
    )
  end

  defp profile_count,
    do: Repo.one!(from(profile in "agent_profiles", prefix: "keyfleet_app", select: count()))

  defp wallet, do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
end

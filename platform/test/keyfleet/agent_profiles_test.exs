defmodule Keyfleet.AgentProfilesTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents
  alias Keyfleet.Agents.AgentProfile
  alias Keyfleet.Repo

  setup context do
    unless context[:independent_connections], do: Ecto.Adapters.SQL.Sandbox.checkout(Repo)
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
          %{wallet_address: actor().wallet_address},
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

    for invalid <- [
          nil,
          Map.from_struct(actor),
          %{role: :agent},
          %{actor | wallet_address: "0xAB" <> String.duplicate("0", 38)},
          %{actor | wallet_address: "0x123"},
          %{actor | chain_id: 1},
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
    assert Repo.query!("SELECT count(*) FROM keyfleet_app.agent_profiles").rows == [[1]]
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

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Agents.edit_my_profile(first, %{name: "Denied"}, actor: other)

    assert Agents.get_my_profile!(actor: actor).name == "Astra"
    assert {:error, _} = Ash.get(AgentProfile, first.id, actor: other)
  end

  test "activity uses database time and status submissions refresh only the status timestamp", %{
    actor: actor,
    input: input
  } do
    original = Agents.ensure_profile!(input, actor: actor)

    edited =
      Agents.edit_my_profile!(
        original,
        %{
          name: "Updated",
          avatar: "https://example.test/a.png",
          proficiencies: ["Elixir"],
          interests: ["Testing"],
          service_ideas: ["Review"],
          current_status: "Working"
        },
        actor: actor
      )

    assert edited.proficiencies == ["Elixir"]
    assert DateTime.compare(edited.last_activity_at, original.last_activity_at) == :gt
    assert DateTime.compare(edited.status_updated_at, original.status_updated_at) == :gt
    renamed = Agents.edit_my_profile!(original, %{name: "Renamed"}, actor: actor)
    assert renamed.status_updated_at == edited.status_updated_at
    assert DateTime.compare(renamed.last_activity_at, edited.last_activity_at) == :gt
    repeated = Agents.edit_my_profile!(original, %{current_status: "Working"}, actor: actor)
    assert DateTime.compare(repeated.status_updated_at, renamed.status_updated_at) == :gt
    unchanged = Agents.edit_my_profile!(repeated, %{name: "Renamed"}, actor: actor)
    assert DateTime.compare(unchanged.last_activity_at, repeated.last_activity_at) == :gt
    assert unchanged.status_updated_at == repeated.status_updated_at
    assert {:error, %Ash.Error.Invalid{}} = Agents.edit_my_profile(unchanged, %{}, actor: actor)
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

  @tag :independent_connections
  test "concurrent ensure calls on independent transactions retain one winner and its values", %{
    actor: actor,
    input: input
  } do
    parent = self()

    tasks =
      for index <- 1..4 do
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:ready, self(), backend})

            receive do
              :go -> Agents.ensure_profile!(%{input | name: "Agent #{index}"}, actor: actor)
            after
              10_000 -> raise "concurrent ensure barrier timed out"
            end
          after
            Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)
      end

    ready =
      for _ <- tasks do
        assert_receive {:ready, pid, backend}, 10_000
        {pid, backend}
      end

    assert ready |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 4
    Enum.each(ready, fn {pid, _} -> send(pid, :go) end)
    profiles = Task.await_many(tasks, 20_000)
    assert profiles |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
    assert profiles |> Enum.map(& &1.name) |> Enum.uniq() |> length() == 1

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert Repo.query!(
               "SELECT count(*) FROM keyfleet_app.agent_profiles WHERE wallet_address = $1",
               [actor.wallet_address]
             ).rows == [[1]]

      Repo.query!("DELETE FROM keyfleet_app.agent_profiles WHERE wallet_address = $1", [
        actor.wallet_address
      ])
    end)
  end

  defp actor do
    %Agent{
      wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower),
      chain_id: 8453,
      audience: "keyfleet"
    }
  end
end

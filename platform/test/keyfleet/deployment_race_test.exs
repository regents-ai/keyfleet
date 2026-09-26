defmodule Keyfleet.DeploymentRaceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.CommittedCatalog
  alias Keyfleet.Fleets
  alias Keyfleet.Repo

  # Each recording runs on a connection of its own and commits, so the fleet is
  # put back unbound, and any fleets committed here are removed, when it ends.
  @fleet "fibonacci_cascade"
  @deployment_fields [
    :chain_id,
    :contract_address,
    :rewards_address,
    :votes_address,
    :usdc_address,
    :asset_registry_address,
    :deployed_block,
    :trait_table_hash
  ]

  setup do
    added_fleets =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        added = CommittedCatalog.commit!()
        assert Fleets.get_fleet!(@fleet).contract_address == nil
        added
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.update_all(from(fleet in "fleets", where: fleet.id == ^@fleet),
          set: Enum.map(@deployment_fields, &{&1, nil})
        )

        CommittedCatalog.remove!(added_fleets)
      end)
    end)

    :ok
  end

  # Both recordings read the fleet unbound before either records, which is
  # the order two recordings started at the same moment can take.
  test "two recordings of one fleet naming different contracts at the same moment bind it once" do
    contracts = ["0x" <> String.duplicate("1", 40), "0x" <> String.duplicate("2", 40)]
    results = race(contracts)

    assert [%{contract_address: bound}] = for({:ok, fleet} <- results, do: fleet)

    assert [{:error, %Ash.Error.Invalid{errors: [%{field: :contract_address}]}}] =
             Enum.reject(results, &match?({:ok, _fleet}, &1))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert Fleets.get_fleet!(@fleet).contract_address == bound
    end)
  end

  defp race(contracts) do
    parent = self()

    callers =
      for contract <- contracts do
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          fleet = Fleets.get_fleet!(@fleet)
          send(parent, {:ready, self()})

          receive do
            :go -> Fleets.record_deployment(fleet, deployment(contract), actor: %System{})
          after
            10_000 -> raise "recording barrier timed out"
          end
        end)
      end

    for _ <- callers do
      assert_receive {:ready, _}, 10_000
    end

    Enum.each(callers, &send(&1.pid, :go))
    Task.await_many(callers, 15_000)
  end

  defp deployment(contract) do
    %{
      chain_id: 8_453,
      contract_address: contract,
      rewards_address: "0x" <> String.duplicate("8", 40),
      votes_address: "0x" <> String.duplicate("9", 40),
      usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      asset_registry_address: "0x" <> String.duplicate("4", 40),
      deployed_block: 1_000,
      trait_table_hash: "0x" <> String.duplicate("a", 64)
    }
  end
end

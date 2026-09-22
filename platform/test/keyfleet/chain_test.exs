defmodule KeyFleet.ChainTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain
  alias KeyFleet.Chain.{OwnershipLog, Scanner, StubClient}
  alias KeyFleet.ChainHelpers
  alias KeyFleet.Fleets
  alias KeyFleet.Keys
  alias KeyFleet.Release
  alias KeyFleet.Repo
  alias KeyFleet.Rooms

  # Other suites commit Syndicate keys outside the sandbox; Accelerant from a
  # high block keeps these readings to what each test puts on the chain.
  @fleet "fleet_tech_accelerant"
  @contract "0x" <> String.duplicate("7", 40)
  @deployed 5_000_000
  @new_hash "0x" <> String.duplicate("e", 64)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    :ok
  end

  describe "freshness" do
    # Authority from a key is refused unless its ownership was read recently,
    # all the way to the head, and never found to disagree with the chain.
    test "ownership is fresh only when read just now, caught up and not stopped" do
      refute Chain.fresh?(@fleet)

      for {attrs, fresh?} <- [
            {%{observed_at: DateTime.add(DateTime.utc_now(), -121, :second)}, false},
            {%{head_block: 1_300, next_block: 1_000}, false},
            {%{}, true},
            {%{rescan_from: 900}, false}
          ] do
        ChainHelpers.seed_cursor!(@fleet, attrs)
        assert Chain.fresh?(@fleet) == fresh?, inspect(attrs)
      end
    end
  end

  describe "reading the chain" do
    setup do
      fleet =
        @fleet
        |> Fleets.get_fleet!()
        |> Fleets.record_deployment!(
          %{
            chain_id: 8_453,
            contract_address: @contract,
            rewards_address: "0x" <> String.duplicate("8", 40),
            votes_address: "0x" <> String.duplicate("9", 40),
            deployed_block: @deployed
          },
          actor: %System{}
        )

      %{fleet: fleet}
    end

    # The cursor moves on only after everything up to the head is recorded,
    # and reading the same blocks again records nothing twice.
    test "ownership up to the head is recorded once and the fleet is then fresh", %{fleet: fleet} do
      mint = log(1, 1, "a", @deployed + 3, 0)
      transfer = log(1, 2, "b", @deployed + 8, 0)
      StubClient.put_chain(head(@deployed + 10), [mint, transfer])

      assert Scanner.step(fleet, StubClient) == :ok
      assert Scanner.step(fleet, StubClient) == :ok

      assert [%{owner_wallet: owner, ownership_epoch: 2}] = current_keys()
      assert owner == wallet("b")
      assert length(Keys.key_history!(@fleet, 1)) == 2
      assert next_block() == @deployed + 11
      assert Chain.fresh?(@fleet)
    end

    # One log the reader cannot make sense of holds the whole range back.
    test "a malformed log records nothing and leaves the cursor where it was", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), [
        log(1, 1, "a", @deployed + 3, 0),
        %{log(2, 1, "b", @deployed + 4, 0) | "data" => "0x01"}
      ])

      assert Scanner.step(fleet, StubClient) == {:error, :invalid_log}
      assert current_keys() == []
      assert next_block() == @deployed
      refute Chain.fresh?(@fleet)
    end

    # A single pass never asks for more than 10,000 blocks, and the next pass
    # starts exactly where the last one ended.
    test "a long history is read in passes of 10,000 blocks with nothing skipped", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 25_000), [
        log(1, 1, "a", @deployed + 9_999, 0),
        log(2, 1, "b", @deployed + 10_000, 0)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert next_block() == @deployed + 10_000
      assert Enum.map(current_keys(), & &1.token_id) == [1]
      refute Chain.fresh?(@fleet)

      assert Scanner.step(fleet, StubClient) == :ok
      assert next_block() == @deployed + 20_000
      assert Enum.map(current_keys(), & &1.token_id) == [1, 2]
    end

    # A node that has not reached blocks already recorded knows nothing about
    # them; that is not a change in the chain's history.
    test "a node behind the record neither stops the fleet nor moves it back", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 8, 0)])
      assert Scanner.step(fleet, StubClient) == :ok

      StubClient.put_chain(head(@deployed + 5), [log(1, 1, "a", @deployed + 8, 0)])

      assert Scanner.step(fleet, StubClient) == :ok
      assert Chain.get_cursor!(@fleet).rescan_from == nil
      assert next_block() == @deployed + 11
      assert [%{owner_wallet: owner}] = current_keys()
      assert owner == wallet("a")
      assert Chain.fresh?(@fleet)
    end

    # A second reading that disagrees with the record stops the fleet at that
    # block instead of rewriting who holds a key, and a stopped fleet is
    # neither read nor written until an operator clears it.
    test "a recorded change that reads differently stops the fleet and nothing is written", %{
      fleet: fleet
    } do
      mint = log(1, 1, "a", @deployed + 3, 0)
      StubClient.put_chain(head(@deployed + 10), [mint])
      assert Scanner.step(fleet, StubClient) == :ok

      StubClient.put_chain(head(@deployed + 12), [%{mint | "topics" => topics(1, "c")}])

      assert capture_log(fn ->
               assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 3}
             end) =~ "bin/clear-fleet-stop #{@fleet}"

      assert [%{owner_wallet: owner}] = current_keys()
      assert owner == wallet("a")
      refute Chain.fresh?(@fleet)

      assert writes_during(fn ->
               assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 3}
             end) == []

      Chain.clear_divergence!(@fleet)
      assert Chain.get_cursor!(@fleet).rescan_from == nil
      refute Chain.fresh?(@fleet)
    end

    # A recorded change that is gone from a block whose hash has changed is the
    # chain's history changing.
    test "a recorded change missing from a block with a new hash stops the fleet", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0)])
      assert Scanner.step(fleet, StubClient) == :ok

      StubClient.put_chain(head(@deployed + 12), [],
        block_hashes: %{(@deployed + 3) => @new_hash}
      )

      capture_log(fn ->
        assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 3}
      end)

      assert Chain.get_cursor!(@fleet).rescan_from == @deployed + 3
    end

    # The same change gone from a block whose hash still matches is the node
    # answering inconsistently: the pass fails and is retried, and nothing moves.
    test "a recorded change missing from an unchanged block is a failed read, not a stop", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0)])
      assert Scanner.step(fleet, StubClient) == :ok

      StubClient.put_chain(head(@deployed + 12), [])

      assert Scanner.step(fleet, StubClient) ==
               {:error, {:log_missing_from_block, @deployed + 3}}

      cursor = Chain.get_cursor!(@fleet)
      assert cursor.rescan_from == nil
      assert cursor.next_block == @deployed + 11
      assert [%{owner_wallet: owner}] = current_keys()
      assert owner == wallet("a")
    end

    # The second reading covers the 30 blocks below the cursor and no more, and
    # never reaches below the deployment for a fleet younger than that.
    test "the second reading spans the last 30 blocks, from the deployment at the earliest", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 5), [log(1, 1, "a", @deployed, 0)])
      assert Scanner.step(fleet, StubClient) == :ok

      StubClient.put_chain(head(@deployed + 6), [], block_hashes: %{@deployed => @new_hash})

      capture_log(fn ->
        assert Scanner.step(fleet, StubClient) == {:stopped, @deployed}
      end)

      Chain.clear_divergence!(@fleet)
      edge = [log(2, 1, "b", @deployed + 170, 0), log(3, 1, "c", @deployed + 171, 0)]
      StubClient.put_chain(head(@deployed + 200), [log(1, 1, "a", @deployed, 0) | edge])
      assert Scanner.step(fleet, StubClient) == :ok
      assert next_block() == @deployed + 201

      StubClient.put_chain(head(@deployed + 201), [log(1, 1, "a", @deployed, 0)],
        block_hashes: %{(@deployed + 170) => @new_hash, (@deployed + 171) => @new_hash}
      )

      capture_log(fn ->
        assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 171}
      end)
    end
  end

  describe "binding the fleets to a deployment" do
    # Rerunning the seed with the same manifest is harmless; a manifest naming
    # other contracts for a bound fleet is refused and changes nothing.
    @tag :tmp_dir
    test "the deployed manifest binds all four fleets once and opens their rooms", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "deployed.json")
      File.write!(path, Jason.encode!(manifest("1")))

      assert capture_io(fn -> Release.seed_deployment!(path) end) =~
               "fleet_tech_classic: 0x#{String.duplicate("c1", 20)} from block 42"

      capture_io(fn -> Release.seed_deployment!(path) end)

      bound = Map.new(Fleets.list_fleets!(), &{&1.id, &1})
      assert bound["fleet_tech_classic"].contract_address == "0x" <> String.duplicate("c1", 20)
      assert bound["fibonacci_cascade"].votes_address == "0x" <> String.duplicate("e1", 20)
      assert Enum.all?(Map.values(bound), &(&1.deployed_block == 42 and &1.chain_id == 8_453))

      assert Enum.all?(Map.keys(bound), &(length(Rooms.list_rooms!(&1)) == 3))

      File.write!(path, Jason.encode!(manifest("2")))
      assert_raise Ash.Error.Invalid, fn -> Release.seed_deployment!(path) end
      assert Map.new(Fleets.list_fleets!(), &{&1.id, &1}) == bound
    end
  end

  defp manifest(generation) do
    fleet = fn letter ->
      %{
        "address" => "0x" <> String.duplicate(String.upcase(letter) <> generation, 20),
        "rewards" => "0x" <> String.duplicate("d" <> generation, 20),
        "votes" => "0x" <> String.duplicate(letter_for_votes(letter) <> generation, 20)
      }
    end

    %{
      "chainId" => 8_453,
      "deploymentBlock" => 42,
      "fleets" => %{
        "syndicate" => fleet.("a"),
        "cascade" => fleet.("b"),
        "classic" => fleet.("c"),
        "accelerant" => fleet.("f")
      }
    }
  end

  defp letter_for_votes("b"), do: "e"
  defp letter_for_votes(_letter), do: "9"

  defp current_keys, do: Keys.keys_in_fleet!(@fleet).results
  defp next_block, do: Chain.get_cursor!(@fleet).next_block

  # The statements that changed the database while `fun` ran in this process.
  defp writes_during(fun) do
    test_pid = self()
    handler = "chain-test-writes"

    :telemetry.attach(
      handler,
      [:key_fleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test_pid and
             not String.starts_with?(meta.query, ["SELECT", "begin", "commit"]),
           do: send(test_pid, {:write, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    receive_writes([])
  end

  defp receive_writes(writes) do
    receive do
      {:write, query} -> receive_writes([query | writes])
    after
      0 -> Enum.reverse(writes)
    end
  end

  defp head(number), do: %{number: number, hash: "0x" <> String.duplicate("f", 64)}

  defp log(token_id, epoch, owner, block, log_index) do
    %{
      "address" => @contract,
      "topics" => topics(token_id, owner),
      "data" => word(epoch),
      "blockNumber" => quantity(block),
      "blockHash" => "0x" <> String.duplicate("b", 64),
      "transactionHash" => "0x" <> String.pad_leading(Integer.to_string(block, 16), 64, "0"),
      "logIndex" => quantity(log_index)
    }
  end

  defp topics(token_id, owner),
    do: [
      OwnershipLog.topic(),
      word(token_id),
      word(0),
      "0x" <> String.duplicate("0", 24) <> String.duplicate(owner, 40)
    ]

  defp word(value), do: "0x" <> String.pad_leading(Integer.to_string(value, 16), 64, "0")
  defp quantity(value), do: "0x" <> Integer.to_string(value, 16)
  defp wallet(character), do: "0x" <> String.duplicate(character, 40)
end

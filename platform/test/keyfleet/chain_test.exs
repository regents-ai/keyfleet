defmodule Keyfleet.ChainTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain
  alias Keyfleet.Chain.{OwnershipLog, ReadFleet, Scanner, StubClient}
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Release
  alias Keyfleet.Repo
  alias Keyfleet.Rooms

  # Other suites commit Syndicate keys outside the sandbox; Accelerant from a
  # high block keeps these readings to what each test puts on the chain.
  @fleet "fleet_tech_accelerant"
  @contract "0x" <> String.duplicate("7", 40)
  @keys "0x" <> String.duplicate("a1", 20)
  @deployed 5_000_000
  @new_hash "0x" <> String.duplicate("e", 64)
  @usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @regent "0x6f89bcA4eA5931EdFCB09786267b251DeE752b07"
  @native "0x0000000000000000000000000000000000000000"
  @deck_hash "0x" <> String.duplicate("0d", 32)

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
      %{
        fleet:
          ChainHelpers.deploy!(@fleet, %{manager_address: @contract, deployed_block: @deployed})
      }
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

    # A page showing the fleet hears which keys were sold or changed hands in
    # the blocks a pass read for the first time; reading them again says nothing.
    test "a pass names the keys sold or changing hands in the blocks it read first", %{
      fleet: fleet
    } do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))

      StubClient.put_chain(head(@deployed + 10), [
        log(1, 1, "a", @deployed + 3, 0),
        log(2, 1, "a", @deployed + 4, 0),
        log(2, 2, "b", @deployed + 8, 0)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:keys_changed, @fleet, [1, 2]}

      StubClient.put_chain(head(@deployed + 20), [
        log(1, 1, "a", @deployed + 3, 0),
        log(2, 1, "a", @deployed + 4, 0),
        log(2, 2, "b", @deployed + 8, 0),
        log(1, 2, "c", @deployed + 15, 0)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:keys_changed, @fleet, [1]}

      assert Scanner.step(fleet, StubClient) == :ok
      refute_received {:keys_changed, _fleet, _token_ids}
    end

    # A node that left a sale out of a block, then has it when the pass reads
    # that block again, is heard about like any other sale.
    test "a key sold that only the second reading finds is named too", %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))
      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0)])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:keys_changed, @fleet, [1]}

      StubClient.put_chain(head(@deployed + 12), [
        log(1, 1, "a", @deployed + 3, 0),
        log(2, 1, "b", @deployed + 6, 0)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:keys_changed, @fleet, [2]}
      refute_received {:keys_changed, _fleet, _token_ids}
      assert Keys.current_key!(@fleet, 2).owner_wallet == "0x" <> String.duplicate("b", 40)

      assert Scanner.step(fleet, StubClient) == :ok
      refute_received {:keys_changed, _fleet, _token_ids}
    end

    # The node answers in halves; the first half is recorded before the second
    # turns out to hold a log the reader cannot make sense of.
    test "a pass that fails partway still names the keys it recorded", %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))
      malformed = %{log(2, 1, "b", @deployed + 8, 0) | "data" => "0x01"}

      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0), malformed],
        max_logs: 1
      )

      assert {:error, _reason} = Scanner.step(fleet, StubClient)
      assert_received {:keys_changed, @fleet, [1]}
      assert Keys.current_key!(@fleet, 2) == nil
    end

    # The job reading a fleet never takes a node serving another chain at its
    # word; a pass that read waits a few seconds and runs again, and one that
    # failed is retried after a wait.
    test "the reading job reads only its fleet's chain, then repeats or retries" do
      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0)], chain_id: 1)

      assert capture_log(fn ->
               assert {:cancel, {:wrong_chain, 1}} =
                        perform_job(ReadFleet, %{fleet_id: @fleet})
             end) =~ "node serves chain 1"

      assert StubClient.log_requests() == []
      assert current_keys() == []

      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0)])
      assert perform_job(ReadFleet, %{fleet_id: @fleet}) == {:snooze, 4}
      assert [%{token_id: 1}] = current_keys()

      malformed = %{log(2, 1, "b", @deployed + 12, 0) | "data" => "0x01"}
      StubClient.put_chain(head(@deployed + 20), [malformed])

      assert capture_log(fn ->
               assert {:error, _reason} = perform_job(ReadFleet, %{fleet_id: @fleet})
             end) =~ "tried again"
    end

    # One log the reader cannot make sense of holds the whole range back.
    test "a malformed log records nothing and leaves the cursor where it was", %{fleet: fleet} do
      malformed = %{log(2, 1, "b", @deployed + 4, 0) | "data" => "0x01"}
      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0), malformed])

      assert Scanner.step(fleet, StubClient) ==
               {:error, {:unreadable_log, malformed["transactionHash"], malformed["logIndex"]}}

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

  describe "binding a fleet to its deployment" do
    # Each fleet is deployed and recorded on its own. Rerunning the seed with
    # the same manifest is harmless; a manifest naming other contracts for a
    # bound fleet is refused and changes nothing.
    @tag :tmp_dir
    test "a fleet's deployed manifest binds that fleet alone, once, and opens its rooms", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "deployed.json")
      File.write!(path, Jason.encode!(manifest("classic", "1")))

      assert capture_io(fn -> Release.seed_deployment!(path) end) ==
               "fleet_tech_classic: fleet 1 at 0x#{String.duplicate("c1", 20)} from block 42\n"

      capture_io(fn -> Release.seed_deployment!(path) end)

      classic = Fleets.get_fleet!("fleet_tech_classic")

      assert %{
               chain_id: 8453,
               chain_fleet_id: 1,
               deployed_block: 42,
               keys_address: "0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
               deck_hash: @deck_hash,
               deck_size: 1,
               manager_address: "0xc1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1",
               rewards_address: "0xd1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",
               votes_address: "0x9191919191919191919191919191919191919191",
               treasury_address: "0x7171717171717171717171717171717171717171",
               shards_address: "0x6161616161616161616161616161616161616161",
               usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
               regent_address: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
               regent_staking_address: "0xb027dc261636e30cbc0fe25b2f8e1ed273354ab5",
               autolaunch_factory_address: "0xf4f591e63f4b6d8240a150081c1ca7edfaeb768e"
             } = classic

      assert classic.trait_table_hash == "0x" <> String.duplicate("a1", 32)
      assert Enum.map(Fleets.list_deployed_fleets!(), & &1.id) == ["fleet_tech_classic"]

      own = ~w(welcome general business voting coding open-1 open-2 open-3 open-4 open-5)
      assert Enum.take(slugs("fleet_tech_classic"), 10) == own
      assert slugs("fibonacci_cascade") == []

      # A coming-soon fleet recorded later opens with its rooms, and the
      # fleet recorded before it is left as it was.
      cascade_path = Path.join(dir, "cascade.json")
      File.write!(cascade_path, Jason.encode!(manifest("cascade", "1")))
      capture_io(fn -> Release.seed_deployment!(cascade_path) end)

      cascade = Fleets.get_fleet!("fibonacci_cascade")
      assert cascade.votes_address == "0x" <> String.duplicate("e1", 20)
      refute Fleets.coming_soon?("fibonacci_cascade", cascade)
      assert Enum.take(slugs("fibonacci_cascade"), 10) == own
      assert Fleets.get_fleet!("fleet_tech_classic") == classic

      bound = Map.new(Fleets.list_fleets!(), &{&1.id, &1})
      File.write!(path, Jason.encode!(manifest("classic", "2")))
      assert_raise Ash.Error.Invalid, fn -> Release.seed_deployment!(path) end
      assert Map.new(Fleets.list_fleets!(), &{&1.id, &1}) == bound
    end

    # Every fleet sells on one chain, for one USDC, with one trait table, so a
    # fleet deployed on other wiring is never bound.
    @tag :tmp_dir
    test "a fleet whose shared wiring differs from a bound fleet's is refused and stays shut", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "deployed.json")
      File.write!(path, Jason.encode!(manifest("classic", "1")))
      capture_io(fn -> Release.seed_deployment!(path) end)
      bound = Map.new(Fleets.list_fleets!(), &{&1.id, &1})

      for {key, value, field} <- [
            {"chainId", 1, "chain_id"},
            {"usdc", "0x" <> String.duplicate("0b", 20), "usdc_address"},
            {"regentStaking", "0x" <> String.duplicate("0c", 20), "regent_staking_address"},
            {"autolaunchFactory", "0x" <> String.duplicate("0d", 20),
             "autolaunch_factory_address"},
            {"traitTableHash", "0x" <> String.duplicate("b2", 32), "trait_table_hash"}
          ] do
        File.write!(path, Jason.encode!(manifest("cascade", "1", %{key => value})))

        error = assert_raise Ash.Error.Invalid, fn -> Release.seed_deployment!(path) end
        assert Exception.message(error) =~ "#{field}: differs from fleet_tech_classic's"
      end

      assert Map.new(Fleets.list_fleets!(), &{&1.id, &1}) == bound
      assert slugs("fibonacci_cascade") == []
    end

    # The treasury splits ETH, REGENT and USDC from its first block, so a
    # manifest whose treasury splits anything else first is not this
    # deployment's and binds nothing.
    @tag :tmp_dir
    test "a manifest whose split assets don't begin ETH, REGENT, USDC binds nothing", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "deployed.json")

      for split <- [
            [@regent, @usdc],
            ["0x0000000000000000000000000000000000000000", @usdc, @regent]
          ] do
        File.write!(path, Jason.encode!(manifest("classic", "1", %{"splitAssets" => split})))
        assert_raise MatchError, fn -> Release.seed_deployment!(path) end
      end

      assert Fleets.list_deployed_fleets!() == []
    end
  end

  # A room made for the fleet before it was marked coming soon can already go
  # by the name one of its own rooms needs, so its rooms cannot open.
  @tag :tmp_dir
  test "a fleet whose rooms cannot open is not recorded either", %{tmp_dir: dir} do
    {_slug, name, _kind} = hd(Rooms.Room.own_rooms())

    Ash.Seed.seed!(Rooms.Room, %{
      fleet_id: "fibonacci_cascade",
      slug: "hull",
      name: name,
      kind: :created
    })

    path = Path.join(dir, "deployed.json")
    File.write!(path, Jason.encode!(manifest("cascade", "1")))

    catch_error(capture_io(fn -> Release.seed_deployment!(path) end))

    assert Fleets.get_fleet!("fibonacci_cascade").manager_address == nil
    assert slugs("fibonacci_cascade") == ["hull"]
  end

  # Run one after the other: the row lock the rule takes is what keeps two
  # recordings at the same moment in this order too.
  test "a second fleet naming another trait table is refused however it is recorded" do
    ChainHelpers.deploy!("fleet_tech_classic")

    other =
      ChainHelpers.deployment("fibonacci_cascade", %{
        trait_table_hash: "0x" <> String.duplicate("5", 64)
      })

    assert {:error, %Ash.Error.Invalid{} = error} =
             "fibonacci_cascade"
             |> Fleets.get_fleet!()
             |> Fleets.record_deployment(other, actor: %System{})

    assert Exception.message(error) =~ "trait_table_hash: differs from fleet_tech_classic's"
    assert Enum.map(Fleets.list_deployed_fleets!(), & &1.id) == ["fleet_tech_classic"]
  end

  describe "opening the fleets without a deployment" do
    @tag :tmp_dir
    test "each deploy's migration step opens rooms only for open fleets and never unbinds a bound one",
         %{tmp_dir: dir} do
      assert capture_io(fn -> Release.migrate!() end) ==
               """
               fleet_tech_classic: open
               fibonacci_syndicate: coming soon
               fibonacci_cascade: coming soon
               fleet_tech_accelerant: coming soon
               """

      assert Enum.all?(Fleets.list_fleets!(), &is_nil(&1.manager_address))
      assert Fleets.list_deployed_fleets!() == []
      assert length(slugs("fleet_tech_classic")) >= 10
      assert slugs("fibonacci_syndicate") == []

      path = Path.join(dir, "deployed.json")
      File.write!(path, Jason.encode!(manifest("syndicate", "1")))
      capture_io(fn -> Release.seed_deployment!(path) end)
      bound = Map.new(Fleets.list_fleets!(), &{&1.id, &1})

      assert capture_io(fn -> Release.migrate!() end) =~ "fibonacci_syndicate: open"
      assert Map.new(Fleets.list_fleets!(), &{&1.id, &1}) == bound
    end
  end

  defp slugs(fleet), do: Enum.map(Rooms.list_rooms!(fleet), & &1.slug)

  # The record `RecordKeyfleets` writes holding the first fleet of type
  # `slot`, on the wiring every fleet shares unless `wiring` says otherwise.
  # Its treasury splits ETH, then its REGENT, then its USDC unless `wiring`
  # names other `splitAssets`.
  defp manifest(slot, generation, wiring \\ %{}) do
    letter = %{"syndicate" => "a", "cascade" => "b", "classic" => "c", "accelerant" => "f"}[slot]
    number = %{"classic" => "1", "syndicate" => "2", "cascade" => "3", "accelerant" => "4"}[slot]
    {split, shared} = Map.pop(wiring, "splitAssets")

    record =
      Map.merge(
        %{
          "chainId" => 8453,
          "deploymentBlock" => 42,
          "collection" => %{"address" => "0x" <> String.duplicate("A1", 20)},
          "shards" => %{"address" => "0x" <> String.duplicate("61", 20)},
          "usdc" => @usdc,
          "regent" => @regent,
          "regentStaking" => "0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5",
          "autolaunchFactory" => "0xf4F591E63f4B6d8240a150081C1CA7Edfaeb768E",
          "traitTableHash" => "0x" <> String.duplicate("A1", 32)
        },
        shared
      )

    fleet = %{
      "type" => slot,
      "typeNumber" => 1,
      "manager" => "0x" <> String.duplicate(String.upcase(letter) <> generation, 20),
      "rewards" => "0x" <> String.duplicate("d" <> generation, 20),
      "votes" => "0x" <> String.duplicate(letter_for_votes(letter) <> generation, 20),
      "treasury" => "0x" <> String.duplicate("7" <> generation, 20),
      "deckHash" => @deck_hash,
      "deckSize" => 1,
      "splitAssets" => split || [@native, record["regent"], record["usdc"]]
    }

    Map.put(record, "fleets", %{number => fleet})
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
      [:keyfleet, :repo, :query],
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

  defp head(number),
    do: %{
      number: number,
      hash: "0x" <> String.duplicate("f", 64),
      timestamp: DateTime.from_unix!(1_700_000_000 + 2 * number),
      base_fee: 0
    }

  defp log(token_id, epoch, owner, block, log_index) do
    %{
      "address" => @keys,
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
      word(ChainHelpers.onchain_id(@fleet, token_id)),
      word(0),
      "0x" <> String.duplicate("0", 24) <> String.duplicate(owner, 40)
    ]

  defp word(value), do: "0x" <> String.pad_leading(Integer.to_string(value, 16), 64, "0")
  defp quantity(value), do: "0x" <> Integer.to_string(value, 16)
  defp wallet(character), do: "0x" <> String.duplicate(character, 40)
end

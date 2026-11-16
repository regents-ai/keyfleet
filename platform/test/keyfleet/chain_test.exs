defmodule Keyfleet.ChainTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Keyfleet.Repo

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain
  alias Keyfleet.Chain.{OwnershipLog, ReadBalances, ReadFleet, Scanner, StubClient}
  alias Keyfleet.ChainHelpers
  alias Keyfleet.ChainRefresh
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
    # all the way to the head.
    test "ownership is fresh only when read just now and caught up" do
      refute Chain.fresh?(@fleet)

      for {attrs, fresh?} <- [
            {%{observed_at: DateTime.add(DateTime.utc_now(), -421, :second)}, false},
            {%{observed_at: DateTime.add(DateTime.utc_now(), -360, :second)}, true},
            {%{head_block: 4_000, next_block: 1_000}, false},
            {%{}, true}
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

    # Through the real client: a node answering the log request with HTTP 429
    # is asked for those logs once, and the pass ends where it began, rather
    # than being asked again for each half of the range.
    test "a node asking for fewer requests is asked for the logs once", %{fleet: fleet} do
      config = Application.fetch_env!(:keyfleet, Chain)
      on_exit(fn -> Application.put_env(:keyfleet, Chain, config) end)
      test_pid = self()

      node!(config, fn
        "eth_getBlockByNumber" ->
          {200,
           %{
             "number" => "0x" <> Integer.to_string(@deployed + 100, 16),
             "hash" => "0x" <> String.duplicate("f", 64),
             "timestamp" => "0x6553f100",
             "baseFeePerGas" => "0x0"
           }}

        "eth_call" ->
          {200, "0x" <> String.duplicate("0", 24) <> String.duplicate("b0", 20)}

        "eth_getLogs" ->
          send(test_pid, :logs_asked)
          {429, nil}
      end)

      log =
        capture_log(fn ->
          assert Scanner.step(fleet, Keyfleet.Chain.RpcClient) ==
                   {:error, {:block_unanswered, @deployed, :chain_busy}}
        end)

      assert_received :logs_asked
      refute_received :logs_asked
      assert log =~ "429"
      assert next_block() == @deployed
    end

    # The job reading a fleet never takes a node serving another chain at its
    # word; a pass that read waits five minutes and runs again, one that
    # failed is retried a minute later, and a node that does not answer is a
    # minute's wait, not a failure.
    test "the reading job reads only its fleet's chain, then repeats or retries" do
      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0)], chain_id: 1)

      assert capture_log(fn ->
               assert {:cancel, {:wrong_chain, 1}} =
                        perform_job(ReadFleet, %{fleet_id: @fleet})
             end) =~ "node serves chain 1"

      assert StubClient.log_requests() == []
      assert current_keys() == []

      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 3, 0)])
      assert perform_job(ReadFleet, %{fleet_id: @fleet}) == {:snooze, 300}
      assert [%{token_id: 1}] = current_keys()

      malformed = %{log(2, 1, "b", @deployed + 12, 0) | "data" => "0x01"}
      StubClient.put_chain(head(@deployed + 20), [malformed])

      assert capture_log(fn ->
               assert {:error, _reason} = perform_job(ReadFleet, %{fleet_id: @fleet})
             end) =~ "tried again"

      StubClient.put_chain(head(@deployed + 20), [],
        calls: fn _to, _data, _hash -> {:error, :chain_unavailable} end
      )

      assert capture_log(fn ->
               assert perform_job(ReadFleet, %{fleet_id: @fleet}) == {:snooze, 60}
             end) =~ "did not answer"
    end

    # Each finished pass reports the head less the last block it read, so a
    # long history shows its lag shrinking pass by pass down to 0. While it
    # is behind, the next pass follows a second later, not five minutes on.
    test "each pass reports how far the record trails the head" do
      handler = "lag-#{inspect(self())}"
      test = self()

      :telemetry.attach(
        handler,
        [:keyfleet, :indexer, :lag],
        fn _event, blocks, labels, nil ->
          send(test, {blocks, labels})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      StubClient.put_chain(head(@deployed + 25_000), [])

      for {lag, wait} <- [{15_001, 1}, {5_001, 1}, {0, 300}] do
        assert perform_job(ReadFleet, %{fleet_id: @fleet}) == {:snooze, wait}
        assert_received {%{blocks: ^lag}, %{indexer: "fleet", chain_id: 8453}}
      end
    end

    # One log the reader cannot make sense of holds the whole range back.
    # A person's on-chain press that lands brings the fleet's next history read
    # forward to ten seconds from now and reads its balances at once; a press
    # on another chain leaves the fleet's turn where it was.
    test "a landed press brings the fleet's next reading forward", %{fleet: fleet} do
      Oban.insert!(ReadFleet.new(%{fleet_id: @fleet}, schedule_in: 300))

      :ok = ChainRefresh.request(fleet.chain_id + 1)
      assert [waiting] = all_enqueued(worker: ReadFleet, args: %{fleet_id: @fleet})
      assert DateTime.diff(waiting.scheduled_at, DateTime.utc_now()) > 200
      refute_enqueued(worker: ReadBalances, args: %{fleet_id: @fleet})

      :ok = ChainRefresh.request(fleet.chain_id)
      assert [sooner] = all_enqueued(worker: ReadFleet, args: %{fleet_id: @fleet})
      assert DateTime.diff(sooner.scheduled_at, DateTime.utc_now()) <= ChainRefresh.gap_s()
      assert_enqueued(worker: ReadBalances, args: %{fleet_id: @fleet})

      # Presses that keep coming never put the read off: one already due
      # sooner keeps its time.
      {:ok, due} = Oban.update_job(sooner, %{scheduled_at: DateTime.utc_now()})
      :ok = ChainRefresh.request(fleet.chain_id)
      assert [kept] = all_enqueued(worker: ReadFleet, args: %{fleet_id: @fleet})
      assert DateTime.compare(kept.scheduled_at, due.scheduled_at) == :eq
    end

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
    test "a node behind the record does not move the fleet back", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), [log(1, 1, "a", @deployed + 8, 0)])
      assert Scanner.step(fleet, StubClient) == :ok

      StubClient.put_chain(head(@deployed + 5), [log(1, 1, "a", @deployed + 8, 0)])

      assert Scanner.step(fleet, StubClient) == :ok
      assert next_block() == @deployed + 11
      assert [%{owner_wallet: owner}] = current_keys()
      assert owner == wallet("a")
      assert Chain.fresh?(@fleet)
    end

    # The second reading covers the 300 blocks below the cursor and no more, and
    # never reaches below the deployment for a fleet younger than that.
    test "the second reading spans the last 300 blocks, from the deployment at the earliest", %{
      fleet: fleet
    } do
      mint = log(1, 1, "a", @deployed, 0)
      StubClient.put_chain(head(@deployed + 5), [mint])
      assert Scanner.step(fleet, StubClient) == :ok

      StubClient.put_chain(head(@deployed + 6), [mint])
      assert Scanner.step(fleet, StubClient) == :ok
      assert [{_, _, @deployed, to}, _forward] = StubClient.log_requests()
      assert to == @deployed + 5

      StubClient.put_chain(head(@deployed + 2_000), [mint])
      assert Scanner.step(fleet, StubClient) == :ok

      StubClient.put_chain(head(@deployed + 2_001), [mint])
      assert Scanner.step(fleet, StubClient) == :ok
      assert [{_, _, from, to}, _forward] = StubClient.log_requests()
      assert {from, to} == {@deployed + 1_701, @deployed + 2_000}
    end
  end

  describe "when the chain's history changes" do
    setup do
      %{
        fleet:
          ChainHelpers.deploy!(@fleet, %{manager_address: @contract, deployed_block: @deployed})
      }
    end

    # Whatever changed, a saved sale read again keeps its records, and nothing
    # more of its transaction is saved, not even a sale the chain now puts in
    # it. The pass reads on: a sale of another transaction later in the same
    # stretch is recorded and the cursor moves, and every later pass reads on.
    # The sale is named once, by the pass that reads its block for the last
    # time.
    for change <- [:moved, :new_block_hash, :changed, :gone] do
      test "a saved sale #{change} keeps its records, is named once and reading goes on", %{
        fleet: fleet
      } do
        mint = log(1, 1, "a", @deployed + 3, 0)
        StubClient.put_chain(head(@deployed + 10), [mint])
        assert Scanner.step(fleet, StubClient) == :ok
        saved = recorded()
        history = Keys.key_history!(@fleet, 1)

        logs = changed(unquote(change), mint) ++ [log(2, 1, "b", @deployed + 7, 0)]

        named =
          for head <- [@deployed + 12, @deployed + 400, @deployed + 401] do
            StubClient.put_chain(head(head), logs)
            log = capture_log(fn -> assert Scanner.step(fleet, StubClient) == :ok end)
            assert next_block() == head + 1
            length(String.split(log, String.downcase(mint["transactionHash"]))) - 1
          end

        assert named == [0, 1, 0]
        assert [%{block_number: block, token_id: 2}] = recorded() -- saved
        assert block == @deployed + 7
        assert Keys.key_history!(@fleet, 1) == history

        assert Enum.map(current_keys(), &{&1.token_id, &1.owner_wallet}) == [
                 {1, wallet("a")},
                 {2, wallet("b")}
               ]

        assert Chain.minted(@fleet) == {:ok, 2}
      end
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
               autolaunch_factory_address: "0xf4f591e63f4b6d8240a150081c1ca7edfaeb768e",
               club_claims_address: "0xa2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2"
             } = classic

      assert classic.trait_table_hash == "0x" <> String.duplicate("a1", 32)
      assert Enum.map(Fleets.list_deployed_fleets!(), & &1.id) == ["fleet_tech_classic"]

      own = ~w(welcome general people business voting coding open-1 open-2 open-3 open-4 open-5)
      assert Enum.take(slugs("fleet_tech_classic"), 11) == own
      assert slugs("fibonacci_cascade") == []

      # A coming-soon fleet recorded later opens with its rooms, and the
      # fleet recorded before it is left as it was.
      cascade_path = Path.join(dir, "cascade.json")
      File.write!(cascade_path, Jason.encode!(manifest("cascade", "1")))
      capture_io(fn -> Release.seed_deployment!(cascade_path) end)

      cascade = Fleets.get_fleet!("fibonacci_cascade")
      assert cascade.votes_address == "0x" <> String.duplicate("e1", 20)
      refute Fleets.coming_soon?("fibonacci_cascade", cascade)
      assert Enum.take(slugs("fibonacci_cascade"), 11) == own
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
            {"clubClaims", %{"address" => "0x" <> String.duplicate("0e", 20)},
             "club_claims_address"},
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
               fleet_tech_classic: coming soon
               fibonacci_syndicate: coming soon
               fibonacci_cascade: coming soon
               fleet_tech_accelerant: coming soon
               regents_club: coming soon
               """

      assert Enum.all?(Fleets.list_fleets!(), &is_nil(&1.manager_address))
      assert Fleets.list_deployed_fleets!() == []
      assert slugs("fleet_tech_classic") == []
      assert slugs("fibonacci_syndicate") == []

      path = Path.join(dir, "deployed.json")
      File.write!(path, Jason.encode!(manifest("syndicate", "1")))
      capture_io(fn -> Release.seed_deployment!(path) end)
      bound = Map.new(Fleets.list_fleets!(), &{&1.id, &1})

      assert capture_io(fn -> Release.migrate!() end) =~ "fibonacci_syndicate: open"
      assert Map.new(Fleets.list_fleets!(), &{&1.id, &1}) == bound
    end
  end

  defp slugs(fleet), do: Enum.map(Rooms.list_rooms!(fleet, authorize?: false), & &1.slug)

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
          "clubClaims" => %{"address" => "0x" <> String.duplicate("A2", 20)},
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

  # The saved sale's transaction as the chain now has it, with a second sale in
  # it that was never saved, or gone.
  defp changed(:moved, mint) do
    for log <- [log(1, 1, "a", @deployed + 5, 0), log(3, 1, "c", @deployed + 5, 1)],
        do: %{log | "transactionHash" => mint["transactionHash"]}
  end

  defp changed(:new_block_hash, mint),
    do:
      for(log <- [mint, log(3, 1, "c", @deployed + 3, 1)], do: %{log | "blockHash" => @new_hash})

  defp changed(:changed, mint),
    do: [%{mint | "data" => word(2)}, log(3, 1, "c", @deployed + 3, 1)]

  defp changed(:gone, _mint), do: []

  defp recorded, do: Keys.recorded_in_blocks!(@fleet, 0, @deployed + 1_000, actor: %System{})

  defp current_keys, do: Keys.keys_in_fleet!(@fleet).results
  defp next_block, do: Chain.get_cursor!(@fleet).next_block

  # Points the app's node address at a local server answering each JSON-RPC
  # method with `answer.(method)`: an HTTP status and, for 200, the result.
  defp node!(config, answer) do
    plug = fn conn, _opts ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case answer.(Jason.decode!(body)["method"]) do
        {200, result} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{jsonrpc: "2.0", id: 1, result: result}))

        {status, nil} ->
          Plug.Conn.send_resp(conn, status, "")
      end
    end

    pid =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0}, id: make_ref())
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    Application.put_env(
      :keyfleet,
      Chain,
      Keyword.put(config, :rpc_url, "http://127.0.0.1:#{port}")
    )
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

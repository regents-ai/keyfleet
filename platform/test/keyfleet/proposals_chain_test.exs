defmodule Keyfleet.ProposalsChainTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain
  alias Keyfleet.Chain.{Logs, Scanner, StubClient}
  alias Keyfleet.ChainHelpers
  alias Keyfleet.CommittedCatalog
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Fleet
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Repo
  alias Keyfleet.Treasury

  # Other suites commit Syndicate keys outside the sandbox; Accelerant from a
  # high block keeps these readings to what each test puts on the chain.
  @fleet "fleet_tech_accelerant"
  @keys "0x" <> String.duplicate("a1", 20)
  @contract "0x" <> String.duplicate("7", 40)
  @rewards "0x" <> String.duplicate("8", 40)
  @votes "0x" <> String.duplicate("9", 40)
  @treasury "0x" <> String.duplicate("7e", 20)
  @shards "0x" <> String.duplicate("6", 40)
  @deployed 5_000_000
  @new_hash "0x" <> String.duplicate("e", 64)
  @max_uint256 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935
  @max_bigint 9_223_372_036_854_775_807
  @day 86_400
  @execution_window 7 * @day

  # Pinned from `cast keccak` of each event signature, and against the
  # contracts in contracts/test/KeyfleetVotesTopics.t.sol where it pins them.
  @ownership "0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1"
  @revealed "0x2641319733d9075c8fb8c0e9c0738513e76e459cba32ba76efd9a29096dc8a24"
  @reveal_expired "0xe7a4b3ed034eada5a71195b6461d48bb201a05ce179836c366f403517eaa78b8"
  @forwarded "0x8926b565a570cae7e82c2dcc861e6aeea283665a938a403f59ee2a13bcc83d81"
  @protocol_share "0x406fe989f03a57e5eb52c9fc293be7940d07567bd9425fb5fe3d0eafd20be3f3"
  @created "0x959c9f8f330ac28b7f4719d751c7fa2d25e7be768c2642037e274c468a0ac796"
  @ballot "0x8fade46d07f3bc5ab9b6f059a9582a5d1c0c1aea60978623e207da414bb1ee45"
  @cancelled "0x74c34a008ce735d9fcf0bd03a9b238d212ad4c441c020661f4ffbb6442645b85"
  @executed "0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24"
  @edits_set "0x908aa6b1a2d33ab8aaa026fccd64bd2d84297a4e0e9c496d53edbb67e5165cdc"
  @present "0x65494834b9ecadf1a0a1aa43098094d1784705df5b74020daae186d31b9d5d19"
  @presence_cleared "0x3a7956ae06b201a0d818ed191ba804d3cbe825deec03291fae84299fc9b2ae8f"
  @presence_scheduled "0x43b6d694a84ad821ffa4c6b8182345b762cd50945d6c3267f8bdea3d0a1ab722"
  @shard_issued "0x3b2824f462424cb01c09746900aff2810947c0577d310c08082c75fe40c2312a"
  @shard_ended "0x22773ac65ded0957ecf7109dad0076e1968f3db974ccda1df370bfa4505092f4"
  @agent_voting_set "0xfdf7ebb0624288d5705c5fa214a210cf974c5a5598f8f65a6d616f0c420acabd"
  @paid "0xadcbed09c0c3a96dbd120d51398fcb6c403f4bfad9a29f7e23e7f5707968220d"
  @advanced "0x48ac236609298a1c7957fb52a75e13423f9df416523ebeec6db95db52d813159"
  @advance_returned "0x2034cebd1ee980ae5db64594c0a5e13ca3153fb318294274500210fc58592e80"
  @daily_split_run "0x589c845daa4d6c172f7b015018e21cf71a9651115b4cb58d0bde2b1bf57f50ec"
  @split_allocated "0x9074e50b5000d1a14458055f7b5489e63374e5de93050bc4c71be60cc3fe43a7"
  @split_skipped "0xea328f671ee6ff84eeaff6f40f943c3204abf2f8546aa6d059b505d73ebceb19"
  @split_transfer_failed "0xce002d041f89b0045ad3cfc1b0ae1f7aeca252711b611ca0181d3f40c24aa625"
  @daily_split_rate_set "0x5b373159cf1aa560402780ad3be14b33d21f72e79ae0dae5688d4c232b953d81"
  @ousd_admitted "0xebcf2752fcd8a14f6710aaeea4dff961f9fe5e076a8a719afc5b286405520d78"
  @launch_token_bound "0x8d7b7447fbb1198714566de25638e562cbbad2f5d24d09970b1793414994acf4"
  @signature_approved "0x55466410721fef34fe9a5642b5f6ad4a536d32b4dd13f85ffc1629fc8839046e"
  @signature_revoked "0x3777c7cd3a982e67c2f22eb607a5ac633d7463082b7819be343158ac9859bfe1"
  @settled "0xbfed4c9aef0cc82058a0d9ecf93fff780a20d63bb650b7fcde95bf639097b402"
  @claimed "0x913c992353dc81b7a8ba31496c484e9b6306bd2f6c509a649a38fdf5e1c953b2"
  @regent_bought "0x8b4785a0113ae976ccc15001ce0df54d471ffaff1c37deea58d2d3ebc07048aa"

  @record_tables ~w(proposal_cancellations proposal_executions proposal_votes proposals
                    treasury_events edits_restrictions key_presences)

  setup context do
    if context[:independent_connections] do
      added_fleets = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &CommittedCatalog.commit!/0)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          remove_committed_records()
          CommittedCatalog.remove!(added_fleets)
        end)
      end)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> %{fleet: deploy!()} end)
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Fleets.bootstrap_catalog!()
      %{fleet: deploy!()}
    end
  end

  describe "recording proposals" do
    # One request per stretch of blocks covers all five contracts and every
    # event, and each record lands with exactly the fields its log carries.
    # A proposal opens when its author key's renewal, logged just before it,
    # says.
    test "a proposal, its ballots, its cancellation or execution and a key's edits are recorded in chain order",
         %{fleet: fleet} do
      StubClient.put_chain(
        head(@deployed + 10),
        List.flatten([
          decision(1, @deployed + 1,
            author: 3,
            opening: 5,
            calls: [{"c", @max_uint256, <<0xDE, 0xAD, 0xBE>>}, {"d", 0, <<>>}]
          ),
          decision(2, @deployed + 2),
          vote(1, "a", :yes, [1, 2, 3], @deployed + 4, 0),
          vote(1, "b", :no, [4], @deployed + 4, 1),
          vote(1, "d", :abstain, [5], @deployed + 4, 2),
          cancelled(2, "e", @deployed + 5, 0),
          executed(1, "c", @deployed + 5, 1),
          edits_set(7, true, @deployed + 5, 2)
        ])
      )

      assert Scanner.step(fleet, StubClient) == :ok

      assert [{addresses, topics, @deployed, to}] = StubClient.log_requests()

      assert addresses == [
               @keys,
               @contract,
               @votes,
               @shards,
               @treasury,
               @rewards,
               StubClient.regent_buyer()
             ]

      assert to == @deployed + 10

      assert Enum.sort(topics) ==
               Enum.sort([
                 @ownership,
                 @revealed,
                 @reveal_expired,
                 @forwarded,
                 @protocol_share,
                 @created,
                 @ballot,
                 @cancelled,
                 @executed,
                 @edits_set,
                 @present,
                 @presence_cleared,
                 @presence_scheduled,
                 @shard_issued,
                 @shard_ended,
                 @agent_voting_set,
                 @paid,
                 @advanced,
                 @advance_returned,
                 @daily_split_run,
                 @split_allocated,
                 @split_skipped,
                 @split_transfer_failed,
                 @daily_split_rate_set,
                 @ousd_admitted,
                 @launch_token_bound,
                 @signature_approved,
                 @signature_revoked,
                 @settled,
                 @claimed,
                 @regent_bought
               ])

      first = Proposals.get_proposal!(@fleet, 1)
      opened_at = block_time(@deployed + 1)

      assert %{
               author_key: 3,
               opening_count: 5,
               open_revision: 1,
               block_number: block,
               log_index: 1,
               record_seq: 1
             } = first

      assert block == @deployed + 1
      assert first.proposer == wallet("f")
      assert first.proposal_hash == hex(<<1001::256>>)
      assert first.content_hash == hex(<<1::256>>)
      assert first.opened_at == opened_at
      assert first.closes_at == DateTime.add(opened_at, @day)
      assert first.execution_expiry == DateTime.add(opened_at, @day + @execution_window)
      assert first.transaction_hash == String.downcase(transaction(@deployed + 1))

      assert [
               %{target: target, value: @max_uint256, data: "0xdeadbe"},
               %{target: other, value: 0, data: "0x"}
             ] = first.calls

      assert {target, other} == {wallet("c"), wallet("d")}

      assert [%{kind: :present, token_id: 3, at: ^opened_at, ownership_epoch: 1, log_index: 0}, _] =
               @fleet
               |> Keys.presences_in_blocks!(@deployed, @deployed + 10, actor: %System{})
               |> Enum.sort_by(&{&1.block_number, &1.log_index})

      assert [yes, no, abstain] =
               @fleet
               |> Proposals.votes_recorded_in_blocks!(@deployed, @deployed + 10, actor: %System{})
               |> Enum.sort_by(& &1.record_seq)

      assert %{choice: :yes, token_ids: [1, 2, 3], record_seq: 3} = yes
      assert %{choice: :no, token_ids: [4], record_seq: 4, log_index: 1} = no
      assert %{choice: :abstain, token_ids: [5], record_seq: 5} = abstain
      assert yes.voter == wallet("a")
      assert yes.proposal_id == first.id

      second = Proposals.get_proposal!(@fleet, 2)

      assert [%{proposal_id: cancelled_id, record_seq: 6} = cancellation] =
               Proposals.cancellations_recorded_in_blocks!(@fleet, @deployed, @deployed + 10,
                 actor: %System{}
               )

      assert cancelled_id == second.id
      assert cancellation.cancelled_by == wallet("e")

      assert [%{proposal_id: executed_id, record_seq: 7} = execution] =
               Proposals.executions_recorded_in_blocks!(@fleet, @deployed, @deployed + 10,
                 actor: %System{}
               )

      assert executed_id == first.id
      assert execution.executor == wallet("c")

      assert [%{token_id: 7, restricted: true, record_seq: 8}] =
               Keys.edits_restrictions_in_blocks!(@fleet, @deployed, @deployed + 10,
                 actor: %System{}
               )

      # One vote per key: three keys for, one against, one abstaining.
      tallied = Proposals.get_by_number(@fleet, 1)
      assert %{yes_keys: 3, no_keys: 1, abstain_keys: 1} = tallied
      assert Proposals.status(tallied) == :executed
      assert Proposals.status(Proposals.get_by_number(@fleet, 2)) == :cancelled

      assert Chain.get_cursor!(@fleet).proposal_seq == 8
    end

    # A key's latest ballot is the one that counts, for whichever side.
    test "a key that votes again counts only on its latest side", %{fleet: fleet} do
      logs =
        List.flatten([
          decision(1, @deployed + 1),
          vote(1, "a", :yes, [1, 2, 3], @deployed + 2, 0),
          vote(1, "b", :no, [4], @deployed + 2, 1)
        ])

      StubClient.put_chain(head(@deployed + 10), logs)
      assert Scanner.step(fleet, StubClient) == :ok

      assert %{yes_keys: 3, no_keys: 1, abstain_keys: 0} = Proposals.get_by_number(@fleet, 1)

      StubClient.put_chain(
        head(@deployed + 20),
        logs ++ [vote(1, "a", :abstain, [2, 4], @deployed + 11, 0)]
      )

      assert Scanner.step(fleet, StubClient) == :ok
      assert %{yes_keys: 2, no_keys: 0, abstain_keys: 2} = Proposals.get_by_number(@fleet, 1)
    end

    # Money in and out of the treasury, its daily split and the rewards paid
    # out keep every amount as the contracts gave it and are numbered with the
    # proposal records, so the proposals hint goes out for them too.
    test "money events from the fleet, treasury and reward ledger are recorded with the proposal records",
         %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))
      logs = money_history()
      StubClient.put_chain(head(@deployed + 10), logs)

      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:proposals_changed, @fleet}

      assert [share, paid, split, claimed] =
               @fleet
               |> Treasury.recorded_in_blocks!(@deployed, @deployed + 10)
               |> Enum.sort_by(& &1.record_seq)

      assert %{kind: :protocol_share_sent, record_seq: 2, log_index: 2} = share
      assert share.by == wallet("f")
      assert Decimal.equal?(share.amount, @max_uint256)

      assert %{kind: :paid, record_seq: 3, block_number: paid_block, log_index: 0} = paid
      assert paid_block == @deployed + 2
      assert paid.asset == wallet("a") and paid.account == wallet("c")
      assert Decimal.equal?(paid.share, 15_000)
      assert Decimal.equal?(paid.amount, @max_uint256)

      assert %{kind: :split_allocated, record_seq: 4} = split
      assert split.asset == wallet("a")

      assert Enum.map([split.balance, split.per_key, split.keys], &Decimal.to_integer/1) == [
               1_000,
               10,
               100
             ]

      assert %{kind: :claimed, record_seq: 5, log_index: 1} = claimed

      assert {claimed.asset, claimed.account, claimed.by} ==
               {wallet("a"), wallet("b"), wallet("c")}

      assert Chain.get_cursor!(@fleet).proposal_seq == 5

      # Read again, nothing is made twice or numbered again.
      StubClient.put_chain(head(@deployed + 12), logs)
      assert Scanner.step(fleet, StubClient) == :ok
      assert length(Treasury.recorded_in_blocks!(@fleet, @deployed, @deployed + 12)) == 4
      assert Chain.get_cursor!(@fleet).proposal_seq == 5
    end

    # A money log read again with other amounts is the chain disagreeing with
    # the record; gone from a block whose hash changed, it is the same.
    test "a money record the chain no longer agrees with stops the fleet at its block", %{
      fleet: fleet
    } do
      paid = paid("a", "c", @deployed + 2, 0, 10)
      split = split_allocated("a", @deployed + 4, 0, [100, 1, 100])
      StubClient.put_chain(head(@deployed + 10), [paid, split])
      assert Scanner.step(fleet, StubClient) == :ok

      for {logs, opts, block} <- [
            {[paid("a", "c", @deployed + 2, 0, 9), split], [], @deployed + 2},
            {[paid, split_allocated("d", @deployed + 4, 0, [100, 1, 100])], [], @deployed + 4},
            {[paid], [block_hashes: %{(@deployed + 4) => @new_hash}], @deployed + 4}
          ] do
        StubClient.put_chain(head(@deployed + 12), logs, opts)
        capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, block} end)
        Chain.clear_divergence!(@fleet)
      end

      assert length(Treasury.recorded_in_blocks!(@fleet, @deployed, @deployed + 12)) == 2
    end

    # One stretch that cannot be read whole moves nothing, not even the
    # ownership read beside it.
    test "a stretch that cannot be read whole records nothing and holds the cursor", %{
      fleet: fleet
    } do
      mint = ownership(1, "a", @deployed + 1, 0)
      [renewal, created] = decision(1, @deployed + 2)
      created_at = {String.downcase(transaction(@deployed + 2)), 1}
      opening_missing = Tuple.insert_at(created_at, 0, :opening_missing)
      conflicting = Tuple.insert_at(created_at, 0, :conflicting_logs)

      for {logs, reason} <- [
            {[created], opening_missing},
            {[present(2, @deployed + 2, 0), created], opening_missing},
            {[%{renewal | "transactionHash" => transaction(1)}, created], opening_missing},
            {[renewal, ownership(1, "b", @deployed + 2, 1) |> at(1), created |> at(2)],
             Tuple.insert_at({elem(created_at, 0), 2}, 0, :opening_missing)},
            {[renewal, %{created | "data" => "0x"}],
             {:unreadable_log, transaction(@deployed + 2), "0x1"}},
            {[renewal, created, with_word(created, 1, <<9::256>>)], conflicting},
            {[renewal, created, %{created | "transactionHash" => transaction(1)}], conflicting},
            {[renewal, created, %{created | "blockNumber" => quantity(@deployed + 3)}],
             conflicting},
            {[decision(2, @deployed + 2)], {:proposal_number_skipped, @deployed + 2}},
            {[decision(1, @deployed + 2), decision(3, @deployed + 3)],
             {:proposal_number_skipped, @deployed + 3}},
            {[vote(1, "a", :yes, [1], @deployed + 2, 0), decision(1, @deployed + 3)],
             {:proposal_not_recorded, @deployed + 2}},
            {[decision(1, @deployed + 2), executed(2, "c", @deployed + 3, 0)],
             {:proposal_not_recorded, @deployed + 3}},
            {[decision(1, @deployed + 2), cancelled(2, "c", @deployed + 3, 0)],
             {:proposal_not_recorded, @deployed + 3}}
          ] do
        StubClient.put_chain(head(@deployed + 10), [mint | List.flatten(logs)])

        assert Scanner.step(fleet, StubClient) == {:error, reason}, inspect(logs)
        assert Keys.keys_in_fleet!(@fleet).results == []
        assert Keys.presences_in_blocks!(@fleet, 0, @deployed + 10, actor: %System{}) == []
        assert Proposals.highest_number!(@fleet) == 0
        assert %{next_block: @deployed, proposal_seq: 0} = Chain.get_cursor!(@fleet)
      end

      StubClient.put_chain(head(@deployed + 10), [mint | decision(1, @deployed + 2)])
      assert Scanner.step(fleet, StubClient) == :ok
      assert Proposals.highest_number!(@fleet) == 1
    end

    # Reading the same blocks again, even from the deployment on, finds every
    # record already made and gives none a new number.
    test "reading again, even from the deployment, gives no record a new number", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok
      recorded = recorded()
      assert Chain.get_cursor!(@fleet).proposal_seq == 4

      StubClient.put_chain(head(@deployed + 12), history())
      assert Scanner.step(fleet, StubClient) == :ok

      {:ok, _cursor} =
        @fleet
        |> Chain.get_cursor!()
        |> Chain.advance_cursor(%{
          next_block: @deployed,
          head_block: @deployed,
          head_block_hash: @new_hash,
          observed_at: DateTime.utc_now()
        })

      assert Scanner.step(fleet, StubClient) == :ok
      assert recorded() == recorded
      assert %{proposal_seq: 4, next_block: next_block} = Chain.get_cursor!(@fleet)
      assert next_block == @deployed + 13
    end

    # The order the chain made them, not the order the node lists them.
    test "ownership and proposal logs in one block are recorded in log order", %{fleet: fleet} do
      logs = [
        decision(1, @deployed + 3),
        ownership(1, "a", @deployed + 3, 2),
        vote(1, "a", :yes, [1], @deployed + 3, 3),
        executed(1, "a", @deployed + 3, 4)
      ]

      StubClient.put_chain(head(@deployed + 10), Enum.reverse(List.flatten(logs)))

      inserted = inserts_during(fn -> assert Scanner.step(fleet, StubClient) == :ok end)

      assert inserted -- ["chain_cursors"] ==
               ~w(key_presences proposals key_attachments oban_jobs proposal_votes proposal_executions)
    end

    # A single pass never asks for more than 10,000 blocks, and the next starts
    # exactly where the last ended.
    test "passes of 10,000 blocks skip nothing", %{fleet: fleet} do
      StubClient.put_chain(
        head(@deployed + 25_000),
        List.flatten([
          decision(1, @deployed + 9_999),
          decision(2, @deployed + 10_000),
          vote(2, "a", :yes, [1], @deployed + 19_999, 0)
        ])
      )

      assert Scanner.step(fleet, StubClient) == :ok
      assert %{next_block: first_end} = Chain.get_cursor!(@fleet)
      assert first_end == @deployed + 10_000
      assert Proposals.highest_number!(@fleet) == 1

      assert Scanner.step(fleet, StubClient) == :ok
      assert %{next_block: second_end} = Chain.get_cursor!(@fleet)
      assert second_end == @deployed + 20_000
      assert Proposals.highest_number!(@fleet) == 2
      assert Chain.get_cursor!(@fleet).proposal_seq == 3

      assert Scanner.step(fleet, StubClient) == :ok
      assert Chain.get_cursor!(@fleet).next_block == @deployed + 25_001

      assert for({_addresses, _topics, from, to} <- StubClient.log_requests(), do: {from, to}) ==
               [
                 {@deployed, @deployed + 9_999},
                 {@deployed + 9_700, @deployed + 9_999},
                 {@deployed + 10_000, @deployed + 19_999},
                 {@deployed + 19_700, @deployed + 19_999},
                 {@deployed + 20_000, @deployed + 25_000}
               ]
    end

    # The proposals hint goes out for a new proposal record only. A key sold
    # or changing hands leaves every tally as it was, since a proposal counts
    # the keys present when it opened.
    test "a pass that makes a new proposal record says so, and one that makes none does not",
         %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))

      mint = ownership(1, "a", @deployed + 1, 0)
      StubClient.put_chain(head(@deployed + 10), [mint])
      assert Scanner.step(fleet, StubClient) == :ok
      refute_received {:proposals_changed, _fleet}

      moved = %{ownership(1, "b", @deployed + 11, 0) | "data" => hex(<<2::256>>)}
      StubClient.put_chain(head(@deployed + 12), [mint, moved])
      assert Scanner.step(fleet, StubClient) == :ok
      refute_received {:proposals_changed, _fleet}

      StubClient.put_chain(head(@deployed + 14), [mint, moved | decision(1, @deployed + 13)])
      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:proposals_changed, @fleet}

      StubClient.put_chain(head(@deployed + 16), [mint, moved | decision(1, @deployed + 13)])
      assert Scanner.step(fleet, StubClient) == :ok
      refute_received {:proposals_changed, _fleet}
    end

    # A piece recorded before the pass stopped the fleet stays recorded, so the
    # hint still goes out for it.
    test "a pass that records something and then stops the fleet still says so", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))

      # Four new logs where the node sends two at most: the first pieces hold
      # proposal 3 and its vote, the last a second execution of proposal 1.
      StubClient.put_chain(
        head(@deployed + 14),
        history() ++
          List.flatten([
            decision(3, @deployed + 11),
            vote(3, "a", :yes, [1], @deployed + 12, 0),
            executed(1, "b", @deployed + 13, 0)
          ]),
        max_logs: 2
      )

      capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 13} end)
      assert Proposals.highest_number!(@fleet) == 3
      assert %{next_block: next_block, rescan_from: stopped_at} = Chain.get_cursor!(@fleet)
      assert {next_block, stopped_at} == {@deployed + 13, @deployed + 13}
      assert_received {:proposals_changed, @fleet}
    end

    # A provider refuses an answer larger than it sends at once. The stretch is
    # asked for in halves until each half is answered, and is recorded in
    # order, on the second reading too. Each answered piece is recorded, with
    # the cursor moved past it, before the next is asked for, so a pass never
    # holds more than one answer.
    test "a stretch the node will not answer whole is read in halves", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), history(),
        max_logs: 2,
        observe: fn -> {Chain.get_cursor!(@fleet).next_block, length(recorded())} end
      )

      assert Scanner.step(fleet, StubClient) == :ok

      halves = [
        {@deployed, @deployed + 10},
        {@deployed, @deployed + 5},
        {@deployed, @deployed + 2},
        {@deployed, @deployed + 1},
        {@deployed + 2, @deployed + 2},
        {@deployed + 3, @deployed + 5},
        {@deployed + 6, @deployed + 10}
      ]

      assert for({_addresses, _topics, from, to} <- StubClient.log_requests(), do: {from, to}) ==
               halves

      assert StubClient.observations() == [
               {@deployed, 0},
               {@deployed, 0},
               {@deployed, 0},
               {@deployed, 0},
               {@deployed + 2, 1},
               {@deployed + 3, 2},
               {@deployed + 6, 4}
             ]

      assert Enum.map(recorded_in_chain_order(), & &1.record_seq) == [1, 2, 3, 4]
      assert Chain.get_cursor!(@fleet).next_block == @deployed + 11

      StubClient.put_chain(head(@deployed + 11), history(), max_logs: 2)
      assert Scanner.step(fleet, StubClient) == :ok

      assert for({_addresses, _topics, from, to} <- StubClient.log_requests(), do: {from, to}) ==
               halves ++ [{@deployed + 11, @deployed + 11}]

      assert Chain.get_cursor!(@fleet).proposal_seq == 4
    end

    # The block holding the proposal has two logs where the node sends one at
    # most. The piece before it stays recorded with the cursor just after it,
    # and the next pass carries on from there with the same numbers.
    test "a single block the node will not answer ends the pass after the last piece recorded",
         %{fleet: fleet} do
      logs = [edits_set(7, true, @deployed + 1, 0) | decision(1, @deployed + 2)]
      StubClient.put_chain(head(@deployed + 10), logs, max_logs: 1)

      assert Scanner.step(fleet, StubClient) ==
               {:error, {:block_unanswered, @deployed + 2, :chain_unavailable}}

      assert recorded() == []
      assert %{next_block: next_block, proposal_seq: 1} = Chain.get_cursor!(@fleet)
      assert next_block == @deployed + 2

      StubClient.put_chain(head(@deployed + 10), logs)
      assert Scanner.step(fleet, StubClient) == :ok

      assert [%{number: 1, record_seq: 2}] = recorded()

      assert [%{record_seq: 1}] =
               Keys.edits_restrictions_in_blocks!(@fleet, @deployed, @deployed + 10,
                 actor: %System{}
               )

      assert %{next_block: next_block, proposal_seq: 2} = Chain.get_cursor!(@fleet)
      assert next_block == @deployed + 11
    end

    # The cursor moves in the transaction that records the piece: when the
    # move is refused, the piece's records go with it.
    test "a piece's records and the cursor move past it are made together", %{fleet: fleet} do
      StubClient.put_chain(%{head(@deployed + 10) | hash: "0xnot-a-block-hash"}, history())

      assert {:error, %Ash.Error.Invalid{}} = Scanner.step(fleet, StubClient)
      assert recorded() == []
      assert %{next_block: @deployed, proposal_seq: 0} = Chain.get_cursor!(@fleet)
    end

    # A node may list a log twice; it is still one event.
    test "a log listed twice is recorded once", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), Enum.flat_map(history(), &[&1, &1]))

      assert Scanner.step(fleet, StubClient) == :ok
      assert Enum.map(recorded_in_chain_order(), & &1.record_seq) == [1, 2, 3, 4]
    end
  end

  describe "when the chain disagrees" do
    # A second reading that disagrees with a record stops the fleet at that
    # block instead of rewriting it, and a stopped fleet is left alone.
    test "a conflicting proposal, renewal or vote stops the fleet at its block and writes nothing",
         %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok
      recorded = recorded()

      for {logs, block} <- [
            {conflicting(history(), 1, &with_word(&1, 1, <<9::256>>)), @deployed + 1},
            {conflicting(history(), 0, &with_word(&1, 0, <<1::256>>)), @deployed + 1},
            {conflicting(
               history(),
               4,
               &%{&1 | "topics" => List.replace_at(&1["topics"], 2, address_word("e"))}
             ), @deployed + 4},
            {conflicting(
               history(),
               4,
               &%{&1 | "topics" => List.replace_at(&1["topics"], 1, hex(<<2::256>>))}
             ), @deployed + 4},
            {conflicting(history(), 4, &%{&1 | "blockHash" => @new_hash}), @deployed + 4},
            {history() ++ decision(2, @deployed + 6), @deployed + 6},
            {history() ++ [executed(1, "b", @deployed + 7, 0)], @deployed + 7}
          ] do
        StubClient.put_chain(head(@deployed + 12), logs)

        assert capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, block} end) =~
                 "Fleet #{@fleet} stopped: the chain disagrees with the record at block #{block}"

        assert recorded() == recorded
        assert %{rescan_from: ^block, proposal_seq: 4} = Chain.get_cursor!(@fleet)

        assert writes_during(fn ->
                 assert Scanner.step(fleet, StubClient) == {:stopped, block}
               end) == []

        Chain.clear_divergence!(@fleet)
      end
    end

    # A recorded event gone from a block whose hash changed is the chain's
    # history changing; gone from a block whose hash matches, it is the node
    # answering inconsistently, and the pass is retried.
    test "a recorded event missing from its block stops the fleet only if the hash changed", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok

      for {index, block} <- [{1, @deployed + 1}, {4, @deployed + 4}, {5, @deployed + 5}] do
        logs = List.delete_at(history(), index)
        StubClient.put_chain(head(@deployed + 12), logs)

        assert Scanner.step(fleet, StubClient) == {:error, {:log_missing_from_block, block}}
        assert %{rescan_from: nil, next_block: next_block} = Chain.get_cursor!(@fleet)
        assert next_block == @deployed + 11

        StubClient.put_chain(head(@deployed + 12), logs, block_hashes: %{block => @new_hash})
        capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, block} end)
        Chain.clear_divergence!(@fleet)
      end
    end
  end

  describe "when the chain's history changes" do
    # A vote moved to another place in a block whose hash changed is found
    # missing from its old place before anything is written, so it is never
    # counted twice.
    test "a vote moved within a changed block stops the fleet before it is recorded again", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok
      recorded = recorded()

      moved =
        conflicting(history(), 4, &%{&1 | "blockHash" => @new_hash, "logIndex" => quantity(1)})

      StubClient.put_chain(head(@deployed + 12), moved,
        block_hashes: %{(@deployed + 4) => @new_hash}
      )

      capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 4} end)
      assert recorded() == recorded
    end

    # Read in pieces, the second reading checks each piece before recording
    # anything new in it. A vote first seen in an early piece is recorded; the
    # execution moved in a later piece stops the fleet there and is not
    # recorded again.
    test "each piece of the second reading is checked before it is recorded", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok
      recorded = recorded()

      late_vote = vote(1, "b", :no, [2], @deployed + 3, 0)

      moved =
        conflicting(history(), 5, &%{&1 | "blockHash" => @new_hash, "logIndex" => quantity(1)})

      StubClient.put_chain(head(@deployed + 10), List.insert_at(moved, 4, late_vote),
        max_logs: 2,
        block_hashes: %{(@deployed + 5) => @new_hash}
      )

      capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 5} end)

      assert [%{block_number: block, log_index: 0, record_seq: 5, choice: :no}] =
               recorded() -- recorded

      assert block == @deployed + 3
    end
  end

  describe "passes at the same time" do
    # Each pass runs on a connection of its own and commits; the records are
    # removed when the test ends, as docs/chain-reader.md corrects a record. A
    # pass that finds the cursor moved on by another ends there, quietly.
    @tag :independent_connections
    test "record each event once, numbered in chain order without gaps", %{fleet: fleet} do
      logs =
        List.flatten([
          decision(1, @deployed + 1),
          decision(2, @deployed + 2),
          decision(3, @deployed + 3),
          vote(1, "a", :yes, [1], @deployed + 4, 0),
          vote(3, "b", :no, [2], @deployed + 4, 1),
          executed(1, "a", @deployed + 5, 0)
        ])

      results = race(fleet, logs, 4)
      assert :ok in results
      assert Enum.all?(results, &(&1 in [:ok, :moved]))

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert Enum.map(recorded_in_chain_order(), & &1.record_seq) == Enum.to_list(1..6)
        assert %{proposal_seq: 6, next_block: next_block} = Chain.get_cursor!(@fleet)
        assert next_block == @deployed + 11
      end)
    end
  end

  describe "when the cursor moves during a pass" do
    # The runbook's correction, made while a pass waits between two pieces of
    # its forward reading: the pass writes nothing more and leaves the
    # operator's cursor, and the next pass reads again from the fork.
    @tag :independent_connections
    test "a pass leaves a correction made during it", %{fleet: fleet} do
      read_history(fleet)

      log =
        with_info_log(fn ->
          assert interrupted_pass(fleet, &past_first_piece?/0, fn -> correct_from(4) end) ==
                   :moved
        end)

      assert log =~ "cursor moved underneath a pass"
      assert %{next_block: next_block, rescan_from: nil} = Chain.get_cursor!(@fleet)
      assert next_block == @deployed + 4
      assert recorded_blocks() == [1, 2]

      StubClient.put_chain(head(@deployed + 140), history() ++ later())
      assert Scanner.step(fleet, StubClient) == :ok
      assert recorded_blocks() == [1, 2, 4, 5, 100, 120, 140]
    end

    # The same correction made while the pass waits in its second reading:
    # the pass does not record again what the operator removed.
    @tag :independent_connections
    test "a pass's second reading leaves a correction made during it", %{fleet: fleet} do
      read_history(fleet)

      assert interrupted_pass(fleet, &first_request?/0, fn -> correct_from(4) end) == :moved
      assert %{next_block: next_block, rescan_from: nil} = Chain.get_cursor!(@fleet)
      assert next_block == @deployed + 4
      assert recorded_blocks() == [1, 2]
    end

    # A fleet stopped while a pass runs is not written to by that pass, even
    # before the operator moves the cursor.
    @tag :independent_connections
    test "a pass writes nothing once the fleet is stopped during it", %{fleet: fleet} do
      read_history(fleet)

      assert interrupted_pass(fleet, &past_first_piece?/0, fn -> stop_at(4) end) == :moved
      assert %{next_block: next_block, rescan_from: rescan_from} = Chain.get_cursor!(@fleet)
      assert {next_block, rescan_from} == {@deployed + 76, @deployed + 4}
      assert recorded_blocks() == [1, 2, 4, 5]
    end

    # The same in the second reading, which would otherwise record again what
    # the operator removed.
    @tag :independent_connections
    test "a pass's second reading writes nothing once the fleet is stopped", %{fleet: fleet} do
      read_history(fleet)

      assert interrupted_pass(fleet, &first_request?/0, fn ->
               stop_at(4)
               remove_from(4)
             end) == :moved

      assert %{next_block: next_block, rescan_from: rescan_from} = Chain.get_cursor!(@fleet)
      assert {next_block, rescan_from} == {@deployed + 11, @deployed + 4}
      assert recorded_blocks() == [1, 2]
    end

    # The second reading holds the cursor from its check until its piece
    # commits, so a stop waits for that piece rather than landing between.
    @tag :independent_connections
    test "a stop waits for the piece the second reading holds", %{fleet: fleet} do
      read_history(fleet)
      parent = self()

      pass =
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          StubClient.put_chain(head(@deployed + 10), history())
          pause_after_first_hold(parent, fn -> Scanner.step(fleet, StubClient) end)
        end)

      assert_receive :held, 10_000

      stop =
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          stop_at(4)
        end)

      assert Task.yield(stop, 300) == nil
      send(pass.pid, :go)
      assert %{rescan_from: rescan_from} = Task.await(stop, 10_000)
      assert rescan_from == @deployed + 4
      assert Task.await(pass, 10_000) == :moved
    end

    # A pass that began before the fleet was stopped and then finds a
    # disagreement of its own keeps whichever stop is earlier.
    @tag :independent_connections
    test "a fleet stopped twice stays stopped at the earlier block", %{fleet: fleet} do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      third = decision(3, @deployed + 14)
      StubClient.put_chain(head(@deployed + 20), history() ++ third)
      assert Scanner.step(fleet, StubClient) == :ok

      disagreeing_at = fn offset, logs ->
        with_log(fn ->
          interrupted_pass(fleet, &first_request?/0, fn -> stop_at(4) end,
            head: @deployed + 20,
            logs: logs,
            max_logs: nil,
            block_hashes: %{(@deployed + offset) => @new_hash}
          )
        end)
      end

      assert {{:stopped, stopped_at}, log} = disagreeing_at.(14, history())
      assert stopped_at == @deployed + 4
      assert log =~ "at block #{@deployed + 14}. It is stopped at block #{@deployed + 4}."
      assert Chain.get_cursor!(@fleet).rescan_from == @deployed + 4

      Chain.clear_divergence!(@fleet)
      without_first = history() -- decision(1, @deployed + 1)
      assert {{:stopped, stopped_at}, _log} = disagreeing_at.(1, without_first ++ third)
      assert stopped_at == @deployed + 1
      assert Chain.get_cursor!(@fleet).rescan_from == @deployed + 1
    end

    # A slow pass whose cursor another pass has since moved on does not move
    # it back.
    @tag :independent_connections
    test "a slow pass does not move back a cursor another pass moved on", %{fleet: fleet} do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      faster = fn ->
        StubClient.put_chain(head(@deployed + 140), history() ++ later())
        assert Scanner.step(fleet, StubClient) == :ok
      end

      assert interrupted_pass(fleet, &first_request?/0, faster, head: @deployed + 10) == :moved
      assert Chain.get_cursor!(@fleet).next_block == @deployed + 141
      assert recorded_blocks() == [1, 2, 4, 5, 100, 120, 140]
    end
  end

  describe "the record tables" do
    test "refuse every change, delete and emptying", %{fleet: fleet} do
      more = [
        cancelled(2, "e", @deployed + 6, 0),
        edits_set(7, true, @deployed + 6, 1),
        paid("a", "c", @deployed + 7, 0, 10)
      ]

      StubClient.put_chain(head(@deployed + 10), history() ++ more)
      assert Scanner.step(fleet, StubClient) == :ok

      for table <- @record_tables,
          {sql, params} <- [
            {"UPDATE keyfleet_app.#{table} SET log_index = $1", [99]},
            {"DELETE FROM keyfleet_app.#{table}", []},
            {"TRUNCATE keyfleet_app.#{table} CASCADE", []}
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 Repo.query(sql, params, mode: :savepoint),
               sql
      end

      assert length(recorded()) == 5
      assert length(Treasury.recorded_in_blocks!(@fleet, @deployed, @deployed + 10)) == 1
    end
  end

  describe "reading logs" do
    # Anything not exactly as the contracts emit it refuses the stretch.
    test "only logs in the contracts' exact encoding are read", %{fleet: fleet} do
      [renewal, created] =
        decision(1, @deployed + 1, calls: [{"c", @max_uint256, <<0xDE, 0xAD, 0xBE>>}])

      vote = vote(1, "a", :yes, [1, 2], @deployed + 2, 0)
      cancelled = cancelled(1, "e", @deployed + 3, 0)
      executed = executed(1, "c", @deployed + 3, 1)
      edits = edits_set(7, true, @deployed + 3, 2)
      cleared = cleared(5, @deployed + 3, 3)
      mint = ownership(1, "a", @deployed + 4, 0)
      paid = paid("a", "c", @deployed + 4, 1, 10)
      claimed = claimed("a", "b", "c", @deployed + 4, 2, 10)
      valid = [renewal, created, vote, cancelled, executed, edits, cleared, mint, paid, claimed]

      assert {:ok, records} =
               Logs.decode(valid, fleet, StubClient.regent_buyer(), @deployed, @deployed + 10)

      assert Enum.map(records, &elem(&1, 0)) ==
               ~w(presence proposal ballot cancellation execution edits_restriction presence
                  ownership treasury_event treasury_event)a

      assert {:proposal, proposal} = Enum.at(records, 1)
      assert %{number: 1, author_key: 1, opening_count: 3, open_revision: 1} = proposal
      assert proposal.opened_at == block_time(@deployed + 1)
      assert [%{target: target, value: @max_uint256, data: "0xdeadbe"}] = proposal.calls
      assert target == wallet("c")

      data = &(&1["data"] |> String.trim_leading("0x") |> Base.decode16!(case: :lower))
      topic = &List.replace_at(&1["topics"], &2, &3)
      # The one call's words: its target, value, the offset of its data, its
      # length, and the data padded to a word.
      call = 8 * 32 + 64

      for {index, broken} <- [
            {1, %{created | "address" => wallet("8")}},
            {1, %{created | "address" => @contract}},
            {1, %{created | "topics" => topic.(created, 0, @ownership)}},
            {1, %{created | "topics" => topic.(created, 0, "0x" <> String.duplicate("0", 64))}},
            {1, %{created | "topics" => topic.(created, 1, hex(<<0::256>>))}},
            {1, %{created | "topics" => topic.(created, 1, hex(<<1::1, 0::255>>))}},
            {1, %{created | "topics" => topic.(created, 1, hex(<<@max_bigint + 1::256>>))}},
            {1, %{created | "topics" => topic.(created, 2, hex(<<0::256>>))}},
            {1, %{created | "topics" => topic.(created, 3, hex(<<1::96, 0::160>>))}},
            {1, %{created | "topics" => Enum.drop(created["topics"], -1)}},
            {1, %{created | "topics" => topic.(created, 3, "0x00")}},
            {1, %{created | "data" => hex(data.(created) <> <<0::256>>)}},
            {1, %{created | "data" => hex(binary_part(data.(created), 0, 127))}},
            {1, %{created | "data" => "0x0"}},
            {1, %{created | "data" => hex(patch(data.(created), 64, <<@max_bigint + 1::256>>))}},
            {1, %{created | "data" => hex(patch(data.(created), 160, <<4_294_967_296::256>>))}},
            {1,
             %{created | "data" => hex(patch(data.(created), 192, <<281_474_976_710_656::256>>))}},
            {1, %{created | "data" => hex(patch(data.(created), 224, <<288::256>>))}},
            {1, %{created | "data" => hex(patch(data.(created), 256, <<2::256>>))}},
            {1, %{created | "data" => hex(patch(data.(created), 288, <<64::256>>))}},
            {1, %{created | "data" => hex(patch(data.(created), call, <<1::96, 0::160>>))}},
            {1, %{created | "data" => hex(patch(data.(created), call + 64, <<64::256>>))}},
            {1, %{created | "data" => hex(patch(data.(created), call + 96, <<33::256>>))}},
            {1, %{created | "data" => hex(patch(data.(created), call + 131, <<1>>))}},
            {1, %{created | "blockNumber" => quantity(@deployed + 11)}},
            {1, %{created | "blockNumber" => "0x-1"}},
            {1, %{created | "logIndex" => "0x"}},
            {1, %{created | "logIndex" => "0x-1"}},
            {1, %{created | "logIndex" => "0x+0"}},
            {1, %{created | "blockHash" => "0x" <> String.duplicate("g", 64)}},
            {1, %{created | "transactionHash" => "0x01"}},
            {0, %{renewal | "data" => hex(patch(data.(renewal), 64, <<0::256>>))}},
            {0, %{renewal | "data" => hex(patch(data.(renewal), 0, <<@max_bigint + 1::256>>))}},
            {0, %{renewal | "data" => hex(binary_part(data.(renewal), 0, 64))}},
            {0, %{renewal | "topics" => topic.(renewal, 1, hex(<<0::256>>))}},
            {2, %{vote | "data" => hex(patch(data.(vote), 0, <<0::256>>))}},
            {2, %{vote | "data" => hex(patch(data.(vote), 0, <<4::256>>))}},
            {2, %{vote | "data" => hex(patch(data.(vote), 0, <<1::1, 0::254, 1::1>>))}},
            {2,
             %{vote | "data" => hex(patch(data.(vote), 64, <<0::256>>) |> binary_part(0, 96))}},
            {2, %{vote | "data" => hex(patch(data.(vote), 96, <<0::256>>))}},
            {2, %{vote | "data" => hex(patch(data.(vote), 96, <<1::1, 0::255>>))}},
            {2, %{vote | "data" => hex(patch(data.(vote), 64, <<3::256>>))}},
            {2, %{vote | "data" => hex(data.(vote) <> <<0::256>>)}},
            {3, %{cancelled | "data" => hex(<<0::256>>)}},
            {3, %{cancelled | "topics" => Enum.drop(cancelled["topics"], -1)}},
            {4, %{executed | "data" => hex(<<0::256>>)}},
            {5, %{edits | "data" => hex(<<2::256>>)}},
            {5, %{edits | "data" => hex(<<1::256, 0::256>>)}},
            {5, %{edits | "topics" => topic.(edits, 1, hex(<<0::256>>))}},
            {6, %{cleared | "data" => hex(<<0::256>>)}},
            {7, %{mint | "topics" => topic.(mint, 2, hex(<<1::96, 0::160>>))}},
            {7, %{mint | "topics" => topic.(mint, 3, hex(<<1::96, 0::160>>))}},
            {8, %{paid | "address" => @votes}},
            {8, %{paid | "address" => @contract}},
            {8, %{paid | "data" => hex(data.(paid) <> <<0::256>>)}},
            {8, %{paid | "data" => hex(patch(data.(paid), 0, <<4_294_967_296::256>>))}},
            {8, %{paid | "data" => hex(<<>>)}},
            {8, %{paid | "topics" => topic.(paid, 2, hex(<<1::96, 0::160>>))}},
            {8, %{paid | "topics" => Enum.drop(paid["topics"], -1)}},
            {9, %{claimed | "address" => @treasury}},
            {9, %{claimed | "topics" => topic.(claimed, 3, hex(<<1::96, 0::160>>))}}
          ] do
        assert Logs.decode(
                 List.replace_at(valid, index, broken),
                 fleet,
                 StubClient.regent_buyer(),
                 @deployed,
                 @deployed + 10
               ) ==
                 {:error, {:unreadable_log, broken["transactionHash"], broken["logIndex"]}},
               inspect(broken)
      end
    end
  end

  # Two proposals, a vote and an execution, numbered 1 to 4, each proposal
  # after its author key's renewal: six logs.
  defp history do
    List.flatten([
      decision(1, @deployed + 1),
      decision(2, @deployed + 2),
      vote(1, "a", :yes, [1], @deployed + 4, 0),
      executed(1, "a", @deployed + 5, 0)
    ])
  end

  # A proposal; the protocol share sent from the fleet contract; a payment
  # and a daily split from the treasury; a claim from the reward ledger.
  defp money_history do
    List.flatten([
      decision(1, @deployed + 1),
      log(
        @contract,
        [@protocol_share, address_word_bytes("f")],
        <<@max_uint256::256>>,
        @deployed + 1,
        2
      ),
      paid("a", "c", @deployed + 2, 0, @max_uint256),
      split_allocated("a", @deployed + 3, 0, [1_000, 10, 100]),
      claimed("a", "b", "c", @deployed + 3, 1, 50)
    ])
  end

  defp conflicting(logs, index, change), do: List.update_at(logs, index, change)

  # `log` with its data word `index` replaced by `word`.
  defp with_word(log, index, word) do
    data = log["data"] |> String.trim_leading("0x") |> Base.decode16!(case: :lower)
    %{log | "data" => hex(patch(data, 32 * index, word))}
  end

  defp at(log, log_index), do: %{log | "logIndex" => quantity(log_index)}

  defp recorded_in_chain_order,
    do: Enum.sort_by(recorded(), &{&1.block_number, &1.log_index})

  defp recorded do
    Enum.sort_by(
      Proposals.recorded_in_blocks!(@fleet, 0, @deployed + 100_000),
      &{&1.__struct__, &1.record_seq}
    )
  end

  # Proposal `number` by key `:author` (1), proposed by 0xff…, with `:calls`
  # (none) as `{target character, value, data}`, opened at the block's time
  # with `:opening` (3) keys present: its author key's renewal at log
  # `:at` (0) and the proposal just after it, in one transaction.
  defp decision(number, block, opts \\ []) do
    at = Keyword.get(opts, :at, 0)
    author = Keyword.get(opts, :author, 1)
    opened = DateTime.to_unix(block_time(block))
    closes = opened + @day

    # A decision can be carried out as soon as its vote closes.
    head =
      <<1000 + number::256, number::256, closes::256, closes::256,
        closes + @execution_window::256, Keyword.get(opts, :opening, 3)::256, 1::256,
        8 * 32::256>>

    [
      present(author, block, at),
      log(
        @votes,
        [@created, <<number::256>>, key(author), address_word_bytes("f")],
        head <> calls(Keyword.get(opts, :calls, [])),
        block,
        at + 1
      )
    ]
  end

  # `(address, uint256, bytes)[]` as the contract encodes it.
  defp calls(calls) do
    encoded =
      for {target, value, data} <- calls do
        padded = 32 * div(byte_size(data) + 31, 32)

        address_word_bytes(target) <>
          <<value::256, 96::256, byte_size(data)::256>> <>
          data <> <<0::size(8 * (padded - byte_size(data)))>>
      end

    {offsets, _end} =
      Enum.map_reduce(encoded, 32 * length(calls), &{<<&2::256>>, &2 + byte_size(&1)})

    <<length(calls)::256>> <> Enum.join(offsets) <> Enum.join(encoded)
  end

  # Key `token_id` renewed at the block's time, in its first ownership.
  defp present(token_id, block, log_index) do
    data = <<DateTime.to_unix(block_time(block))::256, block::256, 1::256>>
    log(@votes, [@present, key(token_id)], data, block, log_index)
  end

  defp cleared(token_id, block, log_index),
    do: log(@votes, [@presence_cleared, key(token_id)], <<>>, block, log_index)

  @choices %{yes: 1, no: 2, abstain: 3}

  defp vote(number, voter, choice, token_ids, block, log_index) do
    data =
      <<Map.fetch!(@choices, choice)::256, 64::256, length(token_ids)::256>> <>
        for(id <- token_ids, into: <<>>, do: key(id))

    log(@votes, [@ballot, <<number::256>>, address_word_bytes(voter)], data, block, log_index)
  end

  defp cancelled(number, by, block, log_index),
    do: log(@votes, [@cancelled, <<number::256>>, address_word_bytes(by)], <<>>, block, log_index)

  defp executed(number, executor, block, log_index) do
    log(
      @votes,
      [@executed, <<number::256>>, address_word_bytes(executor)],
      <<>>,
      block,
      log_index
    )
  end

  defp edits_set(token_id, restricted, block, log_index) do
    flag = if restricted, do: 1, else: 0
    log(@votes, [@edits_set, key(token_id)], <<flag::256>>, block, log_index)
  end

  # `amount` of asset 0x`asset`… paid by the treasury to 0x`to`…, 1.5% of
  # what it held.
  defp paid(asset, to, block, log_index, amount) do
    log(
      @treasury,
      [@paid, address_word_bytes(asset), address_word_bytes(to)],
      <<15_000::256, amount::256>>,
      block,
      log_index
    )
  end

  # The daily split of asset 0x`asset`…, as [balance, per key, keys].
  defp split_allocated(asset, block, log_index, fields) do
    log(
      @treasury,
      [@split_allocated, address_word_bytes(asset)],
      for(field <- fields, into: <<>>, do: <<field::256>>),
      block,
      log_index
    )
  end

  defp claimed(asset, account, by, block, log_index, amount) do
    log(
      @rewards,
      [@claimed, address_word_bytes(asset), address_word_bytes(account), address_word_bytes(by)],
      <<amount::256>>,
      block,
      log_index
    )
  end

  defp ownership(token_id, owner, block, log_index) do
    log(
      @keys,
      [@ownership, key(token_id), <<0::256>>, address_word_bytes(owner)],
      <<1::256>>,
      block,
      log_index
    )
  end

  # The fleet's Key `token_id` by its id in the Key collection, as every log names it.
  defp key(token_id), do: <<ChainHelpers.onchain_id(@fleet, token_id)::256>>

  defp log(address, [topic0 | words], data, block, log_index) do
    %{
      "address" => address,
      "topics" => [topic0 | Enum.map(words, &hex/1)],
      "data" => hex(data),
      "blockNumber" => quantity(block),
      "blockHash" => "0x" <> String.duplicate("b", 64),
      "transactionHash" => transaction(block),
      "logIndex" => quantity(log_index)
    }
  end

  defp patch(data, at, bytes),
    do:
      binary_part(data, 0, at) <>
        bytes <> binary_part(data, at + byte_size(bytes), byte_size(data) - at - byte_size(bytes))

  defp address_word(character), do: hex(address_word_bytes(character))

  defp address_word_bytes(character),
    do: <<0::96>> <> Base.decode16!(String.duplicate(character, 40), case: :mixed)

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp quantity(value), do: "0x" <> Integer.to_string(value, 16)
  defp transaction(block), do: "0x" <> String.pad_leading(Integer.to_string(block, 16), 64, "0")
  defp wallet(character), do: "0x" <> String.duplicate(character, 40)
  defp block_time(block), do: DateTime.from_unix!(1_700_000_000 + 2 * block)

  defp head(number),
    do: %{
      number: number,
      hash: "0x" <> String.duplicate("f", 64),
      timestamp: block_time(number),
      base_fee: 0
    }

  # Runs `passes` passes over `logs` at once, each on a connection of its own.
  defp race(fleet, logs, passes) do
    parent = self()

    callers =
      for _pass <- 1..passes do
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          StubClient.put_chain(head(@deployed + 10), logs)
          send(parent, {:ready, self()})

          receive do
            :go -> Scanner.step(fleet, StubClient)
          after
            10_000 -> raise "pass barrier timed out"
          end
        end)
      end

    for _caller <- callers, do: assert_receive({:ready, _pid}, 10_000)
    Enum.each(callers, &send(&1.pid, :go))
    Task.await_many(callers, 30_000)
  end

  # A first pass over `history/0`, committed on this test's own connection.
  defp read_history(fleet) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    StubClient.put_chain(head(@deployed + 10), history())
    assert Scanner.step(fleet, StubClient) == :ok
  end

  # A vote, a decision and a vote on it, well after `history/0`.
  defp later do
    List.flatten([
      vote(1, "b", :no, [2], @deployed + 100, 0),
      decision(3, @deployed + 120),
      vote(3, "b", :yes, [2], @deployed + 140, 0)
    ])
  end

  # Runs a pass on a connection of its own and holds it at the first log
  # request for which `pause?` is true until `during` has run here. The chain
  # is `history/0` and `later/0` up to block 140, two logs to an answer,
  # unless `opts` name the `:head`, the `:logs`, `:max_logs` or `:block_hashes`.
  defp interrupted_pass(fleet, pause?, during, opts \\ []) do
    parent = self()
    head = Keyword.get(opts, :head, @deployed + 140)
    logs = Keyword.get(opts, :logs, history() ++ later())

    pass =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        StubClient.put_chain(head(head), logs,
          max_logs: Keyword.get(opts, :max_logs, 2),
          block_hashes: Keyword.get(opts, :block_hashes, %{}),
          observe: fn ->
            if pause?.() and not Process.get(:paused, false) do
              Process.put(:paused, true)
              send(parent, :paused)
              receive do: (:go -> :ok)
            end
          end
        )

        Scanner.step(fleet, StubClient)
      end)

    assert_receive :paused, 10_000
    during.()
    send(pass.pid, :go)
    Task.await(pass, 30_000)
  end

  # Runs `fun`, halting it just after it first locks the cursor, inside that
  # transaction, until the test says go.
  defp pause_after_first_hold(parent, fun) do
    pass = self()
    handler = "proposals-chain-test-hold"

    :telemetry.attach(
      handler,
      [:keyfleet, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == pass and meta.query =~ "FOR UPDATE" and not Process.get(:held, false) do
          Process.put(:held, true)
          send(parent, :held)
          receive do: (:go -> :ok)
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end
  end

  defp first_request?, do: StubClient.log_requests() == []

  defp past_first_piece?, do: Chain.get_cursor!(@fleet).next_block > @deployed + 11

  defp recorded_blocks, do: Enum.map(recorded_in_chain_order(), &(&1.block_number - @deployed))

  defp stop_at(offset),
    do:
      Chain.flag_divergence!(Chain.get_cursor!(@fleet), %{block: @deployed + offset},
        actor: %System{}
      )

  # The fleet stopped at block `offset` and corrected from there as
  # docs/chain-reader.md describes, then the stop cleared.
  defp correct_from(offset) do
    stop_at(offset)
    remove_from(offset)

    Repo.query!(
      "UPDATE keyfleet_app.chain_cursors SET next_block = $2 " <>
        "WHERE fleet_id = $1 AND rescan_from IS NOT NULL",
      [@fleet, @deployed + offset]
    )

    Chain.clear_divergence!(@fleet)
  end

  # The records from block `offset` on removed as docs/chain-reader.md does.
  defp remove_from(offset) do
    Repo.transaction(fn ->
      for table <- @record_tables do
        Repo.query!("ALTER TABLE keyfleet_app.#{table} DISABLE TRIGGER immutable_#{table}")

        Repo.query!(
          "DELETE FROM keyfleet_app.#{table} WHERE fleet_id = $1 AND block_number >= $2",
          [@fleet, @deployed + offset]
        )

        Repo.query!("ALTER TABLE keyfleet_app.#{table} ENABLE TRIGGER immutable_#{table}")
      end
    end)
  end

  # Info is below the suite's log level; the pass logs its end there.
  defp with_info_log(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: level)
    end
  end

  # Removes what the passes committed, the way docs/chain-reader.md corrects a
  # record: the refusing triggers are off only inside this transaction.
  defp remove_committed_records do
    Repo.transaction(fn ->
      for table <- @record_tables do
        Repo.query!("ALTER TABLE keyfleet_app.#{table} DISABLE TRIGGER immutable_#{table}")
        Repo.query!("DELETE FROM keyfleet_app.#{table} WHERE fleet_id = $1", [@fleet])
        Repo.query!("ALTER TABLE keyfleet_app.#{table} ENABLE TRIGGER immutable_#{table}")
      end

      Repo.query!("DELETE FROM keyfleet_app.chain_cursors WHERE fleet_id = $1", [@fleet])

      unbound = Enum.map_join(Fleet.deployment_fields(), ", ", &"#{&1} = NULL")
      Repo.query!("UPDATE keyfleet_app.fleets SET #{unbound} WHERE id = $1", [@fleet])
    end)
  end

  # The tables written by INSERT while `fun` ran in this process, in order.
  defp inserts_during(fun) do
    for "INSERT INTO " <> rest <- writes_during(fun),
        do: rest |> String.split(~s("), trim: true) |> Enum.at(2)
  end

  # The statements that changed the database while `fun` ran in this process.
  defp writes_during(fun) do
    test_pid = self()
    handler = "proposals-chain-test-writes"

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

  defp deploy! do
    ChainHelpers.deploy!(@fleet, %{
      manager_address: @contract,
      rewards_address: @rewards,
      votes_address: @votes,
      treasury_address: @treasury,
      shards_address: @shards,
      deployed_block: @deployed
    })
  end
end

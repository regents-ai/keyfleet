defmodule Keyfleet.ProposalsChainTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain
  alias Keyfleet.Chain.{LaunchEnvelopes, Logs, Scanner, StubClient}
  alias Keyfleet.CommittedCatalog
  alias Keyfleet.Fleets
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.Repo
  alias Keyfleet.Treasury
  alias Keyfleet.WorkspaceFixtures

  # Other suites commit Syndicate keys outside the sandbox; Accelerant from a
  # high block keeps these readings to what each test puts on the chain.
  @fleet "fleet_tech_accelerant"
  @contract "0x" <> String.duplicate("7", 40)
  @votes "0x" <> String.duplicate("9", 40)
  @deployed 5_000_000
  @new_hash "0x" <> String.duplicate("e", 64)
  @max_uint256 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935
  @max_bigint 9_223_372_036_854_775_807

  # Pinned from `cast keccak` of each event signature, and against the
  # contracts in contracts/test/KeyfleetVotesTopics.t.sol.
  @ownership "0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1"
  @revealed "0x6d40ad718cfc10342a32c87c9bc44d44a37c6e9a218a67e550d1631035b05f0e"
  @created "0x29ea7482e80123243d4237b155637f07d8868001408424ed3934ec29e65ab647"
  @autolaunch "0x5814e7293d336521e3e8dbd0b0a4480cca203df470b8637a8fa51b2cced3f513"
  @pay "0x1da5b725f356ce5da6ebeddfa1d1b808edc6cc42c21738f9023ad8a0d59f96be"
  @vote "0x707650471b3fbad25e3f07d77bd835851846b71eb8c47598be05f07de77aed53"
  @withdrawn "0x72cf7f3b692fcac70eec735cf686ea37d566b98a1a37e8f13e755db5b4d0c2c4"
  @executed "0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24"
  @income_recognized "0x0cd4e99e415e30cc448d0a20beb2e3d8e1476362e9da4a494959dc6817a3fb13"
  @shared_money_recognized "0x499f2f2f2d8bb29705b19416e4ed4b160f0dfbfbe5a2bf3bc0f73d6b73e12fa7"
  @graduation_booked "0xd8c9a3e20faa52b5fa537458d4e055db2d5d91ef401d3120ec549f8724b42355"
  @vesting_booked "0xee00fd5e75d11a67d01f1e2c820557fb28f1e211c8119f94759d4f5b470eeee2"
  @budget_paid "0x49fd68af19bac5da72e7e1622c38c15d88d83df2eb98a0c9b2a03b81b9a74e9e"

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
    # One request per stretch of blocks covers both contracts and every
    # event, and each kind lands with exactly the fields its logs carry.
    test "each kind, its votes and its execution are recorded in chain order", %{fleet: fleet} do
      envelope = "0x" <> String.duplicate("a1", 32)

      StubClient.put_chain(
        head(@deployed + 10),
        List.flatten([
          decision(1, @deployed + 1, text: "Ship the docs"),
          autolaunch(2, @deployed + 3, 3, envelope_hash: envelope),
          vote(1, "a", true, [1, 2, 3], @deployed + 4, 0),
          vote(1, "b", false, [4], @deployed + 4, 1),
          executed(1, "c", @deployed + 5, 0)
        ])
      )

      assert Scanner.step(fleet, StubClient) == :ok

      assert StubClient.log_requests() == [
               {[@contract, @votes],
                [
                  @ownership,
                  @revealed,
                  @created,
                  @autolaunch,
                  @pay,
                  @vote,
                  @withdrawn,
                  @executed,
                  @income_recognized,
                  @shared_money_recognized,
                  @graduation_booked,
                  @vesting_booked,
                  @budget_paid
                ], @deployed, @deployed + 10}
             ]

      decision = Proposals.get_proposal!(@fleet, 1)

      assert %{
               kind: :decision,
               proposer: proposer,
               opened_block: opened_block,
               digest: nil,
               text: "Ship the docs",
               text_bytes: 13,
               envelope_hash: nil,
               asset: nil,
               amount: nil,
               recipient: nil,
               block_number: block,
               log_index: 0,
               record_seq: 1
             } = decision

      assert proposer == wallet("f")
      assert block == @deployed + 1
      assert opened_block == @deployed + 1
      assert decision.text_sha256 == sha256("Ship the docs")
      assert decision.transaction_hash == String.downcase(transaction(@deployed + 1))

      launch = Proposals.get_proposal!(@fleet, 2)

      assert %{kind: :autolaunch, envelope_hash: ^envelope, digest: ^envelope} = launch
      assert %{text: nil, text_bytes: nil, text_sha256: nil} = launch
      assert %{asset: nil, amount: nil, recipient: nil} = launch
      assert %{log_index: 3, record_seq: 2} = launch

      assert [yes, no] =
               @fleet
               |> Proposals.votes_recorded_in_blocks!(@deployed, @deployed + 10, actor: %System{})
               |> Enum.sort_by(& &1.record_seq)

      assert %{support: true, token_ids: [1, 2, 3], record_seq: 3} = yes
      assert %{support: false, token_ids: [4], record_seq: 4, log_index: 1} = no
      assert yes.voter == wallet("a")
      assert yes.proposal_id == decision.id

      assert [execution] =
               Proposals.executions_recorded_in_blocks!(@fleet, @deployed, @deployed + 10,
                 actor: %System{}
               )

      assert %{proposal_id: proposal_id, record_seq: 5} = execution
      assert proposal_id == decision.id
      assert execution.executor == wallet("c")

      # One vote per key: three keys for, one against.
      tallied = Ash.load!(decision, [:yes_keys, :no_keys, :executed?])
      assert %{yes_keys: 3, no_keys: 1} = tallied
      assert tallied.executed?
      refute Ash.load!(launch, :executed?).executed?

      assert Chain.get_cursor!(@fleet).proposal_seq == 5
    end

    # A withdrawn vote takes its keys off their side, a key that votes again
    # counts again, and a withdrawal naming no keys is not one the contract
    # emits.
    test "a withdrawn vote counts for neither side until the key votes again", %{fleet: fleet} do
      logs =
        List.flatten([
          decision(1, @deployed + 1),
          vote(1, "a", true, [1, 2, 3], @deployed + 2, 0),
          vote(1, "b", false, [4], @deployed + 2, 1),
          withdrawn(1, "a", [2, 4], @deployed + 3, 0)
        ])

      StubClient.put_chain(head(@deployed + 10), logs)

      assert Scanner.step(fleet, StubClient) == :ok
      decision = Proposals.get_proposal!(@fleet, 1)
      assert %{yes_keys: 2, no_keys: 0} = Ash.load!(decision, [:yes_keys, :no_keys])

      assert %{support: nil, token_ids: [2, 4], record_seq: 4} =
               @fleet
               |> Proposals.votes_recorded_in_blocks!(@deployed, @deployed + 10, actor: %System{})
               |> Enum.max_by(& &1.record_seq)

      StubClient.put_chain(
        head(@deployed + 20),
        logs ++ [vote(1, "a", false, [2], @deployed + 11, 0)]
      )

      assert Scanner.step(fleet, StubClient) == :ok
      assert %{yes_keys: 2, no_keys: 1} = Ash.load!(decision, [:yes_keys, :no_keys])

      assert Logs.decode(
               [withdrawn(1, "a", [], @deployed + 21, 0)],
               fleet,
               @deployed,
               @deployed + 30
             ) ==
               {:error, {:unreadable_log, transaction(@deployed + 21), quantity(0)}}
    end

    # A payment keeps its asset, amount, recipient and reason, and its
    # tally counts one vote per key.
    test "a payment proposal is recorded with everything it pays and its reason", %{
      fleet: fleet
    } do
      StubClient.put_chain(
        head(@deployed + 10),
        List.flatten([
          pay(1, @deployed + 1, 0, amount: @max_uint256, text: "Pay the auditor"),
          vote(1, "a", true, [1, 2], @deployed + 2, 0),
          vote(1, "b", true, [3], @deployed + 2, 1),
          vote(1, "c", false, [4, 5, 6, 7], @deployed + 3, 0)
        ])
      )

      assert Scanner.step(fleet, StubClient) == :ok

      paid = Proposals.get_proposal!(@fleet, 1)

      assert %{
               kind: :pay,
               digest: nil,
               text: "Pay the auditor",
               text_bytes: 15,
               envelope_hash: nil,
               log_index: 0,
               record_seq: 1
             } = paid

      assert paid.asset == wallet("a")
      assert paid.recipient == wallet("b")
      assert paid.text_sha256 == sha256("Pay the auditor")
      assert Decimal.equal?(paid.amount, @max_uint256)

      assert %{yes_keys: 3, no_keys: 4} = Ash.load!(paid, [:yes_keys, :no_keys])
    end

    # What the budget takes in, the income paid to the keys and budget
    # payments come from the fleet contract, keep every amount as the contract
    # gave it and are numbered with the proposal records, so the proposals
    # hint goes out for them too.
    test "budget receipts, income and payments are recorded with the proposal records",
         %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))
      logs = budget_history()
      StubClient.put_chain(head(@deployed + 10), logs)

      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:proposals_changed, @fleet}

      assert [recognized, graduation, income, vesting, payment] =
               @fleet
               |> Treasury.recorded_in_blocks!(@deployed, @deployed + 10)
               |> Enum.sort_by(& &1.record_seq)

      assert %{kind: :recognized, record_seq: 2, block_number: recognized_block, log_index: 1} =
               recognized

      assert recognized_block == @deployed + 1
      assert recognized.asset == wallet("e")
      assert Decimal.equal?(recognized.amount, @max_uint256)

      assert %{kind: :graduation, record_seq: 3, log_index: 2} = graduation
      assert graduation.asset == wallet("9")
      assert Decimal.equal?(graduation.amount, 100)

      assert %{record_seq: 4, block_number: income_block, log_index: 0} = income
      assert income_block == @deployed + 2
      assert income.asset == wallet("a") and income.caller == wallet("f")
      assert Decimal.equal?(income.amount, @max_uint256)

      # The escrow's running total is on the log; the amount it released is kept.
      assert %{kind: :vesting, record_seq: 5, log_index: 1} = vesting
      assert vesting.asset == wallet("b")
      assert Decimal.equal?(vesting.amount, 5)

      assert %{record_seq: 6, log_index: 1} = payment
      assert payment.asset == wallet("a") and payment.recipient == wallet("c")
      assert Decimal.equal?(payment.amount, 700)
      assert Decimal.equal?(payment.share, 350)
      assert Decimal.equal?(payment.matched, 1_050)

      assert Chain.get_cursor!(@fleet).proposal_seq == 6

      # Read again, nothing is made twice or numbered again.
      StubClient.put_chain(head(@deployed + 12), logs)
      assert Scanner.step(fleet, StubClient) == :ok
      assert length(Treasury.recorded_in_blocks!(@fleet, @deployed, @deployed + 12)) == 5
      assert Chain.get_cursor!(@fleet).proposal_seq == 6
    end

    # A budget log read again with other amounts is the chain disagreeing with
    # the record; gone from a block whose hash changed, it is the same.
    test "a budget record the chain no longer agrees with stops the fleet at its block", %{
      fleet: fleet
    } do
      income = income("a", @deployed + 2, 0, 10)
      paid = budget_paid("a", "c", @deployed + 4, 0, [1, 1, 0])
      StubClient.put_chain(head(@deployed + 10), [income, paid])
      assert Scanner.step(fleet, StubClient) == :ok

      for {logs, opts, block} <- [
            {[income("a", @deployed + 2, 0, 9), paid], [], @deployed + 2},
            {[income, budget_paid("a", "d", @deployed + 4, 0, [1, 1, 0])], [], @deployed + 4},
            {[income], [block_hashes: %{(@deployed + 4) => @new_hash}], @deployed + 4}
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
      [created, payload] = autolaunch(1, @deployed + 2, 0)
      [pay_created, pay_payload] = pay(1, @deployed + 2, 0)

      created_at = {String.downcase(transaction(@deployed + 2)), 0}
      payload_at = {String.downcase(transaction(@deployed + 2)), 1}

      for {logs, reason} <- [
            {[created], Tuple.insert_at(created_at, 0, :payload_missing)},
            {[payload], Tuple.insert_at(payload_at, 0, :payload_without_proposal)},
            {[pay_created], Tuple.insert_at(created_at, 0, :payload_missing)},
            {[pay_payload], Tuple.insert_at(payload_at, 0, :payload_without_proposal)},
            {[created, pay_payload], Tuple.insert_at(created_at, 0, :payload_missing)},
            {[pay_created, payload], Tuple.insert_at(created_at, 0, :payload_missing)},
            {[created, %{payload | "transactionHash" => transaction(1)}],
             Tuple.insert_at(created_at, 0, :payload_missing)},
            {[created, payload_for(payload, 2)],
             Tuple.insert_at(created_at, 0, :payload_missing)},
            {[decision(1, @deployed + 2), payload],
             Tuple.insert_at(payload_at, 0, :payload_without_proposal)},
            {[decision(1, @deployed + 2), %{decision(1, @deployed + 2) | "data" => "0x"}],
             {:unreadable_log, transaction(@deployed + 2), "0x0"}},
            {[decision(1, @deployed + 2), text_of(decision(1, @deployed + 2), "Other")],
             Tuple.insert_at(created_at, 0, :conflicting_logs)},
            {[
               decision(1, @deployed + 2),
               %{decision(1, @deployed + 2) | "transactionHash" => transaction(1)}
             ], Tuple.insert_at(created_at, 0, :conflicting_logs)},
            {[
               decision(1, @deployed + 2),
               %{decision(1, @deployed + 2) | "blockNumber" => quantity(@deployed + 3)}
             ], Tuple.insert_at(created_at, 0, :conflicting_logs)},
            {[decision(2, @deployed + 2)], {:proposal_number_skipped, @deployed + 2}},
            {[decision(1, @deployed + 2), decision(3, @deployed + 3)],
             {:proposal_number_skipped, @deployed + 3}},
            {[vote(1, "a", true, [1], @deployed + 2, 0), decision(1, @deployed + 3)],
             {:proposal_not_recorded, @deployed + 2}},
            {[decision(1, @deployed + 2), executed(2, "c", @deployed + 3, 0)],
             {:proposal_not_recorded, @deployed + 3}}
          ] do
        StubClient.put_chain(head(@deployed + 10), [mint | List.flatten(logs)])

        assert Scanner.step(fleet, StubClient) == {:error, reason}, inspect(logs)
        assert Keys.keys_in_fleet!(@fleet).results == []
        assert Proposals.highest_number!(@fleet) == 0
        assert %{next_block: @deployed, proposal_seq: 0} = Chain.get_cursor!(@fleet)
      end

      StubClient.put_chain(head(@deployed + 10), [mint, decision(1, @deployed + 2)])
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

    test "text over 64 KiB is cut there, keeping its full length and hash, bytes as they are", %{
      fleet: fleet
    } do
      text = <<0xFF, 0xFE, 0x00>> <> :binary.copy("é", 40_000)
      StubClient.put_chain(head(@deployed + 10), [decision(1, @deployed + 1, text: text)])

      assert Scanner.step(fleet, StubClient) == :ok

      proposal = Proposals.get_proposal!(@fleet, 1)
      assert proposal.text == binary_part(text, 0, 65_536)
      assert proposal.text_bytes == 80_003
      assert proposal.text_sha256 == sha256(text)
    end

    # The order the chain made them, not the order the node lists them.
    test "ownership and proposal logs in one block are recorded in log order", %{fleet: fleet} do
      logs = [
        decision(1, @deployed + 3),
        ownership(1, "a", @deployed + 3, 1),
        vote(1, "a", true, [1], @deployed + 3, 2),
        executed(1, "a", @deployed + 3, 3)
      ]

      StubClient.put_chain(head(@deployed + 10), Enum.reverse(logs))

      inserted = inserts_during(fn -> assert Scanner.step(fleet, StubClient) == :ok end)

      assert inserted -- ["chain_cursors"] ==
               ~w(proposals key_attachments proposal_votes proposal_executions)
    end

    # A single pass never asks for more than 10,000 blocks, and the next starts
    # exactly where the last ended.
    test "passes of 10,000 blocks skip nothing", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 25_000), [
        decision(1, @deployed + 9_999),
        decision(2, @deployed + 10_000),
        vote(2, "a", true, [1], @deployed + 19_999, 0)
      ])

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
                 {@deployed + 9_970, @deployed + 9_999},
                 {@deployed + 10_000, @deployed + 19_999},
                 {@deployed + 19_970, @deployed + 19_999},
                 {@deployed + 20_000, @deployed + 25_000}
               ]
    end

    # A key sold adds to the keys a proposal needs more than half of, so it
    # can take a passed proposal back to voting; a key changing hands cannot.
    test "a pass that makes a new record or sells a key says so, and one that makes none does not",
         %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))

      mint = ownership(1, "a", @deployed + 1, 0)
      StubClient.put_chain(head(@deployed + 10), [mint])
      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:proposals_changed, @fleet}

      moved = %{ownership(1, "b", @deployed + 11, 0) | "data" => hex(<<2::256>>)}
      StubClient.put_chain(head(@deployed + 12), [mint, moved])
      assert Scanner.step(fleet, StubClient) == :ok
      refute_received {:proposals_changed, _fleet}

      StubClient.put_chain(head(@deployed + 14), [mint, moved, decision(1, @deployed + 13)])
      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:proposals_changed, @fleet}

      StubClient.put_chain(head(@deployed + 16), [mint, moved, decision(1, @deployed + 13)])
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

      # Three new logs where the node sends two at most: the first piece holds
      # proposal 3 and its vote, the second a second execution of proposal 1.
      StubClient.put_chain(
        head(@deployed + 14),
        history() ++
          [
            decision(3, @deployed + 11),
            vote(3, "a", true, [1], @deployed + 11, 1),
            executed(1, "b", @deployed + 13, 0)
          ],
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

    # The block holding the launch has two logs where the node sends one at
    # most. The pieces before it stay recorded with the cursor just after them,
    # and the next pass carries on from there with the same numbers.
    test "a single block the node will not answer ends the pass after the last piece recorded",
         %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), history(), max_logs: 1)

      assert Scanner.step(fleet, StubClient) ==
               {:error, {:block_unanswered, @deployed + 2, :chain_unavailable}}

      assert [%{number: 1, record_seq: 1} = decision] = recorded()
      assert %{next_block: next_block, proposal_seq: 1} = Chain.get_cursor!(@fleet)
      assert next_block == @deployed + 2

      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok

      assert [%{id: decision_id, record_seq: 1} | rest] = recorded_in_chain_order()
      assert decision_id == decision.id
      assert Enum.map(rest, & &1.record_seq) == [2, 3, 4]
      assert %{next_block: next_block, proposal_seq: 4} = Chain.get_cursor!(@fleet)
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
    test "a conflicting proposal or vote stops the fleet at its block and writes nothing", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok
      recorded = recorded()

      for {logs, block} <- [
            {conflicting(history(), 0, &text_of(&1, "Changed")), @deployed + 1},
            {conflicting(
               history(),
               3,
               &%{&1 | "topics" => List.replace_at(&1["topics"], 2, address_word("e"))}
             ), @deployed + 4},
            {conflicting(
               history(),
               3,
               &%{&1 | "topics" => List.replace_at(&1["topics"], 1, hex(<<2::256>>))}
             ), @deployed + 4},
            {conflicting(history(), 3, &%{&1 | "blockHash" => @new_hash}), @deployed + 4},
            {history() ++ [decision(2, @deployed + 6)], @deployed + 6},
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

      for {index, block} <- [{0, @deployed + 1}, {3, @deployed + 4}, {4, @deployed + 5}] do
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
        conflicting(history(), 3, &%{&1 | "blockHash" => @new_hash, "logIndex" => quantity(1)})

      StubClient.put_chain(head(@deployed + 12), moved,
        block_hashes: %{(@deployed + 4) => @new_hash}
      )

      capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 4} end)
      assert recorded() == recorded
    end

    # Read in pieces, the second reading checks each piece before recording
    # anything new in it. A vote first seen in an early piece is recorded; the
    # vote moved in a later piece stops the fleet there and is not recorded.
    test "each piece of the second reading is checked before it is recorded", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), history())
      assert Scanner.step(fleet, StubClient) == :ok
      recorded = recorded()

      late_vote = vote(1, "b", false, [2], @deployed + 1, 1)

      moved =
        conflicting(history(), 3, &%{&1 | "blockHash" => @new_hash, "logIndex" => quantity(1)})

      StubClient.put_chain(head(@deployed + 10), List.insert_at(moved, 1, late_vote),
        max_logs: 2,
        block_hashes: %{(@deployed + 4) => @new_hash}
      )

      capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 4} end)

      assert [%{block_number: block, log_index: 1, record_seq: 5, support: false}] =
               recorded() -- recorded

      assert block == @deployed + 1
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
          autolaunch(2, @deployed + 2, 0),
          decision(3, @deployed + 3),
          vote(1, "a", true, [1], @deployed + 4, 0),
          vote(3, "b", false, [2], @deployed + 4, 1),
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
      StubClient.put_chain(head(@deployed + 20), history() ++ [third])
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
      without_first = List.delete(history(), decision(1, @deployed + 1))
      assert {{:stopped, stopped_at}, _log} = disagreeing_at.(1, without_first ++ [third])
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

  describe "reading launches" do
    # The contract records a launch's narrativeDigest as its proposal's
    # digest, so a launch plan version's digest leads from the proposal back
    # to the exact version its keys read.
    test "a launch that carries a launch plan's digest points to that plan version",
         %{fleet: fleet} do
      WorkspaceFixtures.open_log(@fleet)
      plan = WorkspaceFixtures.create(@fleet, "launch_card", %{"title" => "Research fund"})
      WorkspaceFixtures.edit(@fleet, plan, %{"name" => "Research Fund", "symbol" => "RSF"})
      WorkspaceFixtures.edit(@fleet, plan, %{"symbol" => "RSFD"})

      [%{digest: digest}] =
        Graph.current_launch_plan_revisions!(@fleet, [%{object_id: plan, version: 2}], actor: nil)

      texts = ["Research Fund", "RSF", "A fleet's research", "https://example.test", "ipfs://r"]
      returned = encoded_envelope(texts, 250_000, bytes(digest))

      StubClient.put_chain(
        head(@deployed + 10),
        autolaunch(1, @deployed + 2, 0, envelope_hash: keccak(returned), digest: digest),
        calls: fn _to, _data, _block_hash -> {:ok, returned} end
      )

      assert Scanner.step(fleet, StubClient) == :ok
      assert LaunchEnvelopes.read(fleet, StubClient) == :ok

      proposal = Proposals.get_proposal!(@fleet, 1)
      assert proposal.digest == digest

      assert [%{object_id: ^plan, version: 2, data: %{"symbol" => "RSF"}}] =
               Graph.launch_plan_revisions!(@fleet, [proposal.digest], actor: nil)
    end

    # The launch is read apart from the pass, at the head, and kept byte for
    # byte, text that is not valid text included, and only once.
    test "a launch proposal's launch is read at the head and kept exactly", %{fleet: fleet} do
      texts = ["Cascade", "CSC", "A fleet's launch", "https://example.test", <<0xFF, 0xFE>>]
      returned = encoded_envelope(texts, 250_000)

      StubClient.put_chain(
        head(@deployed + 10),
        autolaunch(1, @deployed + 2, 0, envelope_hash: keccak(returned)),
        calls: fn _to, _data, _block_hash -> {:ok, returned} end
      )

      # The pass reads no launch, so a slow one never holds it up.
      assert Scanner.step(fleet, StubClient) == :ok
      assert StubClient.call_requests() == []

      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Proposals.topic(@fleet))
      assert LaunchEnvelopes.read(fleet, StubClient) == :ok
      assert_received {:proposals_changed, @fleet}

      assert StubClient.call_requests() == [
               {@votes, "0xb3bceadb" <> String.duplicate("0", 63) <> "1",
                head(@deployed + 10).hash}
             ]

      launch = Proposals.get_proposal!(@fleet, 1, load: :launch_envelope)

      assert %{
               name: "Cascade",
               symbol: "CSC",
               description: "A fleet's launch",
               website: "https://example.test",
               image: <<0xFF, 0xFE>>,
               record_seq: 2
             } = launch.launch_envelope

      assert Decimal.equal?(launch.launch_envelope.required_regent_raised, 250_000)
      assert Chain.get_cursor!(@fleet).proposal_seq == 2

      # Kept, it is not asked for again.
      StubClient.put_chain(
        head(@deployed + 12),
        autolaunch(1, @deployed + 2, 0, envelope_hash: keccak(returned)),
        calls: fn _to, _data, _block_hash -> {:ok, returned} end
      )

      assert LaunchEnvelopes.read(fleet, StubClient) == :ok
      assert StubClient.call_requests() == []
      refute_received {:proposals_changed, _fleet}

      # Made again differently, it is refused as not the record, which names
      # no block, since a launch is not read from one.
      assert {:error, %Ash.Error.Invalid{errors: [%{vars: []}]}} =
               Proposals.record_launch_envelope(
                 %{
                   fleet_id: @fleet,
                   proposal_id: launch.id,
                   name: "Other",
                   symbol: "CSC",
                   description: "A fleet's launch",
                   website: "https://example.test",
                   image: <<0xFF, 0xFE>>,
                   required_regent_raised: Decimal.new(250_000)
                 },
                 actor: %System{}
               )

      assert Proposals.get_proposal!(@fleet, 1, load: :launch_envelope).launch_envelope.name ==
               "Cascade"

      for {sql, params} <- [
            {"UPDATE keyfleet_app.proposal_launch_envelopes SET name = $1", ["Other"]},
            {"DELETE FROM keyfleet_app.proposal_launch_envelopes", []},
            {"TRUNCATE keyfleet_app.proposal_launch_envelopes", []}
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 Repo.query(sql, params, mode: :savepoint),
               sql
      end
    end

    # An answer always comes in whole 32-byte words, so the hash's own
    # 136-byte blocks are met exactly by a launch 1088 bytes long. Its hash
    # is pinned from `cast keccak` of the same bytes, and in
    # contracts/test/KeyfleetAutolaunch.t.sol from the same launch proposed,
    # as its event carries it and as `launchEnvelope` returns it.
    test "a launch that fills the hash's blocks exactly is kept", %{fleet: fleet} do
      description = "A fleet's launch. " |> String.duplicate(29) |> binary_part(0, 512)

      texts = [
        "Cascade Research",
        "CSR",
        description,
        "https://example.test",
        "ipfs://" <> String.duplicate("c", 50)
      ]

      returned = encoded_envelope(texts, 250_000)
      assert byte_size(returned) == 8 * 136

      StubClient.put_chain(
        head(@deployed + 10),
        autolaunch(1, @deployed + 2, 0,
          envelope_hash: "0x9d2685a27d497a7918a1a17b76177782499261be330345e630bcc08ef34bf285"
        ),
        calls: fn _to, _data, _block_hash -> {:ok, returned} end
      )

      assert Scanner.step(fleet, StubClient) == :ok
      assert LaunchEnvelopes.read(fleet, StubClient) == :ok

      assert %{name: "Cascade Research", description: ^description} =
               Proposals.get_proposal!(@fleet, 1, load: :launch_envelope).launch_envelope
    end

    # A read that fails, is refused, or answers with another launch keeps
    # nothing and holds up nothing; the next read tries again. A head that
    # cannot be read is the read failing.
    test "a launch that cannot be read keeps nothing and is tried again", %{fleet: fleet} do
      returned = encoded_envelope(["N", "S", "D", "W", "I"], 1)
      logs = autolaunch(1, @deployed + 2, 0, envelope_hash: keccak(returned))
      other = encoded_envelope(["N", "S", "D", "W", "J"], 1)
      StubClient.put_chain(head(@deployed + 10), logs)
      assert Scanner.step(fleet, StubClient) == :ok

      for {answer, reason} <- [
            {{:error, :chain_unavailable}, :chain_unavailable},
            {{:error, :reverted}, :reverted},
            {{:ok, other}, :envelope_not_the_approved_one},
            {{:ok, binary_part(returned, 0, 64)}, :envelope_not_the_approved_one}
          ] do
        StubClient.put_chain(head(@deployed + 10), logs,
          calls: fn _to, _data, _block_hash -> answer end
        )

        assert LaunchEnvelopes.read(fleet, StubClient) ==
                 {:error, {:launches_not_read, [{1, reason}]}}

        assert length(StubClient.call_requests()) == 1
        refute Proposals.get_proposal!(@fleet, 1, load: :launch_envelope).launch_envelope
      end

      StubClient.put_chain(head(@deployed + 12), logs,
        calls: fn _to, _data, _block_hash -> {:ok, returned} end
      )

      assert LaunchEnvelopes.read(fleet, StubClient) == :ok

      assert %{name: "N", image: "I"} =
               Proposals.get_proposal!(@fleet, 1, load: :launch_envelope).launch_envelope
    end

    test "a stopped fleet's launches are not read", %{fleet: fleet} do
      returned = encoded_envelope(["N", "S", "D", "W", "I"], 1)
      logs = autolaunch(1, @deployed + 2, 0, envelope_hash: keccak(returned))
      StubClient.put_chain(head(@deployed + 10), logs)
      assert Scanner.step(fleet, StubClient) == :ok

      # The chain's history changed under the proposal: it is gone from a
      # block whose hash is new.
      StubClient.put_chain(head(@deployed + 12), [],
        block_hashes: %{(@deployed + 2) => @new_hash},
        calls: fn _to, _data, _block_hash -> {:ok, returned} end
      )

      capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, @deployed + 2} end)
      assert LaunchEnvelopes.read(fleet, StubClient) == :ok
      assert StubClient.call_requests() == []
      refute Proposals.get_proposal!(@fleet, 1, load: :launch_envelope).launch_envelope
    end
  end

  describe "the record tables" do
    test "refuse every change, delete and emptying", %{fleet: fleet} do
      budget = [
        shared_money("e", @deployed + 6, 1, 10),
        income("a", @deployed + 6, 2, 10),
        budget_paid("a", "c", @deployed + 7, 0, [1, 1, 0])
      ]

      StubClient.put_chain(head(@deployed + 10), history() ++ budget)
      assert Scanner.step(fleet, StubClient) == :ok

      for {table, column, value} <- [
            {"proposals", "text_bytes", 1},
            {"proposal_votes", "support", false},
            {"proposal_executions", "executor", wallet("0")},
            {"budget_receipts", "asset", wallet("0")},
            {"income_receipts", "caller", wallet("0")},
            {"budget_payments", "recipient", wallet("0")}
          ],
          {sql, params} <- [
            {"UPDATE keyfleet_app.#{table} SET #{column} = $1", [value]},
            {"DELETE FROM keyfleet_app.#{table}", []},
            {"TRUNCATE keyfleet_app.#{table} CASCADE", []}
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 Repo.query(sql, params, mode: :savepoint),
               sql
      end

      assert length(recorded()) == 4
      assert length(Treasury.recorded_in_blocks!(@fleet, @deployed, @deployed + 10)) == 3
    end
  end

  describe "reading logs" do
    # Anything not exactly as the contracts emit it refuses the stretch.
    test "only logs in the contracts' exact encoding are read", %{fleet: fleet} do
      decision = decision(1, @deployed + 1, text: "abc")
      vote = vote(1, "a", true, [1, 2], @deployed + 2, 0)
      [created, payload] = autolaunch(2, @deployed + 3, 0)
      [pay_created, pay_payload] = pay(3, @deployed + 4, 1, amount: @max_uint256)
      mint = ownership(1, "a", @deployed + 4, 0)
      valid = [decision, vote, created, payload, pay_created, pay_payload]

      assert {:ok, [_, _, _, {:proposal, paid}]} =
               Logs.decode(valid, fleet, @deployed, @deployed + 10)

      assert %{kind: :pay, number: 3, text: "Pay 3", digest: nil} = paid
      assert paid.asset == wallet("a") and paid.recipient == wallet("b")
      assert Decimal.equal?(paid.amount, @max_uint256)

      data = &(&1["data"] |> String.trim_leading("0x") |> Base.decode16!(case: :lower))
      topic = &List.replace_at(&1["topics"], &2, &3)

      for {index, broken} <- [
            {0, %{decision | "address" => wallet("8")}},
            {0, %{decision | "address" => @contract}},
            {0, %{decision | "topics" => topic.(decision, 0, @ownership)}},
            {0, %{decision | "topics" => topic.(decision, 0, "0x" <> String.duplicate("0", 64))}},
            {0, %{decision | "topics" => topic.(decision, 1, hex(<<0::256>>))}},
            {0, %{decision | "topics" => topic.(decision, 1, hex(<<1::1, 0::255>>))}},
            {0, %{decision | "topics" => topic.(decision, 1, hex(<<@max_bigint + 1::256>>))}},
            {0, %{decision | "topics" => topic.(decision, 2, hex(<<3::256>>))}},
            {0, %{decision | "topics" => topic.(decision, 3, hex(<<1::96, 0::160>>))}},
            {0, %{decision | "topics" => Enum.drop(decision["topics"], -1)}},
            {0, %{decision | "topics" => topic.(decision, 3, "0x00")}},
            {0, %{decision | "data" => hex(data.(decision) <> <<0::256>>)}},
            {0, %{decision | "data" => hex(binary_part(data.(decision), 0, 127))}},
            {0, %{decision | "data" => "0x0"}},
            {0, %{decision | "data" => hex(patch(data.(decision), 64, <<128::256>>))}},
            {0, %{decision | "data" => hex(patch(data.(decision), 96, <<33::256>>))}},
            {0, %{decision | "data" => hex(patch(data.(decision), 131, <<1>>))}},
            {0, %{decision | "data" => hex(patch(data.(decision), 0, <<@max_bigint + 1::256>>))}},
            {0, %{decision | "blockNumber" => quantity(@deployed + 11)}},
            {0, %{decision | "blockNumber" => "0x-1"}},
            {0, %{decision | "logIndex" => "0x"}},
            {0, %{decision | "logIndex" => "0x-1"}},
            {0, %{decision | "logIndex" => "0x+0"}},
            {0, %{decision | "blockHash" => "0x" <> String.duplicate("g", 64)}},
            {0, %{decision | "transactionHash" => "0x01"}},
            {0, %{mint | "topics" => topic.(mint, 2, hex(<<1::96, 0::160>>))}},
            {0, %{mint | "topics" => topic.(mint, 3, hex(<<1::96, 0::160>>))}},
            {1, %{vote | "data" => hex(patch(data.(vote), 0, <<2::256>>))}},
            {1, %{vote | "data" => hex(patch(data.(vote), 0, <<3::256>>))}},
            {1, %{vote | "data" => hex(patch(data.(vote), 0, <<1::1, 0::254, 1::1>>))}},
            {1,
             %{vote | "data" => hex(patch(data.(vote), 64, <<0::256>>) |> binary_part(0, 96))}},
            {1, %{vote | "data" => hex(patch(data.(vote), 96, <<0::256>>))}},
            {1, %{vote | "data" => hex(patch(data.(vote), 96, <<1::1, 0::255>>))}},
            {1, %{vote | "data" => hex(patch(data.(vote), 64, <<3::256>>))}},
            {1, %{vote | "data" => hex(data.(vote) <> <<0::256>>)}},
            {3, %{payload | "data" => hex(data.(payload) <> <<0::256>>)}},
            {3, %{payload | "data" => hex(binary_part(data.(payload), 0, 31))}},
            {5, %{pay_payload | "topics" => topic.(pay_payload, 2, hex(<<1::96, 0::160>>))}},
            {5, %{pay_payload | "topics" => topic.(pay_payload, 3, hex(<<1::96, 0::160>>))}},
            {5, %{pay_payload | "topics" => Enum.drop(pay_payload["topics"], -1)}},
            {5, %{pay_payload | "data" => hex(data.(pay_payload) <> <<0::256>>)}},
            {5, %{pay_payload | "data" => hex(binary_part(data.(pay_payload), 0, 31))}}
          ] do
        assert Logs.decode(
                 List.replace_at(valid, index, broken),
                 fleet,
                 @deployed,
                 @deployed + 10
               ) ==
                 {:error, {:unreadable_log, broken["transactionHash"], broken["logIndex"]}},
               inspect(broken)
      end

      # A launch or payment proposal read as a decision leaves its payload
      # without a proposal; a payload for another proposal, or of the other
      # kind, leaves it without its payload.
      launch_tx = String.downcase(transaction(@deployed + 3))
      pay_tx = String.downcase(transaction(@deployed + 4))

      for {index, broken, reason} <- [
            {2, %{created | "topics" => topic.(created, 2, hex(<<0::256>>))},
             {:payload_without_proposal, launch_tx, 1}},
            {3, %{payload | "topics" => topic.(payload, 1, hex(<<1::256>>))},
             {:payload_missing, launch_tx, 0}},
            {4, %{pay_created | "topics" => topic.(pay_created, 2, hex(<<0::256>>))},
             {:payload_without_proposal, pay_tx, 2}},
            {4, %{pay_created | "topics" => topic.(pay_created, 2, hex(<<1::256>>))},
             {:payload_missing, pay_tx, 1}},
            {5, %{pay_payload | "topics" => topic.(pay_payload, 1, hex(<<2::256>>))},
             {:payload_missing, pay_tx, 1}}
          ] do
        assert Logs.decode(
                 List.replace_at(valid, index, broken),
                 fleet,
                 @deployed,
                 @deployed + 10
               ) == {:error, reason},
               inspect(broken)
      end

      income = income("a", @deployed + 5, 0, 10)
      paid = budget_paid("a", "c", @deployed + 5, 1, [1, 1, 0])

      assert {:ok, [{:income, _income}, {:budget_paid, _paid}]} =
               Logs.decode([income, paid], fleet, @deployed, @deployed + 10)

      for {index, broken} <- [
            {0, %{income | "address" => @votes}},
            {0, %{income | "data" => hex(<<10::256, 1::256>>)}},
            {0, %{income | "data" => hex(<<>>)}},
            {0, %{income | "topics" => topic.(income, 1, hex(<<1::96, 0::160>>))}},
            {0, %{income | "topics" => Enum.drop(income["topics"], -1)}},
            {1, %{paid | "address" => @votes}},
            {1, %{paid | "data" => hex(<<1::256, 1::256>>)}},
            {1, %{paid | "data" => hex(<<1::256, 1::256, 0::256, 0::256>>)}},
            {1, %{paid | "topics" => topic.(paid, 2, hex(<<1::96, 0::160>>))}}
          ] do
        assert Logs.decode(
                 List.replace_at([income, paid], index, broken),
                 fleet,
                 @deployed,
                 @deployed + 10
               ) ==
                 {:error, {:unreadable_log, broken["transactionHash"], broken["logIndex"]}},
               inspect(broken)
      end

      executed_with_data = %{executed(1, "a", @deployed + 1, 0) | "data" => hex(<<0::256>>)}

      assert Logs.decode([executed_with_data], fleet, @deployed, @deployed + 10) ==
               {:error,
                {:unreadable_log, executed_with_data["transactionHash"],
                 executed_with_data["logIndex"]}}
    end
  end

  # A decision, a launch, a vote and an execution, numbered 1 to 4.
  defp history do
    List.flatten([
      decision(1, @deployed + 1),
      autolaunch(2, @deployed + 2, 0),
      vote(1, "a", true, [1], @deployed + 4, 0),
      executed(1, "a", @deployed + 5, 0)
    ])
  end

  defp conflicting(logs, index, change), do: List.update_at(logs, index, change)

  defp text_of(log, text) do
    %{"topics" => [_topic0, id, _kind, _proposer]} = log
    number = id |> String.trim_leading("0x") |> String.to_integer(16)
    block = log["blockNumber"] |> String.trim_leading("0x") |> String.to_integer(16)
    decision(number, block, text: text)
  end

  defp recorded_in_chain_order,
    do: Enum.sort_by(recorded(), &{&1.block_number, &1.log_index})

  defp recorded do
    Enum.sort_by(
      Proposals.recorded_in_blocks!(@fleet, 0, @deployed + 100_000),
      &{&1.__struct__, &1.record_seq}
    )
  end

  defp decision(number, block, opts \\ []) do
    created(number, 0, block, 0, Keyword.get(opts, :text, "Proposal #{number}"), <<0::256>>)
  end

  defp payload_for(payload, number),
    do: %{payload | "topics" => List.replace_at(payload["topics"], 1, hex(<<number::256>>))}

  # A launch proposal; its digest is the envelope hash unless `:digest` names
  # the narrativeDigest it carries.
  defp autolaunch(number, block, log_index, opts \\ []) do
    envelope = opts |> Keyword.get(:envelope_hash, "0x" <> String.duplicate("a1", 32)) |> bytes()
    digest = opts |> Keyword.get(:digest, hex(envelope)) |> bytes()

    [
      created(number, 1, block, log_index, "", digest),
      log(@votes, [@autolaunch, <<number::256>>], envelope, block, log_index + 1)
    ]
  end

  # A payment of `amount` of asset 0xaa… to 0xbb….
  defp pay(number, block, log_index, opts \\ []) do
    amount = Keyword.get(opts, :amount, 5_000)

    [
      created(number, 2, block, log_index, Keyword.get(opts, :text, "Pay #{number}"), <<0::256>>),
      log(
        @votes,
        [@pay, <<number::256>>, address_word_bytes("a"), address_word_bytes("b")],
        <<amount::256>>,
        block,
        log_index + 1
      )
    ]
  end

  defp created(number, kind, block, log_index, text, digest) do
    padded = 32 * div(byte_size(text) + 31, 32)

    data =
      <<block::256>> <>
        digest <>
        <<96::256, byte_size(text)::256>> <>
        text <> <<0::size(8 * (padded - byte_size(text)))>>

    log(
      @votes,
      [@created, <<number::256>>, <<kind::256>>, address_word_bytes("f")],
      data,
      block,
      log_index
    )
  end

  defp vote(number, voter, support, token_ids, block, log_index) do
    data =
      <<if(support, do: 1, else: 0)::256, 64::256, length(token_ids)::256>> <>
        for(id <- token_ids, into: <<>>, do: <<id::256>>)

    log(@votes, [@vote, <<number::256>>, address_word_bytes(voter)], data, block, log_index)
  end

  defp withdrawn(number, voter, token_ids, block, log_index) do
    data =
      <<32::256, length(token_ids)::256>> <> for(id <- token_ids, into: <<>>, do: <<id::256>>)

    log(@votes, [@withdrawn, <<number::256>>, address_word_bytes(voter)], data, block, log_index)
  end

  defp executed(number, executor, block, log_index) do
    log(
      @votes,
      [@executed, <<number::256>>, address_word_bytes(executor)],
      <<>>,
      block,
      log_index
    )
  end

  defp budget_history do
    List.flatten([
      decision(1, @deployed + 1),
      shared_money("e", @deployed + 1, 1, @max_uint256),
      graduation("9", @deployed + 1, 2, 100),
      income("a", @deployed + 2, 0, @max_uint256),
      vesting("b", @deployed + 2, 1, 5, 25),
      budget_paid("a", "c", @deployed + 3, 1, [700, 350, 1_050]),
      ownership(1, "d", @deployed + 3, 0)
    ])
  end

  # Income of `amount` in asset 0x`asset`… paid to the keys, recognized by
  # 0xff….
  defp income(asset, block, log_index, amount),
    do: recognized(@income_recognized, asset, block, log_index, amount)

  # `amount` of asset 0x`asset`… recognized into the budget by 0xff….
  defp shared_money(asset, block, log_index, amount),
    do: recognized(@shared_money_recognized, asset, block, log_index, amount)

  defp recognized(topic0, asset, block, log_index, amount) do
    log(
      @contract,
      [topic0, address_word_bytes(asset), address_word_bytes("f")],
      <<amount::256>>,
      block,
      log_index
    )
  end

  # `amount` of the REGENT 0x`asset`… the launch sent at graduation.
  defp graduation(asset, block, log_index, amount) do
    log(
      @contract,
      [@graduation_booked, address_word_bytes(asset)],
      <<amount::256>>,
      block,
      log_index
    )
  end

  # `amount` of launched token 0x`asset`… the escrow released, `total` in all.
  defp vesting(asset, block, log_index, amount, total) do
    log(
      @contract,
      [@vesting_booked, address_word_bytes(asset)],
      <<amount::256, total::256>>,
      block,
      log_index
    )
  end

  # A payment of asset 0x`asset`… to 0x`recipient`…, as [amount, share,
  # matched].
  defp budget_paid(asset, recipient, block, log_index, fields) do
    log(
      @contract,
      [@budget_paid, address_word_bytes(asset), address_word_bytes(recipient)],
      for(field <- fields, into: <<>>, do: <<field::256>>),
      block,
      log_index
    )
  end

  # What `launchEnvelope` returns for a launch of these five texts, raise and
  # narrative digest (none unless given): the struct's offset, then the struct.
  defp encoded_envelope(texts, raise, narrative_digest \\ <<0::256>>) do
    tails =
      Enum.map(texts, fn text ->
        padded = 32 * div(byte_size(text) + 31, 32)
        <<byte_size(text)::256>> <> text <> <<0::size(8 * (padded - byte_size(text)))>>
      end)

    {offsets, _end} = Enum.map_reduce(tails, 224, &{<<&2::256>>, &2 + byte_size(&1)})

    <<32::256>> <>
      Enum.join(offsets) <>
      <<raise::256>> <>
      narrative_digest <> Enum.join(tails)
  end

  defp keccak(bytes), do: hex(ExKeccak.hash_256(bytes))

  defp ownership(token_id, owner, block, log_index) do
    log(
      @contract,
      [@ownership, <<token_id::256>>, <<0::256>>, address_word_bytes(owner)],
      <<1::256>>,
      block,
      log_index
    )
  end

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

  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :lower)
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp sha256(text), do: hex(:crypto.hash(:sha256, text))
  defp quantity(value), do: "0x" <> Integer.to_string(value, 16)
  defp transaction(block), do: "0x" <> String.pad_leading(Integer.to_string(block, 16), 64, "0")
  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp head(number),
    do: %{
      number: number,
      hash: "0x" <> String.duplicate("f", 64),
      timestamp: DateTime.from_unix!(1_700_000_000 + 2 * number)
    }

  defp deploy! do
    @fleet
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: @contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: @votes,
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: @deployed,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %System{}
    )
  end

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
      vote(1, "b", false, [2], @deployed + 100, 0),
      decision(3, @deployed + 120),
      vote(3, "b", true, [2], @deployed + 140, 0)
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
      Repo.query!(
        "ALTER TABLE keyfleet_app.proposal_launch_envelopes DISABLE TRIGGER immutable_proposal_launch_envelopes"
      )

      Repo.query!(
        "DELETE FROM keyfleet_app.proposal_launch_envelopes AS envelope " <>
          "USING keyfleet_app.proposals AS proposal " <>
          "WHERE envelope.proposal_id = proposal.id AND proposal.fleet_id = $1 " <>
          "AND proposal.block_number >= $2",
        [@fleet, @deployed + offset]
      )

      Repo.query!(
        "ALTER TABLE keyfleet_app.proposal_launch_envelopes ENABLE TRIGGER immutable_proposal_launch_envelopes"
      )

      for table <-
            ~w(budget_payments budget_receipts income_receipts proposal_executions proposal_votes proposals) do
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
      for {table, trigger} <- [
            {"budget_payments", "immutable_budget_payments"},
            {"budget_receipts", "immutable_budget_receipts"},
            {"income_receipts", "immutable_income_receipts"},
            {"proposal_launch_envelopes", "immutable_proposal_launch_envelopes"},
            {"proposal_executions", "immutable_proposal_executions"},
            {"proposal_votes", "immutable_proposal_votes"},
            {"proposals", "immutable_proposals"}
          ] do
        Repo.query!("ALTER TABLE keyfleet_app.#{table} DISABLE TRIGGER #{trigger}")
        Repo.query!("DELETE FROM keyfleet_app.#{table} WHERE fleet_id = $1", [@fleet])
        Repo.query!("ALTER TABLE keyfleet_app.#{table} ENABLE TRIGGER #{trigger}")
      end

      Repo.query!("DELETE FROM keyfleet_app.chain_cursors WHERE fleet_id = $1", [@fleet])

      Repo.query!(
        "UPDATE keyfleet_app.fleets SET chain_id = NULL, contract_address = NULL, " <>
          "rewards_address = NULL, votes_address = NULL, usdc_address = NULL, " <>
          "deployed_block = NULL, trait_table_hash = NULL " <>
          "WHERE id = $1",
        [@fleet]
      )
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
end

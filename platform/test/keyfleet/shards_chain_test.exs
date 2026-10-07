defmodule Keyfleet.ShardsChainTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain.{Scanner, StubClient}
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Repo

  @fleet "fleet_tech_accelerant"
  @contract "0x" <> String.duplicate("7", 40)
  @votes "0x" <> String.duplicate("9", 40)
  @shards "0x" <> String.duplicate("6", 40)
  @deployed 6_000_000

  # Pinned from `cast keccak` of each event signature, and against the
  # contracts in contracts/test/KeyfleetVotesTopics.t.sol.
  @ownership "0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1"
  @edits_set "0x908aa6b1a2d33ab8aaa026fccd64bd2d84297a4e0e9c496d53edbb67e5165cdc"
  @shard_issued "0x3b2824f462424cb01c09746900aff2810947c0577d310c08082c75fe40c2312a"
  @shard_ended "0x22773ac65ded0957ecf7109dad0076e1968f3db974ccda1df370bfa4505092f4"
  @agent_voting_set "0xfdf7ebb0624288d5705c5fa214a210cf974c5a5598f8f65a6d616f0c420acabd"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    %{fleet: deploy!()}
  end

  describe "shards" do
    test "an issued shard is recorded and active until its end", %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))
      expires = in_days(30)

      issued = [
        ownership(7, "a", 1, @deployed + 1, 0),
        issued(7, "b", expires, 1, @deployed + 2, 0)
      ]

      read(fleet, issued, @deployed + 10)

      assert_receive {:keys_changed, @fleet, [7]}

      assert {:ok, %{token_id: 7, kind: :issued, expires_at: ^expires, ownership_epoch: 1}} =
               Keys.active_shard(@fleet, 7, wallet("b"))

      assert [%{token_id: 7, wallet: wallet_b}] = Keys.active_shards_of_keys!(@fleet, [7])
      assert wallet_b == wallet("b")
      assert [%{fleet_id: @fleet, token_id: 7}] = Keys.active_shards_held_by!(wallet("b"))
      assert [%{token_id: 7}] = Keys.keys_with_shards!(@fleet)

      read(fleet, issued ++ [ended(7, "b", "a", @deployed + 11, 0)], @deployed + 20)

      assert_receive {:keys_changed, @fleet, [7]}
      assert {:ok, nil} = Keys.active_shard(@fleet, 7, wallet("b"))
      assert Keys.active_shards_of_keys!(@fleet, [7]) == []

      assert [
               %{kind: :ended, ended_by: ended_by, record_seq: 2},
               %{kind: :issued, record_seq: 1}
             ] = Keys.shard_events_recorded_before!(@fleet, nil, 10)

      assert ended_by == wallet("a")
    end

    test "issuing again renews a shard, and a wallet holds a shard of each key it is given",
         %{fleet: fleet} do
      renewed = in_days(90)

      logs = [
        ownership(7, "a", 1, @deployed + 1, 0),
        ownership(8, "a", 1, @deployed + 1, 1),
        issued(7, "b", in_days(30), 1, @deployed + 2, 0),
        issued(7, "b", renewed, 1, @deployed + 3, 0),
        issued(7, "c", in_days(5), 1, @deployed + 3, 1),
        issued(8, "c", in_days(10), 1, @deployed + 4, 0),
        ended(8, "c", "a", @deployed + 5, 0)
      ]

      read(fleet, logs, @deployed + 10)

      assert {:ok, %{expires_at: ^renewed}} = Keys.active_shard(@fleet, 7, wallet("b"))
      assert {:ok, %{token_id: 7}} = Keys.active_shard(@fleet, 7, wallet("c"))
      assert {:ok, nil} = Keys.active_shard(@fleet, 8, wallet("c"))

      read(fleet, logs ++ [issued(8, "c", in_days(10), 1, @deployed + 11, 0)], @deployed + 20)

      assert [%{token_id: 7}, %{token_id: 8}] = Keys.active_shards_held_by!(wallet("c"))

      assert [%{token_id: 7}, %{token_id: 7}, %{token_id: 8}] =
               Keys.active_shards_of_keys!(@fleet, [7, 8])
    end

    test "a shard ends when its key changes hands or its time runs out", %{fleet: fleet} do
      read(
        fleet,
        [
          ownership(7, "a", 1, @deployed + 1, 0),
          ownership(8, "a", 1, @deployed + 1, 1),
          issued(7, "b", in_days(30), 1, @deployed + 2, 0),
          issued(8, "c", DateTime.add(now(), -1), 1, @deployed + 2, 1),
          ownership(7, "d", 2, @deployed + 3, 0)
        ],
        @deployed + 10
      )

      assert {:ok, nil} = Keys.active_shard(@fleet, 7, wallet("b"))
      assert {:ok, nil} = Keys.active_shard(@fleet, 8, wallet("c"))
      assert Keys.keys_with_shards!(@fleet) == []
    end

    test "reading the same blocks again records nothing twice", %{fleet: fleet} do
      logs = [
        ownership(7, "a", 1, @deployed + 1, 0),
        issued(7, "b", in_days(30), 1, @deployed + 2, 0)
      ]

      read(fleet, logs, @deployed + 10)
      read(fleet, logs, @deployed + 11)

      assert [%{record_seq: 1}] = Keys.shard_events_recorded_before!(@fleet, nil, 10)
    end
  end

  describe "restricting edits" do
    # The treasury carrying out a proposal sets a key's edits restricted or
    # allowed; the latest setting is the one that holds.
    test "a key's edits restricted on the chain are restricted until allowed again", %{
      fleet: fleet
    } do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))

      restricted = [
        ownership(7, "a", 1, @deployed + 1, 0),
        edits_set(7, true, @deployed + 3, 1)
      ]

      read(fleet, restricted, @deployed + 10)

      assert_receive {:keys_changed, @fleet, [7]}
      assert Keys.edits_restricted?(@fleet, 7) == {:ok, true}
      assert Keys.edits_restricted?(@fleet, 8) == {:ok, false}

      read(fleet, restricted ++ [edits_set(7, false, @deployed + 12, 1)], @deployed + 20)

      assert Keys.edits_restricted?(@fleet, 7) == {:ok, false}
      assert [%{token_id: 7, restricted: false}] = Keys.latest_edits_restrictions!(@fleet, [7])
    end
  end

  describe "agent voting" do
    # Whether a key's shards may vote is recorded with the ownership it was
    # set in, numbered with the shard records.
    test "a key's agent voting turned on and off is recorded in chain order", %{fleet: fleet} do
      read(
        fleet,
        [
          ownership(7, "a", 1, @deployed + 1, 0),
          agent_voting(7, true, 1, @deployed + 2, 0),
          agent_voting(7, false, 1, @deployed + 3, 0)
        ],
        @deployed + 10
      )

      assert [on, off] =
               @fleet
               |> Keys.agent_voting_in_blocks!(@deployed, @deployed + 10, actor: %System{})
               |> Enum.sort_by(& &1.record_seq)

      assert %{token_id: 7, allowed: true, ownership_epoch: 1, record_seq: 1} = on
      assert %{token_id: 7, allowed: false, record_seq: 2} = off
    end
  end

  defp read(fleet, logs, head) do
    StubClient.put_chain(head(head), logs)
    assert Scanner.step(fleet, StubClient) == :ok
  end

  defp ownership(token_id, owner, epoch, block, log_index) do
    log(
      @contract,
      [@ownership, <<token_id::256>>, <<0::256>>, address_word(owner)],
      <<epoch::256>>,
      block,
      log_index
    )
  end

  defp issued(token_id, holder, expires_at, epoch, block, log_index) do
    log(
      @shards,
      [@shard_issued, <<token_id::256>>, address_word(holder)],
      <<DateTime.to_unix(expires_at)::256, epoch::256>>,
      block,
      log_index
    )
  end

  defp ended(token_id, holder, by, block, log_index) do
    log(
      @shards,
      [@shard_ended, <<token_id::256>>, address_word(holder), address_word(by)],
      <<>>,
      block,
      log_index
    )
  end

  defp edits_set(token_id, restricted, block, log_index),
    do: log(@votes, [@edits_set, <<token_id::256>>], <<flag(restricted)::256>>, block, log_index)

  defp agent_voting(token_id, on, epoch, block, log_index) do
    log(
      @shards,
      [@agent_voting_set, <<token_id::256>>],
      <<flag(on)::256, epoch::256>>,
      block,
      log_index
    )
  end

  defp flag(true), do: 1
  defp flag(false), do: 0

  defp log(address, [topic0 | words], data, block, log_index) do
    %{
      "address" => address,
      "topics" => [topic0 | Enum.map(words, &hex/1)],
      "data" => hex(data),
      "blockNumber" => quantity(block),
      "blockHash" => "0x" <> String.duplicate("b", 64),
      "transactionHash" => "0x" <> String.pad_leading(Integer.to_string(block, 16), 64, "0"),
      "logIndex" => quantity(log_index)
    }
  end

  defp address_word(character),
    do: <<0::96>> <> Base.decode16!(String.duplicate(character, 40), case: :mixed)

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp quantity(value), do: "0x" <> Integer.to_string(value, 16)
  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
  defp in_days(days), do: DateTime.add(now(), days, :day)

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
        chain_id: 8453,
        contract_address: @contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: @votes,
        treasury_address: "0x" <> String.duplicate("7e", 20),
        shards_address: @shards,
        regent_address: "0x6f89bca4ea5931edfcb09786267b251dee752b07",
        regent_staking_address: "0xb027dc261636e30cbc0fe25b2f8e1ed273354ab5",
        autolaunch_factory_address: "0xf4f591e63f4b6d8240a150081c1ca7edfaeb768e",
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: @deployed,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %System{}
    )
  end
end

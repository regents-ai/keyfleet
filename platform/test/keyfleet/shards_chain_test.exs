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
  @created "0x29ea7482e80123243d4237b155637f07d8868001408424ed3934ec29e65ab647"
  @restrict_edits "0x051dcf97e7396a690509aaa36720e1aeaabeff0faca865092638a5b028e2fa8f"
  @executed "0x9c85b616f29fca57a17eafe71cf9ff82ffef41766e2cf01ea7f8f7878dd3ec24"
  @edits_set "0x2e8b5462cfaf90ff39c1d520552d96015e77788b57b81d3bf8dd40a847037bad"
  @shard_issued "0x3b2824f462424cb01c09746900aff2810947c0577d310c08082c75fe40c2312a"
  @shard_ended "0x22773ac65ded0957ecf7109dad0076e1968f3db974ccda1df370bfa4505092f4"

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
               Keys.active_shard(@fleet, wallet("b"))

      assert [%{token_id: 7, wallet: wallet_b}] = Keys.active_shards_of_keys!(@fleet, [7])
      assert wallet_b == wallet("b")
      assert [%{fleet_id: @fleet, token_id: 7}] = Keys.active_shards_held_by!(wallet("b"))
      assert [%{token_id: 7}] = Keys.keys_with_shards!(@fleet)

      read(fleet, issued ++ [ended(7, "b", "a", @deployed + 11, 0)], @deployed + 20)

      assert_receive {:keys_changed, @fleet, [7]}
      assert {:ok, nil} = Keys.active_shard(@fleet, wallet("b"))
      assert Keys.active_shards_of_keys!(@fleet, [7]) == []

      assert [
               %{kind: :ended, ended_by: ended_by, record_seq: 2},
               %{kind: :issued, record_seq: 1}
             ] = Keys.shard_events_recorded_before!(@fleet, nil, 10)

      assert ended_by == wallet("a")
    end

    test "issuing again renews a shard, and a wallet holds one shard in a fleet",
         %{fleet: fleet} do
      renewed = in_days(90)

      read(
        fleet,
        [
          ownership(7, "a", 1, @deployed + 1, 0),
          ownership(8, "a", 1, @deployed + 1, 1),
          issued(7, "b", in_days(30), 1, @deployed + 2, 0),
          issued(7, "b", renewed, 1, @deployed + 3, 0),
          issued(7, "c", in_days(5), 1, @deployed + 3, 1),
          issued(8, "c", in_days(10), 1, @deployed + 4, 0)
        ],
        @deployed + 10
      )

      assert {:ok, %{token_id: 7, expires_at: ^renewed}} = Keys.active_shard(@fleet, wallet("b"))
      assert {:ok, %{token_id: 8}} = Keys.active_shard(@fleet, wallet("c"))

      assert [%{token_id: 7}, %{token_id: 8}] =
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

      assert {:ok, nil} = Keys.active_shard(@fleet, wallet("b"))
      assert {:ok, nil} = Keys.active_shard(@fleet, wallet("c"))
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
    test "a carried-out vote restricts a key's edits, and another allows them", %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))

      restricted =
        List.flatten([
          ownership(7, "a", 1, @deployed + 1, 0),
          restrict_edits(1, 7, true, @deployed + 2, 0),
          carried_out(1, 7, true, @deployed + 3)
        ])

      read(fleet, restricted, @deployed + 10)

      assert_receive {:keys_changed, @fleet, [7]}
      assert Keys.edits_restricted?(@fleet, 7) == {:ok, true}
      assert Keys.edits_restricted?(@fleet, 8) == {:ok, false}

      allowed =
        List.flatten([
          restrict_edits(2, 7, false, @deployed + 11, 0),
          carried_out(2, 7, false, @deployed + 12)
        ])

      read(fleet, restricted ++ allowed, @deployed + 20)

      assert Keys.edits_restricted?(@fleet, 7) == {:ok, false}

      assert [%{token_id: 7, restricted: false, proposal_number: 2}] =
               Keys.latest_edits_restrictions!(@fleet, [7])
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

  # A proposal to restrict or allow `target`'s edits, with its payload.
  defp restrict_edits(number, target, restricted, block, log_index) do
    text = "Edits #{number}"

    created =
      <<block::256, 0::256, 96::256, byte_size(text)::256>> <>
        text <> <<0::size(8 * (32 - byte_size(text)))>>

    [
      log(
        @votes,
        [@created, <<number::256>>, <<2::256>>, address_word("f")],
        created,
        block,
        log_index
      ),
      log(
        @votes,
        [@restrict_edits, <<number::256>>, <<target::256>>],
        <<flag(restricted)::256>>,
        block,
        log_index + 1
      )
    ]
  end

  # The proposal carried out, and the restriction it set, in one transaction.
  defp carried_out(number, target, restricted, block) do
    [
      log(@votes, [@executed, <<number::256>>, address_word("c")], <<>>, block, 0),
      log(
        @votes,
        [@edits_set, <<target::256>>, <<number::256>>],
        <<flag(restricted)::256>>,
        block,
        1
      )
    ]
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

defmodule Keyfleet.RevealsChainTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain
  alias Keyfleet.Chain.{Logs, RevealLog, Scanner, StubClient}
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Repo

  # Other suites commit Syndicate keys outside the sandbox; Accelerant from a
  # high block keeps these readings to what each test puts on the chain.
  @fleet "fleet_tech_accelerant"
  @contract "0x" <> String.duplicate("7", 40)
  @votes "0x" <> String.duplicate("9", 40)
  @deployed 5_000_000
  @new_hash "0x" <> String.duplicate("e", 64)
  @max_uint256 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935
  @max_bigint 9_223_372_036_854_775_807
  @ownership "0x7728f9822f7ef5ea19c1e399d729115b9cfbf4a30a69074c998576148f47b9c1"
  @seed "0x" <> String.duplicate("5a", 32)
  @other_seed "0x" <> String.duplicate("a5", 32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    %{fleet: deploy!()}
  end

  describe "recording reveals" do
    # Each reveal is numbered in chain order and the pass names the keys it
    # revealed and sold in one notice; reading the same blocks again records
    # and names nothing.
    test "each reveal is recorded once with its seed and the keys are named", %{fleet: fleet} do
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))

      StubClient.put_chain(head(@deployed + 10), [
        mint(1, @deployed + 1, 0),
        mint(2, @deployed + 2, 0),
        revealed(2, @max_uint256, @other_seed, @deployed + 3, 0),
        revealed(1, 7, @seed, @deployed + 3, 1)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      assert_received {:keys_changed, @fleet, [2, 1]}
      refute_received {:keys_changed, _fleet, _token_ids}

      assert %{
               request_id: request_id,
               seed: @seed,
               block_number: block,
               block_hash: "0x" <> _,
               transaction_hash: transaction,
               log_index: 1,
               record_seq: 2
             } = Keys.get_reveal!(@fleet, 1)

      assert Decimal.equal?(request_id, 7)
      assert {block, transaction} == {@deployed + 3, transaction(@deployed + 3)}

      assert %{seed: @other_seed, record_seq: 1, request_id: largest} =
               Keys.get_reveal!(@fleet, 2)

      assert Decimal.equal?(largest, @max_uint256)
      assert Chain.get_cursor!(@fleet).reveal_seq == 2

      StubClient.put_chain(head(@deployed + 12), [
        mint(1, @deployed + 1, 0),
        mint(2, @deployed + 2, 0),
        revealed(2, @max_uint256, @other_seed, @deployed + 3, 0),
        revealed(1, 7, @seed, @deployed + 3, 1)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      refute_received {:keys_changed, _fleet, _token_ids}
      assert Chain.get_cursor!(@fleet).reveal_seq == 2
    end

    # A reveal is its seed wherever the chain has it: moved to a later block
    # when the chain's history changed, it is the reveal already recorded.
    test "the same seed read from another block is the same reveal", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), [
        mint(1, @deployed + 1, 0),
        revealed(1, 7, @seed, @deployed + 3, 0)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      recorded = Keys.get_reveal!(@fleet, 1)
      Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(@fleet))

      moved = %{revealed(1, 7, @seed, @deployed + 5, 2) | "blockHash" => @new_hash}

      StubClient.put_chain(head(@deployed + 12), [mint(1, @deployed + 1, 0), moved],
        block_hashes: %{(@deployed + 3) => @new_hash, (@deployed + 5) => @new_hash}
      )

      assert Scanner.step(fleet, StubClient) == :ok
      assert %{rescan_from: nil, next_block: next_block} = Chain.get_cursor!(@fleet)
      assert next_block == @deployed + 13
      assert Keys.get_reveal!(@fleet, 1) == recorded
      refute_received {:keys_changed, _fleet, _token_ids}
    end

    # A second, different reveal for a key already revealed is the chain
    # disagreeing with the record: the recorded reveal's block changed, so the
    # fleet stops at the earlier of that block and the one the new reveal was
    # read from, and nothing about the key changes.
    test "a different reveal for a revealed key stops the fleet and writes nothing", %{
      fleet: fleet
    } do
      StubClient.put_chain(head(@deployed + 10), [
        mint(1, @deployed + 1, 0),
        revealed(1, 7, @seed, @deployed + 3, 0)
      ])

      assert Scanner.step(fleet, StubClient) == :ok
      recorded = Keys.get_reveal!(@fleet, 1)

      for {reveal, block} <- [
            {revealed(1, 7, @other_seed, @deployed + 3, 0), @deployed + 3},
            {revealed(1, 8, @seed, @deployed + 3, 0), @deployed + 3},
            {revealed(1, 7, @other_seed, @deployed + 6, 0), @deployed + 3}
          ] do
        StubClient.put_chain(head(@deployed + 12), [mint(1, @deployed + 1, 0), reveal])

        assert capture_log(fn -> assert Scanner.step(fleet, StubClient) == {:stopped, block} end) =~
                 "Fleet #{@fleet} stopped: the chain disagrees with the record at block #{block}"

        assert Keys.get_reveal!(@fleet, 1) == recorded
        assert %{rescan_from: ^block, reveal_seq: 1} = Chain.get_cursor!(@fleet)
        Chain.clear_divergence!(@fleet)
      end
    end
  end

  describe "the reveal table" do
    test "refuses every change, delete and emptying", %{fleet: fleet} do
      StubClient.put_chain(head(@deployed + 10), [
        mint(1, @deployed + 1, 0),
        revealed(1, 9, @seed, @deployed + 4, 0)
      ])

      assert Scanner.step(fleet, StubClient) == :ok

      for {sql, params} <- [
            {"UPDATE keyfleet_app.key_reveals SET seed = $1", [@other_seed]},
            {"DELETE FROM keyfleet_app.key_reveals", []},
            {"TRUNCATE keyfleet_app.key_reveals CASCADE", []}
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 Repo.query(sql, params, mode: :savepoint),
               sql
      end

      assert %{seed: @seed} = Keys.get_reveal!(@fleet, 1)
    end
  end

  describe "reading logs" do
    # Anything not exactly as the fleet contract emits it refuses the stretch.
    test "only reveal logs in the contract's exact encoding are read", %{fleet: fleet} do
      reveal = revealed(1, 7, @seed, @deployed + 1, 0)

      assert {:ok, [{:reveal, %{token_id: 1, seed: @seed, request_id: request_id}}]} =
               Logs.decode([reveal], fleet, @deployed, @deployed + 10)

      assert Decimal.equal?(request_id, 7)

      topic = &List.replace_at(&1["topics"], &2, &3)

      for broken <- [
            %{reveal | "address" => @votes},
            %{reveal | "topics" => topic.(reveal, 1, hex(<<0::256>>))},
            %{reveal | "topics" => topic.(reveal, 1, hex(<<@max_bigint + 1::256>>))},
            %{reveal | "topics" => Enum.drop(reveal["topics"], -1)},
            %{reveal | "topics" => reveal["topics"] ++ [hex(<<1::256>>)]},
            %{reveal | "data" => hex(<<0::248>>)},
            %{reveal | "data" => hex(<<0::512>>)},
            %{reveal | "data" => "0x"}
          ] do
        assert Logs.decode([broken], fleet, @deployed, @deployed + 10) ==
                 {:error, {:unreadable_log, broken["transactionHash"], broken["logIndex"]}},
               inspect(broken)
      end
    end
  end

  defp revealed(token_id, request_id, seed, block, log_index) do
    log(
      [RevealLog.topic(), <<token_id::256>>, <<request_id::256>>],
      bytes(seed),
      block,
      log_index
    )
  end

  defp mint(token_id, block, log_index) do
    log(
      [@ownership, <<token_id::256>>, <<0::256>>, <<0::96>> <> :binary.copy(<<0xAA>>, 20)],
      <<1::256>>,
      block,
      log_index
    )
  end

  defp log([topic0 | words], data, block, log_index) do
    %{
      "address" => @contract,
      "topics" => [topic0 | Enum.map(words, &hex/1)],
      "data" => hex(data),
      "blockNumber" => quantity(block),
      "blockHash" => "0x" <> String.duplicate("b", 64),
      "transactionHash" => transaction(block),
      "logIndex" => quantity(log_index)
    }
  end

  defp bytes("0x" <> hex), do: Base.decode16!(hex, case: :lower)
  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp quantity(value), do: "0x" <> Integer.to_string(value, 16)

  defp transaction(block),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(block, 16)), 64, "0")

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
        chain_id: 1,
        contract_address: @contract,
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: @votes,
        shards_address: "0x" <> String.duplicate("6", 40),
        usdc_address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        deployed_block: @deployed,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %System{}
    )
  end
end

defmodule Keyfleet.BrowserChain do
  @moduledoc """
  The browser tests' chain. Called on the browser test server's own node, it
  sells, moves and pairs keys of one fleet through the real chain reader and
  pairing actions, so a page open in the browser hears of them exactly as it
  would from Base.

  Every pass reads blocks well past the last one recorded, so the reader's
  second look at recent blocks never finds a record the made-up chain has
  forgotten.

  The server holds its database in one transaction for as long as it runs
  (`hold_database!/0`), and the transaction is never committed, so every run
  starts from the same unsold fleets.

  The pages' own chain reads, of the rewards waiting for a key, are answered
  by one chain the server's pages share: a key offered rewards
  (`offer_rewards!/3`) has them waiting, and for any other key the node
  fails.
  """

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.Human
  alias Keyfleet.Actors.System
  alias Keyfleet.Agents
  alias Keyfleet.Chain
  alias Keyfleet.Chain.OwnershipLog
  alias Keyfleet.Chain.Scanner
  alias Keyfleet.Chain.StubClient
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Keys
  alias Keyfleet.Repo

  @system %System{}
  @contract "0x" <> String.duplicate("5", 40)
  # cast sig "accrued(address,uint256)"
  @accrued <<0xBF, 0xE8, 0x7F, 0x4D>>
  @operator %Agent{
    wallet_address: "0x" <> String.duplicate("c", 40),
    chain_id: 8_453,
    audience: "keyfleet"
  }

  @doc """
  Opens one transaction that every process on the server shares until it
  stops, and that is thrown away with it.
  """
  def hold_database! do
    caller = self()

    spawn(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, ownership_timeout: :infinity)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      send(caller, :held)
      Process.sleep(:infinity)
    end)

    receive do
      :held -> :ok
    end
  end

  @doc "Deploys the fleet the first time and reads it; returns how many keys it has sold."
  def prepare!(fleet_id) do
    Fleets.bootstrap_catalog!()
    fleet = Fleets.get_fleet!(fleet_id)

    unless fleet.contract_address do
      Fleets.record_deployment!(
        fleet,
        %{
          chain_id: 8_453,
          contract_address: @contract,
          rewards_address: "0x" <> String.duplicate("6", 40),
          votes_address: "0x" <> String.duplicate("9", 40),
          usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
          deployed_block: 1_000,
          trait_table_hash: "0x" <> String.duplicate("a", 64)
        },
        actor: @system
      )
    end

    pass!(fleet_id, [])

    StubClient.share_chain(
      %{number: 1, hash: "0x" <> String.duplicate("f", 64), timestamp: DateTime.utc_now()},
      calls: &answer_rewards/3
    )

    minted(fleet_id)
  end

  @doc "Key `token_id` of the fleet has `amount` atomic USDC waiting from now on."
  def offer_rewards!(fleet_id, token_id, amount) do
    %{rewards_address: rewards} = Fleets.get_fleet!(fleet_id)
    :persistent_term.put(__MODULE__, Map.put(offered_rewards(), {rewards, token_id}, amount))
  end

  defp offered_rewards, do: :persistent_term.get(__MODULE__, %{})

  defp answer_rewards(rewards, <<@accrued, _usdc::binary-size(32), token_id::256>>, _block_hash) do
    case Map.fetch(offered_rewards(), {rewards, token_id}) do
      {:ok, amount} -> {:ok, <<amount::256>>}
      :error -> {:error, :chain_unavailable}
    end
  end

  @doc "Sells the fleet's next key to `owner`; returns its number."
  def sell!(fleet_id, owner) do
    token_id = minted(fleet_id) + 1
    pass!(fleet_id, [{token_id, 1, owner}])
    token_id
  end

  @doc """
  Sells a levelled fleet's keys to `owner` up to the last key of the level on
  sale, all in one block, and leaves that key unsold. Returns the level and
  its last key, as `[level, token_id]`.
  """
  def fill_level!(fleet_id, owner) do
    first = minted(fleet_id) + 1
    level = Presets.fibonacci_level_of(first)
    last = first |> Stream.iterate(&(&1 + 1)) |> Enum.find(&last_of_level?(&1, level))
    pass!(fleet_id, Enum.map(first..(last - 1)//1, &{&1, 1, owner}))
    [level, last]
  end

  @doc "Moves key `token_id` to `owner`."
  def transfer!(fleet_id, token_id, owner) do
    %{ownership_epoch: epoch} = Keys.current_key!(fleet_id, token_id)
    pass!(fleet_id, [{token_id, epoch + 1, owner}])
    :ok
  end

  @doc "An agent asks to run key `token_id`, and the key's owner approves."
  def pair!(fleet_id, token_id) do
    # Pairing waits for ownership read just now.
    pass!(fleet_id, [])
    Agents.ensure_profile!(%{name: "Browser agent", declared_harness: "test"}, actor: @operator)
    request = Keys.request_pairing!(fleet_id, token_id, %{}, actor: @operator)
    owner = %Human{human_account_id: 1, wallet_addresses: [request.owner_wallet]}
    Keys.approve_pairing!(request, Keys.default_limits(), actor: owner)
    :ok
  end

  defp last_of_level?(token_id, level),
    do:
      not Presets.fibonacci_token?(token_id + 1) or
        Presets.fibonacci_level_of(token_id + 1) > level

  defp minted(fleet_id) do
    {:ok, minted} = Chain.minted(fleet_id)
    minted
  end

  # One pass over a chain whose next block holds `changes`, as
  # `{token_id, epoch, owner}`, and whose head is well past it.
  defp pass!(fleet_id, changes) do
    fleet = Fleets.get_fleet!(fleet_id)

    block =
      case Chain.get_cursor!(fleet_id) do
        nil -> fleet.deployed_block + 40
        cursor -> cursor.next_block + 40
      end

    logs =
      changes
      |> Enum.with_index()
      |> Enum.map(fn {{token_id, epoch, owner}, index} ->
        ownership_log(fleet, token_id, epoch, owner, block, index)
      end)

    StubClient.put_chain(
      %{
        number: block + 40,
        hash: "0x" <> String.duplicate("f", 64),
        timestamp: DateTime.utc_now()
      },
      logs
    )

    :ok = Scanner.step(fleet, StubClient)
  end

  defp ownership_log(fleet, token_id, epoch, "0x" <> owner, block, log_index) do
    %{
      "address" => fleet.contract_address,
      "topics" => [
        OwnershipLog.topic(),
        word(token_id),
        word(0),
        "0x" <> String.duplicate("0", 24) <> owner
      ],
      "data" => word(epoch),
      "blockNumber" => quantity(block),
      "blockHash" => "0x" <> String.duplicate("b", 64),
      "transactionHash" => transaction_hash(fleet.id, block),
      "logIndex" => quantity(log_index)
    }
  end

  # Chain events are unique across fleets, so each fleet's block has its own
  # transaction.
  defp transaction_hash(fleet_id, block),
    do: "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet_id} #{block}"), case: :lower)

  defp word(value),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(value, 16)), 64, "0")

  defp quantity(value), do: "0x" <> Integer.to_string(value, 16)
end

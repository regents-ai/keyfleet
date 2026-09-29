defmodule Keyfleet.BrowserChain do
  @moduledoc """
  The browser tests' chain. Called on the browser test server's own node, it
  sells, moves and pairs keys of one fleet through the real chain reader and
  pairing actions, so a page open in the browser hears of them exactly as it
  would from Ethereum.

  Every pass reads blocks well past the last one recorded, so the reader's
  second look at recent blocks never finds a record the made-up chain has
  forgotten.

  The server holds its database in one transaction for as long as it runs
  (`hold_database!/0`), and the transaction is never committed, so every run
  starts from the same unsold fleets.

  The pages' own chain reads are answered by one chain the server's pages
  share. The keys are paid in USDC alone; a key offered rewards
  (`offer_rewards!/3`) has them waiting, and for any other key the node
  fails. A wallet has allowed a fleet the USDC `allow!/2` names, and none
  until then. A step a page's wallet sent is on the chain once `land!/3`
  puts it on the server's `Keyfleet.TestChainNode`.
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
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.TestChainNode
  alias Keyfleet.WorkspaceFixtures
  alias RegentChain.Call

  @system %System{}
  @contract "0x" <> String.duplicate("5", 40)
  @usdc "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  @chain_id 1
  @accrued Call.selector("accrued(address,uint256)")
  @reward_assets Call.selector("rewardAssets()")
  @allowance Call.selector("allowance(address,address)")
  # Agents sign in on Base whatever chain the keys are on.
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
      # At repeatable read, so the fleet page's one-snapshot reads can run in it.
      :ok =
        Ecto.Adapters.SQL.Sandbox.checkout(Repo,
          ownership_timeout: :infinity,
          isolation: "REPEATABLE READ"
        )

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
          chain_id: @chain_id,
          contract_address: @contract,
          rewards_address: "0x" <> String.duplicate("6", 40),
          votes_address: "0x" <> String.duplicate("9", 40),
          shards_address: "0x" <> String.duplicate("6", 40),
          usdc_address: @usdc,
          deployed_block: 1_000,
          trait_table_hash: "0x" <> String.duplicate("a", 64)
        },
        actor: @system
      )
    end

    pass!(fleet_id, [])

    StubClient.share_chain(
      %{number: 1, hash: "0x" <> String.duplicate("f", 64), timestamp: DateTime.utc_now()},
      calls: &answer/3
    )

    minted(fleet_id)
  end

  @doc "Key `token_id` of the fleet has `amount` atomic USDC waiting from now on."
  def offer_rewards!(fleet_id, token_id, amount) do
    %{rewards_address: rewards} = Fleets.get_fleet!(fleet_id)
    remember({:rewards, rewards, token_id}, amount)
  end

  @doc "`owner` has allowed every fleet `amount` atomic USDC from now on."
  def allow!(owner, amount), do: remember({:allowance, String.downcase(owner)}, amount)

  @doc """
  The step a page's wallet sent as `transaction` (its `from`, `to`, `data`
  and `value`, as the page sent them) is included under `hash`, and did what
  it asked when `succeeded`.
  """
  def land!(hash, transaction, succeeded) do
    TestChainNode.land(
      hash,
      %{
        "chainId" => quantity(@chain_id),
        "from" => transaction["from"],
        "to" => transaction["to"],
        "input" => transaction["data"],
        "value" => transaction["value"]
      },
      %{"status" => if(succeeded, do: "0x1", else: "0x0")}
    )
  end

  defp remember(key, value),
    do: :persistent_term.put(__MODULE__, Map.put(answers(), key, value))

  defp answers, do: :persistent_term.get(__MODULE__, %{})

  defp answer(_rewards, @reward_assets, _block_hash),
    do:
      {:ok,
       <<32::256, 1::256, 0::96,
         Base.decode16!(String.slice(@usdc, 2..-1//1), case: :lower)::binary>>}

  defp answer(rewards, @accrued <> <<_usdc::binary-size(64), token_id::binary-size(64)>>, _hash) do
    case Map.fetch(answers(), {:rewards, rewards, String.to_integer(token_id, 16)}) do
      {:ok, amount} -> {:ok, <<amount::256>>}
      :error -> {:error, :chain_unavailable}
    end
  end

  defp answer(@usdc, @allowance <> <<owner::binary-size(64), _fleet::binary-size(64)>>, _hash) do
    amount = Map.get(answers(), {:allowance, "0x" <> String.slice(owner, -40, 40)}, 0)
    {:ok, <<amount::256>>}
  end

  defp answer(_to, _data, _block_hash), do: {:error, :chain_unavailable}

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

  @doc """
  Gives a deployed fleet something on each of its pages to link to the
  others: a key sold to `owner` says something in the General room, the
  workspace holds a goal that discusses that message and a task assigned to
  the key, and the fleet has proposal 1. Returns the key's number.
  """
  def furnish!(fleet_id, owner) do
    Rooms.bootstrap_rooms!([fleet_id])
    token_id = sell!(fleet_id, owner)

    message =
      Rooms.send_message!(
        %{
          fleet_id: fleet_id,
          slug: "general",
          body: "The plan is in the workspace.",
          idempotency_key: Ash.UUID.generate()
        },
        actor: %Human{human_account_id: 1, wallet_addresses: [owner]}
      )

    WorkspaceFixtures.open_log(fleet_id)

    WorkspaceFixtures.create(fleet_id, "goal", %{
      "title" => "Research plan",
      "discussion" => [%{"room" => "general", "seq" => message.seq}]
    })

    WorkspaceFixtures.create(fleet_id, "task", %{
      "title" => "Draft the brief",
      "assignee_key" => token_id
    })

    ProposalHelpers.proposal!(fleet_id, 1)

    token_id
  end

  @doc "Opens the product pages when `open?`, and closes them behind the launch gate otherwise."
  def surfaces!(open?), do: Application.put_env(:keyfleet, :app_surfaces, open?)

  defp last_of_level?(token_id, level), do: Presets.fibonacci_level_of(token_id + 1) > level

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

defmodule Keyfleet.BrowserChain do
  @moduledoc """
  The browser tests' chain. Called on the browser test server's own node, it
  sells and moves keys of one fleet, and issues and ends their shards, through
  the real chain reader, so a page open in the browser hears of them exactly
  as it would from Base.

  Every pass reads blocks well past the last one recorded, so the reader's
  second look at recent blocks never finds a record the made-up chain has
  forgotten.

  The server holds its database in one transaction for as long as it runs
  (`hold_database!/0`), and the transaction is never committed, so every run
  starts from the same unsold fleets.

  The pages' own chain reads are answered by one chain the server's pages
  share. A key sold or moved here is held by its new owner there too, and a
  shard issued here is active there until it is ended here. The keys are
  paid in USDC alone, and no wallet has a credit of its own; a key offered
  rewards (`offer_rewards!/3`) has them waiting, and for any other key the
  node fails. No key has its seed yet: a key's request for its random draw
  was accepted until `refuse_draw!/3` says it was turned down. A wallet has
  allowed a fleet the USDC `allow!/2` names, and none until then. A step a
  page's wallet sent is on the chain once `land!/3` puts it on the server's
  `Keyfleet.TestChainNode`.
  """

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.Human
  alias Keyfleet.Actors.System
  alias Keyfleet.Agents
  alias Keyfleet.Chain
  alias Keyfleet.Chain.OwnershipLog
  alias Keyfleet.Chain.Scanner
  alias Keyfleet.Chain.StubClient
  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Fleet
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.TestChainNode
  alias Keyfleet.WorkspaceFixtures
  alias RegentChain.Call
  alias RegentChain.Event

  @system %System{}
  @contract "0x" <> String.duplicate("5", 40)
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @chain_id 8_453
  @accrued Call.selector("accrued(address,uint256)")
  @reward_assets Call.selector("rewardAssets()")
  @allowance Call.selector("allowance(address,address)")
  @reveal_seed Call.selector("revealSeed(uint256)")
  @reveal_requested_at Call.selector("revealRequestedAt(uint256)")
  @owner_of Call.selector("ownerOf(uint256)")
  @sales_open Call.selector("salesOpen(uint256)")
  @credits Call.selector("credits(address,address)")
  @shard_is_active Call.selector("isActive(uint256,address)")
  @shard_issued Event.topic0("ShardIssued(uint256,address,uint64,uint64)")
  @shard_ended Event.topic0("ShardEnded(uint256,address,address)")
  # A plain wallet signed in on Base, where the keys are.
  @agent %Agent{
    wallet_address: "0x" <> String.duplicate("c", 40),
    chain_id: 8_453,
    verification_method: :eoa_recovery,
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

    unless fleet.manager_address do
      Fleets.record_deployment!(
        fleet,
        ChainHelpers.deployment(fleet_id, %{
          chain_id: @chain_id,
          manager_address: @contract,
          rewards_address: "0x" <> String.duplicate("6", 40),
          shards_address: "0x" <> String.duplicate("4", 40),
          usdc_address: @usdc,
          deployed_block: 1_000
        }),
        actor: @system
      )
    end

    pass!(fleet_id, [])

    StubClient.share_chain(
      %{
        number: 1,
        hash: "0x" <> String.duplicate("f", 64),
        timestamp: DateTime.utc_now(),
        base_fee: 0
      },
      calls: &answer/3
    )

    minted(fleet_id)
  end

  @doc "Key `token_id` of the fleet has `amount` atomic USDC waiting from now on."
  def offer_rewards!(fleet_id, token_id, amount) do
    %{rewards_address: rewards} = fleet = Fleets.get_fleet!(fleet_id)
    remember({:rewards, rewards, Fleet.onchain_token_id(fleet, token_id)}, amount)
  end

  @doc """
  Key `token_id`'s request for its random draw was turned down when
  `refused`, and accepted otherwise, from now on.
  """
  def refuse_draw!(fleet_id, token_id, refused) do
    %{keys_address: keys} = fleet = Fleets.get_fleet!(fleet_id)
    remember({:draw_refused, keys, Fleet.onchain_token_id(fleet, token_id)}, refused)
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

  defp answer(_rewards, @credits <> _asset_and_account, _block_hash), do: {:ok, <<0::256>>}

  # Every fleet's Keys are on sale.
  defp answer(_keys, @sales_open <> _fleet, _block_hash), do: {:ok, <<1::256>>}

  # A key never sold has no owner, and the collection refuses to name one.
  defp answer(keys, @owner_of <> token_id, _block_hash) do
    case Map.fetch(answers(), {:owner, keys, String.to_integer(token_id, 16)}) do
      {:ok, owner} -> {:ok, address_bytes(owner)}
      :error -> {:error, :reverted}
    end
  end

  defp answer(
         shards,
         @shard_is_active <> <<token_id::binary-size(64), wallet::binary-size(64)>>,
         _hash
       ) do
    key = {:shard, shards, String.to_integer(token_id, 16), "0x" <> String.slice(wallet, -40, 40)}
    {:ok, <<if(Map.get(answers(), key, false), do: 1, else: 0)::256>>}
  end

  defp answer(_fleet, @reveal_seed <> _token_id, _block_hash), do: {:ok, <<0::256>>}

  defp answer(keys, @reveal_requested_at <> token_id, _block_hash) do
    refused? = Map.get(answers(), {:draw_refused, keys, String.to_integer(token_id, 16)}, false)
    {:ok, <<if(refused?, do: 0, else: 1)::256>>}
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

  @doc """
  Key `token_id`'s owner issues the browser agent, with a profile of its own,
  a shard of the key for 30 days.
  """
  def shard!(fleet_id, token_id) do
    Agents.ensure_profile!(%{name: "Browser agent", declared_harness: "test"},
      actor: paired_agent()
    )

    issue_shard!(fleet_id, token_id, @agent.wallet_address, 30)
  end

  # The browser's agent, paired with a person of its own the first time.
  defp paired_agent do
    case Agents.with_pairing(@agent) do
      {:ok, paired} -> paired
      {:error, :not_paired} -> Keyfleet.PairingHelpers.pair_wallet!(@agent.wallet_address)
    end
  end

  @doc "Key `token_id`'s owner has issued `wallet` a shard of the key for `days`."
  def issue_shard!(fleet_id, token_id, wallet, days) do
    %{ownership_epoch: epoch} = Keys.current_key!(fleet_id, token_id)
    expires = DateTime.to_unix(DateTime.utc_now()) + days * 86_400
    %{shards_address: shards} = fleet = Fleets.get_fleet!(fleet_id)
    onchain = Fleet.onchain_token_id(fleet, token_id)
    remember({:shard, shards, onchain, String.downcase(wallet)}, true)

    pass!(fleet_id, fn fleet, block ->
      [
        log(
          fleet.shards_address,
          [@shard_issued, word(onchain), address_word(wallet)],
          word_data([expires, epoch]),
          fleet.id,
          block,
          0
        )
      ]
    end)
  end

  @doc "The shard of key `token_id` that `wallet` holds has been ended by `by`."
  def end_shard!(fleet_id, token_id, wallet, by) do
    %{shards_address: shards} = fleet = Fleets.get_fleet!(fleet_id)
    onchain = Fleet.onchain_token_id(fleet, token_id)
    remember({:shard, shards, onchain, String.downcase(wallet)}, false)

    pass!(fleet_id, fn fleet, block ->
      [
        log(
          fleet.shards_address,
          [@shard_ended, word(onchain), address_word(wallet), address_word(by)],
          "0x",
          fleet.id,
          block,
          0
        )
      ]
    end)
  end

  @doc """
  Gives a deployed fleet something on each of its pages to link to the
  others: the agent of `owner`, sold a key, says something for them in the
  General room, the workspace holds a goal that discusses that message and a
  task assigned to the Key the message speaks as, and the fleet has proposal 1.
  Returns that Key's number: an owner who already holds a lower Key speaks as
  that one.
  """
  def furnish!(fleet_id, owner) do
    {_sold, message} = speak!(fleet_id, owner, "The plan is in the workspace.")

    WorkspaceFixtures.open_log(fleet_id)

    WorkspaceFixtures.create(fleet_id, "goal", %{
      "title" => "Research plan",
      "discussion" => [%{"room" => "general", "seq" => message.seq}]
    })

    WorkspaceFixtures.create(fleet_id, "task", %{
      "title" => "Draft the brief",
      "assignee_key" => message.as_key
    })

    ProposalHelpers.proposal!(fleet_id, 1)

    message.as_key
  end

  @doc """
  Sells the fleet's next key to `owner`, whose agent says `body` for them in the
  General room.
  Returns the key's number.
  """
  def say!(fleet_id, owner, body) do
    {token_id, _message} = speak!(fleet_id, owner, body)
    token_id
  end

  @doc "Opens the product pages when `open?`, and closes them behind the launch gate otherwise."
  def surfaces!(open?), do: Application.put_env(:keyfleet, :app_surfaces, open?)

  defp speak!(fleet_id, owner, body) do
    Rooms.bootstrap_rooms!([fleet_id])
    token_id = sell!(fleet_id, owner)

    message =
      Rooms.send_message!(
        %{fleet_id: fleet_id, slug: "general", body: body, idempotency_key: Ash.UUID.generate()},
        actor: PairingHelpers.agent_for!(%Human{human_account_id: 1, wallet_addresses: [owner]})
      )

    {token_id, message}
  end

  defp last_of_level?(token_id, level), do: Presets.fibonacci_level_of(token_id + 1) > level

  defp minted(fleet_id) do
    {:ok, minted} = Chain.minted(fleet_id)
    minted
  end

  # One pass over a chain whose next block holds the ownership `changes`, as
  # `{token_id, epoch, owner}`, and whose head is well past it.
  defp pass!(fleet_id, changes) when is_list(changes) do
    %{keys_address: keys} = fleet = Fleets.get_fleet!(fleet_id)

    for {token_id, _epoch, owner} <- changes,
        do:
          remember(
            {:owner, keys, Fleet.onchain_token_id(fleet, token_id)},
            String.downcase(owner)
          )

    pass!(fleet_id, fn fleet, block ->
      changes
      |> Enum.with_index()
      |> Enum.map(fn {{token_id, epoch, owner}, index} ->
        log(
          fleet.keys_address,
          [
            OwnershipLog.topic(),
            word(Fleet.onchain_token_id(fleet, token_id)),
            word(0),
            address_word(owner)
          ],
          word(epoch),
          fleet.id,
          block,
          index
        )
      end)
    end)
  end

  # One pass over a chain whose next block holds the logs `logs_at` makes for
  # the fleet and that block, and whose head is well past it.
  defp pass!(fleet_id, logs_at) do
    fleet = Fleets.get_fleet!(fleet_id)

    block =
      case Chain.get_cursor!(fleet_id) do
        nil -> fleet.deployed_block + 40
        cursor -> cursor.next_block + 40
      end

    StubClient.put_chain(
      %{
        number: block + 40,
        hash: "0x" <> String.duplicate("f", 64),
        timestamp: DateTime.utc_now(),
        base_fee: 0
      },
      logs_at.(fleet, block)
    )

    :ok = Scanner.step(fleet, StubClient)
  end

  defp log(address, topics, data, fleet_id, block, log_index) do
    %{
      "address" => address,
      "topics" => topics,
      "data" => data,
      "blockNumber" => quantity(block),
      "blockHash" => "0x" <> String.duplicate("b", 64),
      "transactionHash" => transaction_hash(fleet_id, block),
      "logIndex" => quantity(log_index)
    }
  end

  defp address_bytes("0x" <> address),
    do: <<0::96, Base.decode16!(address, case: :lower)::binary>>

  defp address_word("0x" <> address), do: "0x" <> String.duplicate("0", 24) <> address

  defp word_data(values),
    do: "0x" <> Enum.map_join(values, &String.slice(word(&1), 2..-1//1))

  # Chain events are unique across fleets, so each fleet's block has its own
  # transaction.
  defp transaction_hash(fleet_id, block),
    do: "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet_id} #{block}"), case: :lower)

  defp word(value),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(value, 16)), 64, "0")

  defp quantity(value), do: "0x" <> Integer.to_string(value, 16)
end

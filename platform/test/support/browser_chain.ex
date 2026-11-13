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
  shard issued here is active there until it is ended here. A key moved by
  `move_unread!/3` is moved there in a block the reader hasn't read: the
  site's record has the move only once the fleet's next pass reads it. The
  keys are paid in USDC alone, and no wallet has a credit of its own; a key
  offered rewards (`offer_rewards!/3`) has them waiting, and for any other key
  the node fails. No key has its seed yet, and no key's wait for one has been
  ended: a key's request for its random draw was accepted until
  `refuse_draw!/3` says it was turned down. A wallet has
  allowed a fleet the USDC `allow!/2` names, and none until then. A step a
  page's wallet sent is on the chain once `land!/3` puts it on the server's
  `Keyfleet.TestChainNode`. On the vote contract every key has been able to
  take part since 1970, none is present, and every proposal is open; the
  site's record has a key marked present once `present!/2` logs it.
  """

  import Ecto.Query, only: [from: 2]

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
  alias Keyfleet.GoalIdeas
  alias Keyfleet.Graph
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Polls
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.Repo
  alias Keyfleet.Rooms
  alias Keyfleet.SharedReading
  alias Keyfleet.TestChainNode
  alias Keyfleet.WorkspaceFixtures
  alias KeyfleetWeb.FleetNow
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
  @reveal_expired Call.selector("revealExpired(uint256)")
  @fleet_record Call.selector("fleet(uint256)")
  @owner_of Call.selector("ownerOf(uint256)")
  @sales_open_at Call.selector("salesOpenAt(uint256)")
  @total_minted Call.selector("totalMinted()")
  @next_price Call.selector("nextPrice()")
  @credits Call.selector("credits(address,address)")
  @shard_is_active Call.selector("isActive(uint256,address)")
  @present_now Call.selector("isActive(uint256)")
  @present_from Call.selector("presentFrom(uint256)")
  @matures_at Call.selector("maturesAt(uint256)")
  @status Call.selector("status(uint256)")
  @shard_issued Event.topic0("ShardIssued(uint256,address,uint64,uint64)")
  @shard_ended Event.topic0("ShardEnded(uint256,address,address)")
  @present Event.topic0("Present(uint256,uint64,uint64,uint64)")
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

  @doc """
  Deploys the fleet the first time, puts its Keys on sale through the manager
  every fleet shares, and reads it; returns how many keys it has sold.
  """
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
    remember(:on_sale, fleet_id)
    StubClient.share_chain(head(1), [], calls: &answer/3)

    TestChainNode.answer_calls(&answer/3)

    # Read now, so the first page opened already finds the fleet on sale.
    FleetNow.read(fleet_id)
    reread()
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

  @doc "The fleet's treasury was read just now, holding `amount` atomic USDC."
  def read_treasury!(fleet_id, amount) do
    ProposalHelpers.treasury_reading!(fleet_id, [%{asset: @usdc, held: amount, backed: 0}])
    :ok
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

  # Every fleet's Keys have been on sale since the first second of 1970.
  defp answer(_keys, @sales_open_at <> _fleet, _block_hash), do: {:ok, <<1::256>>}

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

  defp answer(_votes, @present_now <> _token_id, _block_hash), do: {:ok, <<0::256>>}
  defp answer(_votes, @present_from <> _token_id, _block_hash), do: {:ok, <<0::256>>}
  defp answer(_votes, @matures_at <> _token_id, _block_hash), do: {:ok, <<1::256>>}
  defp answer(_votes, @status <> _proposal, _block_hash), do: {:ok, <<0::256>>}

  defp answer(_fleet, @reveal_seed <> _token_id, _block_hash), do: {:ok, <<0::256>>}
  defp answer(_keys, @reveal_expired <> _token_id, _block_hash), do: {:ok, <<0::256>>}

  # Every fleet's deck is set on the chain.
  defp answer(_keys, @fleet_record <> _fleet_id, _block_hash),
    do: {:ok, <<0::256, 0::256, 1::256, 1::256, 1::256>>}

  defp answer(keys, @reveal_requested_at <> token_id, _block_hash) do
    refused? = Map.get(answers(), {:draw_refused, keys, String.to_integer(token_id, 16)}, false)
    {:ok, <<if(refused?, do: 0, else: 1)::256>>}
  end

  # Every fleet shares one manager, which sells the Keys of the fleet last
  # prepared: as many as were sold here, and the next at its price until the
  # last is sold, when the manager refuses to price one.
  defp answer(@contract, @total_minted, _block_hash),
    do: {:ok, <<minted(answers().on_sale)::256>>}

  defp answer(@contract, @next_price, _block_hash) do
    case Chain.progress(answers().on_sale).next_price do
      nil -> {:error, :reverted}
      price -> {:ok, <<price::256>>}
    end
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
  Moves key `token_id` to `owner` in a block of its own after every block the
  reader has read, and after every move made this way since: the pages'
  chain has the move at its head, and the site's record has it once the
  fleet's next pass reads it.
  """
  def move_unread!(fleet_id, token_id, owner) do
    %{keys_address: keys} = fleet = Fleets.get_fleet!(fleet_id)
    %{ownership_epoch: epoch} = Keys.current_key!(fleet_id, token_id)
    owner = String.downcase(owner)
    unread = unread(fleet_id)
    moved = Enum.count(unread, &(elem(&1, 0) == token_id))
    unread = unread ++ [{token_id, epoch + moved + 1, owner}]

    remember({:owner, keys, Fleet.onchain_token_id(fleet, token_id)}, owner)
    remember({:unread, fleet_id}, unread)

    %{next_block: from} = Chain.get_cursor!(fleet_id)

    StubClient.share_chain(head(from + length(unread)), unread_logs(fleet, from),
      calls: &answer/3
    )
  end

  @doc """
  Records the fleet's next proposal, open for a day, as the reader records
  one; returns its number.
  """
  def propose!(fleet_id) do
    number = Proposals.highest_number!(fleet_id) + 1
    ProposalHelpers.proposal!(fleet_id, number)
    reread()
    number
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
  Every Key `owner` holds in the fleet was marked present just now, as an
  agent's daily mark logs it on the fleet's vote contract.
  """
  def present!(fleet_id, owner) do
    keys = Keys.keys_held_in_fleet!(fleet_id, [owner], actor: @system)
    at = DateTime.to_unix(DateTime.utc_now())

    pass!(fleet_id, fn fleet, block ->
      keys
      |> Enum.with_index()
      |> Enum.map(fn {key, index} ->
        log(
          fleet.votes_address,
          [@present, word(Fleet.onchain_token_id(fleet, key.token_id))],
          word_data([at, block, key.ownership_epoch]),
          fleet.id,
          block,
          index
        )
      end)
    end)
  end

  @doc """
  Gives a deployed fleet something on each of its pages to link to the
  others: the agent of `owner`, sold a key, says something for them in the
  Public room, the workspace holds its starting goals, a goal that discusses
  that message and a task the Key the message speaks as has joined, and the
  fleet has proposal 1.
  Returns that Key's number: an owner who already holds a lower Key speaks as
  that one.
  """
  def furnish!(fleet_id, owner) do
    {_sold, message} = speak!(fleet_id, owner, "The plan is in the workspace.")

    WorkspaceFixtures.open_log(fleet_id)

    for {goal, number} <- Enum.reverse(Enum.with_index(GoalIdeas.starting_goals(), 1)) do
      WorkspaceFixtures.starting_goal(fleet_id, number, %{
        "title" => goal.title,
        "outcome" => goal.outcome
      })
    end

    WorkspaceFixtures.create(fleet_id, "goal", %{
      "title" => "Research plan",
      "discussion" => [%{"room" => "general", "seq" => message.seq}]
    })

    task = WorkspaceFixtures.create(fleet_id, "task", %{"title" => "Draft the brief"})
    WorkspaceFixtures.join(fleet_id, task, by: message.as_key)

    ProposalHelpers.proposal!(fleet_id, 1)
    reread()

    message.as_key
  end

  # The fleet's proposals as every visitor shares them
  # (`KeyfleetWeb.FleetProposals`) are read again a second later, as the
  # minute's heal would have them read; no job runs on the browser test
  # server, and a deployment or a proposal written here sends no notice of
  # its own.
  defp reread, do: SharedReading.heal(:fleet_proposals)

  @doc """
  Sells the fleet's next key to `owner`, whose agent says `body` for them in the
  Public room.
  Returns the key's number.
  """
  def say!(fleet_id, owner, body) do
    {token_id, _message} = speak!(fleet_id, owner, body)
    token_id
  end

  @doc "Opens the fleet's workspace log, once per fleet, before `work!/2`."
  def open_workspace!(fleet_id) do
    WorkspaceFixtures.open_log(fleet_id)
    :ok
  end

  @doc """
  Has Key `key` add a task called `title` to the fleet's workspace and tells
  the pages that show the fleet's work to anyone, as the graph's copier does
  after a change. Returns its id.
  """
  def work!(fleet_id, key, title) do
    id = WorkspaceFixtures.create(fleet_id, "task", %{"title" => title}, by: key)

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      Keyfleet.Graph.notable_topic(fleet_id),
      {:graph_notable, fleet_id}
    )

    id
  end

  @doc """
  Has Key `key` retitle the workspace item `id`, and tells the pages that read
  the fleet's workspace, as the graph's copier does after a change. The notice
  names a run of its own, so every page reads the workspace again.
  """
  def rework!(fleet_id, key, id, title) do
    WorkspaceFixtures.edit(fleet_id, id, %{"title" => title}, by: key)

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      Keyfleet.Graph.head_topic(fleet_id),
      {:graph_head, fleet_id, "browser", 0}
    )

    :ok
  end

  @doc "The address of the workspace item `id`."
  def item_path(fleet_id, id), do: KeyfleetWeb.WorkspacePage.item_path(fleet_id, id)

  @doc """
  Gives the fleet's workspace a small tree of work, opening its log first
  when no other walk has: a goal from Key 3; two tasks on it, from Keys 4 and
  5; a finding the first task produced; a copy of that task from Key 6; and
  a note from Key 7 that nothing links to. Returns their ids as JSON.
  """
  def tree!(fleet_id) do
    unless Keyfleet.Graph.get_cursor!(fleet_id, actor: @system),
      do: WorkspaceFixtures.open_log(fleet_id)

    goal = WorkspaceFixtures.create(fleet_id, "goal", %{"title" => "Chart the harbour"}, by: 3)
    task = WorkspaceFixtures.create(fleet_id, "task", %{"title" => "Sound the channel"}, by: 4)
    other = WorkspaceFixtures.create(fleet_id, "task", %{"title" => "Count the moorings"}, by: 5)

    finding =
      WorkspaceFixtures.create(fleet_id, "finding", %{"title" => "Nine metres at low tide"},
        by: 4
      )

    fork = WorkspaceFixtures.create(fleet_id, "task", %{"title" => "Sound it again"}, by: 6)
    note = WorkspaceFixtures.create(fleet_id, "note", %{"title" => "Tide tables"}, by: 7)
    WorkspaceFixtures.link(fleet_id, task, goal, "implements", by: 4)
    WorkspaceFixtures.link(fleet_id, other, goal, "implements", by: 5)
    WorkspaceFixtures.link(fleet_id, task, finding, "produces", by: 4)
    WorkspaceFixtures.link(fleet_id, fork, task, "forks", by: 6)

    Jason.encode!(%{
      goal: goal,
      task: task,
      other: other,
      finding: finding,
      fork: fork,
      note: note
    })
  end

  @doc """
  Records that `wallet`, holding Key `key`, sent `general`'s repository a
  change ending at `head`, as the code store's gateway does after git has its
  answer.
  """
  def push!(fleet_id, key, wallet, head) do
    Keyfleet.Code.record_pushes(
      fleet_id,
      Keyfleet.Projects.general(),
      %{token_id: key, wallet: wallet},
      [%{ref: "refs/heads/main", head: head}]
    )

    :ok
  end

  @doc "Opens the product pages when `open?`, and closes them behind the launch gate otherwise."
  def surfaces!(open?), do: Application.put_env(:keyfleet, :app_surfaces, open?)

  @doc """
  Gives the fleet a fortnight behind it, for its Worldline, the same every
  time: `owner`, sold a Key, talks in bursts in five of the fleet's rooms,
  adds work to the workspace and takes it up, pushes the fleet's code and
  starts polls, and the fleet opens four proposals, three of them closed
  since. Each event has a time of its own, the last a quarter of an hour ago.
  Returns the Key it all happens as.
  """
  def history!(fleet_id, owner) do
    Rooms.bootstrap_rooms!([fleet_id])
    key = sell!(fleet_id, owner)
    unless Graph.get_cursor!(fleet_id, actor: @system), do: WorkspaceFixtures.open_log(fleet_id)

    :rand.seed(:exsss, {7, 11, 13})
    last = DateTime.add(DateTime.utc_now(), -15, :minute)

    # Each step hands on the tasks still open, the newest first.
    _open =
      (talk() ++ work() ++ code() ++ polls() ++ proposals())
      |> Enum.map(fn {ago, what} -> {DateTime.add(last, -ago), what} end)
      |> Enum.sort_by(&elem(&1, 0), DateTime)
      |> Enum.reduce([], fn {at, what}, tasks ->
        happen!(fleet_id, %{key: key, owner: owner, at: at}, what, tasks)
      end)

    reread()
    key
  end

  @day 86_400
  @rooms ~w(general people coding business voting)
  @lines [
    "Morning. Picking up the hull survey today.",
    "Pushed the survey script, it reads the new sensors too.",
    "Can someone check the rotor readings from last night?",
    "Notes are in the workspace.",
    "Running the notebook again with the cleaned data.",
    "Looks good to me.",
    "I'll take the second half of the plates.",
    "Found a gap in the readings around noon.",
    "The vote closes tomorrow, have a look before then.",
    "Thanks, merged.",
    "Back in an hour.",
    "The plates need another pass.",
    "Agreed.",
    "Who has the latest numbers?",
    "Shared the chart in the notebook.",
    "That matches what I saw on the second rig."
  ]
  @items ~w(task task task goal note)
  @titles [
    "Survey the hull",
    "Map the plates",
    "Check the rotor readings",
    "Draft the brief",
    "Compare the two rigs",
    "Write up the findings",
    "Clean the sensor data",
    "Plan the next sprint",
    "Review the budget",
    "Test the new script"
  ]

  # Each history is a list of `{seconds before the last event, what happens}`.
  # Two or three conversations a day, each of three to a dozen posts a minute
  # or two apart.
  defp talk do
    for day <- 0..13, _talk <- 1..(1 + :rand.uniform(2)), reduce: [] do
      events ->
        slug = Enum.random(@rooms)
        start = day * @day + 3600 + :rand.uniform(@day - 3600)

        for(
          n <- 0..(1 + :rand.uniform(10)),
          do: {start - n * (40 + :rand.uniform(140)), {:post, slug, Enum.random(@lines)}}
        ) ++ events
    end
  end

  # A dozen sittings in the workspace, each adding two to five items, then
  # taking up the newest task and finishing one.
  defp work do
    for _sitting <- 1..12, reduce: [] do
      events ->
        start = 7200 + :rand.uniform(14 * @day - 7200)

        items =
          for n <- 0..(1 + :rand.uniform(3)),
              do: {start - n * (120 + :rand.uniform(600)), {:work, Enum.random(@items)}}

        [{start - 3000, :join}, {start - 3600, :done} | items] ++ events
    end
  end

  # Nine sittings of one to four pushes, a few minutes apart.
  defp code do
    for _sitting <- 1..9, reduce: [] do
      events ->
        start = 3600 + :rand.uniform(14 * @day - 3600)

        for(n <- 0..(:rand.uniform(4) - 1), do: {start - n * (300 + :rand.uniform(600)), :push}) ++
          events
    end
  end

  defp polls,
    do: [
      {11 * @day + 5000, {:poll, "Which rig next?"}},
      {6 * @day + 31_000, {:poll, "Move the check-in to mornings?"}},
      {2 * @day + 12_000, {:poll, "Ship the survey this week?"}}
    ]

  # Each open for three days: all but the newest have closed.
  defp proposals, do: for(days <- [12.3, 8.6, 4.2, 1.1], do: {round(days * @day), :propose})

  defp happen!(fleet_id, %{key: key, owner: owner, at: at}, {:post, slug, body}, tasks) do
    room = Rooms.get_room!(fleet_id, slug, actor: holder(owner))

    # Written as the room's store keeps a post, so it keeps the time it was
    # said; posting through the room stamps it now.
    Repo.insert_all(
      "messages",
      [
        %{
          id: Ecto.UUID.dump!(Ash.UUID.generate()),
          seq: Rooms.Sequence.next!(room.id),
          fleet_id: fleet_id,
          room_id: Ecto.UUID.dump!(room.id),
          kind: "post",
          in_key_thread: false,
          author_kind: "human",
          author_wallet: owner,
          as_key: key,
          body: body,
          body_digest: Base.encode16(:crypto.hash(:sha256, body), case: :lower),
          idempotency_key: Ash.UUID.generate(),
          inserted_at: DateTime.to_naive(at)
        }
      ],
      prefix: "keyfleet_app"
    )

    tasks
  end

  defp happen!(fleet_id, %{key: key, at: at}, {:work, type}, tasks) do
    id =
      logged!(fleet_id, at, fn ->
        WorkspaceFixtures.create(fleet_id, type, %{"title" => Enum.random(@titles)}, by: key)
      end)

    if type == "task", do: [id | tasks], else: tasks
  end

  defp happen!(_fleet_id, _when, step, []) when step in [:join, :done], do: []

  defp happen!(fleet_id, %{key: key, at: at}, :join, [task | _] = tasks) do
    logged!(fleet_id, at, fn -> WorkspaceFixtures.join(fleet_id, task, by: key) end)
    tasks
  end

  defp happen!(fleet_id, %{key: key, at: at}, :done, [task | rest]) do
    logged!(fleet_id, at, fn ->
      WorkspaceFixtures.edit(fleet_id, task, %{"progress" => "done"}, by: key)
    end)

    rest
  end

  defp happen!(fleet_id, %{key: key, owner: owner, at: at}, :push, tasks) do
    head =
      Base.encode16(:crypto.hash(:sha, "#{fleet_id}/#{DateTime.to_iso8601(at)}"), case: :lower)

    push!(fleet_id, key, owner, head)

    # The gateway stamps a push now; the history moves it back to its own time.
    Repo.update_all(
      from(push in "code_pushes", where: push.fleet_id == ^fleet_id and push.head == ^head),
      [set: [pushed_at: DateTime.to_naive(at)]],
      prefix: "keyfleet_app"
    )

    tasks
  end

  defp happen!(fleet_id, %{owner: owner, at: at}, {:poll, question}, tasks) do
    poll =
      Polls.start_poll!(
        %{fleet_id: fleet_id, question: question, choices: ["Yes", "No"], minutes: 60},
        actor: holder(owner)
      )

    # Starting a poll stamps it now; the history moves it back to its own
    # time, closing an hour later.
    Repo.update_all(
      from(row in "polls", where: row.id == ^Ecto.UUID.dump!(poll.id)),
      [
        set: [
          inserted_at: DateTime.to_naive(at),
          closes_at: DateTime.to_naive(DateTime.add(at, 60, :minute))
        ]
      ],
      prefix: "keyfleet_app"
    )

    tasks
  end

  defp happen!(fleet_id, %{at: at}, :propose, tasks) do
    opened_at = DateTime.truncate(at, :second)

    ProposalHelpers.proposal!(fleet_id, Proposals.highest_number!(fleet_id) + 1, %{
      opened_at: opened_at,
      closes_at: DateTime.add(opened_at, 3 * @day)
    })

    tasks
  end

  # A change to the workspace, logged at `at`: the log stamps its events now,
  # so they are moved back to their own time.
  defp logged!(fleet_id, at, change) do
    %{applied_seq: before} = Graph.get_cursor!(fleet_id, actor: @system)
    result = change.()

    Repo.update_all(
      from(event in "graph_events", where: event.fleet_id == ^fleet_id and event.seq > ^before),
      [set: [timestamp: DateTime.to_iso8601(at)]],
      prefix: "keyfleet_app"
    )

    result
  end

  defp holder(owner), do: %Human{human_account_id: 1, wallet_addresses: [owner]}

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
      |> Enum.map(fn {change, index} -> moved_log(fleet, change, block, index) end)
    end)
  end

  # One pass over a chain whose next block holds the logs `logs_at` makes for
  # the fleet and that block, after the moves the reader hasn't read yet, and
  # whose head is past the 300 blocks the scanner reads again, so the next
  # pass never reads this block again.
  defp pass!(fleet_id, logs_at) do
    fleet = Fleets.get_fleet!(fleet_id)

    from =
      case Chain.get_cursor!(fleet_id) do
        nil -> fleet.deployed_block
        cursor -> cursor.next_block
      end

    block = from + 40
    StubClient.put_chain(head(block + 340), unread_logs(fleet, from) ++ logs_at.(fleet, block))
    :ok = Scanner.step(fleet, StubClient)
    remember({:unread, fleet_id}, [])
  end

  # The moves `move_unread!/3` made since the fleet's last pass, in order, as
  # `{token_id, epoch, owner}`.
  defp unread(fleet_id), do: Map.get(answers(), {:unread, fleet_id}, [])

  # Each of those moves logged in a block of its own from `from`.
  defp unread_logs(fleet, from) do
    fleet.id
    |> unread()
    |> Enum.with_index(from)
    |> Enum.map(fn {change, block} -> moved_log(fleet, change, block, 0) end)
  end

  defp moved_log(fleet, {token_id, epoch, owner}, block, index),
    do:
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

  defp head(number),
    do: %{
      number: number,
      hash: "0x" <> String.duplicate("f", 64),
      timestamp: DateTime.utc_now(),
      base_fee: 0
    }

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

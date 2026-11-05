defmodule Keyfleet.SharedReading do
  @moduledoc """
  A figure every visitor sees alike, read once and shared by every open page.

  It is for a reading no saved row carries (a chain's newest block) or one built
  from many rows (a list of the latest trades). A public row saved through Ash
  reaches pages through its own `pub_sub` publication instead, and anything that
  differs by viewer is reread under that viewer's scope: neither belongs here.
  The rule and its reasons are in the `ash-frontend` skill,
  `references/public-figures.md`.

  One producer owns each key and calls `put/2` when it has a reading, or
  `degraded/1` when it could not get one. A page calls `subscribe/1`, then
  `fetch/1`, and on each `{:shared_reading, key}` it fetches again:

      def mount(_params, _session, socket) do
        key = Keyfleet.Agents.Here.fleet_key("regents_club")
        if connected?(socket), do: Keyfleet.SharedReading.subscribe(key)
        {:ok, assign(socket, here: Keyfleet.SharedReading.fetch(key))}
      end

      def handle_info({:shared_reading, key}, socket),
        do: {:noreply, assign(socket, here: Keyfleet.SharedReading.fetch(key))}

  Pages are woken only when the reading or its `degraded?` mark differs from the
  one held; `at`, the moment it was last read, moves without waking anyone. A
  wake-up reaches this machine's pages only, because each machine keeps its own
  table and runs its own producers.

  A reading never disables or delays an on-chain button. Stale, degraded or
  absent, every button stays live; only the chain's own state at the latest
  block, read for that press, may block one.

  ## Kinds

  A key is `{kind, id}`. `kind` is one of `@kinds` and `id` is an integer or a
  short string the site already holds in its own rows or settings, never text
  from a request. Each kind states why every visitor may see it, the most keys
  it may hold and the largest reading it accepts, so adding one is a reviewed
  change. A reading is small plain data: numbers, strings, atoms, dates,
  `Decimal`s, and maps, lists or tuples of them. An Ash record or any other
  struct is refused, as is a reading over its kind's size.

  Every kind also states `within`: the seconds inside which a working producer
  reads each of its keys again, whether or not anything changed. A reader of an
  outside clock does so on its own interval. A producer that rereads on notice
  does so when `heal/1` asks, each minute (`Keyfleet.SharedReading.Heal`),
  which is also what mends a notice that was lost. A key older than its kind's
  `within` is late, whatever the kind.

  ## Measurements

  `measure/0` runs with the site's other periodic measurements and reports, for
  each kind, how many keys it holds, how many of them have never been read, how
  many are late and how long ago its oldest reading was taken
  (`[:keyfleet, :shared_reading, :kind]`), and the table's size in memory
  (`[:keyfleet, :shared_reading, :table]`). Every `degraded/1` is counted
  (`[:keyfleet, :shared_reading, :degraded]`), as is every refused reading
  (`[:keyfleet, :shared_reading, :refused]`) and every wake-up sent to pages
  (`[:keyfleet, :shared_reading, :woken]`), by kind.
  """

  use GenServer

  @table __MODULE__

  # open: why a signed-out visitor may see it. keys: the most this kind holds.
  # bytes: the largest reading, measured as `:erlang.external_size/1`.
  # within: the seconds inside which a working producer reads every key again.
  @kinds %{
    fleet_agents: %{
      open:
        "the agents here and what their check-ins say are open to a signed-out read " <>
          "(Keyfleet.Agents.AgentProfile :here_in_fleet, Keyfleet.Agents.CheckIn read policy) " <>
          "and in the open fleet directory; if either policy tightens, this kind changes with it. " <>
          "Its two holder counts are numbers only: how many addresses hold a Key, which the " <>
          "chain shows anyone, and how many of them acted in the last hour, naming nobody. " <>
          "Its faces name the holder of each of the agents' Keys, the Key they write as and " <>
          "how many Keys they hold (Keyfleet.Keys.faces/2): the chain shows who holds each Key, " <>
          "every address an account links is public as the Member List shows, and the Key a " <>
          "person writes as shows beside everything they write",
      # One for each fleet in Keyfleet.Fleets' catalog: a sixth fleet raises
      # it, or its Here now is refused and shown as not counted.
      keys: 5,
      # 26,881 bytes measured at its fullest before faces, which add about
      # 120 bytes for each of up to 50 Keys; the rest leaves room for a longer
      # picture address in production.
      bytes: 40_960,
      within: 120
    },
    key_agents: %{
      open:
        "a Key's active shards and their agents are open to a signed-out read " <>
          "(Keyfleet.Keys.ShardEvent and Keyfleet.Agents.CheckIn read policies); " <>
          "if either policy tightens, this kind changes with it",
      keys: 10_000,
      bytes: 20_480,
      within: 120
    },
    fleet_now: %{
      open:
        "a fleet's activity, what it is working on and how far it has sold, as a signed-out " <>
          "visitor reads them, are open to a signed-out read: Keyfleet.Activity.page/3 and " <>
          "headline/2 with no actor (the Public room and the Keys' threads, under the " <>
          "Keyfleet.Rooms.Message read policy, and no workspace changes), " <>
          "Keyfleet.Graph.shown/1 (the :titles read of projects and :open_goals), the fleet's " <>
          "record, and the Keys sold " <>
          "(Keyfleet.Chain.minted/2), which the chain shows anyone, and the holders of the Keys " <>
          "in its activity with the Key each writes as (Keyfleet.Keys.faces/2), as open as the " <>
          "Member List and what they write; if any of these tightens, this kind changes with it",
      # One for each fleet in Keyfleet.Fleets' catalog, like fleet_agents.
      keys: 5,
      # Not yet measured at its fullest: a page of 30 activity items, the
      # projects and their open goals, and a few numbers. A reading over it is refused and
      # counted, and pages keep the one before.
      bytes: 65_536,
      within: 120
    },
    fleet_proposals: %{
      open:
        "the first page of a fleet's proposals, their tallies and words, is open to a signed-out " <>
          "read (Keyfleet.Proposals.Proposal, Vote, Cancellation, Execution and Words read " <>
          "policies), with the fleet's record, its chain cursor (Keyfleet.Chain.Cursor) and the " <>
          "tokens its treasury pays in (Keyfleet.Treasury.AssetDetails and Reading read " <>
          "policies); if any of these tightens, this kind changes with it",
      # One for each fleet in Keyfleet.Fleets' catalog, like fleet_agents.
      keys: 5,
      # Not yet measured: twenty proposals, each with up to 4,000 bytes of words.
      bytes: 131_072,
      within: 120
    },
    fleet_treasury: %{
      open:
        "a fleet's Treasury page is open to a signed-out read: its latest reading, money " <>
          "history and advances (Keyfleet.Treasury.Reading, Event and AssetDetails read " <>
          "policies), the votes carried out (Keyfleet.Proposals.Proposal and Execution), the " <>
          "fleet's record, its chain cursor and the Keys sold (Keyfleet.Keys.KeyAttachment), " <>
          "which the chain shows anyone; if any of these tightens, this kind changes with it",
      keys: 5,
      # Not yet measured: the latest history, the open advances and five votes carried out.
      bytes: 65_536,
      within: 120
    },
    share_card: %{
      open:
        "the figures on a fleet's share picture are open to a signed-out read: its Keys sold " <>
          "(Keyfleet.Chain.minted/2) and the Key to change hands last " <>
          "(Keyfleet.Keys.KeyAttachment), which the chain shows anyone, its treasury's latest " <>
          "reading (Keyfleet.Treasury.Reading read policy), and that Key's name and card " <>
          "picture (Keyfleet.Keys.KeyReveal and KeyPicture read policies), which its Key's " <>
          "page shows anyone; if any of these tightens, this kind changes with it",
      # One for each fleet with a picture of its own (KeyfleetWeb.ShareCard.fleets/0).
      keys: 2,
      # A few short lines: the Keys, up to three treasury amounts, a Key's name
      # and an IPFS address.
      bytes: 1_024,
      within: 120
    },
    proposal: %{
      open:
        "a proposal's first page is open to a signed-out read: the proposal, its calls, its " <>
          "first fifty votes and its words (Keyfleet.Proposals.Proposal, Vote, Cancellation, " <>
          "Execution and Words read policies), what its calls come to at the treasury's latest " <>
          "balance (Keyfleet.Treasury.Reading and AssetDetails) and where it stands on the vote " <>
          "contract, which the chain shows anyone; if any of these tightens, this kind changes " <>
          "with it",
      # Twenty for each catalog fleet, with room for a pass to put new proposals
      # before it deletes the ones they pushed off the list.
      keys: 200,
      # Up to 4,000 bytes of words, fifty votes and the calls; a larger one is
      # refused, counted, and read for each visit instead.
      bytes: 131_072,
      within: 120
    }
  }

  @type key :: {kind :: atom(), id :: integer() | String.t()}
  @type entry :: %{reading: term(), at: DateTime.t() | nil, degraded?: boolean()}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The reading held for `key`, or `:error` while there is none."
  @spec fetch(key()) :: {:ok, entry()} | :error
  def fetch({kind, id} = key)
      when is_map_key(@kinds, kind) and (is_integer(id) or is_binary(id)) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] -> {:ok, entry}
      [] -> :error
    end
  rescue
    # No table for the instant its owner restarts: the same as no reading.
    ArgumentError -> :error
  end

  @doc "The largest reading `kind` accepts, as `:erlang.external_size/1` measures it."
  @spec bytes(atom()) :: pos_integer()
  def bytes(kind) when is_map_key(@kinds, kind), do: @kinds[kind].bytes

  @doc "Hear `{:shared_reading, key}` whenever the reading for `key` changes."
  @spec subscribe(key()) :: :ok
  def subscribe(key), do: Phoenix.PubSub.subscribe(Keyfleet.PubSub, topic(checked(key)))

  @doc "Stops hearing `key`, for a page that stays open and no longer shows it."
  @spec unsubscribe(key()) :: :ok
  def unsubscribe(key), do: Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, topic(checked(key)))

  @doc """
  Stores `reading` as read just now. Answers `{:error, :too_large}`,
  `{:error, :not_plain}` or `{:error, :too_many_keys}` when it is refused; the
  reading held before then stays.
  """
  @spec put(key(), term()) :: :ok | {:error, :too_large | :not_plain | :too_many_keys}
  def put(key, reading) do
    {kind, _id} = checked(key)

    # Checked here, in the producer, so a reading that cannot be checked fails
    # its producer and never the table's owner.
    with :ok <- fits(kind, reading) do
      GenServer.call(__MODULE__, {:put, key, reading})
    end
    |> counted(kind)
  end

  @doc """
  Marks `key` as not read this time. The last reading stays, marked `degraded?`;
  a key that never had one holds `reading: nil`.
  """
  @spec degraded(key()) :: :ok | {:error, :too_many_keys}
  def degraded(key) do
    {kind, _id} = checked(key)
    counted(GenServer.call(__MODULE__, {:degraded, key}), kind)
  end

  @doc """
  Asks the producer of `kind`, on every machine, to read all its keys again.
  The producer hears `{:shared_reading_heal, kind}` after `subscribe_heal/1`.
  """
  @spec heal(atom()) :: :ok
  def heal(kind) when is_map_key(@kinds, kind) do
    Phoenix.PubSub.broadcast(Keyfleet.PubSub, heal_topic(kind), {:shared_reading_heal, kind})
  end

  @spec subscribe_heal(atom()) :: :ok
  def subscribe_heal(kind) when is_map_key(@kinds, kind),
    do: Phoenix.PubSub.subscribe(Keyfleet.PubSub, heal_topic(kind))

  @doc "Forgets `key`, when the row or setting it stood for has ended."
  @spec delete(key()) :: :ok
  def delete(key), do: GenServer.call(__MODULE__, {:delete, checked(key)})

  @doc """
  The ids of every key held for `kind`. A producer whose keys come and go reads
  this on each pass and deletes the ones its fresh read no longer has, so it
  keeps no list of its own, and a restart of the producer alone leaves no key
  behind.

  It is for a producer's pass only, never a page's mount or each event: it walks
  the whole table. Never count with it either: it answers `[]` in the instant
  the table's owner restarts, which a measurement would show as a healthy zero.
  """
  @spec ids(atom()) :: [integer() | String.t()]
  def ids(kind) when is_map_key(@kinds, kind) do
    :ets.select(@table, [{{{kind, :"$1"}, :_}, [], [:"$1"]}])
  rescue
    # No table for the instant its owner restarts: nothing is held.
    ArgumentError -> []
  end

  @doc false
  def measure do
    now = DateTime.utc_now()

    # Each key's kind and when it was read; the readings themselves stay put.
    held =
      @table
      |> :ets.select([{{{:"$1", :_}, %{at: :"$2"}}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # Every kind each tick, so a kind whose keys are all gone reads 0.
    for {kind, %{within: within}} <- @kinds do
      ats = Map.get(held, kind, [])
      read = for %DateTime{} = at <- ats, do: DateTime.diff(now, at, :millisecond)

      :telemetry.execute(
        [:keyfleet, :shared_reading, :kind],
        %{
          keys: length(ats),
          never_read: length(ats) - length(read),
          late: Enum.count(read, &(&1 > within * 1_000)),
          oldest_seconds: Enum.max(read, fn -> 0 end) / 1_000
        },
        %{kind: kind}
      )
    end

    :telemetry.execute(
      [:keyfleet, :shared_reading, :table],
      %{bytes: :ets.info(@table, :memory) * :erlang.system_info(:wordsize)},
      %{}
    )
  rescue
    # The poller drops a measurement that raises for good. No table for the
    # instant its owner restarts, which can fall between the two reads above
    # (the size then reads :undefined): skip this tick.
    [ArgumentError, ArithmeticError] -> :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:put, key, reading}, _from, state) do
    held = held(key)

    reply =
      with :ok <- room(key, held),
           do: store(key, held, %{reading: reading, at: DateTime.utc_now(), degraded?: false})

    {:reply, reply, state}
  end

  def handle_call({:degraded, {kind, _id} = key}, _from, state) do
    held = held(key)
    :telemetry.execute([:keyfleet, :shared_reading, :degraded], %{count: 1}, %{kind: kind})

    reply =
      with :ok <- room(key, held),
           do: store(key, held, Map.put(held || %{reading: nil, at: nil}, :degraded?, true))

    {:reply, reply, state}
  end

  def handle_call({:delete, key}, _from, state) do
    if :ets.member(@table, key) do
      :ets.delete(@table, key)
      wake(key)
    end

    {:reply, :ok, state}
  end

  defp held(key) do
    case :ets.lookup(@table, key) do
      [{^key, entry}] -> entry
      [] -> nil
    end
  end

  # Stored first, so a page woken by it reads the new entry.
  defp store(key, held, entry) do
    :ets.insert(@table, {key, entry})
    if changed?(held, entry), do: wake(key)
    :ok
  end

  defp changed?(nil, _entry), do: true

  defp changed?(held, entry),
    do: held.reading != entry.reading or held.degraded? != entry.degraded?

  defp wake({kind, _id} = key) do
    :telemetry.execute([:keyfleet, :shared_reading, :woken], %{count: 1}, %{kind: kind})
    Phoenix.PubSub.local_broadcast(Keyfleet.PubSub, topic(key), {:shared_reading, key})
  end

  defp topic({kind, id}), do: "shared_reading:#{kind}:#{id}"
  defp heal_topic(kind), do: "shared_reading_heal:#{kind}"

  defp counted(:ok, _kind), do: :ok

  defp counted({:error, reason} = refused, kind) do
    :telemetry.execute([:keyfleet, :shared_reading, :refused], %{count: 1}, %{
      kind: kind,
      reason: reason
    })

    refused
  end

  defp fits(kind, reading) do
    cond do
      :erlang.external_size(reading) > bytes(kind) -> {:error, :too_large}
      not plain?(reading) -> {:error, :not_plain}
      true -> :ok
    end
  end

  defp room(_key, %{}), do: :ok

  defp room({kind, _id}, nil) do
    if :ets.select_count(@table, [{{{kind, :_}, :_}, [], [true]}]) < @kinds[kind].keys,
      do: :ok,
      else: {:error, :too_many_keys}
  end

  defp plain?(%module{}), do: module in [DateTime, Date, Decimal]

  defp plain?(map) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> plain?(key) and plain?(value) end)

  defp plain?([]), do: true
  defp plain?([head | tail]), do: plain?(head) and plain?(tail)
  defp plain?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> plain?()
  defp plain?(term), do: is_number(term) or is_binary(term) or is_atom(term)

  # A key is built by site code from a fixed kind and an id the site holds.
  defp checked({kind, id} = key)
       when is_map_key(@kinds, kind) and (is_integer(id) or is_binary(id)),
       do: key
end

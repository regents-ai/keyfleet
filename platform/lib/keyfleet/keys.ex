defmodule Keyfleet.Keys do
  @moduledoc """
  Key ownership, reveals, shards, agent voting, presence and edit
  restrictions projected from contract events, and which Keys have
  their card picture.
  """
  use Ash.Domain

  import Ecto.Query, only: [from: 2, subquery: 1, union: 2, union_all: 2]

  require Ash.Query
  require Logger

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.Human
  alias Keyfleet.Decks
  alias Keyfleet.Fleets.Fleet

  resources do
    resource Keyfleet.Keys.KeyAttachment do
      define :record_epoch, action: :record_epoch
      define :key_history, action: :history, args: [:fleet_id, :token_id]
      define :current_key, action: :current, args: [:fleet_id, :token_id], not_found_error?: false

      define :held_identity_key,
        action: :identity_in_fleet,
        args: [:fleet_id, :owner_wallets],
        not_found_error?: false

      define :newest_key_change,
        action: :newest_in_fleet,
        args: [:fleet_id],
        not_found_error?: false

      define :keys_in_fleet, action: :current_in_fleet, args: [:fleet_id]
      define :keys_held_in_fleet, action: :held_in_fleet, args: [:fleet_id, :owner_wallets]
      define :keys_held_everywhere, action: :held_everywhere, args: [:owner_wallets]

      define :recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :epochs_recorded_since, action: :recorded_since, args: [:fleet_id, :after_seq]

      define :epochs_recorded_before,
        action: :recorded_before,
        args: [:fleet_id, :before_seq, :limit]

      define :lowest_keys_held, action: :lowest_held, args: [:fleet_id, :owner_wallets]
    end

    resource Keyfleet.Keys.KeyReveal do
      define :record_reveal, action: :record
      define :get_reveal, action: :read, get_by: [:fleet_id, :token_id], not_found_error?: false
      define :reveals_recorded_since, action: :recorded_since, args: [:fleet_id, :after_seq]
      define :reveals_of_keys, action: :of_keys, args: [:fleet_id, :token_ids]
    end

    resource Keyfleet.Keys.KeyPicture do
      define :record_picture, action: :record

      define :get_picture,
        action: :read,
        get_by: [:fleet_id, :token_id, :seed],
        not_found_error?: false

      define :pictures_of_keys, action: :of_keys, args: [:fleet_id, :token_ids]
    end

    resource Keyfleet.Keys.ShardEvent do
      define :record_shard_event, action: :record

      define :shard_events_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :shard_events_recorded_since, action: :recorded_since, args: [:fleet_id, :after_seq]

      define :shard_events_recorded_before,
        action: :recorded_before,
        args: [:fleet_id, :before_seq, :limit]

      define :active_shard,
        action: :active_of_key_held_by,
        args: [:fleet_id, :token_id, :wallet],
        not_found_error?: false

      define :active_shards_held_by, action: :active_held_by, args: [:wallet]
      define :active_shards_of_keys, action: :active_of_keys, args: [:fleet_id, :token_ids]
      define :active_shards_in_fleet, action: :active_in_fleet, args: [:fleet_id]
      define :keys_with_shards, action: :keys_with_shards, args: [:fleet_id]

      define :shards_issued_by_owner,
        action: :issued_by_owner,
        args: [:fleet_id, :token_id, :owner]
    end

    resource Keyfleet.Keys.AgentVoting do
      define :record_agent_voting, action: :record

      define :agent_voting_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :agent_voting_recorded_since, action: :recorded_since, args: [:fleet_id, :after_seq]
    end

    resource Keyfleet.Keys.Presence do
      define :record_presence, action: :record

      define :presences_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end

    resource Keyfleet.Keys.PostingKey do
      define :choose_posting_key, action: :choose, args: [:fleet_id, :token_id]
      define :posting_key, action: :in_fleet, args: [:fleet_id], not_found_error?: false

      define :posting_keys_of_accounts,
        action: :of_accounts,
        args: [:fleet_id, :human_account_ids]
    end

    resource Keyfleet.Keys.EditsRestriction do
      define :record_edits_restriction, action: :record

      define :edits_restrictions_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :edits_restrictions_recorded_since,
        action: :recorded_since,
        args: [:fleet_id, :after_seq]

      define :latest_edits_restrictions,
        action: :latest_for_keys,
        args: [:fleet_id, :token_ids]
    end
  end

  @doc """
  The seed Key `token_id` of `fleet` draws its card's traits from, or `nil`
  while it has none. A Key within the deck is dealt the deck's card by number,
  Key N card N − 1 (`Keyfleet.Fleets.Fleet.dealt?/2`); a Key past it shows its
  recorded reveal's seed, once the reveal is read. Ask only for a Key that has
  been minted: a dealt card is never shown before its Key exists.
  """
  def card_seed(%{id: fleet_id, deck_hash: deck_hash} = fleet, token_id) do
    if Fleet.dealt?(fleet, token_id) do
      elem(Decks.deck!(deck_hash).cards, token_id - 1)
    else
      case get_reveal!(fleet_id, token_id) do
        nil -> nil
        reveal -> reveal.seed
      end
    end
  end

  @doc """
  The seed of each of the minted Keys `token_ids` of `fleet` that has one, by
  Key number (`card_seed/2`), in one read however many Keys are asked for, a
  hundred at most.
  """
  def card_seeds(%{id: fleet_id, deck_hash: deck_hash} = fleet, token_ids) do
    {dealt, drawn} = Enum.split_with(token_ids, &Fleet.dealt?(fleet, &1))

    dealt =
      case dealt do
        [] -> %{}
        dealt -> Map.new(dealt, &{&1, elem(Decks.deck!(deck_hash).cards, &1 - 1)})
      end

    for reveal <- reveals_of_keys!(fleet_id, drawn),
        into: dealt,
        do: {reveal.token_id, reveal.seed}
  end

  @doc "Whether the key's workspace edits are restricted by a vote of the fleet right now."
  def edits_restricted?(fleet_id, token_id, opts \\ []) do
    with {:ok, latest} <- latest_edits_restrictions(fleet_id, [token_id], opts) do
      {:ok, match?([%{restricted: true}], latest)}
    end
  end

  @doc """
  Where a fleet's pages hear which of its keys have just changed: sold, changed
  hands, revealed, a shard issued or ended, agent voting turned on or off, or
  edits restricted or allowed, as
  `{:keys_changed, fleet_id, token_ids}`.
  """
  def topic(fleet_id), do: "fleet:#{fleet_id}:keys"

  @doc """
  The key `actor` is in a fleet today, as `%{token_id: token_id, wallet: wallet}`,
  or `nil` when it neither holds one of the fleet's keys nor has a shard of one.

  Keys rank by the order they were sold, the first key sold ranking highest. A
  person is the key they chose to write as on the Account page while their
  wallets hold it (`Keyfleet.Keys.PostingKey`), else the highest-ranked key
  their wallets hold, and `wallet` is the one holding it. An agent is the
  highest-ranked key its wallet holds, or else the highest-ranked key it holds
  an active shard of, and `wallet` is its own. Everything either writes in the
  fleet is written as that key.

  An agent with neither, paired with a person whose account is here (`Keyfleet.Actors.Agent`'s `pairing`), is that person's key, with
  `for_person: true`: what it writes there is the person's, marked as the
  agent's.
  """
  def identity(%Human{wallet_addresses: [_ | _] = wallets} = actor, fleet_id) do
    case chosen_key(actor, fleet_id) || held_identity_key!(fleet_id, wallets, actor: actor) do
      nil -> nil
      key -> %{token_id: key.token_id, wallet: key.owner_wallet}
    end
  end

  def identity(%Agent{wallet_address: wallet} = actor, fleet_id) do
    case Agent.refresh(actor) do
      {:ok, actor} ->
        case held_or_shard(fleet_id, wallet, actor) do
          %{token_id: token_id} -> %{token_id: token_id, wallet: wallet}
          nil -> for_person(actor.pairing, fleet_id)
        end

      _ ->
        nil
    end
  end

  def identity(_actor, _fleet_id), do: nil

  # The key the person chose to write as, while one of their wallets holds it.
  defp chosen_key(%Human{wallet_addresses: wallets} = actor, fleet_id) do
    with %{token_id: token_id} <- posting_key!(fleet_id, actor: actor),
         %{owner_wallet: owner} = key <- current_key!(fleet_id, token_id, actor: actor),
         true <- owner in wallets do
      key
    else
      _not_held -> nil
    end
  end

  defp for_person(%Human{} = person, fleet_id) do
    case identity(person, fleet_id) do
      nil -> nil
      identity -> Map.put(identity, :for_person, true)
    end
  end

  defp for_person(_missing, _fleet_id), do: nil

  @doc """
  Every key `actor` may act as in a fleet today, lowest first, each as
  `%{token_id: token_id, ownership_epoch: epoch, wallet: wallet, for_person: boolean}`,
  the epoch being the key's current one, by the same rule
  as `identity/2`: a person is every key their wallets hold, with the wallet
  holding it; an agent is every key its wallet holds and every key it holds an
  active shard of, with its own wallet; an agent with neither, paired with a
  person here, is that person's keys, `for_person: true`.
  Nobody else is any key. Direct messages read and send as these keys
  (`Keyfleet.Dms`): a key's new holder sees only messages from when they got it.
  """
  def held_keys(%Human{wallet_addresses: [_ | _] = wallets} = actor, fleet_id) do
    for key <- keys_held_in_fleet!(fleet_id, wallets, actor: actor),
        do: %{
          token_id: key.token_id,
          ownership_epoch: key.ownership_epoch,
          wallet: key.owner_wallet,
          for_person: false
        }
  end

  def held_keys(%Agent{wallet_address: wallet} = actor, fleet_id) do
    case Agent.refresh(actor) do
      {:ok, actor} ->
        held = keys_held_in_fleet!(fleet_id, [wallet], actor: actor)

        sharded =
          for shard <- active_shards_held_by!(wallet, actor: actor),
              shard.fleet_id == fleet_id,
              do: shard

        case Enum.uniq_by(Enum.sort_by(held ++ sharded, & &1.token_id), & &1.token_id) do
          [] -> person_keys(actor.pairing, fleet_id)
          keys -> Enum.map(keys, &agent_key(&1, wallet))
        end

      _ ->
        []
    end
  end

  def held_keys(_actor, _fleet_id), do: []

  @doc """
  Each of `token_ids`' last presence record in the fleet, as `%{token_id =>
  record}`, or its last one before `{block_number, log_index}`. A Key with none
  isn't in the map.
  """
  def last_presence(fleet_id, token_ids, before \\ nil) do
    Keyfleet.Keys.Presence
    |> Ash.Query.filter(fleet_id == ^fleet_id and token_id in ^token_ids)
    |> presence_before(before)
    |> Ash.Query.distinct(:token_id)
    |> Ash.Query.distinct_sort(block_number: :desc, log_index: :desc)
    |> Ash.read!()
    |> Map.new(&{&1.token_id, &1})
  end

  defp presence_before(query, nil), do: query

  defp presence_before(query, {block, log}) do
    Ash.Query.filter(
      query,
      block_number < ^block or (block_number == ^block and log_index < ^log)
    )
  end

  @doc """
  How many of the fleet's Keys a proposal opening now would count, and how many
  of those have a day or less left (see the `present` and `expiring`
  calculations of `Keyfleet.Keys.KeyAttachment`), as `{:ok, %{present, expiring}}`,
  or `{:error, failure}` when the database doesn't answer (see `Keyfleet.Count`).
  """
  def presence_counts(fleet_id) do
    query =
      Ash.Query.for_read(Keyfleet.Keys.KeyAttachment, :present_in_fleet, %{fleet_id: fleet_id})

    with {:ok, present} <- Keyfleet.Count.of(query),
         {:ok, expiring} <- query |> Ash.Query.filter(expiring) |> Keyfleet.Count.of() do
      {:ok, %{present: present, expiring: expiring}}
    end
  end

  @doc """
  How many addresses hold at least one of the fleet's keys today
  (`holders`), and how many of them hold a key that did something since
  `since` (`online`): a post in a room or on a key's wall, a direct message,
  a poll started or voted in, or a check-in or contribution from an agent
  acting as the key. `{:ok, %{holders: n, online: n}}`, or `{:error, failure}`
  when the database doesn't answer.
  """
  def count_holders(fleet_id, since) do
    acted =
      Enum.uniq(
        acted_keys(fleet_id, since) ++ Keyfleet.Agents.keys_active_since!(fleet_id, since)
      )

    with {:ok, holders} <- count_owners(fleet_id, nil),
         {:ok, online} <- count_owners(fleet_id, acted),
         do: {:ok, %{holders: holders, online: online}}
  rescue
    failure in [Ash.Error.Unknown, Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("Counting the holders of #{fleet_id} failed: " <> Exception.message(failure))
      {:error, failure}
  end

  @doc """
  The people holding the fleet's keys today, most keys first, leaving out the
  addresses in `left_out`: `limit` of them from `offset`. A person is a Regent
  account with every address it links counted together; an address no account
  links is a holder of its own. Each is `%{account_id: id_or_nil, wallets:
  wallets, count: count}`, its wallets lowest first; holders with as many keys
  are ordered by their lowest wallet.
  """
  def holders(fleet_id, left_out, offset, limit) do
    from(key in subquery(owned(fleet_id)),
      left_join: linked in subquery(linked_wallets()),
      on: linked.wallet == key.owner_wallet,
      where: key.owner_wallet not in ^left_out,
      group_by: fragment("coalesce(?::text, ?)", linked.account_id, key.owner_wallet),
      order_by: [desc: count(), asc: min(key.owner_wallet)],
      offset: ^offset,
      limit: ^limit,
      select: %{
        account_id: max(linked.account_id),
        wallets: fragment("array_agg(DISTINCT ? ORDER BY ?)", key.owner_wallet, key.owner_wallet),
        count: count()
      }
    )
    # Ownership is public, and so is every address a Regent account links, so
    # keys are counted by person here directly.
    |> Keyfleet.Repo.all()
  end

  @doc "The id of the Regent account linking `wallet`, as `holders/4` counts it, or nil."
  def holder_account_id(wallet) do
    from(linked in subquery(linked_wallets()),
      where: linked.wallet == ^String.downcase(wallet),
      select: linked.account_id
    )
    # Every address a Regent account links is public, as in holders/4.
    |> Keyfleet.Repo.one()
  end

  # Every address a Regent account links, lowercase, with the account it
  # belongs to; an address two accounts claim goes to the older one.
  defp linked_wallets do
    from(
      linked in fragment("""
      SELECT lower(wallet) AS wallet, min(account.id) AS account_id
      FROM regent_names.platform_human_users AS account
      CROSS JOIN LATERAL unnest(account.wallet_addresses || account.wallet_address) AS wallet
      WHERE wallet IS NOT NULL
      GROUP BY lower(wallet)
      """),
      select: %{wallet: linked.wallet, account_id: linked.account_id}
    )
  end

  @doc """
  The lowest `shown` key numbers each of `wallets` holds in the fleet today,
  as `%{wallet => token_ids}`, lowest first.
  """
  def lowest_held(fleet_id, wallets, shown) do
    ranked =
      from(key in subquery(owned(fleet_id)),
        where: key.owner_wallet in ^wallets,
        select: %{
          wallet: key.owner_wallet,
          token_id: key.token_id,
          place: over(row_number(), partition_by: key.owner_wallet, order_by: key.token_id)
        }
      )

    from(key in subquery(ranked),
      where: key.place <= ^shown,
      order_by: [key.wallet, key.token_id],
      select: {key.wallet, key.token_id}
    )
    # Ownership is public; a window over each holder's Keys is read here directly.
    |> Keyfleet.Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Which of `wallets` hold a key of the fleet with a vote now (see the
  `present` calculation of `Keyfleet.Keys.KeyAttachment`).
  """
  def present_holders(fleet_id, wallets) do
    Keyfleet.Keys.KeyAttachment
    |> Ash.Query.for_read(:present_in_fleet, %{fleet_id: fleet_id})
    |> Ash.Query.filter(owner_wallet in ^wallets)
    |> Ash.Query.select([:owner_wallet])
    |> Ash.read!()
    |> MapSet.new(& &1.owner_wallet)
  end

  @doc """
  Which of `wallets` hold a key of the fleet that has no vote now (see the
  `idle` calculation of `Keyfleet.Keys.KeyAttachment`). A newly sold key
  waiting for its automatic start is not idle.
  """
  def idle_holders(fleet_id, wallets) do
    Keyfleet.Keys.KeyAttachment
    |> Ash.Query.for_read(:held_in_fleet, %{fleet_id: fleet_id, owner_wallets: wallets})
    |> Ash.Query.filter(idle)
    |> Ash.read!()
    |> MapSet.new(& &1.owner_wallet)
  end

  @doc """
  When each of `wallets` last did something in the fleet with a key it holds
  today, since it came to hold it: a check-in, a post, a direct message, or a
  poll started or voted in. `%{wallet => at}`, leaving out the wallets that
  have done none of these.
  """
  def last_active(fleet_id, wallets) do
    held = from(key in subquery(owned(fleet_id)), where: key.owner_wallet in ^wallets)

    renewed =
      from(p in "key_presences",
        join: key in subquery(held),
        on: p.token_id == key.token_id and p.ownership_epoch == key.ownership_epoch,
        where: p.fleet_id == ^fleet_id and p.kind == "present",
        select: %{wallet: key.owner_wallet, at: type(p.at, :naive_datetime_usec)}
      )

    posted =
      from(m in "messages",
        join: key in subquery(held),
        on: m.as_key == key.token_id and m.inserted_at >= key.observed_at,
        where: m.fleet_id == ^fleet_id,
        select: %{wallet: key.owner_wallet, at: m.inserted_at}
      )

    messaged =
      from(d in "dm_messages",
        join: key in subquery(held),
        on: d.from_token_id == key.token_id and d.inserted_at >= key.observed_at,
        where: d.fleet_id == ^fleet_id,
        select: %{wallet: key.owner_wallet, at: d.inserted_at}
      )

    started =
      from(p in "polls",
        join: key in subquery(held),
        on: p.started_by_key == key.token_id and p.inserted_at >= key.observed_at,
        where: p.fleet_id == ^fleet_id,
        select: %{wallet: key.owner_wallet, at: p.inserted_at}
      )

    voted =
      from(v in "poll_votes",
        join: p in "polls",
        on: p.id == v.poll_id,
        join: key in subquery(held),
        on: v.token_id == key.token_id and v.inserted_at >= key.observed_at,
        where: p.fleet_id == ^fleet_id,
        select: %{wallet: key.owner_wallet, at: v.inserted_at}
      )

    events = renewed |> union_all(^posted) |> union_all(^messaged) |> union_all(^started)

    from(event in subquery(union_all(events, ^voted)),
      group_by: event.wallet,
      select: {event.wallet, max(event.at)}
    )
    # Only each holder's latest time leaves the database, never what was said.
    |> Keyfleet.Repo.all()
    |> Map.new(fn {wallet, at} -> {wallet, DateTime.from_naive!(at, "Etc/UTC")} end)
  end

  @doc """
  The holder of each of `token_ids` today and the Key they write as, as
  `%{token_id => %{holder: holder, face: token_id, owner: wallet, owned:
  count}}`; a key nobody holds yet is left out. A holder is a Regent account
  with every address it links, or an address no account links, as `holders/4`
  counts them. `face` is the key they chose to write as while their wallets
  hold it (`Keyfleet.Keys.PostingKey`), else the highest-ranked key their
  wallets hold, as `identity/2` picks it; `owner` is their main address and
  `owned` how many of the fleet's keys their addresses hold together.
  """
  def faces(_fleet_id, []), do: %{}

  def faces(fleet_id, token_ids) do
    owners =
      Keyfleet.Keys.KeyAttachment
      |> Ash.Query.for_read(:owned_in_fleet, %{fleet_id: fleet_id, token_ids: token_ids})
      |> Ash.Query.select([:token_id, :owner_wallet])
      |> Ash.read!()
      |> Map.new(&{&1.token_id, &1.owner_wallet})

    linked = linked_to(owners |> Map.values() |> Enum.uniq())
    account_ids = linked |> Map.values() |> Enum.uniq()
    wallets = account_wallets(account_ids)
    # Every address of those accounts, not only the ones holding `token_ids`.
    holders =
      for {account_id, own} <- wallets, wallet <- own, into: linked, do: {wallet, account_id}

    holder = fn wallet -> holders[wallet] || wallet end
    addresses = fn holder -> Map.get(wallets, holder, [holder]) end

    held =
      fleet_id
      |> keys_held_in_fleet!(
        owners
        |> Map.values()
        |> Enum.map(holder)
        |> Enum.uniq()
        |> Enum.flat_map(addresses)
      )
      |> Enum.group_by(&holder.(&1.owner_wallet), & &1.token_id)

    chosen = chosen_keys(fleet_id, account_ids)
    main = main_addresses(account_ids)

    Map.new(owners, fn {token_id, wallet} ->
      holder = holder.(wallet)
      keys = Map.get(held, holder, [token_id])

      {token_id,
       %{
         holder: holder,
         face: if(chosen[holder] in keys, do: chosen[holder], else: Enum.min(keys)),
         owner: main[holder] || wallet,
         owned: length(keys)
       }}
    end)
  end

  # The account linking each of `wallets`, as `holders/4` counts them; an
  # address no account links is left out.
  defp linked_to(wallets) do
    from(linked in subquery(linked_wallets()),
      where: linked.wallet in ^wallets,
      select: {linked.wallet, linked.account_id}
    )
    # Every address a Regent account links is public, as in holders/4.
    |> Keyfleet.Repo.all()
    |> Map.new()
  end

  # Every address each of `account_ids` links, as `holders/4` counts them.
  defp account_wallets([]), do: %{}

  defp account_wallets(account_ids) do
    from(linked in subquery(linked_wallets()),
      where: linked.account_id in ^account_ids,
      select: {linked.account_id, linked.wallet}
    )
    # Every address a Regent account links is public, as in holders/4.
    |> Keyfleet.Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The key each of `account_ids` chose to write as in the fleet. What a
  # person writes shows it beside their words, so it is no secret.
  defp chosen_keys(_fleet_id, []), do: %{}

  defp chosen_keys(fleet_id, account_ids) do
    fleet_id
    |> posting_keys_of_accounts!(account_ids, actor: %Keyfleet.Actors.System{})
    |> Map.new(&{&1.human_account_id, &1.token_id})
  end

  # The main address of each of `account_ids`, as the Member List names them.
  defp main_addresses([]), do: %{}

  defp main_addresses(account_ids) do
    account_ids
    |> Keyfleet.Accounts.accounts_by_ids!(actor: %Keyfleet.Actors.System{})
    |> Map.new(&{&1.id, &1.wallet_address && String.downcase(&1.wallet_address)})
  end

  # The fleet's keys with their owners today, as `:owned_in_fleet` reads them.
  defp owned(fleet_id) do
    {:ok, query} =
      Keyfleet.Keys.KeyAttachment
      |> Ash.Query.for_read(:owned_in_fleet, %{fleet_id: fleet_id})
      |> Ash.Query.data_layer_query()

    query
  end

  defp count_owners(fleet_id, token_ids) do
    Keyfleet.Keys.KeyAttachment
    |> Ash.Query.for_read(:owned_in_fleet, %{fleet_id: fleet_id, token_ids: token_ids})
    |> Ash.aggregate({:owners, :count, field: :owner_wallet, uniq?: true})
    |> case do
      {:ok, %{owners: owners}} -> {:ok, owners}
      {:error, failure} -> {:error, failure}
    end
  end

  # The keys that posted, sent a direct message, or started or voted in a
  # poll in the fleet since `since`, read across the four tables at once
  # since no one resource reads them all.
  defp acted_keys(fleet_id, since) do
    since = DateTime.to_naive(since)

    posted =
      from(m in "messages",
        where: m.fleet_id == ^fleet_id and m.inserted_at >= ^since and not is_nil(m.as_key),
        select: m.as_key
      )

    messaged =
      from(d in "dm_messages",
        where: d.fleet_id == ^fleet_id and d.inserted_at >= ^since,
        select: d.from_token_id
      )

    started =
      from(p in "polls",
        where: p.fleet_id == ^fleet_id and p.inserted_at >= ^since,
        select: p.started_by_key
      )

    voted =
      from(v in "poll_votes",
        join: p in "polls",
        on: p.id == v.poll_id,
        where: p.fleet_id == ^fleet_id and v.inserted_at >= ^since,
        select: v.token_id
      )

    posted
    |> union(^messaged)
    |> union(^started)
    |> union(^voted)
    |> Keyfleet.Repo.all()
  end

  @doc """
  The fleet's keys a person's wallets hold: the lowest `shown` of them by
  number, the lowest of all (who the person is in the fleet, `identity/2`) and
  how many they hold, as `%{first: token_id, token_ids: token_ids, count: count}`,
  or `nil` for someone holding none. Reads `shown` keys and a count, however
  many the person holds.
  """
  def held_summary(%Human{wallet_addresses: [_ | _] = wallets} = actor, fleet_id, shown) do
    held =
      Ash.Query.for_read(
        Keyfleet.Keys.KeyAttachment,
        :held_in_fleet,
        %{fleet_id: fleet_id, owner_wallets: wallets},
        actor: actor
      )

    case held |> Ash.Query.limit(shown) |> Ash.read!() |> Enum.map(& &1.token_id) do
      [] -> nil
      [first | _] = token_ids -> %{first: first, token_ids: token_ids, count: Ash.count!(held)}
    end
  end

  def held_summary(_actor, _fleet_id, _shown), do: nil

  defp agent_key(key, wallet),
    do: %{
      token_id: key.token_id,
      ownership_epoch: key.ownership_epoch,
      wallet: wallet,
      for_person: false
    }

  defp person_keys(%Human{} = person, fleet_id),
    do: Enum.map(held_keys(person, fleet_id), &%{&1 | for_person: true})

  defp person_keys(_missing, _fleet_id), do: []

  defp held_or_shard(fleet_id, wallet, actor),
    do:
      held_identity_key!(fleet_id, [wallet], actor: actor) ||
        Enum.find(active_shards_held_by!(wallet, actor: actor), &(&1.fleet_id == fleet_id))
end

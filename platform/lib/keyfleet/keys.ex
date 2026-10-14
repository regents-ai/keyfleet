defmodule Keyfleet.Keys do
  @moduledoc """
  Key ownership, reveals, shards, agent voting, presence and edit
  restrictions projected from contract events, and which Keys have
  their card picture.
  """
  use Ash.Domain

  import Ecto.Query, only: [from: 2, union: 2]

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

      define :keys_in_fleet, action: :current_in_fleet, args: [:fleet_id]
      define :idle_keys_in_fleet, action: :idle_in_fleet, args: [:fleet_id]
      define :keys_held_in_fleet, action: :held_in_fleet, args: [:fleet_id, :owner_wallets]

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
  person is the highest-ranked key their wallets hold, and `wallet` is the one
  holding it. An agent is the highest-ranked key its wallet holds, or else the
  highest-ranked key it holds an active shard of, and `wallet` is its own. Everything
  either writes in the fleet is written as that key.

  An agent with neither, paired with a person whose account is here (`Keyfleet.Actors.Agent`'s `pairing`), is that person's key, with
  `for_person: true`: what it writes there is the person's, marked as the
  agent's.
  """
  def identity(%Human{wallet_addresses: [_ | _] = wallets} = actor, fleet_id) do
    case held_identity_key!(fleet_id, wallets, actor: actor) do
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
  How many of the fleet's keys have no vote now (see the `idle` calculation of
  `Keyfleet.Keys.KeyAttachment`), as `{:ok, count}`, or `{:error, failure}`
  when the database doesn't answer (see `Keyfleet.Count`).
  """
  def count_idle_keys(fleet_id) do
    Keyfleet.Keys.KeyAttachment
    |> Ash.Query.for_read(:idle_in_fleet, %{fleet_id: fleet_id})
    |> Keyfleet.Count.of()
  end

  @doc """
  How many of the fleet's keys have a vote now, the ones a proposal opening
  now would count, as `{:ok, count}`, or `{:error, failure}` when the database
  doesn't answer (see `Keyfleet.Count`).
  """
  def count_present_keys(fleet_id) do
    Keyfleet.Keys.KeyAttachment
    |> Ash.Query.for_read(:present_in_fleet, %{fleet_id: fleet_id})
    |> Keyfleet.Count.of()
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
  A hundred of the fleet's idle keys by key number, from the start or from
  `position` (`[after: keyset]`), as `{:ok, page}`, or `{:error, failure}`
  when the database doesn't answer, which is logged, so the page says it
  couldn't list them rather than crashing.
  """
  def idle_keys_page(fleet_id, position) do
    with {:error, failure} <- idle_keys_in_fleet(fleet_id, page: position),
         do: idle_keys_unlisted(fleet_id, failure)
  rescue
    failure in [Postgrex.Error, DBConnection.ConnectionError] ->
      idle_keys_unlisted(fleet_id, failure)
  end

  defp idle_keys_unlisted(fleet_id, failure) do
    Logger.warning("Listing the idle keys of #{fleet_id} failed: " <> Exception.message(failure))
    {:error, failure}
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

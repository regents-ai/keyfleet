defmodule KeyFleet.Keys.Profile do
  @moduledoc """
  Everything one key's profile shows, as a plain map: the key itself, the
  wallet holding it, its thread and what it has said in the fleet's rooms.

  Every figure is read with a fixed number of indexed reads, so opening a key
  costs the same however large the fleet is and however many keys its holder
  has. Nothing here writes.

  A key the fleet has not issued yet, the next one on sale, has only its
  number, level and price.
  """

  require Ash.Query

  alias KeyFleet.Actors.Human
  alias KeyFleet.Chain
  alias KeyFleet.Fleets.Presets
  alias KeyFleet.Keys
  alias KeyFleet.Keys.KeyAttachment
  alias KeyFleet.Proposals.Vote
  alias KeyFleet.Rooms
  alias KeyFleet.Rooms.Message
  alias KeyFleet.Traits

  # A holder's keys in the fleet are listed this many at a time.
  @listed 100
  # A thread opens on its latest posts.
  @thread_page 100

  @doc """
  Key `token_id` of the fleet as `viewer` sees it, `viewer` being the person
  signed in or `nil`. `issued?` is false for a key not yet sold.
  """
  def read(fleet_id, token_id, viewer) do
    case Keys.current_key!(fleet_id, token_id) do
      nil -> unissued(fleet_id, token_id)
      current -> issued(fleet_id, token_id, current, viewer)
    end
  end

  @doc """
  Whether `wallet` holds, or has held, any of `token_ids` in the fleet: so
  whether a change to those keys moved one of its keys, to it or away from it.
  """
  def held_any?(fleet_id, wallet, token_ids) do
    KeyAttachment
    |> Ash.Query.for_read(:held_among, %{
      fleet_id: fleet_id,
      owner_wallet: wallet,
      token_ids: token_ids
    })
    |> Ash.exists?()
  end

  @doc """
  Who may write in the key's thread: the same people as in the fleet's rooms,
  while the fleet's key ownership is fresh. `viewer` is the person signed in,
  or `nil`.
  """
  def composer(nil, _fleet_id), do: :sign_in

  def composer(%Human{} = viewer, fleet_id) do
    cond do
      Keys.identity(viewer, fleet_id) == nil -> :no_key
      not Chain.fresh?(fleet_id) -> :refreshing
      true -> :write
    end
  end

  @doc """
  What changes when the key, or a key its holder holds, has written or been
  written to: its thread's length, its posts in the fleet's rooms, and its
  holder's.
  """
  def activity(fleet_id, token_id, holder) do
    thread = Rooms.get_key_thread!(fleet_id, token_id)

    %{
      messages: if(thread, do: thread.head_seq, else: 0),
      posts: count(Message, :room_posts_as_key, %{fleet_id: fleet_id, token_id: token_id}),
      recent_posts: Rooms.posts_as_key!(fleet_id, token_id),
      holder_posts: count(Message, :room_posts_by_wallet, %{fleet_id: fleet_id, wallet: holder})
    }
  end

  @doc "The posts in the key's thread after place `after_seq`, oldest first."
  def thread_after(fleet_id, token_id, after_seq) do
    Rooms.read_key_thread!(fleet_id, token_id, %{after_seq: after_seq, limit: @thread_page})
  end

  @doc """
  The votes the key has been used in, and the votes its holder has cast in
  the fleet with all their keys and on how many proposals.
  """
  def votes(fleet_id, token_id, holder) do
    by_holder =
      Vote
      |> Ash.Query.for_read(:by_voter, %{fleet_id: fleet_id, voter: holder})
      |> Ash.aggregate!([
        {:votes, :sum, field: :key_count},
        {:proposals, :count, field: :proposal_id, uniq?: true}
      ])

    %{
      votes_cast: count(Vote, :with_key, %{fleet_id: fleet_id, token_id: token_id}),
      holder_votes: by_holder.votes || 0,
      holder_proposals: by_holder.proposals
    }
  end

  defp unissued(fleet_id, token_id) do
    %{
      fleet_id: fleet_id,
      token_id: token_id,
      issued?: false,
      level: level(fleet_id, token_id),
      issue_price: Presets.issue_price(fleet_id, token_id)
    }
  end

  # `current` is the record of the holder receiving the key.
  defp issued(fleet_id, token_id, current, viewer) do
    holder = current.owner_wallet
    activity = activity(fleet_id, token_id, holder)
    thread = thread_after(fleet_id, token_id, max(activity.messages - @thread_page, 0))

    held =
      Keys.keys_held_in_fleet!(fleet_id, [holder], query: [limit: @listed])
      |> Enum.map(& &1.token_id)

    %{
      fleet_id: fleet_id,
      token_id: token_id,
      issued?: true,
      level: level(fleet_id, token_id),
      issue_price: Presets.issue_price(fleet_id, token_id),
      traits: traits(fleet_id, token_id),
      held_since: current.observed_at,
      holder: holder,
      yours?: holder in wallets(viewer),
      changed_hands:
        count(KeyAttachment, :history, %{fleet_id: fleet_id, token_id: token_id}) - 1,
      operator: operator(fleet_id, token_id),
      thread: thread,
      last_seq: last_seq(thread, 0),
      holder_keys: held,
      holder_key_count:
        count(KeyAttachment, :held_in_fleet, %{fleet_id: fleet_id, owner_wallets: [holder]}),
      holder_keys_everywhere: count(KeyAttachment, :held_by_wallet, %{owner_wallet: holder}),
      composer: composer(viewer, fleet_id)
    }
    |> Map.merge(activity)
    |> Map.merge(votes(fleet_id, token_id, holder))
  end

  @doc "The place of the last of `posts`, or `shown` when there are none."
  def last_seq([], shown), do: shown
  def last_seq(posts, _shown), do: List.last(posts).seq

  defp level(fleet_id, token_id),
    do: if(Presets.levelled?(fleet_id), do: Presets.fibonacci_level_of(token_id))

  # Each trait the key drew, in its fleet's order, with the share of keys that
  # draw it; `nil` while the key is still revealing.
  defp traits(fleet_id, token_id) do
    case Keys.get_reveal!(fleet_id, token_id, load: [:fleet]) do
      nil ->
        nil

      reveal ->
        table = Traits.table!(reveal.fleet.trait_table_hash)
        weights = Map.new(table, &{&1.name, {Map.new(&1.values), &1.total}})

        table
        |> Traits.draw(reveal.seed)
        |> Enum.map(fn {trait, value} ->
          {values, total} = weights[trait]
          %{trait: trait, value: value, share: values[value] / total}
        end)
    end
  end

  defp operator(fleet_id, token_id) do
    case Keys.current_operator!(fleet_id, token_id) do
      nil ->
        nil

      %{agent_profile: agent} ->
        %{
          name: agent.name,
          harness: agent.declared_harness,
          status: agent.current_status,
          status_updated_at: agent.status_updated_at
        }
    end
  end

  defp wallets(%Human{wallet_addresses: wallets}), do: wallets
  defp wallets(nil), do: []

  defp count(resource, action, arguments),
    do: resource |> Ash.Query.for_read(action, arguments) |> Ash.count!()
end

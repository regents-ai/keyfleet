defmodule Keyfleet.Feed do
  @moduledoc """
  What a signed agent's live feed carries (`GET /api/v1/feed`,
  `KeyfleetWeb.FeedController`): a small event the moment something it should
  answer is posted, heard on the topics the fleet's pages and a waiting sync
  already listen to. An event names its fleet and where the post is, its room,
  wall or conversation, and never its words: the agent reads it through the
  route `read` names, with that route's policies.

  The feed follows each open fleet where the agent acts as a Key
  (`Keyfleet.Keys.identity/2`, the Key a sync names in `yours.as_key`). There:

  - `mention`: a post written as another Key that names the agent's Key
    (`@Key N`), read through the `:mentioning` read, as the sync's
    `yours.mentions` is: never one written as a Key the agent muted.
  - `wall_post`: a post on the wall of the agent's Key, written as another Key
    it has not muted.
  - `room_post`: a post in one of the fleet's rooms written as another Key, or
    as none, and not as a Key the agent muted. A member reads every room;
    anyone else the rooms anyone reads, as the read's own policy decides
    (`Keyfleet.Access`).
  - `dm`: a direct message to a Key the agent reads as (`Keyfleet.Dms.inbox_topics/2`)
    from a Key it does not, read through the `:changes` read, as a sync's
    `dms` is, so what a Key it reads as blocked is never heard.

  A post that names the agent's Key is one `mention`, never also a `room_post`
  or `wall_post`.

  A fleet's Keys changing (`Keyfleet.Keys.topic/1`) reads the agent's place in
  that fleet again, and its mutes changing reads its mutes again; `topics/1`
  then says what the feed listens on.

  A kind of event is added in three places here: its topic in `topics/1`, a
  clause of `heard/2` turning that topic's notice into events, and its read in
  `missed/2`.
  """

  require Ash.Query

  import Ash.Expr, only: [expr: 1]

  alias Keyfleet.Access
  alias Keyfleet.Actors.Agent
  alias Keyfleet.Dms
  alias Keyfleet.Dms.Checks.KeyHolder
  alias Keyfleet.Keys
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Muter

  @enforce_keys [:actor, :muter, :fleets]
  defstruct [:actor, :muter, :fleets]

  @typedoc """
  The agent's place in one fleet, as read when the feed opened or the fleet's
  Keys last changed: the Key it acts as (nil for none), its class there, the
  Keys it reads direct messages as, and the Keys it muted.
  """
  @type place :: %{
          as_key: pos_integer() | nil,
          class: :public | :person | :member,
          held: [pos_integer()],
          muted: [pos_integer()]
        }

  @type t :: %__MODULE__{
          actor: Agent.t(),
          muter: String.t() | nil,
          fleets: %{String.t() => place()}
        }

  @typedoc "One event; `at` orders the feed, and `read` is the route to read it by."
  @type event :: %{
          required(:kind) => String.t(),
          required(:id) => String.t(),
          required(:at) => DateTime.t(),
          required(:fleet) => String.t(),
          required(:read) => String.t(),
          optional(atom()) => term()
        }

  # A reconnect gets at most this many missed events; past that it is told to resync.
  @missed_limit 100
  # A line named by its room and place is read wherever it is.
  @any_time ~U[1970-01-01 00:00:00.000000Z]

  @doc "The agent's feed, with its place in each open fleet."
  @spec open(Agent.t()) :: t()
  def open(%Agent{} = actor) do
    %__MODULE__{
      actor: actor,
      muter: Muter.of(actor),
      fleets: Map.new(Keyfleet.Fleets.open_fleet_ids(), &{&1, place(actor, &1)})
    }
  end

  @doc "The topics the feed listens on."
  @spec topics(t()) :: [String.t()]
  def topics(%__MODULE__{muter: muter, fleets: fleets}) do
    Enum.flat_map(fleets, fn {fleet_id, place} ->
      [Keys.topic(fleet_id) | rooms_topics(fleet_id, place)] ++ inbox_topics(fleet_id, place)
    end) ++ mute_topics(muter)
  end

  # Only a fleet where the agent acts as a Key is followed, on the topic its
  # class hears.
  defp rooms_topics(_fleet_id, %{as_key: nil}), do: []
  defp rooms_topics(fleet_id, %{class: class}), do: [Rooms.topic(fleet_id, class)]

  defp inbox_topics(fleet_id, %{held: held}), do: Enum.map(held, &Dms.inbox_topic(fleet_id, &1))

  defp mute_topics(nil), do: []
  defp mute_topics(muter), do: [Muter.topic(muter)]

  @doc "The events one notice on the feed's topics makes, and the feed after it."
  @spec heard(t(), term()) :: {:ok, [event()], t()} | {:error, term()}
  def heard(feed, %{event: "room_head", topic: topic, payload: %{room_id: room_id, seq: seq}}) do
    case heard_on(feed, &rooms_topics/2, topic) do
      {fleet_id, place} ->
        with {:ok, events} <- posts(feed.actor, fleet_id, place, {:line, room_id, seq}),
             do: {:ok, events, feed}

      nil ->
        {:ok, [], feed}
    end
  end

  def heard(feed, %{event: "dm_head", topic: topic, payload: %{seq: seq}}) do
    case heard_on(feed, &inbox_topics/2, topic) do
      {fleet_id, _place} ->
        with {:ok, events} <- dms(feed.actor, fleet_id, {:seq, seq}), do: {:ok, events, feed}

      nil ->
        {:ok, [], feed}
    end
  end

  def heard(%{fleets: fleets} = feed, %{event: "mutes_changed", payload: %{fleet_id: fleet_id}})
      when is_map_key(fleets, fleet_id),
      do: {:ok, [], put_in(feed.fleets[fleet_id].muted, muted(feed.actor, fleet_id))}

  def heard(%{fleets: fleets} = feed, {:keys_changed, fleet_id, _token_ids})
      when is_map_key(fleets, fleet_id),
      do: {:ok, [], put_in(feed.fleets[fleet_id], place(feed.actor, fleet_id))}

  def heard(feed, _notice), do: {:ok, [], feed}

  # The fleet whose topics of one kind include `topic`, with the agent's place there.
  defp heard_on(feed, topics, topic),
    do: Enum.find(feed.fleets, fn {fleet_id, place} -> topic in topics.(fleet_id, place) end)

  @doc """
  Every event after `since`, oldest first, for a reconnect; `:resync` when
  there are more than a reconnect gets.
  """
  @spec missed(t(), DateTime.t()) :: {:ok, [event()]} | :resync | {:error, term()}
  def missed(%__MODULE__{actor: actor, fleets: fleets}, since) do
    reads =
      Enum.flat_map(fleets, fn {fleet_id, place} ->
        [
          fn -> posts(actor, fleet_id, place, {:since, since}) end,
          fn -> dms(actor, fleet_id, {:since, since}) end
        ]
      end)

    Enum.reduce_while(reads, {:ok, []}, fn read, {:ok, all} ->
      case read.() do
        {:ok, events} -> {:cont, {:ok, events ++ all}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} when length(events) > @missed_limit -> :resync
      {:ok, events} -> {:ok, Enum.sort_by(events, & &1.at, DateTime)}
      error -> error
    end
  end

  defp place(actor, fleet_id) do
    %{
      as_key: actor |> Keys.identity(fleet_id) |> as_key(),
      class: Access.class(actor, fleet_id),
      held: KeyHolder.held(actor, fleet_id),
      muted: muted(actor, fleet_id)
    }
  end

  defp as_key(%{token_id: token_id}), do: token_id
  defp as_key(nil), do: nil

  defp muted(actor, fleet_id), do: fleet_id |> Rooms.muted_keys!(actor) |> MapSet.to_list()

  # The posts in a fleet that are the agent's to answer, each read as the
  # agent, with the class it holds there now: the ones naming its Key, then
  # those on its Key's wall and in the rooms. `scope` is one line,
  # `{:line, room_id, seq}`, or everything posted after a time, `{:since, at}`.
  defp posts(_actor, _fleet_id, %{as_key: nil}, _scope), do: {:ok, []}

  defp posts(actor, fleet_id, %{as_key: me, muted: muted}, scope) do
    opts = [actor: actor, context: Access.context(actor, fleet_id, Access.class(actor, fleet_id))]
    others = expr(as_key != ^me and as_key not in ^muted)

    with {:ok, mentions} <-
           Rooms.Message
           |> Ash.Query.for_read(
             :mentioning,
             %{
               fleet_id: fleet_id,
               token_id: me,
               muted: muted,
               after_at: after_at(scope),
               limit: @missed_limit + 1
             },
             opts
           )
           |> within(scope)
           |> Ash.read(),
         {:ok, wall} <-
           Rooms.Message
           |> Ash.Query.for_read(
             :read_key_thread,
             %{fleet_id: fleet_id, token_id: me, limit: @missed_limit + 1},
             opts
           )
           |> Ash.Query.filter(^others)
           |> within(scope)
           |> Ash.read(),
         {:ok, rooms} <-
           Rooms.Message
           |> Ash.Query.for_read(
             :fleet_lines_before,
             %{fleet_id: fleet_id, limit: @missed_limit + 1},
             opts
           )
           |> Ash.Query.filter(kind == :post and (is_nil(as_key) or ^others))
           |> Ash.Query.ensure_selected([:seq])
           |> within(scope)
           |> Ash.read() do
      mentioned = MapSet.new(mentions, & &1.id)

      {:ok,
       Enum.map(mentions, &post("mention", fleet_id, &1, where(&1.room))) ++
         for(
           post <- wall,
           not MapSet.member?(mentioned, post.id),
           do: post("wall_post", fleet_id, post, %{wall: me})
         ) ++
         for(
           post <- rooms,
           not MapSet.member?(mentioned, post.id),
           do: post("room_post", fleet_id, post, %{room: post.room.slug})
         )}
    end
  end

  # Direct messages to the Keys the agent reads as now from any other Key, as
  # the sync's catch-up reads them.
  defp dms(actor, fleet_id, scope) do
    case KeyHolder.held(actor, fleet_id) do
      [] ->
        {:ok, []}

      held ->
        Dms.Message
        |> Ash.Query.for_read(
          :changes,
          %{
            fleet_id: fleet_id,
            token_ids: held,
            after_seqs: Enum.map(held, fn _token_id -> 0 end),
            limit: @missed_limit + 1
          },
          actor: actor
        )
        |> Ash.Query.filter(to_token_id in ^held and from_token_id not in ^held)
        |> within(scope)
        |> Ash.read()
        |> case do
          {:ok, messages} -> {:ok, Enum.map(messages, &dm(fleet_id, &1))}
          error -> error
        end
    end
  end

  defp within(query, {:since, at}), do: Ash.Query.filter(query, inserted_at > ^at)

  defp within(query, {:line, room_id, seq}),
    do: Ash.Query.filter(query, room_id == ^room_id and seq == ^seq)

  defp within(query, {:seq, seq}), do: Ash.Query.filter(query, seq == ^seq)

  defp after_at({:since, at}), do: at
  defp after_at({:line, _room_id, _seq}), do: @any_time

  defp where(%{kind: :key, token_id: token_id}), do: %{wall: token_id}
  defp where(%{slug: slug}), do: %{room: slug}

  defp post(kind, fleet_id, post, place) do
    Map.merge(
      %{
        kind: kind,
        id: post.id,
        at: post.inserted_at,
        fleet: fleet_id,
        seq: post.seq,
        as_key: post.as_key,
        read: read(fleet_id, place)
      },
      place
    )
  end

  defp read(fleet_id, %{room: slug}),
    do: "POST /api/v1/agent/fleets/#{fleet_id}/rooms/#{slug}/messages/get"

  defp read(fleet_id, %{wall: token_id}),
    do: "POST /api/v1/agent/keys/#{fleet_id}/#{token_id}/messages/get"

  defp dm(fleet_id, message) do
    %{
      kind: "dm",
      id: message.id,
      at: message.inserted_at,
      fleet: fleet_id,
      conversation_id: message.conversation_id,
      as_key: message.from_token_id,
      to_key: message.to_token_id,
      read:
        "POST /api/v1/agent/fleets/#{fleet_id}/keys/#{message.to_token_id}/dms/#{message.from_token_id}/read"
    }
  end
end

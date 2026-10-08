defmodule Keyfleet.Rooms.Checks.RoomPoster do
  @moduledoc """
  Who may read every room of a fleet, post in its rooms and its keys'
  threads, name its open rooms and create rooms in it: the people and agents
  holding the fleet's keys today, and the agents holding an active shard of
  one. Every room and thread of the fleet is open to all of them. With
  `agents_only?: true`, as for creating a room, only agents count.

  Nobody is enrolled in a fleet and nothing about this is stored. Standing is
  read from the keys and their shards, so a key changing hands moves the right
  to post with it and ends its shards. While the fleet's key ownership is not
  fresh, nobody has standing. A query or change with no fleet has nobody with
  standing.

  A request that reads several things in one fleet reads standing once
  (`standing/2`) and hands it to each of them in their context, so it is not
  read again for every room or post.
  """
  use Ash.Policy.SimpleCheck

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Rooms.Message
  alias Keyfleet.Rooms.Room

  @impl true
  def describe(opts) do
    if Keyword.get(opts, :agents_only?, false),
      do: "actor is an agent holding one of the fleet's keys or a shard of one",
      else: "actor holds one of the fleet's keys or a shard of one"
  end

  @impl true
  def match?(actor, %{subject: %Ash.Query{resource: Message} = query}, _opts),
    do: standing?(actor, Ash.Query.get_argument(query, :fleet_id), query.context)

  def match?(actor, %{subject: %Ash.Changeset{resource: Message} = changeset}, _opts),
    do: standing?(actor, Ash.Changeset.get_argument(changeset, :fleet_id), changeset.context)

  def match?(actor, %{subject: %Ash.Changeset{resource: Room} = changeset}, opts),
    do:
      (is_struct(actor, Agent) or not Keyword.get(opts, :agents_only?, false)) and
        standing?(actor, Ash.Changeset.get_attribute(changeset, :fleet_id), changeset.context)

  @doc """
  The context that carries `actor`'s standing in the fleet, read once, to
  every read and change of one request: pass it as `context:`. It is shared
  with whatever those load, and only ever answers for this actor and fleet.
  """
  def standing(actor, fleet_id),
    do: %{
      shared: %{
        room_standing: %{actor: actor, fleet_id: fleet_id, standing?: may_post?(actor, fleet_id)}
      }
    }

  @doc "The standing a `standing/2` context carries."
  def standing?(%{shared: %{room_standing: %{standing?: standing?}}}), do: standing?

  defp standing?(
         actor,
         fleet_id,
         %{shared: %{room_standing: %{actor: actor, fleet_id: fleet_id}}} = context
       ),
       do: standing?(context)

  defp standing?(actor, fleet_id, _context), do: may_post?(actor, fleet_id)

  @doc """
  Whether this actor may post in the fleet's rooms right now: it has a key in
  the fleet to write as (`Keyfleet.Keys.identity/2`) while the fleet's key
  ownership is fresh. Somebody without a key is answered without asking about
  freshness.

  The same question the policy asks, so a page can offer somebody the box to
  write in exactly when the post would be taken.
  """
  def may_post?(_actor, nil), do: false

  def may_post?(actor, fleet_id),
    do: Keyfleet.Keys.identity(actor, fleet_id) != nil and Keyfleet.Chain.fresh?(fleet_id)
end

defmodule KeyFleet.Rooms.Checks.RoomPoster do
  @moduledoc """
  Who may post in a room, or open a topic room following the same rule: the
  people holding the fleet's keys today, and the agents those people have
  attached to them.

  A room for the whole fleet takes posts from anyone holding one of its keys.
  A room that follows a level takes posts from a key that may write that
  level, by the same rule the workspace uses for its level scopes: the level's
  own keys at once, an earlier level's keys once every key of this level is
  sold, and a later level's keys never.

  Nobody is enrolled in a fleet and nothing about this is stored. Standing is
  read from the keys themselves every time, so a key changing hands moves the
  right to post with it. While the fleet's key ownership is not fresh, nobody
  has standing.
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias KeyFleet.Actors.Agent
  alias KeyFleet.Actors.Human
  alias KeyFleet.Fleets.Presets
  alias KeyFleet.Keys.KeyAttachment
  alias KeyFleet.Keys.KeyPairing
  alias KeyFleet.Rooms.Message
  alias KeyFleet.Rooms.Room

  @impl true
  def describe(_opts),
    do: "actor holds or runs a key of the fleet that may post in the room's level, if it has one"

  @impl true
  def match?(actor, %{subject: %Ash.Changeset{resource: Message} = changeset}, _opts) do
    fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)
    slug = Ash.Changeset.get_argument(changeset, :slug)

    # A room the fleet does not have is judged as a room for the whole fleet,
    # so its members are the ones told that it does not exist.
    case KeyFleet.Rooms.get_room!(fleet_id, slug, actor: actor) do
      nil -> may_post?(actor, fleet_id, nil)
      room -> may_post?(actor, fleet_id, room.level)
    end
  end

  def match?(actor, %{subject: %Ash.Changeset{resource: Room} = changeset}, _opts),
    do:
      may_post?(
        actor,
        Ash.Changeset.get_attribute(changeset, :fleet_id),
        Ash.Changeset.get_attribute(changeset, :level)
      )

  def match?(_actor, _context, _opts), do: false

  @doc """
  Whether this actor may post right now in a room of the fleet that follows
  `level`, or in one for the whole fleet when `level` is nil.

  The same question the policy asks, so a page can offer somebody the box to
  write in exactly when the post would be taken.
  """
  def may_post?(actor, fleet_id, nil),
    do: KeyFleet.Chain.fresh?(fleet_id) and holds?(actor, fleet_id)

  def may_post?(actor, fleet_id, level),
    do: KeyFleet.Chain.fresh?(fleet_id) and level in writable_levels(actor, fleet_id)

  @doc """
  Everything a page needs to know about where this actor may post, read once:
  whether they may post in the fleet's rooms for everyone, and the levels whose
  rooms they may post in, lowest first. Neither while the fleet's key
  ownership is not fresh.
  """
  def standing(actor, fleet_id) do
    if KeyFleet.Chain.fresh?(fleet_id),
      do: %{member?: holds?(actor, fleet_id), levels: writable_levels(actor, fleet_id)},
      else: %{member?: false, levels: []}
  end

  @doc "Whether `standing/2` lets its actor post in a room that follows `level`, or in one for everyone."
  def may_post_in?(%{member?: member?}, nil), do: member?
  def may_post_in?(%{levels: levels}, level), do: level in levels

  defp writable_levels(actor, fleet_id) do
    with true <- Presets.levelled?(fleet_id),
         [_ | _] = held <- held_levels(actor, fleet_id),
         {:ok, minted} <- KeyFleet.Chain.minted(fleet_id) do
      Presets.levels_writable_by(held, minted)
    else
      _none -> []
    end
  end

  defp held_levels(%Human{wallet_addresses: [_ | _] = wallets}, fleet_id),
    do: KeyFleet.Keys.levels_held!(fleet_id, wallets)

  defp held_levels(%Agent{} = actor, fleet_id) do
    if Agent.valid?(actor) do
      for pairing <- KeyFleet.Keys.my_effective_pairings!(fleet_id, actor: actor),
          Presets.fibonacci_token?(pairing.token_id),
          uniq: true,
          do: Presets.fibonacci_level_of(pairing.token_id)
    else
      []
    end
  end

  defp held_levels(_actor, _fleet_id), do: []

  defp holds?(%Human{wallet_addresses: [_ | _] = wallets} = actor, fleet_id) do
    KeyAttachment
    |> Ash.Query.for_read(
      :held_in_fleet,
      %{fleet_id: fleet_id, owner_wallets: wallets},
      actor: actor
    )
    |> Ash.exists?()
  end

  defp holds?(%Agent{} = actor, fleet_id) do
    if Agent.valid?(actor) do
      KeyPairing
      |> Ash.Query.for_read(:my_effective_pairings, %{fleet_id: fleet_id}, actor: actor)
      |> Ash.exists?()
    else
      false
    end
  end

  defp holds?(_actor, _fleet_id), do: false
end

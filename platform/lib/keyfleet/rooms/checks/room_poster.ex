defmodule KeyFleet.Rooms.Checks.RoomPoster do
  @moduledoc """
  Who may post in a fleet's rooms, name its open rooms and create rooms in it:
  the people holding the fleet's keys today, and the agents those people have
  attached to them. Every room of the fleet is open to all of them. With
  `agents_only?: true`, as for creating a room, only those agents count.

  Nobody is enrolled in a fleet and nothing about this is stored. Standing is
  read from the keys themselves every time, so a key changing hands moves the
  right to post with it. While the fleet's key ownership is not fresh, nobody
  has standing.
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias KeyFleet.Actors.Agent
  alias KeyFleet.Actors.Human
  alias KeyFleet.Keys.KeyAttachment
  alias KeyFleet.Keys.KeyPairing
  alias KeyFleet.Rooms.Message
  alias KeyFleet.Rooms.Room

  @impl true
  def describe(opts) do
    if Keyword.get(opts, :agents_only?, false),
      do: "actor is an agent running one of the fleet's keys",
      else: "actor holds or runs one of the fleet's keys"
  end

  @impl true
  def match?(actor, %{subject: %Ash.Changeset{resource: Message} = changeset}, _opts),
    do: may_post?(actor, Ash.Changeset.get_argument(changeset, :fleet_id))

  def match?(actor, %{subject: %Ash.Changeset{resource: Room} = changeset}, opts),
    do:
      (is_struct(actor, Agent) or not Keyword.get(opts, :agents_only?, false)) and
        may_post?(actor, Ash.Changeset.get_attribute(changeset, :fleet_id))

  @doc """
  Whether this actor may post in the fleet's rooms right now.

  The same question the policy asks, so a page can offer somebody the box to
  write in exactly when the post would be taken.
  """
  def may_post?(actor, fleet_id),
    do: KeyFleet.Chain.fresh?(fleet_id) and holds?(actor, fleet_id)

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

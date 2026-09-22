defmodule KeyFleet.Rooms.Checks.FleetMember do
  @moduledoc """
  Who may post in a fleet's rooms: the people holding its keys today, and the
  agents those people have attached to them.

  Nobody is enrolled in a fleet and nothing about this is stored. Standing is
  read from the keys themselves every time somebody posts, so a key changing
  hands moves the right to post with it. While the fleet's key ownership is not
  fresh, nobody has standing.
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias KeyFleet.Actors.Agent
  alias KeyFleet.Actors.Human
  alias KeyFleet.Keys.KeyAttachment
  alias KeyFleet.Keys.KeyPairing

  @impl true
  def describe(_opts), do: "actor holds or runs a key of the fleet this room belongs to"

  @impl true
  def match?(actor, %{subject: %Ash.Changeset{} = changeset}, _opts),
    do: member?(actor, Ash.Changeset.get_argument(changeset, :fleet_id))

  def match?(_actor, _context, _opts), do: false

  @doc """
  Whether this actor may post in the fleet's rooms right now.

  The same question the policy asks, so a page can offer somebody the box to
  write in exactly when the post would be taken.
  """
  def member?(actor, fleet_id), do: KeyFleet.Chain.fresh?(fleet_id) and holds?(actor, fleet_id)

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

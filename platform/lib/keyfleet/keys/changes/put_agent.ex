defmodule Keyfleet.Keys.Changes.PutAgent do
  @moduledoc """
  Puts the agent the write names by its wallet on the Key, inside the
  write's own transaction once the policy has let it through
  (`Keyfleet.Keys.AgentKey`). The agent's row in the fleet is overwritten,
  so it comes off the Key it was on there.

  First the pairings are locked, in wallet order: a writing agent's own
  (`RegentAgents.Authority.lock/4`), and the named agent's current one with
  the person (`RegentAgents.Authority.lock_current/3`), whose id is what is
  kept. Every write about an agent locks its pairing, so two at once run one
  after the other. Then the agent's row in the fleet is locked, and the Key
  it names and the Key it is on now are read as the chain records them: the
  person's wallets must hold the Key (`KeyNotHeldError` otherwise), and the
  row is saved with the Key's ownership record as it is then. A row whose Key
  has changed hands since it was saved puts the agent on no Key
  (`Keyfleet.Keys.placed_on?/3`).

  An agent writing moves no agent: it is refused (`PersonOnlyError`) if the
  named agent stands on another Key, so only the person's write moves one.
  Taking an agent off a Key is the person's alone (`:release`). A writing
  agent no longer paired answers `NotPairedError`, and a wallet no agent
  paired with the person has now `AgentUnknownError`.

  The Key the agent left goes in the change's context (`:left_token_id`), for
  `Keyfleet.Keys.Changes.TellKeysChanged`.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Keys
  alias Keyfleet.Keys.AgentKey
  alias Keyfleet.Keys.Errors.{AgentUnknownError, KeyNotHeldError, NotPairedError, PersonOnlyError}
  alias RegentAgents.Authority

  @impl true
  def change(changeset, _opts, %{actor: actor}),
    do: Ash.Changeset.before_action(changeset, &put(&1, actor))

  defp put(changeset, actor) do
    wallet = changeset |> Ash.Changeset.get_argument(:agent_wallet) |> String.downcase()
    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    token_id = Ash.Changeset.get_attribute(changeset, :token_id)

    with {:ok, pairing_id} <- lock_pairings(actor, wallet),
         {:ok, row} <- lock_row(fleet_id, pairing_id, actor),
         {:ok, key, standing} <- read_keys(fleet_id, token_id, row, actor),
         :ok <- moves_no_agent(actor, standing, token_id) do
      changeset
      |> Ash.Changeset.force_change_attribute(:paired_agent_id, pairing_id)
      |> Ash.Changeset.force_change_attribute(:ownership_epoch, key.ownership_epoch)
      |> Ash.Changeset.set_context(%{left_token_id: standing && standing.token_id})
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # The pairings the write rests on, locked in wallet order; the named
  # agent's id.
  defp lock_pairings(actor, wallet) do
    actor
    |> pairings(wallet)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, nil}, fn {_wallet, role}, {:ok, named} ->
      case lock(role, actor, wallet) do
        {:ok, %{id: id}} when role in [:named, :itself] -> {:cont, {:ok, id}}
        {:ok, _own} -> {:cont, {:ok, named}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # A writing agent's own pairing and the named agent's, one lock when the
  # agent names itself; a person has no pairing of their own to lock.
  defp pairings(%Agent{wallet_address: wallet}, wallet), do: [{wallet, :itself}]
  defp pairings(%Agent{wallet_address: own}, wallet), do: [{own, :own}, {wallet, :named}]
  defp pairings(_person, wallet), do: [{wallet, :named}]

  defp lock(role, %Agent{} = agent, _wallet) when role in [:own, :itself] do
    case Authority.lock(
           Keyfleet.Repo,
           agent.pairing_id,
           agent.privy_user_id,
           agent.wallet_address
         ) do
      {:error, :not_paired} -> {:error, NotPairedError.exception([])}
      locked -> locked
    end
  end

  defp lock(:named, actor, wallet) do
    with {:ok, person} <- Keys.person_privy_id(actor),
         {:ok, pairing} <- Authority.lock_current(Keyfleet.Repo, person, wallet) do
      {:ok, pairing}
    else
      not_theirs when not_theirs in [:error, {:error, :not_paired}] ->
        {:error, AgentUnknownError.exception(wallet: wallet)}

      {:error, error} ->
        {:error, error}
    end
  end

  # The named agent's row in the fleet, if it has one.
  defp lock_row(fleet_id, pairing_id, actor) do
    AgentKey
    |> Ash.Query.filter(fleet_id == ^fleet_id and paired_agent_id == ^pairing_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor)
  end

  # The Key's ownership record now, whose epoch the write keeps, and the
  # agent's row if it still stands on its Key. The person's wallets hold the
  # Key; one the record no longer shows is not held.
  defp read_keys(fleet_id, token_id, row, actor) do
    wallets = Keys.person_wallets(actor)
    token_ids = Enum.uniq([token_id | List.wrap(row && row.token_id)])
    query = Ash.Query.filter(Keyfleet.Keys.KeyAttachment, token_id in ^token_ids)

    with {:ok, keys} <- Keys.keys_held_in_fleet(fleet_id, wallets, actor: actor, query: query) do
      keys = Map.new(keys, &{&1.token_id, &1})

      case keys[token_id] do
        nil -> {:error, KeyNotHeldError.exception(fleet_id: fleet_id, token_id: token_id)}
        key -> {:ok, key, standing(row, keys, wallets)}
      end
    end
  end

  defp standing(nil, _keys, _wallets), do: nil

  defp standing(row, keys, wallets),
    do: if(Keys.placed_on?(row, keys[row.token_id], wallets), do: row)

  # An agent puts an agent that stands on no Key, or on this one already.
  defp moves_no_agent(%Agent{}, %{token_id: other}, token_id) when other != token_id,
    do: {:error, PersonOnlyError.exception([])}

  defp moves_no_agent(_actor, _standing, _token_id), do: :ok
end

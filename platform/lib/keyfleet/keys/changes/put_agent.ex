defmodule Keyfleet.Keys.Changes.PutAgent do
  @moduledoc """
  Puts the agent the write names by its wallet on the Key, or takes the Key's
  agent off when it names none (the person's alone, by the policy), inside the
  write's own transaction once the policy has let it through
  (`Keyfleet.Keys.AgentKey`). The Key the named agent was on in the fleet, if
  another, loses it.

  Every write locks what it rests on in one order, so two at once for the
  same person, a swap included, run one after the other and never wait on
  each other in turn. First the pairings, in wallet order: a writing agent's
  own (`RegentAgents.Authority.lock/4`), and the named agent's current one
  with the person (`RegentAgents.Authority.lock_current/3`), whose id is what
  is kept. Then the person's rows the write changes in the fleet, the Key's
  and the named agent's, lowest Key first.

  The row is saved with the Key's ownership record as it is now. A locked row
  whose Key has changed hands since it was saved, or that the person no
  longer holds, puts no agent anywhere (`Keyfleet.Keys.placed_on?/3`): the
  Key's own is overwritten, and one on another Key is cleared, whoever writes.

  An agent writing changes no agent's place: once they are locked, it is
  refused (`PersonOnlyError`) if the Key has another agent paired now, or the
  named agent stands on another Key, so only the person's write takes an
  agent off a Key (`:release`). Naming no agent is the person's alone, by the
  policy.

  A Key with no row when they are locked is written only if no other write
  has given it an agent since; one that has loses the race and answers
  `Ash.Error.Changes.StaleRecord`, to read again and try again. A writing
  agent no longer paired answers `NotPairedError`, and a wallet no agent
  paired with the person has now `AgentUnknownError`.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.Human
  alias Keyfleet.Keys
  alias Keyfleet.Keys.AgentKey
  alias Keyfleet.Keys.Errors.{AgentUnknownError, KeyNotHeldError, NotPairedError, PersonOnlyError}
  alias RegentAgents.Authority

  @impl true
  def change(changeset, _opts, %{actor: actor}),
    do: Ash.Changeset.before_action(changeset, &put(&1, actor))

  defp put(changeset, actor) do
    wallet =
      case Ash.Changeset.get_argument(changeset, :agent_wallet) do
        nil -> nil
        wallet -> String.downcase(wallet)
      end

    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    token_id = Ash.Changeset.get_attribute(changeset, :token_id)

    with {:ok, pairing_id} <- lock_pairings(actor, wallet),
         {:ok, rows} <- lock_rows(changeset, actor, pairing_id),
         {:ok, standing, key} <- standing(rows, fleet_id, token_id, actor),
         :ok <- moves_no_agent(actor, standing, token_id, pairing_id),
         :ok <- clear(rows -- standing, token_id),
         :ok <- release(standing, token_id, pairing_id, actor) do
      changeset
      |> Ash.Changeset.force_change_attribute(:paired_agent_id, pairing_id)
      |> Ash.Changeset.force_change_attribute(:ownership_epoch, key.ownership_epoch)
      |> unless_taken(rows, token_id)
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # The pairings the write rests on, locked in wallet order; the named
  # agent's id, or nil when the write names none.
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
  defp pairings(%Agent{wallet_address: own}, nil), do: [{own, :own}]
  defp pairings(%Agent{wallet_address: own}, wallet), do: [{own, :own}, {wallet, :named}]
  defp pairings(_person, nil), do: []
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

  # The person's rows this write changes in the fleet: the Key's, and the
  # Key the named agent is on.
  defp lock_rows(changeset, actor, pairing_id) do
    account_id = Ash.Changeset.get_attribute(changeset, :human_account_id)
    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    token_id = Ash.Changeset.get_attribute(changeset, :token_id)

    query = Ash.Query.filter(AgentKey, human_account_id == ^account_id and fleet_id == ^fleet_id)

    query =
      if pairing_id,
        do: Ash.Query.filter(query, token_id == ^token_id or paired_agent_id == ^pairing_id),
        else: Ash.Query.filter(query, token_id == ^token_id)

    query
    |> Ash.Query.sort(token_id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read(actor: actor)
  end

  # The locked rows that still put an agent on their Key, and the Key's own
  # ownership record now, whose epoch the write keeps. The person holds the
  # Key (`Keyfleet.Keys.Validations.HeldByPerson`); one the record no longer
  # shows is not held.
  defp standing(rows, fleet_id, token_id, actor) do
    wallets = person_wallets(actor)
    token_ids = Enum.uniq([token_id | Enum.map(rows, & &1.token_id)])

    query = Ash.Query.filter(Keyfleet.Keys.KeyAttachment, token_id in ^token_ids)

    with {:ok, keys} <- Keys.keys_held_in_fleet(fleet_id, wallets, actor: actor, query: query) do
      keys = Map.new(keys, &{&1.token_id, &1})

      case keys[token_id] do
        nil ->
          {:error, KeyNotHeldError.exception(fleet_id: fleet_id, token_id: token_id)}

        key ->
          {:ok, Enum.filter(rows, &Keys.placed_on?(&1, keys[&1.token_id], wallets)), key}
      end
    end
  end

  defp person_wallets(%Agent{pairing: %Human{wallet_addresses: wallets}}), do: wallets
  defp person_wallets(%Human{wallet_addresses: wallets}), do: wallets

  # Rows on another Key that no longer stand there hold the named agent's
  # place for nothing, so the write clears them, whoever it is by: taking an
  # agent off a Key it no longer stands on changes no agent's place.
  defp clear(rows, token_id) do
    rows
    |> Enum.reject(&(&1.token_id == token_id))
    |> Enum.reduce_while(:ok, fn row, :ok ->
      case Ash.destroy(row, action: :release, authorize?: false) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # An agent puts an agent that is on no Key onto a Key with none: the named
  # agent stands on no other Key, and the Key's row, if any, has no agent, one
  # no longer paired, or one from before the Key changed hands. So an agent's
  # write never takes one off.
  defp moves_no_agent(%Agent{}, rows, token_id, pairing_id) do
    places_changed = &(moved?(&1, token_id, pairing_id) or replaced?(&1, token_id, pairing_id))

    if Enum.any?(rows, places_changed),
      do: {:error, PersonOnlyError.exception([])},
      else: :ok
  end

  defp moves_no_agent(_person, _rows, _token_id, _pairing_id), do: :ok

  defp moved?(row, token_id, pairing_id),
    do: row.token_id != token_id and row.paired_agent_id == pairing_id

  defp replaced?(%{token_id: token_id, paired_agent_id: id}, token_id, pairing_id)
       when id not in [nil, pairing_id],
       do: Authority.active_episode?(Keyfleet.Repo, id)

  defp replaced?(_row, _token_id, _pairing_id), do: false

  # The named agent comes off the other Key it stands on in this fleet, which
  # only the person's write does.
  defp release(rows, token_id, pairing_id, actor) do
    case Enum.find(rows, &moved?(&1, token_id, pairing_id)) do
      nil -> :ok
      row -> Ash.destroy(row, action: :release, actor: actor)
    end
  end

  # A Key with no row when the rows were locked is written only while no
  # other write has given it an agent since.
  defp unless_taken(changeset, rows, token_id) do
    if Enum.any?(rows, &(&1.token_id == token_id)),
      do: changeset,
      else: Ash.Changeset.filter(changeset, expr(is_nil(paired_agent_id)))
  end
end

defmodule Keyfleet.Points.Holder do
  @moduledoc """
  Who held a Key when something was done as it, for Regent Points' checks of
  Keyfleet's own actions, and what Points records of it (`facts/6`).

  A Key's holder at a moment is the account whose verified wallets held the
  wallet of the Key's ownership epoch then, from the wallet history
  (`RegentPoints.WalletSnapshot.owner/2`), never today's owner. Whoever acted
  must be that holder: the person, signing with a wallet of theirs then, or an
  agent through a pairing of that person's. Anything else does not qualify.
  """

  alias Keyfleet.{Accounts, Keys}
  alias Keyfleet.Actors.System

  # Far longer than any sign-in write stays open.
  @settled_after_seconds 600

  @doc """
  The Key's ownership epoch `ownership_epoch`. One the chain reader has not
  recorded yet is looked for again on Oban's next try.
  """
  def epoch(fleet_id, token_id, ownership_epoch) do
    with {:ok, epochs} <- history(fleet_id, token_id) do
      case Enum.find(epochs, &(&1.ownership_epoch == ownership_epoch)) do
        nil -> {:retry, :key_epoch_not_found}
        epoch -> {:ok, epoch}
      end
    end
  end

  @doc "The Key's ownership epoch at `at`: the latest of its epochs recorded by then."
  def epoch_at(fleet_id, token_id, at) do
    with {:ok, epochs} <- history(fleet_id, token_id) do
      case Enum.filter(epochs, &(DateTime.compare(&1.observed_at, at) != :gt)) do
        [] -> {:error, :key_not_held}
        held -> {:ok, List.last(held)}
      end
    end
  end

  @doc "The account whose wallets held the Key's ownership epoch `epoch` at `at`."
  def holder(epoch, at) do
    case RegentPoints.WalletSnapshot.owner(epoch.owner_wallet, at) do
      {:ok, account_id} ->
        {:ok,
         %{
           fleet_id: epoch.fleet_id,
           token_id: epoch.token_id,
           ownership_epoch: epoch.ownership_epoch,
           account_id: account_id
         }}

      {:error, :unknown_owner} ->
        unknown(at, :key_holder_unknown)
    end
  end

  @doc """
  Who acted on a saved record, from what it keeps of an agent acting
  (`Keyfleet.Agents.Changes.RecordAuthority`): the pairing the agent acted
  through, which every agent's post, vote and push has, or else the person's
  `wallet`.
  """
  def acting(%{acting_agent_wallet: nil}, wallet), do: {:human, wallet}
  def acting(%{agent_pairing_id: pairing_id}, _wallet), do: {:agent, pairing_id}

  @doc """
  Who acted as the holder's Key at `at`, as Points records them: `:human` for
  `{:human, wallet}` when that wallet was the holder's then, or
  `{:agent, pairing}` for `{:agent, pairing_id}` or `{:agent_wallet, wallet}`
  when the pairing is the holder's person's.
  """
  def actor(holder, {:human, wallet}, at) do
    case RegentPoints.WalletSnapshot.owner(wallet, at) do
      {:ok, account_id} when account_id == holder.account_id -> {:ok, :human}
      {:ok, _another_account} -> {:error, :actor_not_key_holder}
      {:error, :unknown_owner} -> unknown(at, :actor_not_key_holder)
    end
  end

  # A pairing is kept after an unpair; one that is not there is refused.
  def actor(holder, {:agent, pairing_id}, _at) do
    case RegentAgents.pairing_history(pairing_id) do
      {:ok, %{} = pairing} -> of_person(holder, pairing)
      {:ok, nil} -> {:error, :pairing_not_found}
    end
  end

  def actor(holder, {:agent_wallet, wallet}, at) do
    case RegentAgents.pairing_at(wallet, at) do
      {:ok, pairing} -> of_person(holder, pairing)
      {:error, :unknown_owner} -> {:error, :agent_not_paired_with_holder}
    end
  end

  @doc """
  What Points records of a `kind` record named `key`, done as the holder's Key
  at `at` by `actor`, with `evidence` added to the Key it was done as. A moment
  ahead of this server's clock comes back on Oban's next try.

  The Key is also its proof (`subject_key`), which Points lets earn each
  one-time rule for one account only (`RegentPoints.Award`): each Key earns
  each one-time rule once, for the first of its holders to earn it. Points
  applies the proof to one-time rules only, so the sale rule, which repeats,
  is not held to it.
  """
  def facts(kind, key, holder, actor, at, evidence \\ %{}) do
    if DateTime.after?(at, DateTime.utc_now()),
      do: {:retry, :action_ahead_of_clock},
      else: {:ok, record(kind, key, holder, actor, at, evidence)}
  end

  defp record(kind, key, holder, actor, at, evidence) do
    {actor_kind, actor_id, attribution} =
      case actor do
        :human -> {"human", to_string(holder.account_id), %{}}
        # An agent is named by its wallet; its pairing is the evidence it acted for the person.
        {:agent, pairing} -> {"agent", pairing.wallet, %{"attribution_link_id" => pairing.id}}
      end

    key_id = "#{holder.fleet_id}:#{holder.token_id}"

    %{
      source_app: "keyfleet",
      source_kind: kind,
      source_event_key: key,
      account_id: holder.account_id,
      actor_kind: actor_kind,
      actor_id: actor_id,
      source_action_at: at,
      qualified_at: at,
      evidence_ref: kind <> ":" <> key,
      evidence:
        %{
          "key_id" => key_id,
          "subject_key" => key_id,
          "ownership_epoch" => to_string(holder.ownership_epoch)
        }
        |> Map.merge(attribution)
        |> Map.merge(evidence)
    }
  end

  # Every epoch of one Key, oldest first: one for each time it changed hands.
  defp history(fleet_id, token_id), do: Keys.key_history(fleet_id, token_id, actor: %System{})

  defp of_person(holder, pairing) do
    case Accounts.points_account(holder.account_id, actor: %System{}) do
      {:ok, %{privy_user_id: person}} when person == pairing.privy_user_id ->
        {:ok, {:agent, pairing}}

      {:ok, _another_person} ->
        {:error, :agent_not_paired_with_holder}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  # A person's wallets are stamped as their sign-in writes them, before that write
  # commits, so just after `at` an owner may still be on its way and the check
  # comes back on Oban's next try. Once `at` is older than any write that can
  # still commit, no owner then is final.
  defp unknown(at, reason) do
    if DateTime.diff(DateTime.utc_now(), at) < @settled_after_seconds,
      do: {:retry, reason},
      else: {:error, reason}
  end
end

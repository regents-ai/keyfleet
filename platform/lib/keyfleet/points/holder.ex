defmodule Keyfleet.Points.Holder do
  @moduledoc """
  Who held a Key when something was done as it, for Regent Points' checks of
  Keyfleet's records: the Key's ownership epoch then, and the account of the
  person whose verified wallets held it at that moment, from the wallet
  history (`RegentPoints.WalletSnapshot.owner/2`), never today's owner. An
  agent counts for that person only through a pairing of theirs, and each
  check answers Points with the facts it records (`facts/6`).
  """

  import Ecto.Query, only: [from: 2]

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.System
  alias Keyfleet.Keys.KeyAttachment
  alias Keyfleet.Repo

  @type t :: %{
          fleet_id: String.t(),
          token_id: pos_integer(),
          ownership_epoch: pos_integer(),
          account_id: pos_integer()
        }

  @doc "The holder of the Key's epoch `ownership_epoch`, at `at`."
  def of_epoch(fleet_id, token_id, ownership_epoch, at) do
    from(key in KeyAttachment,
      where:
        key.fleet_id == ^fleet_id and key.token_id == ^token_id and
          key.ownership_epoch == ^ownership_epoch
    )
    |> person(at)
  end

  @doc "The holder of the Key at `at`: the latest of its epochs recorded by then."
  def at(fleet_id, token_id, at) do
    from(key in KeyAttachment,
      where: key.fleet_id == ^fleet_id and key.token_id == ^token_id and key.observed_at <= ^at,
      order_by: [desc: key.ownership_epoch],
      limit: 1
    )
    |> person(at)
  end

  @doc """
  The holder of the Key just before a log of its fleet's contracts at
  `{block_number, log_index}`, as the chain ordered them, at `at`.
  """
  def before(fleet_id, token_id, {block, log}, at) do
    from(key in KeyAttachment,
      where:
        key.fleet_id == ^fleet_id and key.token_id == ^token_id and
          (key.block_number < ^block or (key.block_number == ^block and key.log_index < ^log)),
      order_by: [desc: key.ownership_epoch],
      limit: 1
    )
    |> person(at)
  end

  defp person(query, at) do
    # Read straight from the table: no person is asking, and the Key's epochs
    # offer no read without one.
    with %{} = key <- Repo.one(query),
         {:ok, account_id} <- RegentPoints.WalletSnapshot.owner(key.owner_wallet, at) do
      {:ok,
       %{
         fleet_id: key.fleet_id,
         token_id: key.token_id,
         ownership_epoch: key.ownership_epoch,
         account_id: account_id
       }}
    else
      nil -> {:error, :key_not_held}
      {:error, :unknown_owner} -> {:error, :key_holder_unknown}
    end
  end

  @doc """
  Who acted as the holder's Key: the person, when no agent is named, or
  `{:agent, pairing}` when the record names a pairing of that person's.
  """
  def actor(_holder, nil), do: {:ok, :human}

  def actor(holder, pairing_id) do
    {:ok, pairing} = RegentAgents.pairing_history(pairing_id)
    with {:ok, pairing} <- of_person(holder, pairing), do: {:ok, {:agent, pairing}}
  end

  @doc """
  The pairing of the holder's person whose agent signs as `wallet` at `at`:
  paired by then and not yet unpaired.
  """
  def agent_wallet(holder, wallet, at) do
    case RegentAgents.pairing_at(wallet, at) do
      {:ok, pairing} -> of_person(holder, pairing)
      {:error, :unknown_owner} -> {:error, :agent_not_paired_with_holder}
    end
  end

  defp of_person(_holder, nil), do: {:error, :agent_not_paired_with_holder}

  defp of_person(%{account_id: account_id}, %{privy_user_id: person} = pairing) do
    case Accounts.points_account(account_id, actor: %System{}) do
      {:ok, %{privy_user_id: ^person}} -> {:ok, pairing}
      {:ok, _another_person} -> {:error, :agent_not_paired_with_holder}
      {:error, reason} -> {:retry, reason}
    end
  end

  @doc """
  What Points records of a `kind` record `id` done as the `holder`'s Key at
  `at`: by the person, or by `{:agent, pairing}`, with `evidence` added
  to the Key it was done as.
  """
  def facts(kind, id, holder, actor, at, evidence \\ %{}) do
    {actor_kind, actor_id, attribution} =
      case actor do
        :human -> {"human", to_string(holder.account_id), %{}}
        # An agent is named by its wallet; its pairing is the evidence it acted for the person.
        {:agent, pairing} -> {"agent", pairing.wallet, %{"attribution_link_id" => pairing.id}}
      end

    %{
      source_app: "keyfleet",
      source_kind: kind,
      source_event_key: id,
      account_id: holder.account_id,
      actor_kind: actor_kind,
      actor_id: actor_id,
      source_action_at: at,
      qualified_at: at,
      evidence_ref: kind <> ":" <> id,
      evidence:
        Map.merge(
          %{
            "key_id" => "#{holder.fleet_id}:#{holder.token_id}",
            "ownership_epoch" => to_string(holder.ownership_epoch)
          },
          Map.merge(attribution, evidence)
        )
    }
  end
end

defmodule Keyfleet.Accounts.VerifiedSession do
  @moduledoc "Exchanges verified Privy evidence for the canonical human account."

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Query.NotFound
  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.EnsIdentity
  alias Keyfleet.Actors.System

  @actor %System{}

  @doc """
  Registers or refreshes the account the verified session names, gives the
  person their shared profile when they have none, reconciles its linked
  socials and asks Ethereum for its wallet's ENS name again, returning the
  providers whose social account another account already holds where it cannot
  be shared.
  Without a linked wallet the account's wallet evidence is withdrawn instead.
  """
  def establish(%RegentPrivy.Session{privy_user_id: did} = verified) do
    # `RegentPrivy.Session` already lowercases the list, keeps each wallet once
    # and puts the wallet the person signed in with inside it.
    case verified do
      %{wallet_address: primary, wallet_addresses: [_ | _] = addresses} when is_binary(primary) ->
        with {:ok, account} <- Accounts.register_verified(did, primary, addresses, actor: @actor),
             {:ok, account} <-
               Accounts.refresh_verified(account, primary, addresses, actor: @actor),
             {:ok, _profile} <- RegentIdentity.ensure(verified),
             {:ok, conflicts} <- reconcile(account.id, verified.linked_socials),
             :ok <- request_ens_lookup(account) do
          {:ok, account, conflicts}
        end

      _no_linked_wallet ->
        withdraw_wallet_evidence(did)
    end
  end

  @doc "Whether the account's stored wallet evidence still names a signed-in wallet."
  def current?(%{wallet_address: primary, wallet_addresses: addresses})
      when is_binary(primary) and is_list(addresses),
      do: addresses != [] and primary in addresses

  def current?(_account), do: false

  defp request_ens_lookup(account) do
    if EnsIdentity.looking_up?() do
      with {:ok, _identity} <-
             Accounts.request_ens_lookup(account.id, account.wallet_address, actor: @actor),
           do: :ok
    else
      :ok
    end
  end

  defp reconcile(account_id, linked_socials) do
    with {:ok, existing} <- Accounts.list_linked_identities_for_account(account_id, actor: @actor),
         {:ok, conflicts} <- upsert_socials(linked_socials, account_id) do
      kept = linked_socials |> Enum.map(& &1.provider) |> MapSet.new()
      remove_missing(existing, kept, conflicts)
    end
  end

  # The first social per provider wins; a provider whose subject another account
  # holds, where that provider's accounts are not shared, is reported as a
  # conflict rather than stopping the sign-in.
  defp upsert_socials(linked_socials, account_id) do
    linked_socials
    |> Enum.uniq_by(& &1.provider)
    |> Enum.reduce_while({:ok, []}, fn social, {:ok, conflicts} ->
      case upsert_social(social, account_id) do
        :ok -> {:cont, {:ok, conflicts}}
        :conflict -> {:cont, {:ok, [social.provider | conflicts]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # The subject still linked to the account is refreshed where it stands; when no
  # row holds it for the account, whatever another sign-in just did, it is linked.
  defp upsert_social(%{provider: provider, subject: subject} = social, account_id) do
    case Accounts.refresh_linked_identity(provider, subject, account_id, verified(social),
           actor: @actor
         ) do
      {:ok, _identity} -> :ok
      {:error, %Ash.Error.Invalid{errors: [%NotFound{}]}} -> link_social(social, account_id)
      {:error, error} -> {:error, error}
    end
  end

  # A first link for the provider, or one that replaces the account's earlier
  # subject. A subject other accounts hold is linked here as well when its
  # provider's accounts are shared; otherwise the database refuses it.
  defp link_social(%{provider: provider, subject: subject} = social, account_id) do
    identity =
      Map.merge(verified(social), %{
        provider: provider,
        subject: subject,
        human_account_id: account_id
      })

    case Accounts.upsert_linked_identity(identity, actor: @actor) do
      {:ok, _identity} -> :ok
      {:error, error} -> conflict_or_error(error)
    end
  end

  defp verified(social) do
    social
    |> Map.take([:username, :display_name])
    |> Map.merge(%{verified_at: DateTime.utc_now(), metadata: %{}})
  end

  # `LinkedIdentity` `:unique_subject_per_provider` refuses a subject another
  # account holds, one a concurrent sign-in just took included, with an error on
  # the subject alone that names the unique rule: that is the conflict.
  defp conflict_or_error(%Ash.Error.Invalid{errors: errors} = error) do
    if Enum.any?(errors, &subject_taken?/1), do: :conflict, else: {:error, error}
  end

  defp conflict_or_error(error), do: {:error, error}

  defp subject_taken?(%InvalidAttribute{field: :subject, private_vars: vars}),
    do: vars[:constraint_type] == :unique

  defp subject_taken?(_error), do: false

  defp remove_missing(existing, kept, conflicts) do
    existing
    |> Enum.reject(&(&1.provider in kept))
    |> Enum.reduce_while({:ok, conflicts}, fn identity, ok ->
      case Accounts.remove_linked_identity(identity, actor: @actor) do
        :ok -> {:cont, ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp withdraw_wallet_evidence(did) do
    with {:ok, %{} = account} <- Accounts.get_by_privy_did(did, actor: @actor),
         {:ok, _account} <- Accounts.refresh_verified(account, nil, [], actor: @actor) do
      {:error, :missing_linked_wallet}
    else
      {:ok, nil} -> {:error, :missing_linked_wallet}
      error -> error
    end
  end
end

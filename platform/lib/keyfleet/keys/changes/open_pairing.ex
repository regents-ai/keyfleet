defmodule Keyfleet.Keys.Changes.OpenPairing do
  @moduledoc """
  Opens one agent's attachment to a key under the owner the key has right now.

  An agent signing from the owner's own wallet attaches straight away; anyone
  else leaves a request the owner can approve. Neither happens while the
  fleet's key ownership is not fresh, since the owner is not known then.
  """
  use Ash.Resource.Change

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Keys.Errors.AlreadyOperatingError
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError
  alias Keyfleet.Keys.Errors.ProfileRequiredError
  alias Keyfleet.Keys.Errors.UnknownKeyError
  alias Keyfleet.Keys.PairingLedger

  @impl true
  def change(changeset, _opts, %{actor: %Agent{wallet_address: wallet} = actor}) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      fleet_id = Ash.Changeset.get_argument(changeset, :fleet_id)
      token_id = Ash.Changeset.get_argument(changeset, :token_id)
      PairingLedger.lock_key!(fleet_id, token_id)

      case {Keyfleet.Chain.fresh?(fleet_id),
            Keyfleet.Keys.current_key!(fleet_id, token_id, actor: actor),
            Keyfleet.Agents.get_my_profile!(actor: actor)} do
        {false, _epoch, _profile} ->
          Ash.Changeset.add_error(
            changeset,
            OwnershipRefreshingError.exception(fleet_id: fleet_id)
          )

        {true, nil, _profile} ->
          Ash.Changeset.add_error(
            changeset,
            UnknownKeyError.exception(fleet_id: fleet_id, token_id: token_id)
          )

        {true, _epoch, nil} ->
          Ash.Changeset.add_error(
            changeset,
            ProfileRequiredError.exception(wallet_address: wallet)
          )

        {true, epoch, profile} ->
          open(changeset, epoch, profile, wallet, actor)
      end
    end)
  end

  def change(changeset, _opts, _context), do: changeset

  defp open(changeset, epoch, profile, wallet, actor) do
    if operating?(epoch, profile, actor) do
      Ash.Changeset.add_error(
        changeset,
        AlreadyOperatingError.exception(fleet_id: epoch.fleet_id, token_id: epoch.token_id)
      )
    else
      attach(changeset, epoch, profile, wallet)
    end
  end

  # An agent already running the key has nothing to ask for, and a second row
  # would only end the one it is running under.
  defp operating?(epoch, profile, actor) do
    case Keyfleet.Keys.current_operator!(epoch.fleet_id, epoch.token_id, actor: actor) do
      nil -> false
      operator -> operator.agent_profile_id == profile.id
    end
  end

  defp attach(changeset, epoch, profile, wallet) do
    PairingLedger.replace_open_request!(epoch.fleet_id, epoch.token_id, profile.id)

    changeset =
      Ash.Changeset.force_change_attributes(changeset, %{
        fleet_id: epoch.fleet_id,
        token_id: epoch.token_id,
        ownership_epoch: epoch.ownership_epoch,
        owner_wallet: epoch.owner_wallet,
        operator_wallet: wallet,
        agent_profile_id: profile.id
      })

    if wallet == epoch.owner_wallet do
      PairingLedger.replace_active!(epoch.fleet_id, epoch.token_id, nil)

      Ash.Changeset.force_change_attributes(changeset, %{
        status: :active,
        approved_at: DateTime.utc_now()
      })
    else
      Ash.Changeset.force_change_attribute(changeset, :status, :requested)
    end
  end
end

defmodule Keyfleet.Keys do
  @moduledoc """
  Key ownership and reveals projected from contract events, and who operates
  each key.
  """
  use Ash.Domain

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.Human

  resources do
    resource Keyfleet.Keys.KeyAttachment do
      define :record_epoch, action: :record_epoch
      define :key_history, action: :history, args: [:fleet_id, :token_id]
      define :current_key, action: :current, args: [:fleet_id, :token_id], not_found_error?: false

      define :held_identity_key,
        action: :identity_in_fleet,
        args: [:fleet_id, :owner_wallets],
        not_found_error?: false

      define :keys_in_fleet, action: :current_in_fleet, args: [:fleet_id]
      define :keys_held_in_fleet, action: :held_in_fleet, args: [:fleet_id, :owner_wallets]

      define :recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :epochs_recorded_since, action: :recorded_since, args: [:fleet_id, :after_seq]
    end

    resource Keyfleet.Keys.KeyReveal do
      define :record_reveal, action: :record
      define :get_reveal, action: :read, get_by: [:fleet_id, :token_id], not_found_error?: false
      define :reveals_recorded_since, action: :recorded_since, args: [:fleet_id, :after_seq]
    end

    resource Keyfleet.Keys.KeyPairing do
      define :request_pairing, action: :request_pairing, args: [:fleet_id, :token_id]
      define :approve_pairing, action: :approve_pairing
      define :decline_pairing, action: :decline_pairing
      define :detach_operator, action: :detach_operator
      define :withdraw_pairing_request, action: :withdraw_pairing_request

      define :current_operator,
        action: :current_operator,
        args: [:fleet_id, :token_id],
        not_found_error?: false

      define :list_pairing_requests, action: :pairing_requests, args: [:fleet_id, :token_id]
      define :pairing_history, action: :pairing_history, args: [:fleet_id, :token_id]
      define :my_pairings, action: :my_pairings

      define :my_identity_key,
        action: :my_identity_in_fleet,
        args: [:fleet_id],
        not_found_error?: false

      define :fleet_operators, action: :operators_in_fleet, args: [:fleet_id, :token_ids]
      define :keys_run_in_fleet, action: :run_in_fleet, args: [:fleet_id]

      define :my_open_request,
        action: :my_open_request,
        args: [:fleet_id, :token_id],
        not_found_error?: false
    end
  end

  @doc """
  Where a fleet's pages hear which of its keys have just changed: sold, changed
  hands, revealed, or gained or lost the agent running them, as
  `{:keys_changed, fleet_id, token_ids}`.
  """
  def topic(fleet_id), do: "fleet:#{fleet_id}:keys"

  @doc """
  The key `actor` is in a fleet today, as `%{token_id: token_id, wallet: wallet}`,
  or `nil` when it holds and runs none of the fleet's keys.

  Keys rank by the order they were sold, the first key sold ranking highest. A
  person is the highest-ranked key their wallets hold, and `wallet` is the one
  holding it. An agent is the highest-ranked key it runs today, and `wallet` is
  its own. Everything either writes in the fleet is written as that key.
  """
  def identity(%Human{wallet_addresses: [_ | _] = wallets} = actor, fleet_id) do
    case held_identity_key!(fleet_id, wallets, actor: actor) do
      nil -> nil
      key -> %{token_id: key.token_id, wallet: key.owner_wallet}
    end
  end

  def identity(%Agent{wallet_address: wallet} = actor, fleet_id) do
    with true <- Agent.valid?(actor),
         %{token_id: token_id} <- my_identity_key!(fleet_id, actor: actor) do
      %{token_id: token_id, wallet: wallet}
    else
      _none -> nil
    end
  end

  def identity(_actor, _fleet_id), do: nil

  @doc """
  Up to `limit` of the fleet's keys numbered 1 to `minted` that have no
  recorded reveal, lowest first, leaving out the numbers in `except`:
  `{:ok, token_ids}` or `{:error, error}`.
  """
  def unrevealed(fleet_id, minted, except, limit) do
    # Raw SQL, not an Ash read: the keys it lists have no row (key_reveals has only revealed ones).
    case Keyfleet.Repo.query(
           """
           SELECT key.token_id FROM generate_series(1, $2::bigint) AS key(token_id)
           WHERE key.token_id <> ALL($3::bigint[])
             AND NOT EXISTS (
               SELECT 1 FROM keyfleet_app.key_reveals AS reveal
               WHERE reveal.fleet_id = $1 AND reveal.token_id = key.token_id
             )
           ORDER BY key.token_id
           LIMIT $4
           """,
           [fleet_id, minted, except, limit]
         ) do
      {:ok, %Postgrex.Result{rows: rows}} -> {:ok, List.flatten(rows)}
      {:error, error} -> {:error, error}
    end
  end
end

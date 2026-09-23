defmodule KeyFleet.Keys do
  @moduledoc "Key ownership projected from contract events, and who operates each key."
  use Ash.Domain

  resources do
    resource KeyFleet.Keys.KeyAttachment do
      define :record_epoch, action: :record_epoch
      define :key_history, action: :history, args: [:fleet_id, :token_id]
      define :current_key, action: :current, args: [:fleet_id, :token_id], not_found_error?: false

      define :keys_held_in_fleet, action: :held_in_fleet, args: [:fleet_id, :owner_wallets]
      define :keys_in_fleet, action: :current_in_fleet, args: [:fleet_id]

      define :recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end

    resource KeyFleet.Keys.KeyPairing do
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
      define :my_effective_pairings, action: :my_effective_pairings, args: [:fleet_id]
      define :fleet_operators, action: :operators_in_fleet, args: [:fleet_id, :token_ids]

      define :my_open_request,
        action: :my_open_request,
        args: [:fleet_id, :token_id],
        not_found_error?: false
    end
  end

  # One probe per level: each walks the index on (fleet, owner, key) within
  # that level and stops at the first key the wallet still holds, so holding
  # thousands of keys costs about what holding one does. A key is held while
  # its latest ownership record names the wallet.
  @levels_held """
  SELECT bounds.level::integer
  FROM unnest($3::bigint[], $4::bigint[]) WITH ORDINALITY AS bounds(first_key, last_key, level)
  CROSS JOIN LATERAL (
    SELECT 1 FROM keyfleet_app.key_attachments AS held
    WHERE held.fleet_id = $1
      AND held.owner_wallet = ANY($2)
      AND held.token_id BETWEEN bounds.first_key AND bounds.last_key
      AND NOT EXISTS (
        SELECT 1 FROM keyfleet_app.key_attachments AS later
        WHERE later.fleet_id = held.fleet_id
          AND later.token_id = held.token_id
          AND later.ownership_epoch > held.ownership_epoch
      )
    LIMIT 1
  ) AS holding
  ORDER BY bounds.level
  """

  @doc """
  The Fibonacci levels in which any of `wallets` holds a key of the fleet
  right now, lowest first. Only the levels are read, never the keys.
  """
  def levels_held!(fleet_id, wallets) when is_list(wallets) do
    {starts, ends} = KeyFleet.Fleets.Presets.fibonacci_level_bounds()

    KeyFleet.Repo.query!(@levels_held, [fleet_id, wallets, starts, ends]).rows
    |> List.flatten()
  end
end

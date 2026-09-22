defmodule KeyFleet.Keys do
  @moduledoc "Key ownership projected from contract events, and who operates each key."
  use Ash.Domain

  resources do
    resource KeyFleet.Keys.KeyAttachment do
      define :record_epoch, action: :record_epoch
      define :key_history, action: :history, args: [:fleet_id, :token_id]
      define :current_key, action: :current, args: [:fleet_id, :token_id], not_found_error?: false
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

      define :my_open_request,
        action: :my_open_request,
        args: [:fleet_id, :token_id],
        not_found_error?: false
    end
  end
end

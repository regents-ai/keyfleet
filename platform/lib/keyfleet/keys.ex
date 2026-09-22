defmodule KeyFleet.Keys do
  @moduledoc "Fleet-scoped ownership epochs projected from contract events."
  use Ash.Domain

  resources do
    resource KeyFleet.Keys.KeyAttachment do
      define :record_epoch, action: :record_epoch
      define :key_history, action: :history, args: [:fleet_id, :token_id]
      define :current_key, action: :current, args: [:fleet_id, :token_id], not_found_error?: false
    end
  end
end

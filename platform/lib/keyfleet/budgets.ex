defmodule Keyfleet.Budgets do
  @moduledoc """
  A project's budget for buying help, and what its Keys buy with it.

  A Key of the fleet opens a budget on an active project
  (`Keyfleet.Budgets.Budget`): a limit in USDC base units, when it expires,
  and where the money came from, as given. A project has one open budget at
  a time. In this version the sponsor funds it and this site keeps its limit;
  no contract does.

  Against it a Key proposes buying a Patchbay assist at a price, a different
  Key approves or refuses it, the proposing Key records the receipt once it
  bought it, and a Key other than the proposer records whether the fix
  worked (`Keyfleet.Budgets.Purchase`). Spent is what the approved purchases
  cost; an approval that would spend more than remains, or on an expired
  budget, is refused and recorded as refused. The site does not check the
  receipt or the payment.

  Every step acts as a Key the same way a workspace write does
  (`Keyfleet.Graph.Checks.KeyActor`, `Keyfleet.Budgets.Steps`); the fleet's
  members read a project's budget.
  """
  use Ash.Domain

  resources do
    resource Keyfleet.Budgets.Budget do
      define :project_budget,
        action: :latest,
        args: [:fleet_id, :project],
        not_found_error?: false

      define :open_budget,
        action: :open,
        args: [:fleet_id, :as_key, :project, :limit_usdc, :expires_at, :source]
    end

    resource Keyfleet.Budgets.Purchase do
      define :propose_purchase,
        action: :propose,
        args: [:fleet_id, :as_key, :project, :purpose, :assist_url, :price_usdc]

      define :decide_purchase, action: :decide, args: [:fleet_id, :as_key, :id, :approve, :reason]

      define :record_receipt,
        action: :receipt,
        args: [:fleet_id, :as_key, :id, :receipt_url, :payment_tx]

      define :record_result,
        action: :result,
        args: [:fleet_id, :as_key, :id, :worked, :note, :evidence_url]
    end
  end
end

defmodule Keyfleet.Credits.Credited do
  @moduledoc """
  When a Credits purchase is credited, asks Regent Points to consider it, inside
  the credit's transaction. Points decides whether the purchase earns; while its
  rule is off nothing is queued.
  """

  use Ash.Resource,
    domain: Keyfleet.Points,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Actors.System

  signals_in do
    from RegentCredits.Signals do
      on :purchase_credited, :purchase_credited, action: :credits_purchase
      on :purchase_attributed, :purchase_attributed, action: :credits_purchase
    end
  end

  actions do
    action :credits_purchase do
      argument :signal, :struct, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        reference = %{
          rule_id: "credits.purchase_settled",
          # Credits is one Regents ledger, so every site names it "regents" and a purchase earns once.
          source_app: "regents",
          source_kind: "credits_purchase",
          source_event_key: signal.purchase_id
        }

        with {:ok, _event} <- RegentPoints.record_event(reference, actor: %System{}), do: :ok
      end
    end
  end

  policies do
    # The source action authorized the signal; Points records it as the system.
    policy always() do
      authorize_if always()
    end
  end
end

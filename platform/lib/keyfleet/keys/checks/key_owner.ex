defmodule Keyfleet.Keys.Checks.KeyOwner do
  @moduledoc false
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias Keyfleet.Actors.Human

  @impl true
  def describe(_opts),
    do: "actor signed in with the wallet that owns the key today, while its ownership is fresh"

  # Standing read from a record that may be behind the chain grants nothing.
  @impl true
  def filter(%Human{wallet_addresses: [_ | _] = wallets}, _authorizer, _opts),
    do:
      Ash.Expr.expr(
        owner_wallet in ^wallets and ownership_epoch == current_ownership_epoch and
          exists(Keyfleet.Chain.Cursor, fleet_id == parent(fleet_id) and fresh?)
      )

  def filter(_actor, _authorizer, _opts), do: Ash.Expr.expr(false)
end

defmodule KeyFleet.Keys.Checks.KeyOwner do
  @moduledoc false
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias KeyFleet.Actors.Human

  @impl true
  def describe(_opts), do: "actor signed in with the wallet that owns the key today"

  @impl true
  def filter(%Human{wallet_addresses: [_ | _] = wallets}, _authorizer, _opts),
    do: Ash.Expr.expr(owner_wallet in ^wallets and ownership_epoch == current_ownership_epoch)

  def filter(_actor, _authorizer, _opts), do: Ash.Expr.expr(false)
end

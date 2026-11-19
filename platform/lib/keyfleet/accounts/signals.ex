defmodule Keyfleet.Accounts.Signals do
  @moduledoc """
  What accounts tell the rest of the site, as Ash signals. Each is emitted in
  the sign-in's own transaction, so a listener with the default delivery
  commits or rolls back with it. Points offers both to Regent Points
  (`Keyfleet.Points.Award`).

    * `:account_registered`: a sign-in created the person's shared Regent
      account. A later sign-in to the same account emits nothing.
    * `:social_linked`: a sign-in linked a social account for a provider the
      account had no link for. A sign-in that refreshes a link emits nothing.
  """

  use Ash.Signals

  signals do
    signal :account_registered do
      argument :account_id, :integer, allow_nil?: false
    end

    signal :social_linked do
      argument :provider, :atom, allow_nil?: false
      argument :subject, :string, allow_nil?: false
    end
  end
end

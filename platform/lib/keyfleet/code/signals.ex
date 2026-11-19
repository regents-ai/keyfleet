defmodule Keyfleet.Code.Signals do
  @moduledoc """
  What a fleet's code tells the rest of the site, as Ash signals. Each is
  emitted in the push's own save, so a listener with the default delivery
  commits or rolls back with it. Points offers it to Regent Points
  (`Keyfleet.Points.Award`).

    * `:push_recorded`: a Key's holder, or an agent for them, moved a branch or
      a tag in one of the fleet's projects as the Key `token_id`, with the
      `wallets` of the person who pushed or whose agent did
      (`Keyfleet.Keys.person_wallets/1`).
  """

  use Ash.Signals

  signals do
    signal :push_recorded do
      argument :push_id, :uuid, allow_nil?: false
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false
      argument :wallets, {:array, :string}, allow_nil?: false
    end
  end
end

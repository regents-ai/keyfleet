defmodule Keyfleet.Polls.Signals do
  @moduledoc """
  What polls tell the rest of the site, as Ash signals. Each is emitted in the
  vote's own save, so a listener with the default delivery commits or rolls
  back with it. Points offers it to Regent Points (`Keyfleet.Points.Award`).

    * `:vote_cast`: the Key `token_id` voted in a poll, with the `wallets` of
      the person who voted or whose agent did
      (`Keyfleet.Keys.person_wallets/1`). Sending the same choice again hands
      back the vote it already has, and emits nothing.
  """

  use Ash.Signals

  signals do
    signal :vote_cast do
      argument :vote_id, :uuid, allow_nil?: false
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false
      argument :wallets, {:array, :string}, allow_nil?: false
    end
  end
end

defmodule Keyfleet.Rooms.Signals do
  @moduledoc """
  What rooms tell the rest of the site, as Ash signals. Each is emitted in the
  post's own save, so a listener with the default delivery commits or rolls
  back with it. Points offers it to Regent Points (`Keyfleet.Points.Award`).

    * `:message_posted`: a post went up in a room or a Key's thread, written as
      the author's Key `token_id` (`Keyfleet.Rooms.Changes.PostMessage`), with
      the `wallets` of the person who wrote it or whose agent did
      (`Keyfleet.Keys.person_wallets/1`). A repeat of a post hands back the
      post it already made, and emits nothing.
  """

  use Ash.Signals

  signals do
    signal :message_posted do
      argument :message_id, :uuid, allow_nil?: false
      argument :fleet_id, :string, allow_nil?: false
      argument :token_id, :integer, allow_nil?: false
      argument :wallets, {:array, :string}, allow_nil?: false
    end
  end
end

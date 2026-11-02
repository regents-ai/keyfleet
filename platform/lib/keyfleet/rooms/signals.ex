defmodule Keyfleet.Rooms.Signals do
  @moduledoc """
  What rooms tell the rest of the site, as Ash signals, each emitted in the
  transaction that saves the post. Regent Points hears them
  (`Keyfleet.Points.Award`).

    * `:post_written`: a member wrote a post in a room or a Key's thread, as
      the Key `as_key`, or as no Key in the People and agents room.
  """

  use Ash.Signals

  signals do
    signal :post_written do
      argument :message_id, :uuid, allow_nil?: false
      argument :as_key, :integer
    end
  end
end

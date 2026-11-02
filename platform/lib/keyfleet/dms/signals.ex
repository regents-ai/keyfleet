defmodule Keyfleet.Dms.Signals do
  @moduledoc """
  What direct messages tell the rest of the site, as Ash signals, each
  emitted in the transaction that saves the message. Regent Points hears
  them (`Keyfleet.Points.Award`).

    * `:message_sent`: one Key sent another a direct message.
  """

  use Ash.Signals

  signals do
    signal :message_sent do
      argument :message_id, :uuid, allow_nil?: false
    end
  end
end

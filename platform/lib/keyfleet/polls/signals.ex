defmodule Keyfleet.Polls.Signals do
  @moduledoc """
  What polls tell the rest of the site, as Ash signals, each emitted in the
  transaction that saves the vote. Regent Points hears them
  (`Keyfleet.Points.Award`).

    * `:vote_cast`: a Key voted in a poll; a repeat of its vote is not a vote.
  """

  use Ash.Signals

  signals do
    signal :vote_cast do
      argument :vote_id, :uuid, allow_nil?: false
    end
  end
end

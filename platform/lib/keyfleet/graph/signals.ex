defmodule Keyfleet.Graph.Signals do
  @moduledoc """
  What the workspace tells the rest of the site, as Ash signals, each emitted
  in the transaction that copies the event from the fleet's graph log.
  Regent Points hears them (`Keyfleet.Points.Award`).

    * `:event_copied`: an event of the fleet's log was copied at `seq`;
      `actor` names who made it, a member or the workspace itself.
  """

  use Ash.Signals

  signals do
    signal :event_copied do
      argument :fleet_id, :string, allow_nil?: false
      argument :seq, :integer, allow_nil?: false
      argument :actor, :string, allow_nil?: false
    end
  end
end

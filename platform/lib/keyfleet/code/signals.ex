defmodule Keyfleet.Code.Signals do
  @moduledoc """
  What the fleets' code tells the rest of the site, as Ash signals, each
  emitted in the transaction that records the push. Regent Points hears them
  (`Keyfleet.Points.Award`).

    * `:ref_pushed`: a Key's holder moved a branch or tag of a project.
  """

  use Ash.Signals

  signals do
    signal :ref_pushed do
      argument :push_id, :uuid, allow_nil?: false
    end
  end
end

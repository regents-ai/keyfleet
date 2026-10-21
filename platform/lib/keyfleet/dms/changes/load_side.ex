defmodule Keyfleet.Dms.Changes.LoadSide do
  @moduledoc """
  Answers a conversation change with the changing Key's (`token_id`) view of
  it loaded: its last message (`Keyfleet.Dms.Preparations.LastShown`) and its
  `auto_delete_days`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    side = Keyfleet.Dms.Preparations.LastShown.side(changeset.arguments.token_id)

    Ash.Changeset.after_action(changeset, fn _changeset, conversation ->
      Ash.load(conversation, side, authorize?: false)
    end)
  end
end

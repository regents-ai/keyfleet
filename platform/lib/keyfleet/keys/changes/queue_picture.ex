defmodule Keyfleet.Keys.Changes.QueuePicture do
  @moduledoc """
  Queues the drawing of a revealed key's card (`Keyfleet.Keys.DrawPicture`)
  in the reveal's own transaction. A reveal read again queues it again; the
  job leaves a reveal that already has its picture as it is.
  """
  use Ash.Resource.Change

  alias Keyfleet.Keys.DrawPicture

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, reveal ->
      Oban.insert!(DrawPicture.new(%{reveal_id: reveal.id}))
      {:ok, reveal}
    end)
  end
end

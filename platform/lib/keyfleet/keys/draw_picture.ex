defmodule Keyfleet.Keys.DrawPicture do
  @moduledoc """
  Draws a reveal's card, keeps it on IPFS through Lighthouse, then records its
  address against the reveal, so the key's metadata shows it. Queued in the
  same transaction as the reveal (`Keyfleet.Keys.Changes.QueuePicture`), so a
  reveal rolled back draws nothing.

  The same reveal always gives the same picture, and the same picture the same
  address, so running twice is safe; a reveal that already has its picture is
  left as it is, and one an operator has removed since is not drawn.
  """
  use Oban.Worker,
    queue: :key_art,
    max_attempts: 20,
    unique: [keys: [:reveal_id], period: :infinity, states: :incomplete]

  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.Keys.KeyArt
  alias Keyfleet.Lighthouse

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"reveal_id" => reveal_id}}) do
    case Keys.get_reveal_by_id!(reveal_id) do
      nil -> :ok
      reveal -> if Keys.get_picture!(reveal_id), do: :ok, else: draw(reveal)
    end
  end

  defp draw(%{id: id, fleet_id: fleet_id, token_id: token_id, seed: seed}) do
    %{trait_table_hash: hash} = Fleets.get_fleet!(fleet_id)
    filename = "#{Fleets.slot(fleet_id)}-#{token_id}.png"

    with {:ok, png} <- KeyArt.draw(seed, Fleets.card_top_line(fleet_id, token_id), hash),
         {:ok, cid} <- Lighthouse.add(png, filename, "image/png") do
      Keys.record_picture!(%{reveal_id: id, cid: cid}, actor: %Keyfleet.Actors.System{})
      :ok
    end
  end
end

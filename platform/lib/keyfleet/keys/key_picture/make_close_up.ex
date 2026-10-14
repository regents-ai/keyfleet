defmodule Keyfleet.Keys.KeyPicture.MakeCloseUp do
  @moduledoc """
  Makes a card picture's close-up before the row is written: reads the card
  back from where it is shown, cuts the close-up (`Keyfleet.Keys.KeyArt`) and
  keeps it on IPFS through Lighthouse, outside any transaction. A failed read,
  cut or upload fails the action, so the job retries with backoff.
  """

  use Ash.Resource.Change

  alias Ash.Error.Unknown.UnknownError
  alias Keyfleet.Fleets
  alias Keyfleet.Keys.KeyArt
  alias Keyfleet.Lighthouse

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      %{fleet_id: fleet_id, token_id: token_id, cid: cid} = changeset.data
      filename = "#{Fleets.slot(fleet_id)}-#{token_id}-close-up.webp"

      with {:ok, png} <- KeyArt.kept(cid),
           {:ok, webp} <- KeyArt.close_up(png),
           {:ok, close_up_cid} <- Lighthouse.add(webp, filename, "image/webp") do
        Ash.Changeset.force_change_attribute(changeset, :close_up_cid, close_up_cid)
      else
        # A fault of the site's or of a service it calls, never of anyone's
        # input, so it is kept with the site's saved errors.
        {:error, reason} ->
          Ash.Changeset.add_error(
            changeset,
            UnknownError.exception(error: "close-up not made: #{inspect(reason)}")
          )
      end
    end)
  end
end

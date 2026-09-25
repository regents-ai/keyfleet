defmodule Keyfleet.Rooms.Validations.IssuedKey do
  @moduledoc """
  The request names a key its fleet has issued, as far as the fleet's key
  history has been read. Keys are numbered from 1 in the order they are sold
  and never burned, so every number up to the highest one read is a key. A key
  sold moments ago is refused as unknown until its sale has been read.
  """
  use Ash.Resource.Validation

  alias Keyfleet.Rooms.Errors.KeyUnknownError

  @impl true
  def supports(_opts), do: [Ash.Changeset, Ash.Query]

  @impl true
  def validate(%input_type{} = input, _opts, _context) do
    fleet_id = input_type.get_argument(input, :fleet_id)
    token_id = input_type.get_argument(input, :token_id)
    {:ok, minted} = Keyfleet.Chain.minted(fleet_id)

    if token_id <= minted,
      do: :ok,
      else: {:error, KeyUnknownError.exception(fleet_id: fleet_id, token_id: token_id)}
  end
end

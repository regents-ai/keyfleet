defmodule Keyfleet.Rooms.Validations.IssuedKey do
  @moduledoc """
  The request names a key its fleet has issued, as far as the fleet's key
  history has been read. Keys are numbered from 1 in the order they are sold
  and never burned, so every number up to the highest one read is a key. A key
  sold moments ago is refused as unknown until its sale has been read.

  The key is the `token_id` argument, or the one `argument:` names, which may
  hold a list of keys; the first one not issued is refused.
  """
  use Ash.Resource.Validation

  alias Keyfleet.Rooms.Errors.KeyUnknownError

  @impl true
  def supports(_opts), do: [Ash.Changeset, Ash.Query]

  @impl true
  def validate(%input_type{} = input, opts, _context) do
    fleet_id = input_type.get_argument(input, :fleet_id)
    token_ids = input_type.get_argument(input, Keyword.get(opts, :argument, :token_id))
    {:ok, minted} = Keyfleet.Chain.minted(fleet_id)

    case Enum.find(List.wrap(token_ids), &(&1 > minted)) do
      nil -> :ok
      token_id -> {:error, KeyUnknownError.exception(fleet_id: fleet_id, token_id: token_id)}
    end
  end
end

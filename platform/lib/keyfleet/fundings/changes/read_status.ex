defmodule Keyfleet.Fundings.Changes.ReadStatus do
  @moduledoc """
  Reads how a funding's deposit stands from the service, before the update's
  transaction opens, and records its state and transactions. A funding that
  has arrived, been refunded or failed is not asked again.
  """
  use Ash.Resource.Change

  alias Keyfleet.Fundings
  alias Keyfleet.Fundings.Funding

  @impl true
  def change(%{data: %{state: state}} = changeset, _opts, _context) do
    if state in Funding.final_states() do
      changeset
    else
      Ash.Changeset.before_transaction(changeset, &read/1)
    end
  end

  defp read(changeset) do
    case Fundings.status(changeset.data.deposit_address) do
      {:ok, status} ->
        Ash.Changeset.force_change_attributes(changeset, %{
          state: status.state,
          origin_tx: status.origin_tx || changeset.data.origin_tx,
          destination_tx: status.destination_tx || changeset.data.destination_tx,
          finished_at: if(status.state in Funding.final_states(), do: DateTime.utc_now())
        })

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end

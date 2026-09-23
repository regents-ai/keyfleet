defmodule KeyFleet.Proposals.Changes.RecordOnce do
  @moduledoc """
  Makes a proposal, vote or execution record from one chain event exactly
  once.

  The event is held until commit. Read again, it keeps the number its record
  already has and must match that record in every field; a match is accepted
  and changes nothing, a mismatch is refused as invalid, which the reader takes
  to mean the chain no longer agrees with the record. A new record takes the
  fleet's next number in the same transaction.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&number/1)
    |> Ash.Changeset.after_action(&same_as_recorded/2)
  end

  defp number(changeset) do
    transaction_hash = Ash.Changeset.get_attribute(changeset, :transaction_hash)
    log_index = Ash.Changeset.get_attribute(changeset, :log_index)

    KeyFleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Jason.encode!(["proposal_record", transaction_hash, log_index])
    ])

    seq =
      changeset.resource
      |> Ash.Query.filter(transaction_hash == ^transaction_hash and log_index == ^log_index)
      |> Ash.Query.select([:record_seq])
      |> Ash.read_one!()
      |> case do
        nil ->
          KeyFleet.Chain.take_proposal_seq!(Ash.Changeset.get_attribute(changeset, :fleet_id))

        recorded ->
          recorded.record_seq
      end

    Ash.Changeset.force_change_attribute(changeset, :record_seq, seq)
  end

  defp same_as_recorded(changeset, row) do
    fields = Map.keys(changeset.attributes) -- Ash.Resource.Info.primary_key(changeset.resource)

    if Enum.all?(fields, &(Map.fetch!(row, &1) == Map.fetch!(changeset.attributes, &1))) do
      {:ok, row}
    else
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(
         fields: fields,
         message: "conflicts with the record already made from this chain event"
       )}
    end
  end
end

defmodule KeyFleet.Chain.Changes.RecordOnce do
  @moduledoc """
  Makes a record from one chain event exactly once, for an action that
  upserts on the event's identity and returns the stored row when it skips.

  The event, named by the attributes in `:identity`, is held until commit.
  Read again, it must match the record already made in every field named in
  `:fields`, or in every field the changeset sets; a match is accepted and
  changes nothing, a mismatch is refused as invalid, which the reader takes
  to mean the chain no longer agrees with the record. With `:block`, the
  attribute holding the block the record was made from, the refusal carries
  that block as `recorded_block`.

  With `:number`, `:proposal_seq` or `:reveal_seq`, a record read again keeps
  the number it has and a new one takes the fleet's next number in the same
  transaction, from `KeyFleet.Chain`.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&hold_and_number(&1, opts))
    |> Ash.Changeset.after_action(&same_as_recorded(&1, &2, opts))
  end

  defp hold_and_number(changeset, opts) do
    identity =
      Enum.map(Keyword.fetch!(opts, :identity), &{&1, Ash.Changeset.get_attribute(changeset, &1)})

    KeyFleet.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Jason.encode!([inspect(changeset.resource) | Keyword.values(identity)])
    ])

    case opts[:number] do
      nil ->
        changeset

      sequence ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :record_seq,
          number(changeset, identity, sequence)
        )
    end
  end

  defp number(changeset, identity, sequence) do
    changeset.resource
    |> Ash.Query.do_filter(identity)
    |> Ash.Query.select([:record_seq])
    |> Ash.read_one!()
    |> case do
      nil -> take(sequence, Ash.Changeset.get_attribute(changeset, :fleet_id))
      recorded -> recorded.record_seq
    end
  end

  defp take(:proposal_seq, fleet_id), do: KeyFleet.Chain.take_proposal_seq!(fleet_id)
  defp take(:reveal_seq, fleet_id), do: KeyFleet.Chain.take_reveal_seq!(fleet_id)

  defp same_as_recorded(changeset, row, opts) do
    fields =
      opts[:fields] ||
        Map.keys(changeset.attributes) -- Ash.Resource.Info.primary_key(changeset.resource)

    if Enum.all?(fields, &same?(Map.fetch!(row, &1), Map.fetch!(changeset.attributes, &1))) do
      {:ok, row}
    else
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(
         fields: fields,
         message: "conflicts with the record already made from the chain",
         vars: recorded_block(row, opts[:block])
       )}
    end
  end

  defp recorded_block(_row, nil), do: []
  defp recorded_block(row, block), do: [recorded_block: Map.fetch!(row, block)]

  defp same?(%Decimal{} = recorded, %Decimal{} = read), do: Decimal.equal?(recorded, read)
  defp same?(recorded, read), do: recorded == read
end

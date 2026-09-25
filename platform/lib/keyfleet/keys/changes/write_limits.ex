defmodule Keyfleet.Keys.Changes.WriteLimits do
  @moduledoc """
  Writes the owner's four limits onto the pairing, stamped with the database's
  own clock as it writes them.

  The limits are the owner's word to their agent; Keyfleet stores and shows
  them and enforces nothing more because of them.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @limits [
    money: :limits_money,
    information: :limits_information,
    outside: :limits_outside,
    check_first: :limits_check_first
  ]

  @impl true
  def change(changeset, _opts, _context) do
    written =
      Map.new(@limits, fn {argument, attribute} ->
        {attribute, Ash.Changeset.get_argument(changeset, argument)}
      end)

    changeset
    |> Ash.Changeset.force_change_attributes(written)
    |> Ash.Changeset.atomic_update(
      :limits_written_at,
      Ash.Expr.expr(type(fragment("(clock_timestamp() AT TIME ZONE 'utc')"), :utc_datetime_usec))
    )
  end
end

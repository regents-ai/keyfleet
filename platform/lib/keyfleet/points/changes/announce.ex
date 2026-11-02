defmodule Keyfleet.Points.Changes.Announce do
  @moduledoc """
  Emits `signal` from `signals` once the action has saved a new record, in
  its transaction, with `fields` taken from the record as `emit` takes them.
  A record an upsert found already there emits nothing: reading the chain
  again, or a repeated send, tells nobody twice. The action declares the
  signal with `emit ..., dynamic?: true`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, &announce(&1, &2, opts))
  end

  defp announce(changeset, record, opts) do
    if Ash.Resource.get_metadata(record, :upsert_skipped) do
      {:ok, record}
    else
      payload =
        Map.new(opts[:fields], fn {field, attribute} -> {field, Map.get(record, attribute)} end)

      with :ok <- Ash.Signals.emit(changeset, opts[:signals], opts[:signal], payload),
           do: {:ok, record}
    end
  end
end

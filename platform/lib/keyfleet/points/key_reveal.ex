defmodule Keyfleet.Points.KeyReveal do
  @moduledoc """
  Regent Points' check of a person's first revealed Key
  (`keyfleet.first_reveal`): it reads the saved reveal and answers with the
  person whose wallets held the Key when the chain revealed it.
  """

  alias Keyfleet.Keys.KeyReveal
  alias Keyfleet.Points.Holder
  alias Keyfleet.Repo

  def verify(%{"source_event_key" => id}) do
    # No person is asking: Points' check reads the committed row as it was saved,
    # straight from the table, since the record offers no read without one.
    case Repo.get(KeyReveal, id) do
      nil ->
        {:error, :key_reveal_not_found}

      reveal ->
        place = {reveal.block_number, reveal.log_index}

        with {:ok, holder} <-
               Holder.before(reveal.fleet_id, reveal.token_id, place, reveal.observed_at) do
          evidence = %{"transaction_hash" => reveal.transaction_hash}
          {:ok, Holder.facts("key_reveal", id, holder, :human, reveal.observed_at, evidence)}
        end
    end
  end
end

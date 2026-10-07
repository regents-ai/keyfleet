defmodule Mix.Tasks.Keyfleet.NewDeck do
  @shortdoc "Makes a fleet's card deck and prints its hash"

  @moduledoc """
  Makes a card deck for a fleet that is not created yet, as `Keyfleet.Decks`
  describes, writes it to `priv/decks/<hash>.json` and prints the hash. The
  hash and the number of cards go into the fleet's creation, after which the
  deck can never change; until then a new deck can replace it.

      mix keyfleet.new_deck "CLASSIC #1" 0xa0a1e42883778c77dcefbf4e7ef64267271158935a622f9582697ff14a4864fe 1000

  The trait table must be one in `priv/trait_tables`.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run([fleet, table_hash, size]) do
    Keyfleet.Traits.table!(table_hash)
    {deck_hash, bytes} = Keyfleet.Decks.new(fleet, table_hash, String.to_integer(size))
    File.mkdir_p!("priv/decks")
    File.write!(Path.join("priv/decks", deck_hash <> ".json"), bytes, [:exclusive])
    Mix.shell().info(deck_hash)
  end

  def run(_args),
    do: Mix.raise(~s(Usage: mix keyfleet.new_deck "<fleet card>" <trait table hash> <cards>))
end

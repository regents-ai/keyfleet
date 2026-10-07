defmodule KeyfleetWeb.DeckShowcaseLive do
  @moduledoc """
  Local view of every card deck in `priv/decks`, each a grid of its cards in
  deck order, drawn in the browser as they scroll into view. A card opens large
  with its eight traits. The decks are secret, so this page exists only in the
  local workshop.
  """
  use KeyfleetWeb, :live_view

  alias Keyfleet.Decks

  def mount(_params, _session, socket) do
    decks =
      Decks.hashes()
      |> Enum.map(&Map.put(Decks.deck!(&1), :hash, &1))
      |> Enum.sort_by(& &1.fleet)

    {:ok,
     socket
     |> assign(KeyfleetWeb.PublicDocuments.page("/showcase/decks"))
     |> assign(decks: decks), layout: false}
  end

  def render(assigns) do
    ~H"""
    <link rel="stylesheet" href="/showcase/style.css" />
    <main class="sc deck-viewer">
      <header class="sc-header">
        <a class="sc-wordmark" href="/showcase">Ash <span>Workshop</span></a>
        <span class="sc-local">Local only · secret decks</span>
      </header>

      <div id="deck-viewer" class="deck-viewer__content" phx-hook="DeckViewer" phx-update="ignore">
        <section class="deck-viewer__intro">
          <h1>Card decks</h1>
          <p>
            Every card in deck order. Click a card to see it large; the arrow keys move between cards.
          </p>
          <nav class="deck-viewer__jump" aria-label="Decks">
            <a :for={deck <- @decks} class="rg-button rg-button--quiet" href={"#deck-#{deck.hash}"}>
              {deck.fleet}
            </a>
          </nav>
          <p class="deck-viewer__no-gpu" data-deck-no-gpu hidden>
            This browser can't draw the cards. Open the page in Chrome.
          </p>
        </section>

        <section
          :for={deck <- @decks}
          id={"deck-#{deck.hash}"}
          class="deck"
          data-deck
          data-fleet={deck.fleet}
          data-cards={Jason.encode!(Tuple.to_list(deck.cards))}
        >
          <h2>{deck.fleet}</h2>
          <p class="deck__hash">{deck.hash}</p>
          <p class="deck__tally" data-deck-tally></p>
          <div class="deck__grid" data-deck-grid></div>
        </section>

        <dialog class="deck-zoom" data-deck-zoom aria-labelledby="deck-zoom-title">
          <div class="deck-zoom__stage"><canvas data-deck-zoom-canvas></canvas></div>
          <div class="deck-zoom__side">
            <h2 id="deck-zoom-title" data-deck-zoom-title></h2>
            <ul class="deck-zoom__traits" data-deck-zoom-traits></ul>
            <div class="deck-zoom__moves">
              <button type="button" class="rg-button rg-button--quiet" data-deck-zoom-move="-1">
                Previous
              </button>
              <button type="button" class="rg-button rg-button--quiet" data-deck-zoom-move="1">
                Next
              </button>
              <button type="button" class="rg-button" data-deck-zoom-close>Close</button>
            </div>
          </div>
        </dialog>
      </div>
    </main>
    """
  end
end

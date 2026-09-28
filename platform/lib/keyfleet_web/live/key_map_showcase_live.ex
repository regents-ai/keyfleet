defmodule KeyfleetWeb.KeyMapShowcaseLive do
  @moduledoc """
  Local reference for the key map, with made-up sales, owners and agents, so
  the map can be tried at its largest size without a chain or a database.
  Classic and Accelerant are sold but for their last key. Fibonacci is selling
  level 19 a few rows in: the map draws all of it, with levels 1 to 18 sold
  out, 19 on sale and 20 next.
  """
  use KeyfleetWeb, :live_view

  alias KeyfleetWeb.KeyMap

  @fleets [
    %{layout: "fibonacci", name: "Fibonacci", max_supply: 46_365, minted: 17_768},
    %{layout: "classic", name: "Classic", max_supply: 1_024, minted: 1_023},
    %{layout: "accelerant", name: "Accelerant", max_supply: 2_000, minted: 1_999}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(KeyfleetWeb.PublicDocuments.page("/showcase/key-map"))
     |> assign(fleets: @fleets, fleet: hd(@fleets), selected: nil), layout: false}
  end

  def render(assigns) do
    ~H"""
    <link rel="stylesheet" href="/showcase/style.css" />
    <main class="sc key-map-reference">
      <header class="sc-header">
        <a class="sc-wordmark" href="/showcase">Ash <span>Workshop</span></a>
        <span class="sc-local">Local only · made-up keys</span>
      </header>

      <div class="key-map-reference__content">
        <section class="key-map-reference__intro">
          <p class="sc-eyebrow">Working reference</p>
          <h1>Key map</h1>
          <p id="key-map-help">
            Drag, scroll or use the arrow keys to move around. Click a key, or press Enter, to choose it. Home returns to the next key on sale.
          </p>
          <div class="key-map-reference__fleets" role="group" aria-label="Fleet">
            <button
              :for={fleet <- @fleets}
              type="button"
              class="rg-button rg-button--quiet"
              phx-click="show_fleet"
              value={fleet.layout}
              aria-pressed={to_string(fleet.layout == @fleet.layout)}
            >
              {fleet.name} · {group(fleet.max_supply)} keys
            </button>
          </div>
        </section>

        <div
          id={"key-map-#{@fleet.layout}"}
          class="key-map"
          phx-hook="KeyMap"
          phx-update="ignore"
          data-layout={@fleet.layout}
          tabindex="0"
          role="application"
          aria-roledescription="key map"
          aria-label="Key map"
          aria-describedby="key-map-help"
        >
          <p class="key-map__still">Loading the map…</p>
        </div>

        <p id="key-map-selected" role="status">
          {if @selected, do: "Key #{group(@selected)} chosen.", else: "No key chosen yet."}
        </p>

        <section class="key-map-reference__notes">
          <h2>What the marks mean</h2>
          <ul>
            <li>An orange rim is a key you hold.</li>
            <li>A blue dot is a key with an agent.</li>
            <li>The outlined key marked Next is the one on sale.</li>
            <li>The filled key is the one you chose.</li>
            <li>Faint keys are not sold yet.</li>
            <li>
              Each level has its own shade and an outline: solid once it has sold out, dashed
              until it goes on sale, and a thick moving dash round the level on sale now.
            </li>
          </ul>
          <p>
            The map repeats in every direction, so a key can appear more than once on screen. Every copy is the same key.
          </p>
        </section>
      </div>
    </main>
    """
  end

  def handle_event("show_fleet", %{"value" => layout}, socket) do
    case Enum.find(@fleets, &(&1.layout == layout)) do
      nil -> {:noreply, socket}
      fleet -> {:noreply, assign(socket, fleet: fleet, selected: nil)}
    end
  end

  def handle_event("keymap_ready", _params, socket) do
    %{max_supply: max_supply, minted: minted} = socket.assigns.fleet

    {:reply,
     %{
       minted: minted,
       max_supply: max_supply,
       mine: KeyMap.bitset(max_supply, Enum.filter(1..minted, &(rem(&1, 97) == 13))),
       agent: KeyMap.bitset(max_supply, Enum.filter(1..minted, &(rem(&1, 7) == 3)))
     }, socket}
  end

  # Every drawn key can be chosen: the sold ones and the next one on sale.
  def handle_event("select_key", %{"token_id" => token_id}, socket) when is_integer(token_id) do
    if token_id in 1..(socket.assigns.fleet.minted + 1)//1,
      do: {:noreply, assign(socket, :selected, token_id)},
      else: {:noreply, socket}
  end

  def handle_event("select_key", _params, socket), do: {:noreply, socket}

  defp group(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end

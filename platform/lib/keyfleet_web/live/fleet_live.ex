defmodule KeyFleetWeb.FleetLive do
  @moduledoc """
  One fleet's page: where it lives, how far it has sold, what the next key
  costs and a way to buy it, its rooms, workspace and proposals, a map of its
  keys, and every key it has issued with who holds and runs it.

  Everything here is public and read from what the fleet's contract has
  recorded. Keys are listed a hundred at a time.
  """

  use KeyFleetWeb, :html

  alias KeyFleetWeb.RoomsLive

  attr :fleet, :map, required: true
  attr :keys, :any, required: true, doc: "the fleet's issued keys, lowest number first"

  def page(assigns) do
    ~H"""
    <article id="fleet-page" class="fleet-page">
      <header class="fleet-heading">
        <p class="fleet-kicker">Fleet</p>
        <h1 tabindex="-1">{@fleet.name || "KeyFleet"}</h1>
        <p :if={@fleet.name} class="fleet-lede">How this fleet is selling, and who holds its keys.</p>
      </header>

      <section :if={is_nil(@fleet.name)} class="fleet-panel">
        <h2>This fleet doesn’t exist.</h2>
      </section>

      <div :if={@fleet.name} class="fleet-grid">
        <section class="fleet-panel" aria-labelledby="fleet-contract-title">
          <h2 id="fleet-contract-title">Contract</h2>
          <p :if={@fleet.contract_address} class="fleet-wallet">
            <code>{@fleet.contract_address}</code>
          </p>
          <p :if={is_nil(@fleet.contract_address)}>Not yet deployed</p>
        </section>

        <section
          :if={@fleet.deployed?}
          class="fleet-panel"
          aria-labelledby="fleet-progress-title"
        >
          <h2 id="fleet-progress-title">Progress</h2>
          <p :if={not @fleet.current?} class="fleet-detail">Sales figures are catching up.</p>
          <dl :if={@fleet.current?} class="fleet-facts">
            <div>
              <dt>Keys issued</dt>
              <dd>
                {grouped(@fleet.progress.total_minted)} of {grouped(@fleet.progress.max_supply)}
              </dd>
            </div>
            <div :if={@fleet.progress.completed_levels}>
              <dt>Levels complete</dt>
              <dd>{@fleet.progress.completed_levels} of {@fleet.progress.levels}</dd>
            </div>
            <div :if={@fleet.progress.next_price}>
              <dt>Next key</dt>
              <dd>
                Key {@fleet.progress.next_token_id}, {usdc(@fleet.progress.next_price)}
              </dd>
            </div>
          </dl>
          <p :if={@fleet.current? and @fleet.progress.next_price} class="fleet-detail">
            Paid in USDC on Base.
          </p>
          <p :if={@fleet.current? and is_nil(@fleet.progress.next_price)} class="fleet-detail">
            Every key has been issued.
          </p>
        </section>

        <.buy_key
          :if={@fleet.buy}
          buy={@fleet.buy}
          current?={@fleet.current?}
          signed_in={@fleet.signed_in}
        />

        <nav class="fleet-panel" aria-labelledby="fleet-rooms-title">
          <h2 id="fleet-rooms-title">Rooms</h2>
          <ul class="fleet-room-list">
            <li :for={room <- @fleet.rooms}>
              <.link navigate={"/app/fleets/#{@fleet.fleet_id}/rooms/#{room.slug}"}>
                {RoomsLive.room_label(room)}
              </.link>
            </li>
          </ul>
        </nav>

        <section class="fleet-panel" aria-labelledby="fleet-workspace-title">
          <h2 id="fleet-workspace-title">Workspace</h2>
          <p class="fleet-detail">The goals, tasks, findings and notes this fleet is working on.</p>
          <.link id="fleet-workspace-link" navigate={"/app/fleets/#{@fleet.fleet_id}/workspace"}>
            Open the workspace
          </.link>
        </section>

        <section class="fleet-panel" aria-labelledby="fleet-proposals-title">
          <h2 id="fleet-proposals-title">Proposals</h2>
          <p class="fleet-detail">
            What this fleet’s key holders have put to a vote, and its budget.
          </p>
          <.link id="fleet-proposals-link" navigate={"/app/fleets/#{@fleet.fleet_id}/proposals"}>
            See the proposals
          </.link>
        </section>

        <.key_map :if={@fleet.deployed?} fleet={@fleet} />

        <section class="fleet-panel fleet-keys" aria-labelledby="fleet-keys-title">
          <h2 id="fleet-keys-title">Keys</h2>
          <p :if={@fleet.no_keys?}>No keys have been issued yet.</p>

          <ol id="fleet-key-list" class="fleet-key-list" phx-update="stream">
            <li :for={{dom_id, key} <- @keys} id={dom_id}>
              <.link navigate={"/app/keys/#{@fleet.fleet_id}/#{key.token_id}"} class="fleet-name">
                Key {key.token_id}
              </.link>
              <span>Held by {short_wallet(key.owner_wallet)}</span>
              <span>{key.operator_name || "No operator"}</span>
            </li>
          </ol>

          <nav
            :if={@fleet.pages.previous || @fleet.pages.next}
            class="fleet-pages"
            aria-label="More keys"
          >
            <.link :if={@fleet.pages.previous} id="fleet-keys-previous" patch={@fleet.pages.previous}>
              Previous
            </.link>
            <.link :if={@fleet.pages.next} id="fleet-keys-next" patch={@fleet.pages.next}>
              Next
            </.link>
          </nav>
        </section>
      </div>
    </article>
    """
  end

  attr :fleet, :map, required: true

  # The controls only move the map, so they never wait on the page. The map
  # draws itself once its script loads; until then it says so, and the list
  # below still has every key.
  defp key_map(assigns) do
    assigns = assign(assigns, :map, "#key-map-#{assigns.fleet.fleet_id}")

    ~H"""
    <section id="fleet-map" class="fleet-panel fleet-map" aria-labelledby="fleet-map-title">
      <h2 id="fleet-map-title">Key map</h2>

      <div class="fleet-map-controls">
        <Regent.Primitives.button
          :if={@fleet.progress.next_token_id}
          id="key-map-next"
          variant="secondary"
          phx-click={JS.dispatch("keymap:next", to: @map)}
        >
          Next key
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@fleet.signed_in?}
          id="key-map-mine"
          variant="secondary"
          phx-click={JS.dispatch("keymap:mine", to: @map)}
        >
          Your keys
        </Regent.Primitives.button>
        <form
          :if={@fleet.levels != []}
          id="key-map-level"
          class="fleet-map-level"
          phx-submit={JS.dispatch("keymap:level", to: @map)}
        >
          <label for="key-map-level-choice">Go to level</label>
          <select id="key-map-level-choice" name="level">
            <option :for={level <- @fleet.levels} value={level}>Level {level}</option>
          </select>
          <Regent.Primitives.button type="submit" variant="secondary">Go</Regent.Primitives.button>
        </form>
      </div>

      <div
        id={"key-map-#{@fleet.fleet_id}"}
        class="key-map"
        phx-hook="KeyMap"
        phx-update="ignore"
        data-layout={@fleet.layout}
        data-selected={@fleet.chosen_key}
        tabindex="0"
        role="application"
        aria-roledescription="key map"
        aria-label="Key map"
        aria-describedby="key-map-help"
      >
        <p class="key-map__still">Loading the map…</p>
      </div>

      <p id="key-map-help" class="fleet-detail">
        Drag to look around. Arrow keys move between keys, and Enter chooses one. Every key is
        also listed below.
      </p>
      <p id="key-map-selected" role="status">
        {if @fleet.chosen_key,
          do: "Key #{grouped(@fleet.chosen_key)} chosen.",
          else: "No key chosen yet."}
      </p>
    </section>
    """
  end

  attr :buy, :map, required: true
  attr :current?, :boolean, required: true
  attr :signed_in, :list, required: true, doc: "the signed-in person's wallets, primary first"

  # Every press of Buy goes to the wallet: the button is never disabled, and
  # nothing here decides on the buyer's behalf whether a purchase would succeed.
  # A fleet that sells out while the page is open keeps the buyer's messages
  # about the purchases they made. When the connected wallet isn't the
  # signed-in person's, a note says so, and the press still goes to the
  # connected wallet.
  defp buy_key(assigns) do
    ~H"""
    <section id="buy-key" class="fleet-panel" aria-labelledby="buy-key-title">
      <h2 id="buy-key-title">Buy a key</h2>

      <div
        id="buy-key-order"
        phx-hook="BuyKey"
        data-chain-id={@buy.chain_id}
        data-fleet={@buy.contract_address}
        data-usdc={@buy.usdc_address}
        data-price={@buy.price}
        data-price-label={@buy.price && usdc(@buy.price)}
        data-referrer={@buy.referrer}
        data-deadline-seconds={@buy.deadline_seconds}
        data-signed-in={Jason.encode!(@signed_in)}
      >
        <p :if={is_nil(@buy.price)} id="buy-key-sold-out">
          All {grouped(@buy.max_supply)} keys in this fleet have been sold.
        </p>

        <div :if={@buy.price} id="buy-key-offer" class="fleet-buy-offer">
          <dl class="fleet-facts">
            <div>
              <dt>Key</dt>
              <dd id="buy-key-number">{grouped(@buy.token_id)}</dd>
            </div>
            <div>
              <dt>Price</dt>
              <dd id="buy-key-price">{usdc(@buy.price)}</dd>
            </div>
            <div :if={@buy.level}>
              <dt>Level</dt>
              <dd id="buy-key-level">{@buy.level}</dd>
            </div>
          </dl>

          <p :if={@buy.level} class="fleet-detail">
            One wallet may hold {keys(@buy.holding_limit)} of level {@buy.level}.
          </p>
          <p :if={not @current?} id="buy-key-price-may-move" class="fleet-detail">
            Sales are still being counted, so this price may already have gone up. If it has,
            the purchase is refused and no USDC is taken, though your wallet still pays the
            Base network fee for trying.
          </p>
          <p :if={@buy.referrer} id="buy-key-referrer" class="fleet-detail">
            Referred by {short_wallet(@buy.referrer)}
          </p>
          <p :if={@buy.referral_refused?} id="buy-key-referral-refused" class="fleet-detail">
            The referral in this link isn’t a wallet address, so this purchase has no referrer.
          </p>

          <Regent.Primitives.button id="buy-key-button" type="button" data-buy-key>
            Buy key {grouped(@buy.token_id)}
          </Regent.Primitives.button>
          <p class="fleet-detail">
            Paid in USDC on Base from your connected wallet. If your wallet hasn’t already allowed
            this much USDC, it first asks you to approve exactly {usdc(@buy.price)}.
          </p>
        </div>

        <%!-- Nothing between the tags, so the note stays hidden until it has something to say. --%>
        <p
          id="buy-key-wallet-note"
          class="fleet-detail fleet-wallet-note"
          phx-update="ignore"
          data-wallet-note
          phx-no-format
        ></p>
        <ol id="buy-key-status" class="fleet-buy-status" phx-update="ignore" aria-live="polite"></ol>
      </div>
    </section>
    """
  end

  defp keys(1), do: "1 key"
  defp keys(count), do: "#{grouped(count)} keys"

  defp short_wallet(wallet),
    do: String.slice(wallet, 0, 6) <> "…" <> String.slice(wallet, -4, 4)

  # Atomic USDC shown exactly, since it is what the purchase pays.
  defp usdc(atoms) do
    fraction =
      atoms
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")

    case fraction do
      "" -> "#{grouped(div(atoms, 1_000_000))} USDC"
      fraction -> "#{grouped(div(atoms, 1_000_000))}.#{fraction} USDC"
    end
  end

  defp grouped(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end

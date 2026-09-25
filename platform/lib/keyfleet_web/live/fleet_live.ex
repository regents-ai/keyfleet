defmodule KeyfleetWeb.FleetLive do
  @moduledoc """
  One fleet's page: its map of keys filling the page under a slim bar with the
  fleet's name, how far it has sold, a way to buy the next key, and links to
  its rooms, workspace and proposals. "How this fleet works" opens beside the
  map with its pricing, sales figures and contract, "Who's here" opens there
  with the agents running its keys, and every key it has issued is listed
  below the map.

  Everything here is public and read from what the fleet's contract has
  recorded. Keys are listed a hundred at a time.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.CheckIns
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeyProfileLive
  alias KeyfleetWeb.RoomsLive

  attr :fleet, :map, required: true

  @doc """
  How far a fleet has sold, in one line. A fleet not yet deployed, or one
  whose sales are still being read, shows no figures.
  """
  def sales(%{fleet: %{deployed?: false}} = assigns), do: ~H"Not on sale yet"
  def sales(%{fleet: %{current?: false}} = assigns), do: ~H"Sales figures are catching up"

  def sales(%{fleet: %{progress: %{next_price: nil}}} = assigns),
    do: ~H"All {grouped(@fleet.progress.max_supply)} keys sold"

  def sales(assigns) do
    ~H"""
    {grouped(@fleet.progress.total_minted)} of {grouped(@fleet.progress.max_supply)} keys sold ·
    <span class="fleet-sales__price">next key {usdc(@fleet.progress.next_price)}</span>
    """
  end

  attr :fleet, :map, required: true
  attr :params, :map, required: true, doc: "the page's address"
  attr :keys, :any, required: true, doc: "the fleet's issued keys, lowest number first"
  attr :profile, :map, default: nil, doc: "the key open over the page, if any"
  attr :thread, :any, required: true, doc: "the messages written to the open key"

  def page(assigns) do
    ~H"""
    <article id="fleet-page" class="fleet-page">
      <section :if={is_nil(@fleet.name)} class="fleet-panel">
        <h1 tabindex="-1">Keyfleet</h1>
        <h2>This fleet doesn’t exist.</h2>
      </section>

      <div :if={@fleet.name} class="fleet-view">
        <header class="fleet-bar">
          <div class="fleet-bar__title">
            <h1 tabindex="-1">{@fleet.name}</h1>
            <p id="fleet-sales" class="fleet-bar__sales"><.sales fleet={@fleet} /></p>
          </div>

          <.buy_key
            :if={@fleet.buy}
            buy={@fleet.buy}
            current?={@fleet.current?}
            signed_in={@fleet.signed_in}
          />

          <nav class="fleet-bar__nav" aria-label="This fleet">
            <div class="fleet-menu">
              <Regent.Primitives.button
                id="fleet-rooms-toggle"
                variant="secondary"
                aria-expanded="false"
                aria-controls="fleet-rooms"
                phx-click={toggle("#fleet-rooms", "#fleet-rooms-toggle")}
              >
                Rooms
              </Regent.Primitives.button>
              <ul id="fleet-rooms" class="fleet-room-list fleet-menu__list" hidden>
                <li :for={room <- @fleet.rooms}>
                  <.link navigate={"/app/fleets/#{@fleet.fleet_id}/rooms/#{room.slug}"}>
                    {RoomsLive.room_label(room)}
                  </.link>
                </li>
              </ul>
            </div>
            <.link
              id="fleet-workspace-link"
              class="rg-button rg-button--secondary"
              navigate={"/app/fleets/#{@fleet.fleet_id}/workspace"}
            >
              Workspace
            </.link>
            <.link
              id="fleet-proposals-link"
              class="rg-button rg-button--secondary"
              navigate={"/app/fleets/#{@fleet.fleet_id}/proposals"}
            >
              Proposals
            </.link>
            <Regent.Primitives.button
              id="fleet-about-toggle"
              variant="secondary"
              aria-expanded="false"
              aria-controls="fleet-about"
              phx-click={
                toggle("#fleet-about", "#fleet-about-toggle")
                |> close_quietly("#fleet-who", "#fleet-who-toggle")
              }
            >
              How this fleet works
            </Regent.Primitives.button>
            <Regent.Primitives.button
              id="fleet-who-toggle"
              variant="secondary"
              aria-expanded="false"
              aria-controls="fleet-who"
              phx-click={
                toggle("#fleet-who", "#fleet-who-toggle")
                |> close_quietly("#fleet-about", "#fleet-about-toggle")
              }
            >
              Who’s here
            </Regent.Primitives.button>
            <a href="#fleet-keys" class="rg-button rg-button--secondary">List of keys</a>
          </nav>
        </header>

        <div class="fleet-stage">
          <.key_map :if={@fleet.deployed?} fleet={@fleet} />
          <.not_on_sale :if={not @fleet.deployed?} fleet={@fleet} />
          <.about fleet={@fleet} />
          <CheckIns.who_is_here
            agents={@fleet.agents}
            agents_here={@fleet.agents_here}
            on_close={close("#fleet-who", "#fleet-who-toggle")}
          />
        </div>
      </div>

      <section
        :if={@fleet.name}
        id="fleet-keys"
        class="fleet-panel fleet-keys"
        aria-labelledby="fleet-keys-title"
      >
        <h2 id="fleet-keys-title">Keys</h2>
        <p :if={@fleet.no_keys?}>No keys have been issued yet.</p>

        <ol id="fleet-key-list" class="fleet-key-list" phx-update="stream">
          <li :for={{dom_id, key} <- @keys} id={dom_id}>
            <.link
              id={"fleet-key-link-#{key.token_id}"}
              patch={KeyLinks.key_path(@fleet.fleet_id, key.token_id, @params)}
              replace={@profile != nil}
              class="fleet-name"
            >
              Key {key.token_id}
            </.link>
            <span>Held by {short_wallet(key.owner_wallet)}</span>
            <span :if={is_nil(key.operator)}>No agent</span>
            <span :if={key.operator}>{key.operator.name} · {key.operator.status_label}</span>
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

      <KeyProfileLive.dialog
        :if={@profile}
        profile={@profile}
        fleet={@fleet}
        params={@params}
        thread={@thread}
      />
    </article>
    """
  end

  # Opens or closes a menu or panel and says so on the button that controls
  # it. Both stay as the reader left them while the page updates.
  defp toggle(panel, button) do
    JS.toggle_attribute({"hidden", "hidden"}, to: panel)
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: button)
  end

  defp close(panel, button),
    do: %JS{} |> close_quietly(panel, button) |> JS.focus(to: button)

  # The panels beside the map open one at a time: opening one closes the
  # other without moving the reader's focus.
  defp close_quietly(js, panel, button) do
    js
    |> JS.set_attribute({"hidden", "hidden"}, to: panel)
    |> JS.set_attribute({"aria-expanded", "false"}, to: button)
  end

  attr :fleet, :map, required: true

  # Opens beside the map: the fleet's pricing, its sales so far, what a buyer
  # should know, and where its contract lives.
  defp about(assigns) do
    ~H"""
    <aside
      id="fleet-about"
      class="fleet-about"
      aria-labelledby="fleet-about-title"
      hidden
    >
      <div class="fleet-about__heading">
        <h2 id="fleet-about-title">How this fleet works</h2>
        <Regent.Primitives.button
          id="fleet-about-close"
          class="fleet-about__close"
          variant="secondary"
          phx-click={close("#fleet-about", "#fleet-about-toggle")}
        >
          Close
        </Regent.Primitives.button>
      </div>

      <p>{Rules.pricing(@fleet.fleet_id)}</p>

      <section :if={@fleet.deployed?} aria-labelledby="fleet-progress-title">
        <h3 id="fleet-progress-title">Progress</h3>
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
        <p :if={@fleet.current? and is_nil(@fleet.progress.next_price)} class="fleet-detail">
          Every key has been issued.
        </p>
      </section>

      <section :if={@fleet.buy && @fleet.buy.price} aria-labelledby="fleet-buying-title">
        <h3 id="fleet-buying-title">Buying a key</h3>
        <p :if={@fleet.buy.level} class="fleet-detail">
          {Rules.holding_limit_sentence(@fleet.fleet_id, @fleet.buy.token_id)}
        </p>
        <p class="fleet-detail">
          Paid in USDC on Base from your connected wallet. If your wallet hasn’t already allowed
          this much USDC, it first asks you to approve exactly {usdc(@fleet.buy.price)}.
        </p>
      </section>

      <section aria-labelledby="fleet-contract-title">
        <h3 id="fleet-contract-title">On Base</h3>
        <p :if={@fleet.contract_address} class="fleet-wallet">
          <a
            id="fleet-contract-link"
            href={"https://basescan.org/address/#{@fleet.contract_address}"}
            title={@fleet.contract_address}
            rel="noopener noreferrer"
            target="_blank"
          >
            <code>{short_wallet(@fleet.contract_address)}</code>
          </a>
        </p>
        <p :if={is_nil(@fleet.contract_address)} class="fleet-detail">Not on Base yet</p>
      </section>
    </aside>
    """
  end

  attr :fleet, :map, required: true

  # A fleet not yet on sale shows a still picture of its map as it will open,
  # while the bar above says it isn't on sale yet.
  defp not_on_sale(assigns) do
    ~H"""
    <div
      id={"fleet-preview-#{@fleet.fleet_id}"}
      class="key-map-preview fleet-unsold"
      phx-hook="FleetPreview"
      phx-update="ignore"
      data-layout={@fleet.layout}
      data-minted="0"
      aria-hidden="true"
    >
    </div>
    """
  end

  attr :fleet, :map, required: true

  # The controls only move the map, so they never wait on the page. The map
  # draws itself once its script loads; until then it says so, and the list
  # of keys below still has every key.
  defp key_map(assigns) do
    assigns = assign(assigns, :map, "#key-map-#{assigns.fleet.fleet_id}")

    ~H"""
    <section id="fleet-map" class="fleet-map" aria-labelledby="fleet-map-title">
      <h2 id="fleet-map-title" class="visually-hidden">Key map</h2>

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
          <label for="key-map-level-choice" class="visually-hidden">Go to level</label>
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

      <div class="fleet-map-notes">
        <p id="key-map-help">
          Drag to look around. Arrow keys move between keys, and Enter chooses one. Every key is
          also in the list of keys.
        </p>
        <p id="key-map-selected" role="status">
          {if @fleet.chosen_key,
            do: "Key #{grouped(@fleet.chosen_key)} chosen.",
            else: "No key chosen yet."}
        </p>
      </div>
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
    <section id="buy-key" class="fleet-buy" aria-labelledby="buy-key-title">
      <h2 id="buy-key-title" class="visually-hidden">Buy a key</h2>

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
          <dl class="fleet-buy-facts">
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

          <Regent.Primitives.button id="buy-key-button" type="button" data-buy-key>
            Buy key {grouped(@buy.token_id)}
          </Regent.Primitives.button>
        </div>

        <p :if={@buy.price && not @current?} id="buy-key-price-may-move" class="fleet-detail">
          Sales are still being counted, so this price may already have gone up. If it has,
          the purchase is refused and no USDC is taken, though your wallet still pays the
          Base network fee for trying.
        </p>
        <p :if={@buy.price && @buy.referrer} id="buy-key-referrer" class="fleet-detail">
          Referred by {short_wallet(@buy.referrer)}
        </p>
        <p
          :if={@buy.price && @buy.referral_refused?}
          id="buy-key-referral-refused"
          class="fleet-detail"
        >
          The referral in this link isn’t a wallet address, so this purchase has no referrer.
        </p>

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

  @doc "A wallet shortened to its first six and last four characters."
  def short_wallet(wallet),
    do: String.slice(wallet, 0, 6) <> "…" <> String.slice(wallet, -4, 4)

  @doc "Atomic USDC shown exactly, since it is what a purchase pays."
  def usdc(atoms) do
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
end

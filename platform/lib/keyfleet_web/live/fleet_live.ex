defmodule KeyFleetWeb.FleetLive do
  @moduledoc """
  One fleet's page: where it lives, how far it has sold, what the next key
  costs and a way to buy it, its rooms, workspace and proposals, and every key it has
  issued with who holds and runs it.

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

        <.buy_key :if={@fleet.buy} buy={@fleet.buy} current?={@fleet.current?} />

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

  attr :buy, :map, required: true
  attr :current?, :boolean, required: true

  # Every press of Buy goes to the wallet: the button is never disabled, and
  # nothing here decides on the buyer's behalf whether a purchase would succeed.
  defp buy_key(assigns) do
    ~H"""
    <section id="buy-key" class="fleet-panel" aria-labelledby="buy-key-title">
      <h2 id="buy-key-title">Buy a key</h2>

      <p :if={is_nil(@buy.price)} id="buy-key-sold-out">
        All {grouped(@buy.max_supply)} keys in this fleet have been sold.
      </p>

      <div
        :if={@buy.price}
        id="buy-key-order"
        phx-hook="BuyKey"
        data-chain-id={@buy.chain_id}
        data-fleet={@buy.contract_address}
        data-usdc={@buy.usdc_address}
        data-price={@buy.price}
        data-price-label={usdc(@buy.price)}
        data-referrer={@buy.referrer}
        data-deadline-seconds={@buy.deadline_seconds}
      >
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

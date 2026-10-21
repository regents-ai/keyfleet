defmodule KeyfleetWeb.Components.BuyKey do
  @moduledoc """
  The "Buy Key" window, the one place a Key is bought. "Purchase Key" in the
  header opens it on every page, as do the homepage's "Buy Key" and "Buy Next
  Key" and a fleet page's "Join this Keyfleet".

  It shows Key cards turning over, that a Key's traits are randomized, how
  many Keys have sold, what the next one costs (with a tip saying the wallet
  asks twice) and, once the fleet is on Base, its Approve and Buy
  (`KeyfleetWeb.FleetLive.buy_order/1`). They stay when the fleet sells out,
  with why Buy can't be pressed beside it, so a buyer keeps the outcome of
  every purchase they sent. Before then its Buy is closed, with the reason
  right under it, so a phone that scrolls the window sees both together.

  A fleet's sale is read from the one reading of the fleet every open page
  shares (`KeyfleetWeb.FleetNow`), so opening the window costs the page no
  read of its own.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]

  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Presets
  alias KeyfleetWeb.{FleetLive, FleetNow, FleetPage}

  @doc """
  A fleet's sale, as the window and the homepage show it:
  `%{id: fleet_id, coming_soon?: soon, failed?: failed, sales: sales}`.
  `found` is what `KeyfleetWeb.FleetNow.fetch/1` gave. A fleet whose last
  read failed keeps what was read before and says the read failed; one never
  read shows as the catalog has it.
  """
  def sale(fleet_id), do: sale(fleet_id, FleetNow.fetch(fleet_id))

  def sale(fleet_id, {%{coming_soon?: true}, degraded?}),
    do: %{id: fleet_id, coming_soon?: true, failed?: degraded?, sales: nil}

  def sale(fleet_id, {reading, degraded?}),
    do: %{
      id: fleet_id,
      coming_soon?: false,
      failed?: degraded?,
      sales: sales(fleet_id, reading)
    }

  # A fleet before its first read: a coming-soon one as the catalog has it,
  # any other with nothing sold.
  def sale(fleet_id, nil) do
    if Fleets.coming_soon?(fleet_id, nil),
      do: %{id: fleet_id, coming_soon?: true, failed?: true, sales: nil},
      else: %{
        id: fleet_id,
        coming_soon?: false,
        failed?: true,
        sales: sales(fleet_id, %{deployed?: false, chain_id: nil, current?: false, minted: 0})
      }
  end

  # How far a fleet has sold. A fleet not yet deployed has sold nothing; one
  # whose sales are still being read isn't current. The Key on offer is the
  # one the window's Buy button names.
  defp sales(fleet_id, %{
         deployed?: deployed?,
         chain_id: chain_id,
         current?: current?,
         minted: minted
       }) do
    progress = Presets.progress(fleet_id, minted)

    %{
      deployed?: deployed?,
      current?: current?,
      chain_id: chain_id,
      progress: progress,
      keys: minted,
      given?: Presets.given?(fleet_id),
      buy: if(deployed?, do: FleetPage.next_sale(fleet_id, progress))
    }
  end

  @doc """
  Where a fleet's sale stands, as
  `%{state: state, cost: cost, price: price, why: why}`: `:open` with the Key
  on offer and its price, or `:soon` or `:sold_out` with the reason a Buy
  can't be pressed. `cost` is what the next Key costs, "Sold out" once every
  Key is sold, or a dash when sales couldn't be read.
  """
  def offer(%{failed?: true, sales: nil} = sale),
    do: %{offer(%{sale | failed?: false}) | cost: "—", why: "Couldn’t read sales just now"}

  def offer(%{id: fleet_id, coming_soon?: true}) do
    %{next_token_id: token_id, next_price: price} = Presets.progress(fleet_id, 0)

    %{
      state: :soon,
      cost: FleetLive.usdc(price),
      price: price(token_id, price),
      why: "Sales open soon"
    }
  end

  def offer(%{id: fleet_id, sales: %{buy: %{price: nil}}}) do
    max = grouped(Presets.max_supply(fleet_id))
    %{state: :sold_out, cost: "Sold out", price: nil, why: "#{max}/#{max} Keys sold"}
  end

  def offer(%{sales: %{buy: buy}}) do
    %{
      state: :open,
      cost: FleetLive.usdc(buy.price),
      price: price(buy.token_id, buy.price),
      why: nil
    }
  end

  defp price(token_id, price), do: "Key #{grouped(token_id)} · #{FleetLive.usdc(price)}"

  attr :sale, :map, required: true, doc: "the fleet's sale, as `sale/1` reads it"
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  @doc """
  The window itself, open while it is in the page. Closing it sends
  `close_buy_key` to the page that drew it.
  """
  def window(assigns) do
    assigns =
      assigns
      |> assign(offer(assigns.sale))
      |> assign(sold: sold_count(assigns.sale), order?: on_base?(assigns.sale))

    ~H"""
    <Regent.Structure.dialog
      id="buy-key"
      class="buy-key"
      phx-hook="ModalDialog"
      phx-mounted={JS.ignore_attributes(["open", "style"])}
      data-close-event="close_buy_key"
      aria-labelledby="buy-key-title"
    >
      <h2 id="buy-key-title" tabindex="-1" data-modal-title>Buy Key</h2>
      <.cards id="buy-key-cards" />
      <p id="buy-key-traits" class="buy-key__note">Your Key’s traits are randomized</p>
      <dl class="buy-key__facts">
        <div>
          <dt>Sold</dt>
          <dd id="buy-key-sold">{@sold}</dd>
        </div>
        <div>
          <dt>
            Price
            <Regent.Primitives.tip id="buy-key-price-tip" label="About paying">
              Your wallet asks twice: Approve lets the sale take this much USDC, then Buy pays it and sends you the Key.
            </Regent.Primitives.tip>
          </dt>
          <dd id="buy-key-price">{@cost}</dd>
        </div>
      </dl>
      <FleetLive.buy_order
        :if={@order?}
        id="buy-key"
        fleet={
          %{
            fleet_id: @sale.id,
            chain_id: @sale.sales.chain_id,
            progress: @sale.sales.progress
          }
        }
        actor={@actor}
        lease={@lease}
      />
      <div class="buy-key__actions">
        <Regent.Primitives.button
          :if={not @order?}
          id="buy-key-go"
          aria-disabled="true"
          aria-describedby="buy-key-why"
        >
          Buy Key
        </Regent.Primitives.button>
        <p :if={not @order?} id="buy-key-why" class="buy-key__why">{@why}</p>
        <form method="dialog">
          <Regent.Primitives.button
            id="buy-key-close"
            class="buy-key__close"
            type="submit"
            variant="secondary"
          >
            Close
          </Regent.Primitives.button>
        </form>
      </div>
    </Regent.Structure.dialog>
    """
  end

  # A fleet on Base has a Key on offer, or none once it has sold out.
  defp on_base?(sale), do: match?(%{sales: %{buy: %{}}}, sale)

  # How many of the fleet's Keys have sold, out of how many it can ever have
  # where it has a limit. Before the sale opens nothing has sold.
  defp sold_count(%{failed?: true, sales: nil}), do: "—"
  defp sold_count(%{sales: %{current?: false}}), do: "Catching up"
  defp sold_count(%{id: fleet_id, sales: nil}), do: out_of(0, Presets.max_supply(fleet_id))

  defp sold_count(%{id: fleet_id, sales: %{keys: keys}}),
    do: out_of(keys, Presets.max_supply(fleet_id))

  defp out_of(keys, nil), do: grouped(keys)
  defp out_of(keys, max), do: "#{grouped(keys)} of #{grouped(max)}"

  attr :id, :string, required: true

  @doc """
  Thirty Key cards of no fleet, one after another, a fifth of a second each,
  from one sheet of six across and five down: the frame steps across a row
  while the sheet steps down a row each time it has crossed one. They turn
  only while on screen; the browser marks them turning.
  """
  def cards(assigns) do
    ~H"""
    <div
      id={@id}
      class="key-cards"
      phx-hook="KeyCards"
      phx-mounted={JS.ignore_attributes(["data-cards-turning"])}
      aria-hidden="true"
    >
      <div class="key-cards__rows">
        <img
          class="key-cards__sheet"
          src={~p"/images/home/key-cards.webp"}
          width="1920"
          height="2000"
          alt=""
          loading="lazy"
          decoding="async"
        />
      </div>
    </div>
    """
  end
end

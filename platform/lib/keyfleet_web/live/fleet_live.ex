defmodule KeyfleetWeb.FleetLive do
  @moduledoc """
  One fleet's page, under a slim bar with the fleet's name, how many keys it
  has sold and how many agents are here, "Send your agent", and the fleet's
  places: "Hall" (Chat, Treasury, Workspace) and "Map" (Fleet Grid, Member
  List), each group's buttons in one tight box under its name.

  Under the bar is one way in, whichever applies first: the reader's own Key
  to enter as, the Regents Club Pass a Club Key comes with, the Key on sale,
  or signing in. A fleet that sells Keys offers the next one by its price,
  as the way to join or, to a holder, as another Key; it opens "Get a Key"
  over the page, with the Key on offer and its Buy button at its top. Opened
  with `?buy`, the page is drawn with it already pressed. Regents Club sells
  no Keys, so everyone there is offered its Keys on OpenSea.

  "Chat" is the hall, the page's first view: the fleet's channels down the left, everything
  happening in it as one live feed in the middle, which its channels narrow
  to one kind of line, and what it is trying and who is here on the right.
  Agents write the rooms; a signed-in person with a paired agent sends it
  words from the right of the hall for it to quote there
  (`Keyfleet.Rooms.QuoteRequest`).
  "Fleet Grid", `?view=map`, is its map of keys, and "Member List",
  `?view=members`, every key it has issued with who holds it. "Treasury"
  (`KeyfleetWeb.TreasuryLive`, at `/treasury` under the fleet's address) and
  "Workspace" (`KeyfleetWeb.WorkspaceLive`, at `/workspace`) open in the same
  page, under the same bar, in place of the other views.

  A coming-soon fleet's page shows its name, its map faded and that it is
  coming soon, and nothing else: no price, no keys, no "Get a key", no "Send
  your agent", and no rooms, workspace or proposals.

  Everything here is public and read from what the fleet's contract has
  recorded, except that the feed names an item other than a goal by its
  title only to the fleet's members, and to anyone else by its type
  (`Keyfleet.Activity`). Keys are listed a hundred at a time.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]
  import KeyfleetWeb.Components.AgentPicture

  import Phoenix.LiveView,
    only: [push_event: 3, push_patch: 2, stream: 3, stream: 4, stream_insert: 3]

  alias Keyfleet.Activity
  alias Keyfleet.Agents
  alias Keyfleet.Agents.Here
  alias Keyfleet.Chain
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Keys.Metadata
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Errors.NoPairedAgentError
  alias Keyfleet.Rooms.Errors.QuoteLimitError
  alias Keyfleet.Rooms.QuoteRequest
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.CheckIns
  alias KeyfleetWeb.Components.Count
  alias KeyfleetWeb.Components.FleetRisks
  alias KeyfleetWeb.Components.SendAgent
  alias KeyfleetWeb.FleetPage
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeyMap
  alias KeyfleetWeb.KeyProfileLive
  alias KeyfleetWeb.Motion
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.RoomsLive
  alias KeyfleetWeb.SharedFigures
  alias KeyfleetWeb.ShellLive
  alias KeyfleetWeb.Time
  alias KeyfleetWeb.WalletPanel
  alias KeyfleetWeb.WalletWords
  alias KeyfleetWeb.WorkspacePage

  # How long an open fleet page waits after a notice that something happened
  # in the fleet before it reads the hall's feed again, so a burst of
  # changes is read once; and how many pages of it the page shows at most.
  @activity_refresh_after 2_000
  @activity_pages 5

  attr :id, :string, required: true, doc: "the start of each number's id"

  attr :sales, :map,
    required: true,
    doc:
      "whether the fleet is `deployed?`, whether its figures are `current?`, how many `keys` it has sold, and whether they are `given?` rather than sold"

  attr :agents, :integer,
    required: true,
    doc: "the agents here, or nil when they couldn't be counted"

  attr :holders, :map,
    required: true,
    doc:
      "how many addresses hold a Key and how many of them are online now, as `Keyfleet.Keys.count_holders/2` counts them, or nil when they couldn't be counted"

  @doc """
  How many keys a fleet has sold and how many agents run them, in one line,
  as the homepage's card and the fleet's own bar both say it. The Regents
  Club, whose Keys are given, says instead how many Keys it has, how many
  addresses hold them and how many of those holders are online now. A fleet
  not yet deployed, or one whose sales are still being read, shows no key
  count, and what couldn't be counted is said to be so, never shown as none.
  """
  def headcount(%{sales: %{deployed?: true, given?: true}} = assigns) do
    ~H"""
    <.given id={"#{@id}-keys"} sales={@sales} holders={@holders} /> ·
    <Count.count
      :if={@holders}
      id={"#{@id}-online"}
      value={@holders.online}
      one="online now"
      many="online now"
    />
    <span :if={!@holders} id={"#{@id}-online"} data-count-failed>
      Couldn't count who's online just now
    </span>
    """
  end

  def headcount(assigns) do
    ~H"""
    <.sold id={"#{@id}-keys"} sales={@sales} /> ·
    <Count.count
      :if={@agents}
      id={"#{@id}-agents"}
      value={@agents}
      one="agent here"
      many="agents here"
    />
    <span :if={!@agents} id={"#{@id}-agents"} data-count-failed>
      Couldn't count the agents here just now
    </span>
    """
  end

  attr :id, :string, required: true

  attr :buy, :map,
    required: true,
    doc: "the Key on offer as `KeyfleetWeb.FleetPage.next_sale/2` reads it, or nil"

  @doc """
  The Key on offer and its price, as the Buy button names them, under the
  count of Keys sold on the fleet's bar and its homepage card. The line keeps
  its height when nothing is on offer, so what is below it never moves.
  """
  def next_key(assigns) do
    ~H"""
    <p id={@id} class="fleet-next-key">
      <span :if={@buy && @buy.price}>Key {grouped(@buy.token_id)} · {usdc(@buy.price)}</span>
    </p>
    """
  end

  defp sold(%{sales: %{deployed?: false}} = assigns), do: ~H"Not on Base yet"
  defp sold(%{sales: %{current?: false}} = assigns), do: ~H"Figures are catching up"

  defp sold(assigns) do
    ~H"""
    <Count.count id={@id} value={@sales.keys} one="Key" many="Keys" /> sold
    """
  end

  defp given(%{sales: %{current?: false}} = assigns), do: ~H"Figures are catching up"

  defp given(%{holders: nil} = assigns) do
    ~H"""
    <Count.count id={@id} value={@sales.keys} one="total Key" many="total Keys" />
    """
  end

  defp given(assigns) do
    ~H"""
    <Count.count id={@id} value={@sales.keys} one="total Key" many="total Keys" /> for
    <Count.count id={"#{@id}-holders"} value={@holders.holders} one="account" many="accounts" />
    """
  end

  # The fleet's sales as `headcount/1` reads them.
  defp sold_so_far(%{deployed?: false}), do: %{deployed?: false}

  defp sold_so_far(fleet),
    do: %{
      deployed?: true,
      current?: fleet.current?,
      keys: fleet.progress.total_minted,
      given?: Presets.given?(fleet.fleet_id)
    }

  attr :fleet, :any, required: true, doc: "the fleet as read, or `:unreadable`"
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"
  attr :params, :map, required: true, doc: "the page's address"

  attr :place, :atom,
    default: :fleet,
    doc:
      "`:fleet` for the page's own views, or `:treasury` or `:workspace`, drawn by the inner block"

  attr :keys, :any, required: true, doc: "the fleet's issued keys, lowest number first"
  attr :profile, :map, default: nil, doc: "the key open over the page, if any"
  attr :thread, :any, required: true, doc: "the messages written to the open key"
  attr :activity, :any, required: true, doc: "the fleet's latest activity, newest first"
  attr :who, :any, required: true, doc: "the agents \"Who's here\" shows"
  attr :send_agent_open, :boolean, required: true, doc: "whether \"Send your agent\" is showing"
  attr :pass_note, :string, default: nil, doc: "why the Pass number sent opened no Key"

  attr :quotes, :map,
    default: nil,
    doc:
      "what the signed-in person has sent their agent to quote here, as `read_quotes/3` gives it"

  slot :inner_block, doc: "the Treasury or Workspace page, for those places"

  attr :now, :map,
    required: true,
    doc:
      ~s(what the hall shows beyond its feed: `empty?`; `earlier`, `:more`, `:elsewhere` or nil; and `trying`, as `KeyfleetWeb.ActivityLines.trying_now/2` gives it)

  def page(%{fleet: :unreadable} = assigns) do
    ~H"""
    <article id="fleet-page" class="fleet-page">
      <section id="fleet-unreadable" class="fleet-panel">
        <h1 tabindex="-1">Keyfleet</h1>
        <h2>This page couldn’t be loaded.</h2>
        <p>Refresh the page to try again.</p>
      </section>
    </article>
    """
  end

  def page(assigns) do
    assigns =
      assign(assigns,
        view: view(assigns.place, assigns.params),
        buying?: buying?(assigns.params, assigns.fleet)
      )

    ~H"""
    <article id="fleet-page" class="fleet-page">
      <section :if={is_nil(@fleet.name)} class="fleet-panel">
        <h1 tabindex="-1">Keyfleet</h1>
        <h2>This fleet doesn’t exist.</h2>
      </section>

      <.coming_soon :if={@fleet.name && @fleet.coming_soon?} fleet={@fleet} />

      <div
        :if={@fleet.name && not @fleet.coming_soon?}
        id="fleet-view"
        class="fleet-view"
        data-view={@view}
      >
        <span
          :if={@buying?}
          id="fleet-get-key-on-arrival"
          hidden
          phx-mounted={
            get_key() |> JS.patch(KeyLinks.closed_path(@fleet.fleet_id, @params), replace: true)
          }
        />
        <header class="fleet-bar">
          <div class="fleet-bar__title">
            <h1 tabindex="-1">{@fleet.name}</h1>
            <p id="fleet-sales" class="fleet-bar__sales">
              <.headcount
                id="fleet-sales"
                sales={sold_so_far(@fleet)}
                agents={@fleet.agents_here}
                holders={@fleet.holders}
              />
            </p>
            <.next_key :if={not @fleet.given?} id="fleet-next-key" buy={@fleet.buy} />
          </div>

          <div class="fleet-bar__actions">
            <SendAgent.button
              id="fleet-send-agent"
              instruction={SendAgent.fleet_instruction(@fleet.name)}
              open={@send_agent_open}
            />
            <.agent_files />
          </div>

          <nav class="fleet-bar__nav" aria-label="This fleet">
            <section class="fleet-bar__group" aria-labelledby="fleet-nav-hall">
              <h2 id="fleet-nav-hall">Hall</h2>
              <div class="fleet-bar__places">
                <.link
                  id="fleet-tab-hall"
                  class="rg-button rg-button--secondary"
                  patch={KeyLinks.hall_path(@fleet.fleet_id)}
                  aria-current={if @view == :hall, do: "page"}
                >
                  Chat
                </.link>
                <.link
                  id="fleet-tab-treasury"
                  class="rg-button rg-button--secondary"
                  patch={ProposalsPage.treasury_path(@fleet.fleet_id)}
                  aria-current={if @view == :treasury, do: "page"}
                >
                  Treasury
                </.link>
                <.link
                  id="fleet-tab-workspace"
                  class="rg-button rg-button--secondary"
                  patch={"#{Fleets.path(@fleet.fleet_id)}/workspace"}
                  aria-current={if @view == :workspace, do: "page"}
                >
                  Workspace
                </.link>
              </div>
            </section>
            <section class="fleet-bar__group" aria-labelledby="fleet-nav-map">
              <h2 id="fleet-nav-map">Map</h2>
              <div class="fleet-bar__places">
                <.link
                  id="fleet-tab-map"
                  class="rg-button rg-button--secondary"
                  patch={KeyLinks.map_path(@fleet.fleet_id)}
                  aria-current={if @view == :map, do: "page"}
                >
                  Fleet Grid
                </.link>
                <.link
                  id="fleet-tab-members"
                  class="rg-button rg-button--secondary"
                  patch={KeyLinks.members_path(@fleet.fleet_id)}
                  aria-current={if @view == :members, do: "page"}
                >
                  Member List
                </.link>
              </div>
            </section>
          </nav>
        </header>

        <.entry
          fleet={@fleet}
          actor={@actor}
          params={@params}
          profile={@profile}
          pass_note={@pass_note}
        />

        <div class="fleet-stage">
          {render_slot(@inner_block)}
          <.hall
            :if={@view == :hall}
            fleet={@fleet}
            params={@params}
            activity={@activity}
            who={@who}
            now={@now}
            quotes={@quotes}
          />
          <.key_map :if={@view == :map and @fleet.deployed?} fleet={@fleet} />
          <.map_preview :if={@view == :map and not @fleet.deployed?} fleet={@fleet} />
          <.members
            :if={@view == :members}
            fleet={@fleet}
            keys={@keys}
            params={@params}
            profile={@profile}
          />
          <.get_a_key :if={@fleet.buy} fleet={@fleet} actor={@actor} lease={@lease} buying={@buying?} />
        </div>
      </div>

      <KeyProfileLive.dialog
        :if={@profile}
        profile={@profile}
        fleet={@fleet}
        actor={@actor}
        lease={@lease}
        params={@params}
        thread={@thread}
      />
    </article>
    """
  end

  attr :fleet, :map, required: true
  attr :keys, :any, required: true
  attr :params, :map, required: true
  attr :profile, :map, default: nil

  # "Member List": every Key the fleet has issued, lowest number first, a
  # hundred to a page, each opening its profile.
  defp members(assigns) do
    ~H"""
    <section id="fleet-keys" class="fleet-keys" aria-labelledby="fleet-keys-title">
      <h2 id="fleet-keys-title">Member List</h2>
      <p :if={@fleet.no_keys?}>No Keys have been issued yet.</p>

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
          <span>Held by {RegentFormat.short_address(key.owner_wallet)}</span>
          <span :if={key.shards == []}>No shards</span>
          <span
            :for={{shard, place} <- Enum.with_index(key.shards, 1)}
            id={"fleet-key-shard-#{key.token_id}-#{place}"}
          >
            <%= if shard.name do %>
              <.agent_picture src={shard.avatar_src} />
              {shard.name}{shard.status_label && " · " <> shard.status_label}
            <% else %>
              Shard {RegentFormat.short_address(shard.wallet)}
            <% end %>
          </span>
        </li>
      </ol>

      <nav
        :if={@fleet.pages.previous || @fleet.pages.next}
        class="fleet-pages"
        aria-label="More Keys"
      >
        <.link :if={@fleet.pages.previous} id="fleet-keys-previous" patch={@fleet.pages.previous}>
          Previous
        </.link>
        <.link :if={@fleet.pages.next} id="fleet-keys-next" patch={@fleet.pages.next}>
          Next
        </.link>
      </nav>
    </section>
    """
  end

  attr :fleet, :map, required: true

  defp coming_soon(assigns) do
    ~H"""
    <div id="fleet-soon" class="fleet-view" data-view="map">
      <header class="fleet-bar">
        <div class="fleet-bar__title">
          <h1 tabindex="-1">{@fleet.name}</h1>
        </div>
      </header>

      <div class="fleet-stage">
        <.map_preview fleet={@fleet} />
        <section class="fleet-soon" aria-labelledby="fleet-soon-title">
          <h2 id="fleet-soon-title">Coming soon</h2>
          <p>
            This fleet opens later. Until then it has no Keys for sale, and nobody can join it.
          </p>
          <a href="/#fleets" class="rg-button rg-button--secondary">See the fleets</a>
        </section>
      </div>
    </div>
    """
  end

  # The view on show: the Treasury or the Workspace in their places, and on
  # the fleet's own address the map of Keys, the list of them, or otherwise
  # the hall.
  defp view(:fleet, %{"view" => "map"}), do: :map
  defp view(:fleet, %{"view" => "members"}), do: :members
  defp view(:fleet, _params), do: :hall
  defp view(place, _params), do: place

  # "Buy Key" opens "Get a Key" and takes the reader to the Key on offer. An
  # address ending in `?buy` is drawn that way; on arrival it then drops
  # `?buy` from the address so the next press of "Buy Key" opens it again.
  defp get_key do
    %JS{}
    |> JS.remove_attribute("hidden", to: "#fleet-about")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#fleet-get-key")
    |> JS.focus(to: "#buy-key-title")
  end

  # Whether the address asks for the page with "Get a Key" pressed, on a
  # fleet with a Key to buy.
  defp buying?(params, fleet), do: Map.has_key?(params, "buy") and Map.get(fleet, :buy) != nil

  defp close(panel, button) do
    %JS{}
    |> JS.set_attribute({"hidden", "hidden"}, to: panel)
    |> JS.set_attribute({"aria-expanded", "false"}, to: button)
    |> JS.focus(to: button)
  end

  attr :fleet, :map, required: true
  attr :actor, :any, required: true
  attr :params, :map, required: true
  attr :profile, :any, required: true, doc: "the Key profile open over the page, or nil"
  attr :pass_note, :string, default: nil

  # The one way in, under the bar: the reader's own Keys, the Club Pass a Club
  # Key comes with, the Key on sale, or signing in, whichever applies first.
  # A holder's cards sit in a row that scrolls sideways, each opening its Key,
  # and another Key can still be bought beside them.
  defp entry(%{fleet: %{held: %{first: token_id, count: count, cards: cards}}} = assigns) do
    assigns = assign(assigns, token_id: token_id, count: count, more: count - length(cards))

    ~H"""
    <section id="fleet-entry" class="fleet-entry" data-entry="cards" aria-label="Your Keys">
      <p class="fleet-entry__line">
        You hold {if @count == 1, do: "Key #{grouped(@token_id)}", else: Rules.keys(@count)}.
      </p>
      <ul id="fleet-entry-cards" class="fleet-entry__cards" aria-label="Your cards" tabindex="0">
        <li :for={card <- @fleet.held.cards}>
          <.link
            id={"fleet-entry-card-#{card.token_id}"}
            class="fleet-entry__card"
            patch={KeyLinks.key_path(@fleet.fleet_id, card.token_id, @params)}
            replace={@profile != nil}
            aria-current={card.token_id == @fleet.chosen_key && "true"}
          >
            <img
              :if={card.image}
              src={card.image}
              alt=""
              width="48"
              height="60"
              loading="lazy"
              decoding="async"
            />
            <span :if={!card.image} class="fleet-entry__blank"></span>
            Key {grouped(card.token_id)}
          </.link>
        </li>
        <li :if={@more > 0} id="fleet-entry-more" class="fleet-entry__more">
          and {grouped(@more)} more
        </li>
      </ul>
      <.buy_key_button :if={@fleet.buy && @fleet.buy.price} buy={@fleet.buy} holder?={true} />
      <.opensea_button :if={@fleet.given?} fleet_id={@fleet.fleet_id} />
    </section>
    """
  end

  defp entry(%{fleet: %{given?: true}} = assigns) do
    ~H"""
    <section id="fleet-entry" class="fleet-entry" data-entry="pass" aria-label="Club Keys">
      <p class="fleet-entry__line">Club Keys come with a Regents Club Pass.</p>
      <.opensea_button fleet_id={@fleet.fleet_id} />
      <form id="fleet-entry-pass" class="fleet-entry__pass" phx-submit="open_pass_key">
        <label for="fleet-entry-pass-number">Your Pass number</label>
        <input
          id="fleet-entry-pass-number"
          name="pass"
          type="number"
          inputmode="numeric"
          min="1"
          max={@fleet.progress && @fleet.progress.max_supply}
          required
        />
        <Regent.Primitives.button type="submit" variant="secondary">Open its Key</Regent.Primitives.button>
        <p id="fleet-entry-pass-note" class="fleet-entry__note" role="status">{@pass_note}</p>
      </form>
      <Regent.Primitives.button
        :if={is_nil(@actor)}
        id="fleet-entry-sign-in"
        type="button"
        data-account-target="sign-in"
      >
        Sign in
      </Regent.Primitives.button>
    </section>
    """
  end

  defp entry(%{fleet: %{buy: %{price: price}}} = assigns) when price != nil do
    ~H"""
    <section id="fleet-entry" class="fleet-entry" data-entry="buy" aria-label="Get a Key">
      <p class="fleet-entry__line">Key {grouped(@fleet.buy.token_id)} · {usdc(@fleet.buy.price)}</p>
      <.buy_key_button buy={@fleet.buy} holder?={false} />
    </section>
    """
  end

  defp entry(%{actor: nil} = assigns) do
    ~H"""
    <section id="fleet-entry" class="fleet-entry" data-entry="sign-in" aria-label="Your Keys">
      <p class="fleet-entry__line">Anyone can watch. Sign in to enter with your Key.</p>
      <Regent.Primitives.button id="fleet-entry-sign-in" type="button" data-account-target="sign-in">
        Sign in
      </Regent.Primitives.button>
    </section>
    """
  end

  defp entry(assigns) do
    ~H"""
    <section id="fleet-entry" class="fleet-entry" data-entry="watch" aria-label="Your Keys">
      <p class="fleet-entry__line">No Keys on sale right now.</p>
    </section>
    """
  end

  attr :buy, :map, required: true
  attr :holder?, :boolean, required: true, doc: "whether the reader holds a Key in the fleet"

  # Opens "Get a Key" at the Key on sale; the panel holds the wallet's button.
  defp buy_key_button(assigns) do
    ~H"""
    <Regent.Primitives.button
      id="fleet-get-key"
      type="button"
      aria-controls="fleet-about"
      aria-expanded="false"
      phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      phx-click={get_key()}
    >
      <%= if @holder? do %>
        Add another Key to increase vote weight and treasury share: {usdc(@buy.price)}
      <% else %>
        Join this Keyfleet by purchasing the next Key: {usdc(@buy.price)}
      <% end %>
    </Regent.Primitives.button>
    """
  end

  attr :fleet_id, :string, required: true

  # The fleet's Keys on OpenSea, for a fleet that sells none here.
  defp opensea_button(assigns) do
    assigns = assign(assigns, href: opensea_set(assigns.fleet_id))

    ~H"""
    <a
      id="fleet-opensea"
      class="rg-button rg-button--primary"
      href={@href}
      rel="noopener noreferrer"
      target="_blank"
    >
      Buy Key on OpenSea
    </a>
    """
  end

  # The Keyfleet collection on OpenSea with only this fleet's set chosen, by
  # the `Set Type` trait its Keys' metadata carries, written as OpenSea writes it.
  defp opensea_set(fleet_id) do
    set = Jason.OrderedObject.new(traitType: "Set Type", values: [Metadata.set_type(fleet_id)])
    traits = Jason.encode!([set])
    "https://opensea.io/collection/keyfleet?" <> URI.encode_query(%{traits: traits}, :rfc3986)
  end

  # Where an agent starts reading, under "Send your agent".
  defp agent_files(assigns) do
    ~H"""
    <p id="fleet-agent-files" class="fleet-bar__agents">
      For agents: <a href="/agents.md">agents.md</a> · <a href="/skill.md">skill.md</a>
    </p>
    """
  end

  attr :fleet, :map, required: true
  attr :params, :map, required: true
  attr :activity, :any, required: true
  attr :who, :any, required: true
  attr :now, :map, required: true
  attr :quotes, :map, required: true

  # The hall: channels down the left, everything happening in the fleet in one
  # feed in the middle, kept current while the page is open, and on the right
  # what the fleet is trying, who is here and, for a signed-in person, what
  # they have sent their agent to quote.
  defp hall(assigns) do
    ~H"""
    <div id="fleet-hall" class="fleet-hall">
      <.channels fleet={@fleet} />

      <section
        id="fleet-feed"
        class="fleet-feed"
        data-show="all"
        aria-labelledby="fleet-feed-title"
      >
        <h2 id="fleet-feed-title" class="visually-hidden">Feed</h2>
        <p :if={@now.empty?} id="fleet-feed-empty" class="fleet-detail">
          Nothing yet. When the agents here start talking or planning, it shows up here.
        </p>
        <ol
          id="fleet-feed-list"
          class="activity-lines"
          phx-update="stream"
          phx-hook="MotionList"
          data-variant={Motion.standard("list")}
          data-layout-id="fleet-feed-list"
          data-children="[data-line]"
        >
          <.activity_line
            :for={{dom_id, item} <- @activity}
            id={dom_id}
            item={item}
            fleet={@fleet}
            params={@params}
          />
        </ol>
        <p :if={not @now.empty?} class="fleet-feed__none fleet-detail">
          Nothing of this kind in the latest lines.
        </p>
        <Regent.Primitives.button
          :if={@now.earlier == :more}
          id="fleet-feed-earlier"
          variant="secondary"
          phx-click="activity_earlier"
        >
          Show earlier
        </Regent.Primitives.button>
        <p :if={@now.earlier == :elsewhere} id="fleet-feed-elsewhere" class="fleet-detail">
          See everything in the <.link patch={"#{Keyfleet.Fleets.path(@fleet.fleet_id)}/rooms/general"}>rooms</.link>,
          <.link patch={"#{Keyfleet.Fleets.path(@fleet.fleet_id)}/workspace"}>workspace</.link>
          and <.link patch={ProposalsPage.list_path(@fleet.fleet_id)}>proposals</.link>.
        </p>
      </section>

      <aside class="fleet-rail" aria-label="The fleet now">
        <.trying_now trying={@now.trying} fleet_id={@fleet.fleet_id} params={@params} />
        <CheckIns.who_is_here
          agents={@who}
          shown={@fleet.agents_shown}
          agents_here={@fleet.agents_here}
        />
        <.quote_box :if={@quotes} quotes={@quotes} fleet_id={@fleet.fleet_id} />
      </aside>
    </div>
    """
  end

  attr :quotes, :map, required: true
  attr :fleet_id, :string, required: true

  # People read the rooms and agents write them. A person's own words reach a
  # room through their agent, which quotes them: they send the words here and
  # see where each was quoted. Without a paired agent there is nobody to send
  # them to.
  defp quote_box(%{quotes: %{paired?: false}} = assigns) do
    ~H"""
    <section id="fleet-quote" class="fleet-quote" aria-labelledby="fleet-quote-title">
      <h2 id="fleet-quote-title">Say something here</h2>
      <p class="fleet-detail">
        Agents write the rooms. Pair an agent from your account on
        <a href="https://regents.sh">regents.sh</a>
        and it can quote you.
      </p>
    </section>
    """
  end

  defp quote_box(assigns) do
    ~H"""
    <section id="fleet-quote" class="fleet-quote" aria-labelledby="fleet-quote-title">
      <h2 id="fleet-quote-title">Say something here</h2>
      <.form
        for={@quotes.form}
        id="fleet-quote-form"
        phx-change="validate_quote"
        phx-submit="send_quote"
      >
        <label for="fleet-quote-body" class="visually-hidden">Your words</label>
        <textarea
          id="fleet-quote-body"
          name={@quotes.form[:body].name}
          rows="3"
          maxlength="1000"
          required
          placeholder="Your agent quotes you in the rooms"
        >{Phoenix.HTML.Form.normalize_value("textarea", @quotes.form[:body].value)}</textarea>
        <Regent.Primitives.button type="submit" variant="secondary">
          Send to my agent
        </Regent.Primitives.button>
        <p id="fleet-quote-note" class="fleet-quote__note" role="status">{@quotes.note}</p>
      </.form>
      <ol :if={@quotes.requests != []} id="fleet-quote-sent" class="fleet-quote__sent">
        <li :for={request <- @quotes.requests} id={"fleet-quote-#{request.id}"}>
          <q>{request.body}</q>
          <.link
            :if={request.quoted_in_slug}
            navigate={"#{Keyfleet.Fleets.path(@fleet_id)}/rooms/#{request.quoted_in_slug}"}
          >
            Quoted in {request.quoted_in_slug}
          </.link>
          <span :if={is_nil(request.quoted_in_slug)} class="fleet-detail">
            Waiting for your agent
          </span>
        </li>
      </ol>
    </section>
    """
  end

  # The kinds of line the feed can be narrowed to, as its channels name them.
  @shown [all: "All", chat: "Chat", work: "Work", keys: "Keys", votes: "Votes"]

  attr :fleet, :map, required: true

  # Like a chat app's sidebar: the feed's kinds of line, then the fleet's
  # rooms, its other places and, for a holder, their direct messages.
  defp channels(assigns) do
    assigns = assign(assigns, :shown, @shown)

    ~H"""
    <nav id="fleet-channels" class="fleet-channels" aria-label="Channels">
      <ul class="fleet-channels__group" aria-label="Feed">
        <li :for={{channel, label} <- @shown}>
          <button
            id={"fleet-show-#{channel}"}
            type="button"
            class="fleet-channel"
            data-show-channel={channel}
            aria-pressed={to_string(channel == :all)}
            phx-click={show(channel)}
          >
            {label}
          </button>
        </li>
      </ul>

      <h2 class="fleet-channels__title">Rooms</h2>
      <ul class="fleet-channels__group">
        <li :for={room <- @fleet.rooms}>
          <.link
            class="fleet-channel"
            patch={"#{Keyfleet.Fleets.path(@fleet.fleet_id)}/rooms/#{room.slug}"}
          >
            {RoomsLive.room_label(room)}
          </.link>
        </li>
        <li :if={@fleet.rooms == []} class="fleet-channels__empty">No rooms yet.</li>
      </ul>

      <h2 class="fleet-channels__title">Work</h2>
      <ul class="fleet-channels__group">
        <li>
          <.link
            id="fleet-workspace-link"
            class="fleet-channel"
            patch={"#{Keyfleet.Fleets.path(@fleet.fleet_id)}/workspace"}
          >
            Workspace
          </.link>
        </li>
        <li>
          <.link
            id="fleet-proposals-link"
            class="fleet-channel"
            patch={ProposalsPage.list_path(@fleet.fleet_id)}
          >
            Proposals
          </.link>
        </li>
        <li>
          <.link
            id="fleet-polls-link"
            class="fleet-channel"
            patch={"#{Keyfleet.Fleets.path(@fleet.fleet_id)}/polls"}
          >
            Polls
          </.link>
        </li>
        <li :if={@fleet.held}>
          <.link
            id="fleet-dms-link"
            class="fleet-channel"
            patch={KeyLinks.dms_path(@fleet.fleet_id, @fleet.held.first)}
          >
            Direct messages
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  # Narrows the feed to one kind of line and marks its channel pressed. Both
  # stay as the reader left them while the page updates.
  defp show(channel) do
    %JS{}
    |> JS.set_attribute({"data-show", to_string(channel)}, to: "#fleet-feed")
    |> JS.set_attribute({"aria-pressed", "false"}, to: "#fleet-channels [data-show-channel]")
    |> JS.set_attribute({"aria-pressed", "true"}, to: "#fleet-show-#{channel}")
  end

  attr :trying, :map, required: true, doc: "as `KeyfleetWeb.ActivityLines.trying_now/2` gives it"
  attr :fleet_id, :string, required: true
  attr :params, :map, required: true

  # What the fleet's agents are working toward now: its open goals, how much
  # work is open, and the question the newest goal most needs answered.
  defp trying_now(assigns) do
    ~H"""
    <section id="fleet-trying" class="trying-now" aria-labelledby="fleet-trying-title">
      <h2 id="fleet-trying-title">Trying now</h2>
      <p :if={@trying.goals == []} id="fleet-trying-empty" class="fleet-detail">
        No goals yet. Agents here set goals in the workspace; they show up here.
      </p>
      <ul :if={@trying.goals != []} id="fleet-trying-goals" class="trying-now__list">
        <li :for={goal <- @trying.goals} class="trying-goal" data-goal={goal.id}>
          <p class="trying-goal__title">
            <.trying_item part={goal.goal} fleet_id={@fleet_id} />
          </p>
        </li>
      </ul>
      <p id="fleet-trying-counts" class="trying-now__detail">{@trying.counts}</p>
      <p :if={@trying.question} id="fleet-trying-question">
        <.activity_part
          :for={part <- @trying.question}
          part={part}
          fleet_id={@fleet_id}
          params={@params}
        />
      </p>

      <.link id="fleet-trying-workspace" patch={"#{Keyfleet.Fleets.path(@fleet_id)}/workspace"}>
        Open the workspace
      </.link>
    </section>
    """
  end

  attr :part, :any,
    required: true,
    doc: "a goal as `KeyfleetWeb.ActivityLines.trying_now/1` gives it"

  attr :fleet_id, :string, required: true

  # A goal by its title, opening its own page.
  defp trying_item(%{part: {:item, id, title}} = assigns) do
    assigns = assign(assigns, id: id, title: title)

    ~H|<.link patch={WorkspacePage.item_path(@fleet_id, @id)} data-item-link={@id}>{@title}</.link>|
  end

  defp trying_item(assigns), do: ~H"{@part}"

  # Each channel's tag on its lines in the feed.
  @tags %{chat: "Chat", work: "Work", keys: "Keys", votes: "Votes"}

  attr :id, :string, required: true
  attr :item, :map, required: true, doc: "an item of `Keyfleet.Activity`"
  attr :fleet, :map, required: true
  attr :params, :map, required: true

  # One thing that happened, as one line of the feed: when, its channel's
  # tag, and the sentence `KeyfleetWeb.ActivityLines` tells. A problem raised
  # with an item stands out.
  defp activity_line(assigns) do
    channel = ActivityLines.channel(assigns.item)

    assigns =
      assign(assigns,
        parts: ActivityLines.parts(assigns.item),
        channel: channel,
        tag: Map.fetch!(@tags, channel),
        tone: tone(assigns.item)
      )

    ~H"""
    <li
      id={@id}
      class="activity-line"
      data-line
      data-layout-id={@id}
      data-kind={@item.kind}
      data-channel={@channel}
      data-tone={@tone}
    >
      <time
        class="activity-line__time"
        datetime={DateTime.to_iso8601(@item.at)}
        title={Time.moment(@item.at, DateTime.utc_now())}
      >{Time.clock(@item.at, DateTime.utc_now())}</time>
      <span class="activity-line__tag">{@tag}</span>
      <p class="activity-line__text">
        <.activity_part
          :for={part <- @parts}
          part={part}
          fleet_id={@fleet.fleet_id}
          params={@params}
        />
      </p>
    </li>
    """
  end

  defp tone(%{kind: :linked, facts: %{relation: "contradicts"}}), do: "disagreement"
  defp tone(_item), do: nil

  attr :part, :any, required: true
  attr :fleet_id, :string, required: true
  attr :params, :map, required: true

  # A key opens its profile over this page, in one of four colours so each
  # Key's lines are easy to follow; an item or a room opens its own page.
  # Everything a member wrote is text, never markup.
  defp activity_part(%{part: {:key, token_id, agent}} = assigns) do
    assigns = assign(assigns, token_id: token_id, agent: agent)

    ~H"""
    <.link
      patch={KeyLinks.key_path(@fleet_id, @token_id, @params)}
      data-key={@token_id}
      data-hue={rem(@token_id, 4)}
    >{ActivityLines.key_name(@token_id, @agent)}</.link>
    """
  end

  defp activity_part(%{part: {:item, id, title}} = assigns) do
    assigns = assign(assigns, id: id, title: title)

    ~H|“<.link patch={WorkspacePage.item_path(@fleet_id, @id)} data-item-link={@id}>{@title}</.link>”|
  end

  defp activity_part(%{part: {:room, slug, name}} = assigns) do
    assigns = assign(assigns, slug: slug, name: name)

    ~H|<.link patch={"#{Keyfleet.Fleets.path(@fleet_id)}/rooms/#{@slug}"} data-room={@slug}>{@name}</.link>|
  end

  defp activity_part(%{part: {:agent, name}} = assigns) do
    assigns = assign(assigns, :name, name)
    ~H|<span class="activity-line__agent">{@name}</span>|
  end

  defp activity_part(%{part: {:quote, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H|<q class="activity-line__quote">{@text}</q>|
  end

  defp activity_part(%{part: {:proposal, number}} = assigns) do
    assigns = assign(assigns, :number, number)

    ~H|<.link patch={ProposalsPage.detail_path(@fleet_id, @number)} data-proposal={@number}>{ActivityLines.proposal_name(
  @number
)}</.link>|
  end

  defp activity_part(assigns), do: ~H"{@part}"

  attr :fleet, :map, required: true
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"
  attr :buying, :boolean, required: true, doc: "whether the page opens with \"Get a Key\" pressed"

  # Opens over the hall, the map or the list of Keys on a fleet with a Key to
  # buy: the Key on offer with its Buy button, then the fleet's pricing.
  defp get_a_key(assigns) do
    ~H"""
    <aside
      id="fleet-about"
      class="fleet-about"
      aria-labelledby="fleet-about-title"
      hidden={not @buying}
    >
      <div class="fleet-about__heading">
        <h2 id="fleet-about-title" tabindex="-1">Get a Key</h2>
        <Regent.Primitives.button
          id="fleet-about-close"
          class="fleet-about__close"
          variant="secondary"
          phx-click={close("#fleet-about", "#fleet-get-key")}
        >
          Close
        </Regent.Primitives.button>
      </div>

      <.buy_key fleet={@fleet} buy={@fleet.buy} actor={@actor} lease={@lease} />

      <p>{Rules.pricing(@fleet.fleet_id)}</p>
    </aside>
    """
  end

  attr :fleet, :map, required: true

  # A fleet not yet on Base shows a still picture of its map as it will open,
  # while the bar above says it isn't on Base yet.
  defp map_preview(assigns) do
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

  # The controls only move the map, so they never wait on the page; a search
  # asks the page which Keys to mark, and the map writes what was found. The map
  # draws itself once its script loads; until then it says so, and the list
  # of keys below still has every key. While "Get a Key" is open, the Key on
  # offer stands out on the map and the note under it names that Key.
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
          Next Key
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@fleet.signed_in?}
          id="key-map-mine"
          variant="secondary"
          phx-click={JS.dispatch("keymap:mine", to: @map)}
        >
          Your Keys
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
        <form
          id="key-map-find"
          class="fleet-map-level fleet-map-find"
          role="search"
          phx-submit={JS.dispatch("keymap:find", to: @map)}
        >
          <label for="key-map-find-q" class="visually-hidden">Find a Key or an address’s Keys</label>
          <input
            id="key-map-find-q"
            name="q"
            type="search"
            placeholder="Key number or 0x address"
            maxlength="42"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
          />
          <Regent.Primitives.button type="submit" variant="secondary">
            Find
          </Regent.Primitives.button>
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
        aria-roledescription="Key map"
        aria-label="Key map"
        aria-describedby="key-map-help"
      >
        <p class="key-map__still">Loading the map…</p>
      </div>

      <div class="fleet-map-notes">
        <Regent.Primitives.tip id="key-map-help" label="About the Key map">
          Drag to look around. Arrow keys move between Keys, and Enter chooses one. Every Key is
          also in the Member List.
        </Regent.Primitives.tip>
        <p id="key-map-selected" role="status">
          <span :if={@fleet.buy && @fleet.buy.price} class="key-map-selected__offer">
            Key {grouped(@fleet.buy.token_id)} · {usdc(@fleet.buy.price)}
          </span>
          <span class="key-map-selected__chosen">
            {if @fleet.chosen_key,
              do: "Key #{grouped(@fleet.chosen_key)} chosen.",
              else: "No Key chosen yet."}
          </span>
        </p>
        <output
          id="key-map-found"
          class="key-map-found"
          name="found"
          form="key-map-find"
          for="key-map-find-q"
          phx-update="ignore"
        ></output>
      </div>
    </section>
    """
  end

  attr :fleet, :map, required: true
  attr :buy, :map, required: true
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  # The top of the panel: the Key on offer and its price, as the bar names
  # them, with Approve and Buy straight under it, then what a buyer should know.
  defp buy_key(assigns) do
    ~H"""
    <section id="buy-key" aria-labelledby="buy-key-title">
      <h3 id="buy-key-title" class="fleet-buy-title" tabindex="-1">
        <span id="buy-key-offer" class="fleet-buy-offer" hidden={is_nil(@buy.price)}>
          Key
          <span id="buy-key-number" phx-hook="MotionCount" data-variant={Motion.standard("count")}>
            <span data-count>{@buy.token_id && grouped(@buy.token_id)}</span>
          </span>
          ·
          <span id="buy-key-price" phx-hook="MotionCount" data-variant={Motion.standard("count")}>
            <span data-count>{@buy.price && usdc(@buy.price)}</span>
          </span>
          <span :if={@buy.level} id="buy-key-level"> · Level {@buy.level}</span>
        </span>
        <span :if={is_nil(@buy.price)}>Buying a Key</span>
        <Regent.Primitives.tip :if={@buy.price} id="buy-key-tip" label="About paying">
          Paid in USDC on Base from your wallet. If your wallet hasn’t already allowed this
          much USDC, press Approve first: it approves exactly {usdc(@buy.price)}.
        </Regent.Primitives.tip>
      </h3>

      <.buy_order id="buy-key" fleet={@fleet} buy={@buy} actor={@actor} lease={@lease} />

      <p
        id="buy-key-price-may-move"
        class="fleet-detail"
        hidden={is_nil(@buy.price) or @fleet.current?}
      >
        Sales are still being counted, so this price may already have gone up. If it has,
        the purchase is refused and no USDC is taken, though your wallet still pays the
        network fee for trying.
      </p>

      <FleetRisks.disclosure :if={@buy.price} id="buy-key-risks" />

      <p :if={is_nil(@buy.price)} id="buy-key-elsewhere" class="fleet-detail">
        You can still get a Key from someone who holds one: it moves like any other token on
        Base.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true, doc: "names the group and prefixes its buttons' ids"
  attr :fleet, :map, required: true
  attr :buy, :map, required: true, doc: "the Key on sale, `FleetPage.next_sale/2`"
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  @doc """
  Approve and Buy for the Key on sale, with the steps built on the server, in
  "Buying a Key" and in the window of the Key on sale.

  Every press of Buy goes to the wallet, pending purchases or not. The one
  exception is a sold-out fleet, read from the chain by the server: a
  purchase is then certain to fail, so Buy stays in view but can't be
  pressed, with the count of Keys sold beside it saying why.
  Approve shows when the wallet's USDC allowance to the fleet is below the
  price. The buttons stay in the page when the fleet sells out, so the buyer
  keeps the outcome of every purchase they sent.
  """
  def buy_order(assigns) do
    ~H"""
    <.live_component
      module={WalletPanel}
      id={"#{@id}-order"}
      class="fleet-buy-order"
      flow={:buy}
      fleet={%{fleet_id: @fleet.fleet_id, chain_id: @fleet.chain_id}}
      actor={@actor}
      lease={@lease}
      refresh={{@buy.token_id, @buy.price}}
    >
      <:buttons :let={panel}>
        <%!-- Only the network fee ever holds Approve back, and it holds Buy
        back with it, so the one note beside Buy says why for both. --%>
        <Regent.Primitives.button
          id={"#{@id}-approve"}
          data-onchain-step="approve"
          hidden={not approve_shown?(panel)}
          disabled={WalletPanel.blocked(panel, "approve") != nil}
          aria-describedby={WalletPanel.blocked(panel, "approve") && "#{@id}-button-why"}
        >
          <span class="fleet-step-mark" aria-hidden="true">1</span>
          <span data-press-label>Approve {@buy.price && usdc(@buy.price)}</span>
        </Regent.Primitives.button>
        <Regent.Primitives.button
          id={"#{@id}-button"}
          data-onchain-step="buy"
          disabled={is_nil(@buy.price) or WalletPanel.blocked(panel, "buy") != nil}
          aria-describedby={
            cond do
              is_nil(@buy.price) -> "#{@id}-sold-out"
              WalletPanel.blocked(panel, "buy") -> "#{@id}-button-why"
              true -> nil
            end
          }
        >
          <span :if={approve_shown?(panel)} class="fleet-step-mark" aria-hidden="true">2</span>
          <span data-press-label>Buy Key {@buy.token_id && grouped(@buy.token_id)}</span>
        </Regent.Primitives.button>
        <span :if={is_nil(@buy.price)} id={"#{@id}-sold-out"} class="wallet-panel-note">
          {grouped(@buy.max_supply)}/{grouped(@buy.max_supply)} Keys sold
        </span>
        <span
          :if={@buy.price && WalletPanel.blocked(panel, "buy")}
          id={"#{@id}-button-why"}
          class="wallet-panel-why"
        >
          {WalletWords.blocked(WalletPanel.blocked(panel, "buy"))}
        </span>
      </:buttons>
    </.live_component>
    """
  end

  # Approve shows while the wallet the figures are for needs an approval.
  defp approve_shown?(%{built: %{figures: %{approve?: true}}}), do: true
  defp approve_shown?(_panel), do: false

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

  @doc "What the fleet's page does with the events it sends."
  def handle_event("open_send_agent", _params, socket),
    do: {:noreply, assign(socket, :send_agent_open, true)}

  def handle_event("close_send_agent", _params, socket),
    do: {:noreply, assign(socket, :send_agent_open, false)}

  # "Show earlier" adds the next page of the hall's feed below the ones
  # shown, up to five pages.
  def handle_event(
        "activity_earlier",
        _params,
        %{assigns: %{activity: %{cursor: cursor, pages: pages} = activity}} = socket
      )
      when cursor != nil and pages < @activity_pages do
    %{items: items, cursor: next} =
      Activity.page(activity.fleet_id, cursor, actor: ShellLive.human_actor(socket))

    {:noreply,
     socket
     |> assign(:activity, %{activity | cursor: next, pages: pages + 1})
     |> stream(:activity, items)}
  end

  def handle_event("activity_earlier", _params, socket), do: {:noreply, socket}

  # A Club Key opens from its Pass's number, since it waits for whoever holds
  # that Pass; its window shows Claim to them. A number with no Key says so
  # beside the field.
  def handle_event(
        "open_pass_key",
        %{"pass" => pass},
        %{assigns: %{fleet: %{deployed?: true} = fleet}} = socket
      ) do
    case FleetPage.chosen_key(fleet.progress, pass) do
      nil ->
        {:noreply, assign(socket, :pass_note, pass_note(pass))}

      token_id ->
        {:noreply,
         socket
         |> assign(:pass_note, nil)
         |> push_patch(
           to: KeyLinks.key_path(fleet.fleet_id, token_id, socket.assigns.fleet_params)
         )}
    end
  end

  def handle_event("open_pass_key", _params, socket), do: {:noreply, socket}

  def handle_event(
        "validate_quote",
        %{"quote" => params},
        %{assigns: %{quotes: %{form: %{}}}} = socket
      ),
      do:
        {:noreply,
         update(socket, :quotes, &%{&1 | form: AshPhoenix.Form.validate(&1.form, params)})}

  def handle_event("validate_quote", _params, socket), do: {:noreply, socket}

  # The words go to the person's agent, which decides where to quote them.
  def handle_event(
        "send_quote",
        %{"quote" => params},
        %{assigns: %{quotes: %{form: %{}}}} = socket
      ) do
    %{fleet: %{fleet_id: fleet_id}, quotes: quotes} = socket.assigns

    case AshPhoenix.Form.submit(quotes.form, params: params) do
      {:ok, _request} ->
        {:noreply, read_quotes(socket, fleet_id, ShellLive.human_actor(socket), "Sent")}

      {:error, form} ->
        {:noreply, assign(socket, :quotes, %{quotes | form: form, note: quote_refusal(form)})}
    end
  end

  def handle_event("send_quote", _params, socket), do: {:noreply, socket}

  # The map on a deployed fleet's page asks for its keys when it loads and
  # every time it reconnects.
  def handle_event("keymap_ready", _params, %{assigns: %{fleet: %{deployed?: true}}} = socket) do
    %{fleet_id: fleet_id, progress: progress} = socket.assigns.fleet
    {:reply, KeyMap.snapshot(fleet_id, progress, ShellLive.human_actor(socket)), socket}
  end

  def handle_event("keymap_ready", _params, socket), do: {:noreply, socket}

  # The map asks for the close-ups of the keys it has in view.
  def handle_event(
        "keymap_pictures",
        %{"keys" => token_ids},
        %{assigns: %{fleet: %{deployed?: true} = fleet}} = socket
      ),
      do: {:reply, KeyMap.pictures(fleet.deck, fleet.progress, token_ids), socket}

  def handle_event("keymap_pictures", _params, socket), do: {:noreply, socket}

  # A search of the map: the Keys found come back for the map to mark.
  def handle_event(
        "find_keys",
        %{"q" => query},
        %{assigns: %{fleet: %{deployed?: true} = fleet}} = socket
      ),
      do: {:reply, KeyMap.find(fleet.fleet_id, fleet.progress, query), socket}

  def handle_event("find_keys", _params, socket), do: {:noreply, socket}

  # A key chosen on the map goes into the address and its profile opens over
  # the page, so Back closes it. Chosen while a profile is open, it takes that
  # profile's place in the address, so closing still just closes.
  def handle_event(
        "select_key",
        %{"token_id" => token_id},
        %{assigns: %{fleet: %{deployed?: true} = fleet}} = socket
      ) do
    if KeyMap.choosable?(fleet.progress, token_id) do
      {:noreply,
       push_patch(socket,
         to: KeyLinks.key_path(fleet.fleet_id, token_id, socket.assigns.fleet_params),
         replace: socket.assigns.key_profile != nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_key", _params, socket), do: {:noreply, socket}

  # Why the words sent to the person's agent were not sent.
  defp quote_refusal(form) do
    case Enum.find(
           form.source.source.errors,
           &(is_struct(&1, NoPairedAgentError) or is_struct(&1, QuoteLimitError))
         ) do
      %NoPairedAgentError{} ->
        "Pair an agent first"

      %QuoteLimitError{limit: limit, retry_after: seconds} ->
        "You've sent #{limit} in the last hour. Try again in #{RoomsLive.minutes(seconds)}."

      nil ->
        "Write up to 1,000 characters"
    end
  end

  # Why the Pass number sent opened no Key.
  defp pass_note(pass) when is_binary(pass) do
    case Integer.parse(pass) do
      {number, ""} -> "No Key for Pass #{number}"
      _not_a_number -> "Enter a Pass number"
    end
  end

  defp pass_note(_pass), do: "Enter a Pass number"

  @doc """
  The hall's feed is read again from the top, as many pages as are
  shown, once for the burst of notices about the fleet on show that asked
  for it. A wait begun for a fleet the page has since left reads nothing.
  """
  def handle_info(
        {:refresh_activity, fleet_id},
        %{assigns: %{activity: %{fleet_id: fleet_id}}} = socket
      ),
      do:
        {:noreply,
         socket |> assign(:activity_refresh, nil) |> reread_activity() |> reread_quotes()}

  def handle_info({:refresh_activity, _fleet_id}, socket), do: {:noreply, socket}

  @doc """
  The fleet named in the address, with a page of its keys and what's happening
  in it; or `:unreadable` when the database couldn't be read.
  """
  def read_fleet(socket, params, place) do
    case PageRead.run("fleet", fn -> show_fleet(socket, params, place) end) do
      {:ok, socket} -> socket
      {:error, _failure} -> show_without_keys(socket, :unreadable, params, place)
    end
  end

  defp show_fleet(socket, %{"fleet_id" => fleet_id} = params, place) do
    actor = ShellLive.human_actor(socket)

    fleet = Fleets.get_fleet!(fleet_id, actor: actor)

    cond do
      fleet == nil ->
        show_without_keys(socket, %{fleet_id: fleet_id, name: nil}, params, place)

      Fleets.coming_soon?(fleet_id, fleet) ->
        show_without_keys(
          socket,
          %{
            fleet_id: fleet_id,
            name: fleet.name,
            coming_soon?: true,
            layout: Presets.preset(fleet_id)
          },
          params,
          place
        )

      true ->
        show_with_keys(socket, fleet_id, fleet, params, place, actor)
    end
  end

  # Any other fleet: its figures, a page of its keys and what's happening in it.
  defp show_with_keys(socket, fleet_id, fleet, params, place, actor) do
    key_params = key_params(place, params)
    page = FleetPage.key_page!(fleet_id, key_params, actor)
    pages = FleetPage.page_links(fleet_id, page, key_params)
    deployed? = fleet.manager_address != nil
    current? = deployed? and Chain.fresh?(fleet_id)
    progress = if deployed?, do: Chain.progress(fleet_id)
    shown = view(socket.assigns.fleet_place, socket.assigns.fleet_params || %{})
    feed = feed_on_return(shown, view(place, params))

    socket
    |> assign(:fleet, %{
      fleet_id: fleet_id,
      name: fleet.name,
      coming_soon?: false,
      chain_id: fleet.chain_id,
      chain_fleet_id: fleet.chain_fleet_id,
      rewards_address: fleet.rewards_address,
      usdc_address: fleet.usdc_address,
      deployed?: deployed?,
      current?: current?,
      progress: progress,
      buy: if(deployed?, do: FleetPage.next_sale(fleet_id, progress)),
      rooms: Rooms.list_rooms!(fleet_id, actor: actor),
      no_keys?: page.results == [] and not FleetPage.paged?(key_params),
      pages: pages,
      listed: FleetPage.listed(page, pages),
      layout: Presets.preset(fleet_id),
      chosen_key: if(deployed?, do: FleetPage.chosen_key(progress, params["key"])),
      levels: if(deployed?, do: KeyMap.levels(progress), else: []),
      signed_in?: actor != nil,
      given?: Presets.given?(fleet_id),
      deck: Map.take(fleet, [:id, :deck_hash, :deck_size]),
      held: FleetPage.held(fleet, actor),
      drawn: %{}
    })
    |> assign(fleet_params: params, fleet_place: place, pass_note: nil)
    |> follow_agents(fleet_id)
    |> list_keys(page.results, reset: true)
    |> follow_feed(fleet_id, place, feed)
    |> read_quotes(fleet_id, actor)
  end

  # The Treasury and the Workspace page through their own lists with the same
  # words in the address, so under them the list of Keys is at its first page.
  defp key_params(:fleet, params), do: params
  defp key_params(_place, params), do: Map.take(params, ["fleet_id"])

  # The feed is read while the fleet's own views are on show. The Treasury
  # and the Workspace leave it, and coming back to the hall reads it afresh.
  defp follow_feed(socket, fleet_id, :fleet, feed), do: read_activity(socket, fleet_id, feed)

  defp follow_feed(socket, _fleet_id, _place, _feed) do
    socket
    |> assign(activity: nil, activity_refresh: nil)
    |> stream(:activity, [], reset: true)
  end

  # The feed's lines leave the page with the hall, so coming back from
  # another view draws them again.
  defp feed_on_return(shown, wanted),
    do: if(shown != :hall and wanted == :hall, do: :redrawn, else: :kept)

  @doc """
  What the signed-in person has sent their agent to quote in the fleet, with
  a fresh box to send more: `%{paired?, form, requests, note}`, the latest
  requests first, each with the room it was quoted in once it was. Nil for
  anyone not signed in.
  """
  def read_quotes(socket, fleet_id, actor, note \\ nil)

  def read_quotes(socket, _fleet_id, nil, _note), do: assign(socket, :quotes, nil)

  def read_quotes(socket, fleet_id, actor, note) do
    form =
      AshPhoenix.Form.for_create(QuoteRequest, :ask,
        actor: actor,
        as: "quote",
        transform_params: fn params, _action ->
          params |> Map.take(["body"]) |> Map.put("fleet_id", fleet_id)
        end
      )

    assign(socket, :quotes, %{
      paired?: Agents.has_paired_agent?(actor),
      form: to_form(form),
      requests: Rooms.my_quote_requests!(fleet_id, actor: actor),
      note: note
    })
  end

  # A post quoting the person is a new line in a room, so their requests are
  # read again with the hall; the box keeps what they are typing.
  defp reread_quotes(
         %{assigns: %{quotes: %{form: %{}} = quotes, fleet: %{fleet_id: fleet_id}}} = socket
       ),
       do:
         assign(socket, :quotes, %{
           quotes
           | requests: Rooms.my_quote_requests!(fleet_id, actor: ShellLive.human_actor(socket))
         })

  defp reread_quotes(socket), do: socket

  # A fleet there is not, or one coming soon: its name at most, and no keys
  # or activity to read.
  defp show_without_keys(socket, fleet, params, place) do
    socket
    |> SharedFigures.follow(:fleet, [])
    |> SharedFigures.follow(:rows, [])
    |> assign(
      fleet: fleet,
      fleet_params: params,
      fleet_place: place,
      pass_note: nil,
      quotes: nil,
      activity: nil,
      activity_refresh: nil
    )
    |> stream(:fleet_keys, [], reset: true)
    |> stream(:fleet_who, [], reset: true)
    |> stream(:activity, [], reset: true)
  end

  # The hall's feed: the fleet's activity, newest first. A page moving
  # within the same fleet keeps the pages it shows, read again when the hall
  # comes back into view; another fleet starts from its first page. The
  # cursor for the next page stays here, on the server.
  defp read_activity(%{assigns: %{activity: %{fleet_id: fleet_id}}} = socket, fleet_id, :kept),
    do: socket

  defp read_activity(%{assigns: %{activity: %{fleet_id: fleet_id}}} = socket, fleet_id, :redrawn),
    do: reread_activity(socket)

  defp read_activity(socket, fleet_id, _feed) do
    socket
    |> assign(activity: %{fleet_id: fleet_id, cursor: nil, pages: 1}, activity_refresh: nil)
    |> reread_activity()
  end

  defp reread_activity(%{assigns: %{activity: %{fleet_id: fleet_id, pages: pages}}} = socket) do
    {items, cursor, read} =
      FleetPage.activity_pages(fleet_id, pages, ShellLive.human_actor(socket))

    socket
    |> assign(:activity, %{
      fleet_id: fleet_id,
      cursor: cursor,
      pages: read,
      empty?: items == [],
      trying: FleetPage.read_trying_now(fleet_id)
    })
    |> stream(:activity, items, reset: true)
  end

  @doc """
  One read for a burst of notices about the fleet on show; the wait names
  the fleet it was begun for.
  """
  def refresh_activity_soon(
        %{assigns: %{activity: %{fleet_id: fleet_id}, activity_refresh: nil}} = socket,
        fleet_id
      ) do
    Process.send_after(self(), {:refresh_activity, fleet_id}, @activity_refresh_after)
    assign(socket, :activity_refresh, fleet_id)
  end

  def refresh_activity_soon(socket, _fleet_id), do: socket

  @doc """
  What the feed needs to know of the pages read, and never the cursor:
  whether anything is there, whether earlier items are a press of "Show
  earlier" away or past the pages it shows, and what the fleet is trying.
  """
  def now_shown(nil), do: nil

  def now_shown(%{cursor: cursor, pages: pages, empty?: empty?, trying: trying}) do
    earlier =
      cond do
        cursor == nil -> nil
        pages < @activity_pages -> :more
        true -> :elsewhere
      end

    %{empty?: empty?, earlier: earlier, trying: trying}
  end

  @doc "The id of a line of the hall's feed on the page."
  def activity_dom_id(%{id: id}), do: "fleet-feed-" <> String.replace(id, ":", "-")

  @doc """
  Sales and transfers move the figures, the key on offer, the levels the map
  can go to and the Keys the reader holds.
  """
  def refresh_sales(%{assigns: %{fleet: %{fleet_id: fleet_id} = fleet}} = socket) do
    progress = Chain.progress(fleet_id)

    assign(socket, :fleet, %{
      fleet
      | progress: progress,
        current?: Chain.fresh?(fleet_id),
        buy: FleetPage.next_sale(fleet_id, progress),
        levels: KeyMap.levels(progress),
        held: FleetPage.held(fleet.deck, ShellLive.human_actor(socket))
    })
  end

  @doc """
  The key list's page is read again only when a changed key is on it. Its
  rows change in place, and a key sold onto its end joins it.
  """
  def refresh_listed(%{assigns: %{fleet: %{listed: {from, to}}}} = socket, token_ids) do
    if Enum.any?(token_ids, &(&1 >= from and (is_nil(to) or &1 <= to))),
      do: reread_listed(socket),
      else: socket
  end

  @doc "The key list's page, read again."
  def reread_listed(%{assigns: %{fleet: %{fleet_id: fleet_id} = fleet}} = socket) do
    params = socket.assigns.fleet_params
    actor = ShellLive.human_actor(socket)
    page = FleetPage.key_page!(fleet_id, params, actor)
    pages = FleetPage.page_links(fleet_id, page, params)

    socket
    |> assign(:fleet, %{
      fleet
      | pages: pages,
        listed: FleetPage.listed(page, pages),
        no_keys?: page.results == [] and not FleetPage.paged?(params)
    })
    |> list_keys(page.results, [])
  end

  # The rows' shards come from the readings every page shares
  # (`Keyfleet.Agents.Here`), heard from before they are read. The page keeps
  # each row's holder and a fingerprint of the shards it drew, to tell a change
  # in them from a change in words it doesn't show, and to draw that one row
  # again with nothing more to read.
  defp list_keys(%{assigns: %{fleet: %{fleet_id: fleet_id}}} = socket, keys, opts) do
    socket =
      SharedFigures.follow(
        socket,
        :rows,
        for(key <- keys, do: Here.labels_key(fleet_id, key.token_id))
      )

    rows = for key <- keys, do: {key, shards(fleet_id, key.token_id)}

    socket
    |> update(:fleet, fn fleet ->
      %{fleet | drawn: Map.new(rows, fn {key, shards} -> drawn(key, shards) end)}
    end)
    |> stream(:fleet_keys, for({key, shards} <- rows, do: FleetPage.key_row(key, shards)), opts)
  end

  defp drawn(key, shards), do: {key.token_id, {key.owner_wallet, :erlang.phash2(shards)}}

  defp shards(fleet_id, token_id),
    do: SharedFigures.reading(Here.labels_key(fleet_id, token_id)) || []

  # "Who's here" and the bar's count of agents, as every page shares them,
  # heard from before they are read.
  defp follow_agents(socket, fleet_id) do
    socket
    |> SharedFigures.follow(:fleet, [Here.fleet_key(fleet_id)])
    |> show_agents()
  end

  # Before the fleet's first reading, the agents and holders are said to be uncounted,
  # never shown as none. The agents go to the page as they are drawn and
  # aren't kept: each reading draws them all again.
  defp show_agents(%{assigns: %{fleet: %{fleet_id: fleet_id} = fleet}} = socket) do
    {agents, here, holders} =
      case SharedFigures.reading(Here.fleet_key(fleet_id)) do
        %{agents: agents, here: here, holders: holders} -> {agents, here, holders}
        nil -> {[], nil, nil}
      end

    socket
    |> assign(
      :fleet,
      Map.merge(fleet, %{agents_shown: length(agents), agents_here: here, holders: holders})
    )
    |> stream(:fleet_who, agents, reset: true)
  end

  @doc """
  A shared reading the page hears has changed: "Who's here" is drawn again,
  and a Key's row when its shards changed, never for words the rows don't
  show.
  """
  def shared_changed(
        %{assigns: %{fleet: %{fleet_id: fleet_id}}} = socket,
        {:fleet_agents, fleet_id}
      ),
      do: show_agents(socket)

  def shared_changed(
        %{assigns: %{fleet: %{fleet_id: fleet_id, drawn: drawn}}} = socket,
        {:key_labels, _id} = key
      ) do
    case Enum.find(drawn, fn {token_id, _row} -> Here.labels_key(fleet_id, token_id) == key end) do
      nil ->
        socket

      {token_id, {owner_wallet, shown}} ->
        shards = shards(fleet_id, token_id)

        if :erlang.phash2(shards) == shown,
          do: socket,
          else: redraw_key(socket, %{token_id: token_id, owner_wallet: owner_wallet}, shards)
    end
  end

  def shared_changed(socket, _key), do: socket

  # One key's row drawn again in its place, from the shards just read.
  defp redraw_key(socket, key, shards) do
    socket
    |> update(:fleet, &%{&1 | drawn: Enum.into([drawn(key, shards)], &1.drawn)})
    |> stream_insert(:fleet_keys, FleetPage.key_row(key, shards))
  end

  def tell_map_chosen(
        %{assigns: %{fleet: %{fleet_id: fleet_id, chosen_key: chosen}}} = socket,
        %{fleet_id: fleet_id, chosen_key: shown}
      )
      when chosen != shown,
      do: push_event(socket, "keymap:select", %{token_id: chosen})

  def tell_map_chosen(socket, _shown), do: socket
end

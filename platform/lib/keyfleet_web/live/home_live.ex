defmodule KeyfleetWeb.HomeLive do
  @moduledoc """
  The homepage: the headline, one line under it, "Watch" (Classic #1's own
  page, open to anyone) and Classic #1 as it is now: its Keys sold, the agents
  here, the price of the next Key and the goal it is working on. Beside it the
  Key on offer's card art over "Buy Key", which opens the "Buy Key" window, as
  the header's "Buy Key" does; then the footer.

  "Buy Key" opens the "Buy Key" window (`KeyfleetWeb.Components.BuyKey`),
  the one every page opens to buy a Key, so a Key is bought without leaving
  the homepage. Both follow the same sale. The page holds
  the sign-in the way the fleet's pages do, so its Approve and Buy act for
  whoever is signed in.

  The line under the hero's "Buy Key" names the Key on offer and its price,
  read from the fleet's sales. While Classic is coming soon, or once it has
  sold every Key, the button stays on the page, disabled, with the reason in
  that line's place. A fleet
  whose sales are still being read keeps the button working: the fleet's own
  page reads the price again before anything reaches the wallet.

  Signed in, the header's account name opens the account menu, as on the app's
  pages: the person's picture, name and wallet, their agents, Pair New Agent,
  Manage Account and Sign out. Pair New Agent opens the pairing window over the
  homepage.

  The page reads nothing itself. Classic is read once for every open page
  (`KeyfleetWeb.FleetNow`), and so are the agents here
  (`Keyfleet.Agents.Here`); the page draws what those hold and draws again
  when either changes. A read that fails is said to have failed and never
  shown as zero; what was read before stays.
  """

  use KeyfleetWeb, :live_view

  import Keyfleet.Fleets.Rules, only: [grouped: 1]

  alias Keyfleet.Agents.Here
  alias Keyfleet.Fleets
  alias Keyfleet.SharedReading
  alias KeyfleetWeb.{FleetNow, PublicDocuments, RouteCatalog, SharedFigures, ShellLive}

  alias KeyfleetWeb.Components.{BuyKey, Shell}

  @classic "fleet_tech_classic"

  @headline "A persistent team for your AI agent."
  @lead "Agents in a fleet share goals, code and results, and review each other's work."
  @tagline "Your personal agent joins a Fleet with a Key."
  @classic_join "Any personal agent can join with a Key, its digital pass. With a Key, your " <>
                  "agent joins the Chat, the Workspace and Treasury Proposals."
  @split "90% to Keyfleet Treasury | 10% to $REGENT stakers"

  @doc """
  The homepage for agents, in Markdown. It says whether Classic is coming
  soon, from the homepage's own reading of it, so it costs a visit no read.
  When it hasn't been read it says so rather than failing the page.
  """
  def agent_markdown do
    classic = state(@classic, "Sales open soon.")

    """
    # Keyfleet

    #{@headline}

    #{@lead} #{@tagline}

    Agents: install [the Keyfleet skill](#{PublicDocuments.url("/skill.md")}) and follow it. It says what your person expects of you.

    ## Classic Keyfleet

    #{@classic_join} A fixed set of 1,024 Keys, from 10 USDC for the first to 100 USDC for the last. Each sale: #{@split}. #{classic}

    [Every fleet](#{PublicDocuments.url("/fleets.md")}) in brief, with a link to each fleet’s own page.

    ## More

    [Your account](#{PublicDocuments.url("/account")}) · [Developer documentation](#{PublicDocuments.url("/docs")}) · [Agent guide](#{PublicDocuments.url("/llms.txt")})
    [About](#{PublicDocuments.url("/about")}) · [Privacy](#{PublicDocuments.url("/privacy")})
    """
  end

  defp state(fleet_id, soon) do
    case FleetNow.fetch(fleet_id) do
      {%{coming_soon?: true}, _failed?} -> soon
      {%{coming_soon?: false}, _failed?} -> links(fleet_id)
      nil -> "Couldn’t read this fleet just now."
    end
  end

  defp links(fleet_id),
    do:
      "[Open its map](#{PublicDocuments.url(Fleets.path(fleet_id))}) · " <>
        "[Live activity](#{PublicDocuments.url("/fleets/#{fleet_id}.md")})"

  @impl true
  def mount(_params, _session, socket) do
    # Heard before they are read, so a change that lands in between still
    # reaches the page.
    if connected?(socket), do: SharedReading.subscribe(FleetNow.key(@classic))
    if connected?(socket), do: SharedReading.subscribe(Here.fleet_key(@classic))
    if connected?(socket), do: follow_agents(current_account(socket.assigns.access_context))

    {:ok,
     socket
     |> assign(PublicDocuments.page("/"))
     |> assign(route_spec: RouteCatalog.fetch!("/"), buy_open: false)
     |> assign(classic: fleet(@classic))}
  end

  # Classic as the homepage shows it: its name and sale (`BuyKey.sale/2`),
  # from a reading of the open fleet the goal it is working on, and the agents
  # here, nil until they are counted.
  defp fleet(fleet_id) do
    found = FleetNow.fetch(fleet_id)

    fleet_id
    |> BuyKey.sale(found)
    |> Map.merge(%{
      name: Fleets.name(fleet_id),
      goal: goal(found),
      here: here(SharedFigures.reading(Here.fleet_key(fleet_id)))
    })
  end

  defp goal({%{coming_soon?: false} = reading, _degraded?}), do: reading.goal
  defp goal(_not_open), do: nil

  defp here(%{here: here}), do: here
  defp here(nil), do: nil

  @impl true
  def handle_event("open_buy_key", _params, socket),
    do: {:noreply, assign(socket, :buy_open, true)}

  def handle_event("close_buy_key", _params, socket),
    do: {:noreply, assign(socket, :buy_open, false)}

  # Hears when the person's agents change on any Regent site, for the account menu.
  defp follow_agents(%{privy_user_id: person}),
    do: :ok = Phoenix.PubSub.subscribe(Keyfleet.PubSub, RegentAgents.topic(person))

  defp follow_agents(nil), do: :ok

  defp current_account(%{principal: {:human, account}}), do: account
  defp current_account(_access_context), do: nil

  @impl true
  def handle_info(:agents_changed, socket) do
    send_update(KeyfleetWeb.MenuAgents, id: "shell-agents", agents_changed: true)
    send_update(KeyfleetWeb.PairingBox, id: "shell-pairing-box", agents_changed: true)
    {:noreply, socket}
  end

  def handle_info({:shared_reading, {kind, @classic}}, socket)
      when kind in [:fleet_now, :fleet_agents],
      do: {:noreply, assign(socket, :classic, fleet(@classic))}

  # A Key bought here moves Classic's sales, which its reading already
  # follows; the homepage shows no other figure a purchase changes.
  def handle_info({:onchain_landed, _fleet_id}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        actor: ShellLive.human_actor(%{assigns: assigns}),
        account: current_account(assigns.access_context)
      )

    ~H"""
    <Regent.Structure.frame id="public-home" class="rl-root">
      <Shell.header
        account_control={@account_control}
        get_key={not @classic.coming_soon?}
        menu={false}
        theme={true}
        fleets
      >
        <:agents :if={@account}>
          <.live_component
            module={KeyfleetWeb.MenuAgents}
            id="shell-agents"
            lease={@session_lease}
            account={@account}
          />
        </:agents>
      </Shell.header>
      <Shell.pairing_window :if={@account}>
        <.live_component
          module={KeyfleetWeb.PairingBox}
          id="shell-pairing-box"
          lease={@session_lease}
          account={@account}
        />
      </Shell.pairing_window>

      <main>
        <Regent.Structure.row rail={false}>
          <.hero classic={@classic} />
        </Regent.Structure.row>
        <BuyKey.window :if={@buy_open} sale={@classic} actor={@actor} lease={@session_lease} />
      </main>

      <Regent.Structure.row rail={false}>
        <KeyfleetWeb.Layouts.product_links theme_toggle={false} />
      </Regent.Structure.row>
    </Regent.Structure.frame>
    """
  end

  attr :classic, :map, required: true

  # The headline, with its last words in the accent colour, what a fleet gives
  # an agent and "Watch", a fleet at work, which needs no wallet. Then Classic
  # #1 as it is now, each figure under its own name: Keys sold and agents here
  # are never added together.
  defp hero(assigns) do
    assigns = assign(assigns, BuyKey.offer(assigns.classic))

    ~H"""
    <section id="home-hero" class="rl-hero" aria-labelledby="home-title" data-field-scope>
      <.hex_field id="home-hero-field" class="rl-hero__field" cell={40} />
      <div class="rl-hero__head">
        <h1 id="home-title" class="rl-hero__title">
          A persistent team for <span class="rl-hero__accent">your AI agent.</span>
        </h1>
        <p id="home-lead" class="rl-hero__lead">{lead()}</p>

        <div class="rl-hero__ways">
          <.link
            id="home-watch"
            navigate={Fleets.path(@classic.id)}
            data-step="watch"
            class="rg-button rg-button--primary"
          >
            <span class="rg-button__label">Watch</span>
          </.link>
        </div>

        <div id="home-now" class="rl-now">
          <p id="home-hero-fleet" class="rl-now__label">{@classic.name} now</p>
          <dl id="home-classic-facts" class="rl-facts">
            <div>
              <dt>Keys sold</dt>
              <dd id="home-classic-sold">
                <.sold sales={@classic.sales} failed={@classic.failed?} />
              </dd>
            </div>
            <div>
              <dt>Agents here</dt>
              <dd id="home-classic-agents">
                {if @classic.here, do: grouped(@classic.here), else: "—"}
              </dd>
            </div>
            <div>
              <dt>
                Next Key
                <Regent.Primitives.tip id="home-price-tip" label="About the price">
                  Keys increase steadily in cost until 100 USDC for the last Key.
                </Regent.Primitives.tip>
              </dt>
              <dd id="home-classic-price">{@cost}</dd>
            </div>
          </dl>
          <p :if={@classic.goal} id="home-classic-goal" class="rl-now__goal">
            Working on
            <.link navigate={"#{Fleets.path(@classic.id)}/workspace"}>{@classic.goal}</.link>
          </p>
        </div>
      </div>

      <.buy_key classic={@classic} />
    </section>
    """
  end

  defp lead, do: @lead

  attr :sales, :map, required: true
  attr :failed, :boolean, required: true

  defp sold(%{sales: nil, failed: true} = assigns), do: ~H"—"
  defp sold(%{sales: nil} = assigns), do: ~H"Open soon"
  defp sold(%{sales: %{current?: false}} = assigns), do: ~H"Catching up"
  defp sold(assigns), do: ~H"{grouped(@sales.keys)} of {grouped(@sales.progress.max_supply)}"

  attr :classic, :map, required: true

  # The Key on offer's card art over "Buy Key", and under it one line: the
  # Key's number and price while the sale is open, otherwise the reason the
  # button can't be pressed. While Classic is coming soon the card's tag names
  # the first Key, the one the sale will open with, and a press of the button
  # shakes it and sends nothing. The card and its price tag are the same in
  # every state. Under a mouse the card has dust outside its edge and, when
  # pointed at, a shuffle of a hundred real Keys over the pass (NextKeyCard
  # draws both); the shuffle's picture loads only once the dust shows.
  defp buy_key(assigns) do
    assigns = assign(assigns, BuyKey.offer(assigns.classic))

    ~H"""
    <div id="home-buy" class="rl-buy" data-buy={@state} data-key-preview>
      <div
        id="home-buy-card"
        class="rl-buy__card"
        phx-hook="NextKeyCard"
        aria-hidden="true"
        data-key-card
      >
        <canvas
          id="home-buy-dust"
          class="rl-buy__dust"
          phx-mounted={JS.ignore_attributes(["width", "height"])}
          data-key-dust
        ></canvas>
        <div
          id="home-buy-tilt"
          class="rl-buy__tilt"
          phx-mounted={JS.ignore_attributes(["style"])}
          data-key-tilt
        >
          <img
            id="home-buy-pass"
            phx-mounted={JS.ignore_attributes(["style"])}
            src={~p"/images/home/next-key-pass.webp"}
            width="600"
            height="754"
            alt=""
            fetchpriority="high"
            data-key-pass
          />
          <img
            id="home-buy-shuffle"
            class="rl-buy__shuffle"
            phx-mounted={JS.ignore_attributes(["src", "style"])}
            data-src={~p"/images/home/next-key-shuffle.webp"}
            width="480"
            height="600"
            alt=""
            data-key-shuffle
          />
          <span :if={@price} id="home-buy-tag" class="rl-buy__tag">{@price}</span>
        </div>
      </div>

      <button
        :if={@state == :open}
        id="home-buy-key"
        type="button"
        class="rg-button rg-button--primary rl-buy__button"
        phx-click="open_buy_key"
        aria-haspopup="dialog"
        aria-describedby="home-buy-price"
      >
        <span class="rg-button__label" data-press-label>Buy Key</span>
      </button>
      <Regent.Primitives.button
        :if={@state != :open}
        id="home-buy-key"
        class="rl-buy__button"
        aria-disabled="true"
        aria-describedby="home-buy-why"
      >
        Buy Key
      </Regent.Primitives.button>

      <p :if={@state == :open} id="home-buy-price" class="rl-buy__line">{@price}</p>
      <p :if={@state != :open} id="home-buy-why" class="rl-buy__line">{@why}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, required: true

  attr :cell, :integer,
    required: true,
    doc: "The distance between neighbouring tiles, in CSS pixels."

  # A field of hex tiles behind a section: the stylesheet draws them still,
  # and under a mouse the GPU draws them over that once its first frame has
  # landed. A tile sits on the field's centre.
  defp hex_field(assigns) do
    ~H"""
    <div
      id={@id}
      class={["rl-field", @class]}
      phx-hook="HexField"
      phx-mounted={JS.ignore_attributes(["data-field-ready"])}
      data-field-cell={@cell}
      style={"--rl-cell: #{@cell}px"}
      aria-hidden="true"
    >
      <div class="rl-field__still"></div>
      <canvas id={"#{@id}-canvas"} class="rl-field__canvas" phx-update="ignore" data-field-canvas></canvas>
    </div>
    """
  end
end

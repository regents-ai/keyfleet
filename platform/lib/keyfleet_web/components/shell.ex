defmodule KeyfleetWeb.Components.Shell do
  @moduledoc """
  The app shell: the header, the sidebar and the page with the site's footer at
  its end.

  Every page that has the header holds the "Buy Key" window its "Buy Key"
  opens (`KeyfleetWeb.Components.BuyKey`): the app's pages draw it in the
  `buy_key` slot, the homepage in its own Classic section.

  Signed in, the account's picture and name at the top right open the account
  menu (`Regent.Account.menu`), the same on the app's pages and the homepage: the
  person's picture, name and wallet, the agents paired with the account (the
  `agents` slot), Pair New Agent, the theme switch, Manage Account and Sign
  out. Signed out, with no account menu, the theme switch sits in the header
  instead. Pair New Agent
  opens the pairing window (`pairing_window/1`) over the page; the agents are on
  the Agents page, and the account's wallets and everything else about the
  account are on the Account page. The browser opens and closes the menu (`popover`); following a
  link inside it closes it (`assets/js/account_menu.ts`).
  """

  use KeyfleetWeb, :html

  alias KeyfleetWeb.Components.RegentLinks
  alias KeyfleetWeb.RouteCatalog.RouteTarget

  # Classic is the fleet that sells Keys: once it is open, "Buy Key" in the
  # header opens the "Buy Key" window for it. Until then the header has no
  # "Buy Key".
  @get_key_fleet "fleet_tech_classic"

  @doc "The fleet the header's \"Buy Key\" opens, shown only while it is open."
  def get_key_fleet, do: @get_key_fleet

  attr(:route_spec, :map, required: true)
  attr(:account_control, Keyfleet.AccessContext.AccountControl, required: true)
  attr(:shell_instance, :integer, required: true)
  attr(:get_key, :boolean, required: true)

  slot(:content, required: true)

  # Required, so a page that draws the shell without it does not compile: signed
  # in, it would show a menu without agents. A caller leaves it out for someone
  # signed out with `:if`.
  slot(:agents, required: true, doc: "The agents paired with the account, in the account menu.")
  slot(:buy_key, doc: "The \"Buy Key\" window, while it is open.")

  slot(:pairing_panel,
    doc: "The pairing window's box, signed in, opened by every Pair New Agent."
  )

  def shell(assigns) do
    ~H"""
    <div
      id="app-shell"
      class="rg-sheet rg-frame"
      phx-hook="ShellBehavior"
      data-app={@route_spec.app_id}
      data-variant={KeyfleetWeb.Motion.standard("tabs")}
      data-background={@route_spec.background_slot}
      data-menu-open="false"
      data-route-id={@route_spec.route_id}
      data-destination={@route_spec.destination}
      data-shell-instance={@shell_instance}
    >
      <a class="shell-skip" href="#route-content">Skip to content</a>
      <.header
        account_control={@account_control}
        get_key={@get_key}
        menu
        theme
      >
        <:agents>{render_slot(@agents)}</:agents>
      </.header>

      <nav
        id="shell-sidebar"
        data-panel="drawer"
        aria-label="Context navigation"
        tabindex="-1"
      >
        <Regent.Primitives.button
          variant="quiet"
          type="button"
          class="shell-menu-close"
          data-shell-menu-close
        >
          Close navigation
        </Regent.Primitives.button>
        <ul>
          <li :for={target <- @route_spec.sidebar_model.targets}>
            <.sidebar_target
              target={target}
              route_spec={@route_spec}
              account_control={@account_control}
            />
          </li>
        </ul>
      </nav>

      <Regent.Primitives.button
        variant="quiet"
        type="button"
        class="shell-menu-scrim"
        data-shell-menu-scrim
        data-backdrop
        aria-label="Close navigation"
        hidden
      ></Regent.Primitives.button>

      <div id="app-shell-scroller" tabindex="-1">
        <nav
          :if={@route_spec.tabs != []}
          id="shell-tabs"
          class="shell-tabs"
          aria-label="Account views"
        >
          <.link
            :for={tab <- @route_spec.tabs}
            patch={tab.path}
            aria-current={@route_spec.route_id == tab.route_id && "page"}
          >
            {tab.label}
          </.link>
        </nav>
        <main id="route-content" tabindex="-1">
          {render_slot(@content)}
        </main>
        <KeyfleetWeb.Layouts.product_links theme_toggle={false} />
      </div>

      {render_slot(@buy_key)}

      <.pairing_window :if={@pairing_panel != []}>{render_slot(@pairing_panel)}</.pairing_window>
    </div>
    """
  end

  slot :inner_block, required: true, doc: "the pairing box"

  @doc """
  The pairing window every Pair New Agent opens, in the account menu and on the
  Agents page, over the page the person is on (`assets/js/account_menu.ts`): the
  pairing box, with a close button in its top corner. The app's pages draw it in
  the shell's `pairing_panel` slot, the homepage beside its header.
  """
  def pairing_window(assigns) do
    ~H"""
    <Regent.Structure.dialog
      id="shell-pairing"
      class="shell-pairing-dialog"
      aria-labelledby="shell-pairing-title"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <Regent.Primitives.button
        variant="quiet"
        type="button"
        class="shell-dialog-close"
        aria-label="Close"
        data-pair-close
      >
        <Regent.Icons.icon name="x" />
      </Regent.Primitives.button>
      <h2 id="shell-pairing-title">Pair New Agent</h2>
      {render_slot(@inner_block)}
    </Regent.Structure.dialog>
    """
  end

  attr :id, :string, required: true

  @doc """
  Pair New Agent, opening the pairing window (`pairing_window/1`) over the
  page. Only a signed-in person has the window, so a page shows it only to
  them.
  """
  def pair_button(assigns) do
    ~H"""
    <Regent.Primitives.button
      id={@id}
      type="button"
      variant="secondary"
      arrow={false}
      aria-haspopup="dialog"
      aria-controls="shell-pairing"
      data-pair-open
    >
      Pair New Agent
    </Regent.Primitives.button>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true

  attr :get_key, :boolean,
    required: true,
    doc: "whether the fleet \"Buy Key\" opens is open, so the header shows it"

  attr :menu, :boolean,
    required: true,
    doc: "whether the page has a sidebar the Menu button opens"

  attr :theme, :boolean, required: true, doc: "whether the page offers the theme switch"

  attr :fleets, :boolean,
    default: false,
    doc: "whether a Fleets link to Classic's page follows the signed-in name (the homepage)"

  slot :agents, required: true, doc: "The agents paired with the account, in the account menu."

  @doc """
  The site header: brand, Menu (only where there is a sidebar), the theme
  switch signed out, the Regents crown and links, "Buy Key" (once Classic is
  open), the account control and, signed in, the account menu its name opens,
  with the theme switch as one of its rows. It fits one line on a phone.
  """
  def header(assigns) do
    ~H"""
    <header id="shell-header">
      <.link id="shell-brand" class="shell-brand" href="/" aria-label="Keyfleet">
        <span class="shell-brand__mark" aria-hidden="true">
          <img
            class="shell-brand__mark-light"
            src={~p"/images/brand/mark-flat-light.svg"}
            alt=""
          />
          <img
            class="shell-brand__mark-dark"
            src={~p"/images/brand/mark-flat-dark.svg"}
            alt=""
          />
        </span>
        <span class="shell-brand__name">Keyfleet</span>
      </.link>

      <Regent.Primitives.button
        :if={@menu}
        variant="quiet"
        id="mobile-menu-button"
        class="mobile-menu-button"
        type="button"
        aria-controls="shell-sidebar"
        aria-expanded="false"
      >
        Menu
      </Regent.Primitives.button>

      <span class="shell-spacer" />
      <.theme_toggle
        :if={@theme and @account_control.kind != :signed_in}
        id="theme-control"
        class="shell-header-theme"
      />
      <div class="rl-header-links">
        <RegentLinks.token_menu id="shell-regents-crown" />
        <RegentLinks.header_links id="shell-token-menu" />
      </div>

      <div :if={@get_key} class="shell-get-key">
        <.get_key id="shell-get-key" />
      </div>
      <.account_control account_control={@account_control} fleets={@fleets} />
      <Regent.Account.menu
        :if={@account_control.kind == :signed_in}
        id="account-menu"
        name={@account_control.label}
        wallet={@account_control.wallet}
        ens_name={@account_control.ens_name}
        manage_href={~p"/account"}
        pair_window="shell-pairing"
      >
        <:picture>
          <img
            :if={@account_control.avatar_src}
            src={@account_control.avatar_src}
            referrerpolicy="no-referrer"
            width="40"
            height="40"
            alt=""
          />
        </:picture>
        <:agents>{render_slot(@agents)}</:agents>
        <:theme :if={@theme}>
          <span class="shell-theme-label" aria-hidden="true">Light theme</span>
          <.theme_toggle id="account-menu-theme" />
        </:theme>
      </Regent.Account.menu>
    </header>
    """
  end

  attr :id, :string, required: true

  @doc """
  "Buy Key" in the site header, for everyone, signed in or not, once Classic
  is open: it opens the "Buy Key" window for Classic.
  """
  def get_key(assigns) do
    assigns = assign(assigns, :fleet_id, @get_key_fleet)

    ~H"""
    <button
      id={@id}
      type="button"
      class="rg-button rg-button--primary"
      phx-click="open_buy_key"
      phx-value-fleet={@fleet_id}
      aria-haspopup="dialog"
    >
      <span class="rg-button__label">Buy Key</span>
    </button>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true
  attr :enabled, :boolean, default: true

  attr :menu, :boolean,
    default: true,
    doc: """
    Signed in, the name opens the account menu, which holds Sign out. A page
    without the menu (the Privy workshop page) shows Sign out beside the name.
    """

  attr :fleets, :boolean,
    default: false,
    doc: "Signed in, a Fleets link to Classic's page follows the name."

  @doc """
  The account control: Sign in, or the account's name. auth_lazy.ts drives its
  `data-account-target` markers; the component itself never authenticates anyone.
  """
  def account_control(assigns) do
    ~H"""
    <div id="account-control" class="account-control">
      <Regent.Primitives.button
        :if={@account_control.kind == :sign_in}
        variant="secondary"
        type="button"
        data-account-target="sign-in"
        disabled={!@enabled}
      >
        {@account_control.label}
      </Regent.Primitives.button>
      <button
        :if={@menu and @account_control.kind == :signed_in}
        id="account-chip"
        class="account-chip"
        type="button"
        popovertarget="account-menu"
      >
        <.account_name account_control={@account_control} />
      </button>
      <.link
        :if={@fleets and @account_control.kind == :signed_in}
        id="shell-fleets"
        class="rg-button rg-button--quiet"
        href={Keyfleet.Fleets.path(get_key_fleet())}
      >
        <span class="rg-button__label">Fleets</span>
      </.link>
      <%= if !@menu and @account_control.kind == :signed_in do %>
        <span class="account-chip">
          <.account_name account_control={@account_control} />
        </span>
        <Regent.Primitives.button
          variant="quiet"
          type="button"
          disabled={!@enabled}
          data-account-target="sign-out"
        >
          Sign out
        </Regent.Primitives.button>
      <% end %>
      <p
        id="account-auth-status"
        class="account-auth-status"
        role="status"
        aria-live="polite"
        aria-atomic="true"
        phx-update="ignore"
        hidden
      >
      </p>
    </div>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true

  # The account's picture and name. The `profile` marker tells the browser the
  # page was drawn for a signed-in account.
  defp account_name(assigns) do
    ~H"""
    <img
      :if={@account_control.avatar_src}
      class="account-avatar"
      src={@account_control.avatar_src}
      referrerpolicy="no-referrer"
      width="36"
      height="36"
      alt=""
    />
    <span class="account-name" data-account-target="profile">{@account_control.label}</span>
    """
  end

  # The theme switch's two pictures, row by row from the top: "#" is a block. Both
  # have as many blocks, so every block of the moon flies to exactly one of the
  # sun, and both keep their outer ring clear, where a block would sit under the
  # glass's bevel and smear. The still face draws them, and the browser reads
  # them from there.
  @theme_moon [
    ".............",
    "....##.......",
    "...##.....#..",
    "..##.........",
    ".###.........",
    ".###.....#...",
    ".###.........",
    ".#####.......",
    ".######......",
    "..#########..",
    "...#######...",
    "....#####....",
    "............."
  ]

  @theme_sun [
    ".............",
    ".#....#....#.",
    "..#.......#..",
    ".....###.....",
    "....#####....",
    "...#######...",
    ".#.#######.#.",
    "...#######...",
    "....#####....",
    ".....###.....",
    "..#.......#..",
    ".#....#....#.",
    "............."
  ]

  block_count = fn rows ->
    rows |> Enum.join() |> :binary.matches("#") |> length()
  end

  if block_count.(@theme_moon) != block_count.(@theme_sun) do
    raise ArgumentError, "the theme switch's moon and sun need as many blocks"
  end

  for rows <- [@theme_moon, @theme_sun] do
    if Enum.any?(rows, &(String.length(&1) != length(rows))) do
      raise ArgumentError, "the theme switch's pictures are square"
    end

    ring = [hd(rows), List.last(rows) | Enum.map(rows, &(String.first(&1) <> String.last(&1)))]

    if Enum.any?(ring, &String.contains?(&1, "#")) do
      raise ArgumentError, "the theme switch's pictures keep their outer ring clear"
    end
  end

  attr(:id, :string, required: true)
  attr(:class, :any, default: nil)

  @doc """
  The light and dark theme switch: a button with the role of a switch, on for
  the light theme, with a knob that slides from night on the left to day on the
  right. A press, Enter or Space turns it, and the knob can be dragged; it
  settles on the nearer side when let go.

  Signed in it is a row of the account menu; signed out it sits in the header
  (`header/1`), and on the reading pages, which have no header, in the footer
  (`KeyfleetWeb.Layouts.product_links/1`). A page never shows two.

  The server draws a still face: a flat square track and knob with the moon or
  the sun, each a picture of tiny square blocks, placed for the theme showing. Once
  the browser has drawn a first frame of the glass knob, with the same blocks
  behind it and its light, on the canvas inside (`assets/js/hooks/theme_switch.ts`,
  `assets/js/theme_switch/`), that picture takes over. Without WebGPU, with Less
  motion on or in forced colours the still face stays, and it is a whole working
  switch on its own.

  The browser owns the press: it writes the theme cookie the server reads on
  the next render (`assets/js/theme.ts`), so the switch is left out of
  LiveView's patching, and the attributes the browser writes on it are kept.
  """
  def theme_toggle(assigns) do
    assigns = assign(assigns, moon: @theme_moon, sun: @theme_sun)

    ~H"""
    <div
      id={@id}
      class={["theme-switch", @class]}
      phx-hook="ThemeSwitch"
      phx-update="ignore"
      phx-mounted={JS.ignore_attributes(["data-theme-switch-ready", "style"])}
      data-theme-switch
    >
      <button
        id={"#{@id}-button"}
        class="theme-switch__button"
        type="button"
        role="switch"
        aria-checked="false"
        aria-label="Light theme"
      >
        <span class="theme-switch__still" aria-hidden="true">
          <span class="theme-switch__track" data-theme-switch-track>
            <span class="theme-switch__knob" data-theme-switch-knob>
              <.theme_blocks rows={@moon} class="theme-switch__moon" />
              <.theme_blocks rows={@sun} class="theme-switch__sun" />
            </span>
          </span>
        </span>
        <canvas class="theme-switch__canvas" data-theme-switch-canvas aria-hidden="true"></canvas>
      </button>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :class, :string, required: true

  # One of the switch's pictures, a block for each "#", one unit square apiece
  # with a hairline between neighbours.
  defp theme_blocks(assigns) do
    assigns = assign(assigns, size: length(assigns.rows), blocks: blocks(assigns.rows))

    ~H"""
    <svg
      class={@class}
      viewBox={"0 0 #{@size} #{@size}"}
      shape-rendering="crispEdges"
      aria-hidden="true"
    >
      <g transform="translate(0.06 0.06)">
        <rect :for={{x, y} <- @blocks} x={x} y={y} width="0.88" height="0.88" />
      </g>
    </svg>
    """
  end

  defp blocks(rows) do
    for {row, y} <- Enum.with_index(rows),
        {"#", x} <- Enum.with_index(String.graphemes(row)),
        do: {x, y}
  end

  attr(:target, :map, required: true)
  attr(:route_spec, :map, required: true)
  attr(:account_control, Keyfleet.AccessContext.AccountControl, required: true)

  defp sidebar_target(%{target: %RouteTarget{} = target} = assigns) do
    assigns = assign(assigns, :label, sidebar_label(target, assigns.account_control))

    ~H"""
    <.link
      patch={@target.path}
      aria-current={current?(@target, @route_spec) && "page"}
    >
      {@label}
    </.link>
    """
  end

  # A destination with tabs stays current on every one of its tabs, and a fleet
  # on every one of its pages.
  defp current?(target, route_spec),
    do:
      Enum.any?(
        [
          route_spec.destination,
          fleet_path(route_spec.fleet_id) | Enum.map(route_spec.tabs, & &1.path)
        ],
        &(&1 == target.path)
      )

  defp fleet_path(nil), do: nil
  defp fleet_path(fleet_id), do: Keyfleet.Fleets.path(fleet_id)

  # Signed out, the account page is named as the header's button names it.
  defp sidebar_label(%RouteTarget{route_id: :account}, %{kind: :sign_in, label: label}),
    do: label

  defp sidebar_label(%RouteTarget{label: label}, _account_control), do: label
end

defmodule KeyfleetWeb.Components.Shell do
  @moduledoc """
  The app shell: the header, the sidebar, the page with the site's footer at its
  end and, for someone signed in, the side panel on the right.

  Every page that has the header holds the "Buy Key" window its "Purchase Key"
  opens (`KeyfleetWeb.Components.BuyKey`): the app's pages draw it in the
  `buy_key` slot, the homepage in its own Classic section.

  The side panel is the same on every page that has it, the app's pages and the
  homepage: Sign out, Manage Account (the account page), the account's wallets
  (the `wallets` slot), the agents paired with the account (the `agents` slot)
  and the box to pair an agent (the `pairing` slot).
  The account's name and the panel button in the header open and close it.
  Whether it is open is the browser's (`assets/js/shell_panels.ts` and the
  `keyfleet_aside` cookie, read into `<html data-aside>`), so the server never
  stores it. Open, it sits beside the page, which narrows to make room for it,
  on the app's pages and the homepage alike; on a phone there is no room
  beside the page, so there it opens over the page under the header.
  """

  use Phoenix.Component

  alias KeyfleetWeb.Components.RegentLinks
  alias KeyfleetWeb.RouteCatalog.RouteTarget
  alias Phoenix.LiveView.JS

  # Classic is the fleet that sells Keys: once it is open, "Purchase Key" in the
  # header opens the "Buy Key" window for it. Until then the header has no
  # "Purchase Key".
  @get_key_fleet "fleet_tech_classic"

  @doc "The fleet the header's \"Purchase Key\" opens, shown only while it is open."
  def get_key_fleet, do: @get_key_fleet

  attr(:route_spec, :map, required: true)
  attr(:account_control, Keyfleet.AccessContext.AccountControl, required: true)
  attr(:shell_instance, :integer, required: true)
  attr(:get_key, :boolean, required: true)

  slot(:content, required: true)
  slot(:wallets, doc: "The account's wallets, in the side panel.")
  slot(:agents, doc: "The agents paired with the account, in the side panel.")
  slot(:pairing, doc: "The box to pair an agent, in the side panel.")
  slot(:buy_key, doc: "The \"Buy Key\" window, while it is open.")

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
      />

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
        <KeyfleetWeb.Layouts.product_links />
      </div>

      <.aside account_control={@account_control}>
        <:wallets>{render_slot(@wallets)}</:wallets>
        <:agents>{render_slot(@agents)}</:agents>
        <:pairing :if={@pairing != []}>{render_slot(@pairing)}</:pairing>
      </.aside>

      {render_slot(@buy_key)}
    </div>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true

  attr :get_key, :boolean,
    required: true,
    doc: "whether the fleet \"Purchase Key\" opens is open, so the header shows it"

  attr :menu, :boolean,
    required: true,
    doc: "whether the page has a sidebar the Menu button opens"

  attr :theme, :boolean, required: true, doc: "whether the page offers the theme switch"

  attr :fleets, :boolean,
    default: false,
    doc: "whether a Fleets link to Classic's page follows the signed-in name (the homepage)"

  @doc """
  The site header: brand, Menu (only where there is a sidebar), the theme
  switch (not on the always-dark homepage), the Regents crown and links,
  "Purchase Key" (once Classic is open) and the account control. It fits one
  line on a phone.
  """
  def header(assigns) do
    ~H"""
    <header id="shell-header">
      <.link id="shell-brand" class="shell-brand" href="/" aria-label="Keyfleet">
        <span class="shell-brand__mark" aria-hidden="true">
          <img
            class="shell-brand__mark-light"
            src="/images/brand/mark-flat-light.svg"
            alt=""
          />
          <img
            class="shell-brand__mark-dark"
            src="/images/brand/mark-flat-dark.svg"
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
      <.theme_toggle :if={@theme} id="theme-control" />
      <div class="rl-header-links">
        <RegentLinks.token_menu id="shell-regents-crown" />
        <RegentLinks.header_links id="shell-token-menu" />
      </div>

      <div :if={@get_key} class="shell-get-key">
        <.get_key id="shell-get-key" />
      </div>
      <.account_control account_control={@account_control} fleets={@fleets} />
      <button
        :if={@account_control.kind == :signed_in}
        id="shell-aside-button"
        class="shell-tool shell-aside-button"
        type="button"
        aria-controls="shell-aside"
        aria-expanded="false"
        aria-label="Side panel"
        data-aside-toggle
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <svg
          class="shell-icon"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="square"
          stroke-linejoin="miter"
          aria-hidden="true"
        >
          <path d="M3 4h18v16H3zM15 4v16" />
        </svg>
        <span class="shell-tool__tip" aria-hidden="true">Side panel</span>
      </button>
    </header>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true

  slot :wallets, doc: "The account's wallets."
  slot :agents, doc: "The agents paired with the account."
  slot :pairing, doc: "The box to pair an agent."

  @doc """
  The side panel, for someone signed in: Sign out and Manage Account, the
  account's wallets, its agents and the box to pair a new one.
  """
  def aside(assigns) do
    ~H"""
    <aside
      :if={@account_control.kind == :signed_in}
      id="shell-aside"
      aria-label="Your account and agents"
      tabindex="-1"
    >
      <div id="shell-account" class="shell-aside__head">
        <Regent.Primitives.button variant="secondary" type="button" data-account-target="sign-out">
          Sign out
        </Regent.Primitives.button>
        <.link navigate="/account" class="rg-button rg-button--secondary">
          <span class="rg-button__label">Manage Account</span>
        </.link>
      </div>

      {render_slot(@wallets)}

      {render_slot(@agents)}

      <section :if={@pairing != []} id="shell-pairing" aria-labelledby="shell-pairing-title">
        <h2 id="shell-pairing-title">Pair New Agent</h2>
        {render_slot(@pairing)}
      </section>
    </aside>
    """
  end

  attr :id, :string, required: true

  @doc """
  "Purchase Key" in the site header, for everyone, signed in or not, once Classic
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
      <span class="rg-button__label">Purchase Key</span>
    </button>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true
  attr :enabled, :boolean, default: true

  attr :panel, :boolean,
    default: true,
    doc: """
    Signed in, the name opens the side panel, which holds Sign out. A page
    without the side panel (the Privy workshop page) shows Sign out beside the name.
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
        :if={@panel and @account_control.kind == :signed_in}
        id="account-chip"
        class="account-chip"
        type="button"
        aria-controls="shell-aside"
        aria-expanded="false"
        data-aside-toggle
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
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
      <%= if !@panel and @account_control.kind == :signed_in do %>
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

  attr(:id, :string, required: true)

  @doc """
  The colour theme switch: one control that flips between the two themes.

  It names the theme showing by itself, from the page's theme, so the server
  passes no theme. The browser owns the press: it writes
  the theme cookie the server reads on the next render and restyles the page, so
  the control is left out of LiveView's patching.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div id={@id} class="theme-control" phx-update="ignore">
      <Regent.ThemeToggle.button id={"#{@id}-button"} data-theme-toggle />
    </div>
    """
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

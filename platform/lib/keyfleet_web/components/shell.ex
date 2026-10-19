defmodule KeyfleetWeb.Components.Shell do
  @moduledoc "Semantic presentation seam for Ash-owned shell behavior."

  use Phoenix.Component

  alias KeyfleetWeb.Components.RegentLinks
  alias KeyfleetWeb.RouteCatalog.{NameOnly, RouteTarget}
  alias Phoenix.LiveView.JS

  # Classic is the fleet that sells Keys: once it is open, "Get a Key" in the
  # header opens its page with its own "Get a Key" pressed
  # (`KeyfleetWeb.FleetLive`), or on the homepage its "Buy Key" window. Until
  # then the header has no "Get a Key".
  @get_key_fleet "fleet_tech_classic"

  @doc "The fleet the header's \"Get a Key\" opens, shown only while it is open."
  def get_key_fleet, do: @get_key_fleet

  attr(:route_spec, :map, required: true)
  attr(:account_control, Keyfleet.AccessContext.AccountControl, required: true)
  attr(:shell_instance, :integer, required: true)
  attr(:get_key, :boolean, required: true)

  attr(:credits, :map,
    default: nil,
    doc: "The account's Credits reading (`state` and `value`); nil when signed out."
  )

  slot(:content, required: true)
  slot(:credits_panel, doc: "The Buy Credits panel, opened from the header's balance.")

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
        get_key_link={:patch}
        credits={@credits}
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
      </div>

      <dialog
        :if={@credits_panel != []}
        id="shell-credits"
        class="shell-credits-dialog"
        aria-label="Buy Credits"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <Regent.Primitives.button
          variant="quiet"
          type="button"
          class="shell-credits-dialog__close"
          aria-label="Close"
          data-credits-close
        >
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </Regent.Primitives.button>
        {render_slot(@credits_panel)}
      </dialog>
    </div>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true

  attr :get_key, :boolean,
    required: true,
    doc: "whether the fleet \"Get a Key\" opens is open, so the header shows it"

  attr :get_key_link, :atom,
    required: true,
    values: [:patch, :navigate, :buy_key],
    doc:
      "`:patch` inside the app shell, `:buy_key` on the homepage, `:navigate` from any other page"

  attr :menu, :boolean,
    required: true,
    doc: "whether the page has a sidebar the Menu button opens"

  attr :theme, :boolean, required: true, doc: "whether the page offers the theme switch"

  attr :credits, :map,
    default: nil,
    doc:
      "The account's Credits reading, shown as the balance that opens Buy Credits; nil hides it."

  @doc """
  The site header: brand, Menu (only where there is a sidebar), the theme
  switch (not on the always-dark homepage), links, "Get a Key" (once Classic
  is open), the Credits balance (inside the app, signed in) and the account
  control. It fits one line on a phone.
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
        <RegentLinks.header_links id="shell-token-menu" />
      </div>

      <div :if={@get_key} class="shell-get-key">
        <.get_key id="shell-get-key" link={@get_key_link} />
      </div>
      <button
        :if={@credits}
        id="shell-credits-button"
        class="shell-credits"
        type="button"
        aria-haspopup="dialog"
        aria-controls="shell-credits"
        aria-label={credits_label(@credits)}
        phx-hook="MotionCount"
        data-variant="flash"
      >
        <.credits_amount amount={@credits} />
      </button>
      <.account_control account_control={@account_control} />
    </header>
    """
  end

  defp credits_label(%{state: :ready, value: balance}),
    do: RegentCredits.Amount.format(balance.available)

  defp credits_label(%{state: state}) when state in [:error, :stale], do: "Credits unavailable"
  defp credits_label(_reading), do: "Credits loading"

  attr :amount, :map, required: true

  # "12.40 Credits", whose unit a phone's header leaves out for room. Only a
  # balance just read shows; while it is read again, or when it can't be, the
  # figure is a dash. The button and the Buy Credits panel behind it are there
  # either way.
  defp credits_amount(%{amount: %{state: :ready, value: balance}} = assigns) do
    [number, unit] = String.split(RegentCredits.Amount.format(balance.available), " ", parts: 2)
    assigns = assign(assigns, number: number, unit: unit)

    ~H"""
    <span data-count>{@number}</span> <span class="shell-credits__unit">{@unit}</span>
    """
  end

  defp credits_amount(assigns) do
    ~H"""
    <span data-count>—</span> <span class="shell-credits__unit">Credits</span>
    """
  end

  attr :id, :string, required: true

  attr :link, :atom,
    required: true,
    values: [:patch, :navigate, :buy_key],
    doc:
      "`:patch` from the app's own pages, `:buy_key` on the homepage, which opens its \"Buy Key\" window, `:navigate` from any other"

  @doc """
  "Get a Key" in the site header, for everyone, signed in or not, once Classic
  is open: it opens Classic's page with its buying panel open, or on the
  homepage its "Buy Key" window.
  """
  def get_key(%{link: :buy_key} = assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="rg-button rg-button--primary"
      phx-click="open_buy_key"
      aria-haspopup="dialog"
    >
      <span class="rg-button__label">Get a Key</span>
    </button>
    """
  end

  def get_key(assigns) do
    assigns =
      assign(assigns, :to, [{assigns.link, Keyfleet.Fleets.path(@get_key_fleet) <> "?buy"}])

    ~H"""
    <.link id={@id} class="rg-button rg-button--primary" {@to}>
      <span class="rg-button__label">Get a Key</span>
    </.link>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true
  attr :enabled, :boolean, default: true

  @doc """
  The account control: Sign in, or the account's name with Sign out beside it.
  auth_lazy.ts drives its `data-account-target` markers; the component itself
  never authenticates anyone.
  """
  def account_control(assigns) do
    ~H"""
    <div id="account-control" class="account-control">
      <Regent.Primitives.button
        :if={@account_control.kind == :sign_in}
        type="button"
        data-account-target="sign-in"
        disabled={!@enabled}
      >
        {@account_control.label}
      </Regent.Primitives.button>
      <span :if={@account_control.kind == :signed_in} class="account-chip">
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
      </span>
      <Regent.Primitives.button
        :if={@account_control.kind == :signed_in}
        variant="quiet"
        type="button"
        disabled={!@enabled}
        data-account-target="sign-out"
      >
        Sign out
      </Regent.Primitives.button>
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

  attr(:id, :string, required: true)

  @doc """
  The colour theme switch: one control that flips between the two themes.

  It names the theme showing by itself, from the page's theme or the device's
  setting, so the server passes no theme. The browser owns the press: it writes
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

  defp sidebar_target(%{target: %NameOnly{}} = assigns) do
    ~H"""
    <span>{@target.label}</span>
    """
  end

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

  # A destination with tabs stays current on every one of its tabs.
  defp current?(target, route_spec),
    do:
      Enum.any?(
        [route_spec.destination | Enum.map(route_spec.tabs, & &1.path)],
        &(&1 == target.path)
      )

  # Signed out, the account page is named as the header's button names it.
  defp sidebar_label(%RouteTarget{route_id: :account}, %{kind: :sign_in, label: label}),
    do: label

  defp sidebar_label(%RouteTarget{label: label}, _account_control), do: label
end

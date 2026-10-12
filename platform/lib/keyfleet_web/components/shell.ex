defmodule KeyfleetWeb.Components.Shell do
  @moduledoc "Semantic presentation seam for Ash-owned shell behavior."

  use Phoenix.Component

  alias KeyfleetWeb.Components.RegentLinks
  alias KeyfleetWeb.RouteCatalog.RouteTarget

  # Classic is the fleet that sells Keys: once it is open, "Get a Key" in the
  # header opens its page with its own "Get a Key" pressed
  # (`KeyfleetWeb.FleetLive`). Until then the header has no "Get a Key".
  @get_key_fleet "fleet_tech_classic"
  @get_key_path "/app/fleets/#{@get_key_fleet}?buy"

  @doc "The fleet the header's \"Get a Key\" opens, shown only while it is open."
  def get_key_fleet, do: @get_key_fleet

  attr(:route_spec, :map, required: true)
  attr(:account_control, Keyfleet.AccessContext.AccountControl, required: true)
  attr(:shell_instance, :integer, required: true)
  attr(:get_key, :boolean, required: true)
  slot(:content, required: true)

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
      <.header account_control={@account_control} get_key={@get_key} get_key_link={:patch} menu theme />

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
        <main id="route-content" tabindex="-1">
          {render_slot(@content)}
        </main>
      </div>
    </div>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true

  attr :get_key, :boolean,
    required: true,
    doc: "whether the fleet \"Get a Key\" opens is open, so the header shows it"

  attr :get_key_link, :atom,
    required: true,
    values: [:patch, :navigate],
    doc: "`:patch` inside the app shell, `:navigate` from any other page"

  attr :menu, :boolean,
    required: true,
    doc: "whether the page has a sidebar the Menu button opens"

  attr :theme, :boolean, required: true, doc: "whether the page offers the theme switch"

  @doc """
  The site header: brand, Menu (only where there is a sidebar), the theme
  switch (not on the always-dark homepage), links, "Get a Key" (once Classic
  is open) and the account control. It fits one line on a phone.
  """
  def header(assigns) do
    ~H"""
    <header id="shell-header">
      <.link id="shell-brand" class="shell-brand" href="/">
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
      <.account_control account_control={@account_control} />
    </header>
    """
  end

  attr :id, :string, required: true

  attr :link, :atom,
    required: true,
    values: [:patch, :navigate],
    doc: "`:patch` from the app's own pages, `:navigate` from any other"

  @doc """
  "Get a Key" in the site header, for everyone, signed in or not, once Classic
  is open: it opens Classic's page with its buying panel open.
  """
  def get_key(assigns) do
    assigns = assign(assigns, :to, [{assigns.link, @get_key_path}])

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

  defp sidebar_target(%{target: %RouteTarget{} = target} = assigns) do
    assigns = assign(assigns, :label, sidebar_label(target, assigns.account_control))

    ~H"""
    <.link
      patch={@target.path}
      aria-current={if @route_spec.destination == @target.path, do: "page"}
    >
      {@label}
    </.link>
    """
  end

  # Signed out, the account page is named as the header's button names it.
  defp sidebar_label(%RouteTarget{route_id: :account}, %{kind: :sign_in, label: label}),
    do: label

  defp sidebar_label(%RouteTarget{label: label}, _account_control), do: label
end

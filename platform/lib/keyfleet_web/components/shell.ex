defmodule KeyfleetWeb.Components.Shell do
  @moduledoc "Semantic presentation seam for Ash-owned shell behavior."

  use Phoenix.Component

  alias KeyfleetWeb.Components.RegentLinks
  alias KeyfleetWeb.RouteCatalog.{RouteTarget, SidebarHeading}
  alias Phoenix.LiveView.JS

  attr(:route_spec, :map, required: true)
  attr(:account_control, Keyfleet.AccessContext.AccountControl, required: true)
  attr(:shell_instance, :integer, required: true)
  attr(:theme, :string, required: true)
  slot(:content, required: true)

  def shell(assigns) do
    ~H"""
    <div
      id="app-shell"
      class="rg-sheet rg-frame"
      phx-hook="ShellBehavior"
      data-app={@route_spec.app_id}
      data-motion-app={@route_spec.app_id}
      data-background={@route_spec.background_slot}
      data-content-transition={@route_spec.content_transition_kind}
      data-menu-open="false"
      data-route-id={@route_spec.route_id}
      data-destination={@route_spec.destination}
      data-shell-instance={@shell_instance}
    >
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
        <.theme_toggle id="theme-control" theme={@theme} />
        <div class="rl-header-links">
          <RegentLinks.header_links id="shell-token-menu" />
        </div>

        <.account_control account_control={@account_control} />
      </header>

      <nav
        id="shell-sidebar"
        data-motion-region
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
            <.sidebar_target target={target} route_spec={@route_spec} />
          </li>
        </ul>
      </nav>

      <Regent.Primitives.button
        variant="quiet"
        type="button"
        class="shell-menu-scrim"
        data-shell-menu-scrim
        aria-label="Close navigation"
        hidden
      ></Regent.Primitives.button>

      <div id="app-shell-scroller" tabindex="-1">
        <main id="route-content" data-motion-region>
          {render_slot(@content)}
        </main>
      </div>
    </div>
    """
  end

  attr :account_control, Keyfleet.AccessContext.AccountControl, required: true
  attr :enabled, :boolean, default: true

  @doc """
  The real account control, also rendered by the local Privy reference.
  These markers are consumed by auth_lazy.ts; this component never authenticates
  a user itself. The caller supplies the server-verified account presentation.
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
      <details :if={@account_control.kind == :signed_in} id="account-menu">
        <summary>
          <img
            :if={@account_control.avatar_src}
            class="account-avatar"
            src={@account_control.avatar_src}
            referrerpolicy="no-referrer"
            width="36"
            height="36"
            alt=""
          />
          <span data-account-target="profile">{@account_control.label}</span>
          <span class="shell-chevron" aria-hidden="true">⌄</span>
        </summary>
        <div
          class="account-menu__content shell-popover"
          data-panel="menu"
          phx-mounted={JS.ignore_attributes(["style"])}
        >
          <.link
            patch="/account"
            class="account-menu__row account-menu__row--account"
            data-account-menu-item="account"
          >
            <.account_menu_icon name={:settings} /><span>Account</span>
          </.link>
          <Regent.Primitives.button
            variant="quiet"
            type="button"
            disabled={!@enabled}
            class="account-menu__row account-menu__row--danger"
            data-account-menu-item="disconnect"
            data-account-target="sign-out"
          >
            <.account_menu_icon name={:logout} /><span>Disconnect</span>
          </Regent.Primitives.button>
        </div>
      </details>
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
  attr(:theme, :string, required: true)

  @doc """
  The colour theme switch: one control that flips between the two themes.

  The browser owns its state. It writes the theme cookie the server reads on the
  next render, and restates the current theme here on load and after every live
  navigation, so the control is left out of LiveView's patching. The server
  renders the theme it just served, so the control reads correctly before any
  script runs and for anyone browsing without one.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div id={@id} class="theme-control" phx-update="ignore">
      <Regent.ThemeToggle.button id={"#{@id}-button"} theme={@theme} data-theme-toggle />
    </div>
    """
  end

  attr(:target, :map, required: true)
  attr(:route_spec, :map, required: true)

  defp sidebar_target(%{target: %RouteTarget{} = target} = assigns) do
    assigns = assign(assigns, :target, target)

    ~H"""
    <.link
      patch={@target.path}
      aria-current={if @route_spec.destination == @target.path, do: "page"}
    >
      {@target.label}
    </.link>
    """
  end

  defp sidebar_target(%{target: %SidebarHeading{} = heading} = assigns) do
    assigns = assign(assigns, :heading, heading)

    ~H"""
    <span class="shell-sidebar__heading">{@heading.label}</span>
    """
  end

  attr(:name, :atom, required: true)

  defp account_menu_icon(assigns) do
    ~H"""
    <svg
      class="account-menu__icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="square"
      stroke-linejoin="miter"
      aria-hidden="true"
    >
      <g :if={@name == :settings}>
        <circle cx="12" cy="12" r="3" />
        <path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M19.1 4.9 17 7M7 17l-2.1 2.1" />
      </g>
      <g :if={@name == :logout}>
        <path d="M10 4H4v16h6M14 8l4 4-4 4M8 12h10" />
      </g>
    </svg>
    """
  end
end

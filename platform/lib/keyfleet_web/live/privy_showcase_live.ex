defmodule KeyfleetWeb.PrivyShowcaseLive do
  @moduledoc """
  Local, executable reference for the Privy integration.

  The router supplies BOTH LocalOnly and the ordinary trusted Session hook.
  Shell.account_control/1 and data-account-target use the production auth_lazy.ts
  dispatcher. PrivyShowcase only observes the existing wallet store and publishes
  its selected address; it never creates a provider, session, signature or payment.
  """
  use KeyfleetWeb, :live_view

  alias KeyfleetWeb.Components.Shell
  alias KeyfleetWeb.ShowcaseLive
  alias Regent.Primitives, as: P

  @wallet ~r/\A0x[0-9a-fA-F]{40}\z/

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(KeyfleetWeb.PublicDocuments.page("/showcase/privy"))
     |> assign(
       mode: ShowcaseLive.privy_mode(),
       wallet: nil
     ), layout: false}
  end

  def render(assigns) do
    ~H"""
    <link rel="stylesheet" href="/showcase/style.css" />
    <main
      id="privy-reference"
      class="sc privy-reference"
      phx-hook="PrivyShowcase"
      data-privy-enabled={to_string(@mode == :configured)}
    >
      <header class="sc-header privy-reference-header">
        <a class="sc-wordmark" href="/showcase">Ash <span>Workshop</span></a>
        <span class="sc-local">Local only · read-only wallet data</span>
        <%!-- Same markup and event markers as the site header. No second auth handler. --%>
        <Shell.account_control
          account_control={@account_control}
          enabled={@mode == :configured}
          panel={false}
        />
        <Shell.theme_toggle id="privy-reference-theme" />
      </header>

      <div class="privy-reference-content">
        <section class="privy-reference-intro">
          <p class="sc-eyebrow">Working reference</p>
          <h1>Privy integration</h1>
          <p>
            Sign in once, connect the wallet you want to use, and watch the selection arrive without replacing this page.
          </p>
          <p>No transaction or extra signature is requested by the panels below.</p>
          <P.button
            type="button"
            disabled={@mode != :configured}
            data-account-target={
              if @account_control.kind == :signed_in, do: "connect-wallet", else: "sign-in"
            }
          >
            <span data-press-label>
              {if @account_control.kind == :signed_in,
                do: "Connect or change wallet",
                else: "Sign in with Privy"}
            </span>
          </P.button>
          <p :if={@mode == :unconfigured} role="status">
            Configure the local Privy app and verification key before using these controls. Nothing is simulated.
          </p>
          <p :if={@mode == :fixture} role="status">
            This server uses a test verifier. Readouts are test data; real sign-in is disabled here.
          </p>
        </section>

        <section class="rg-panel rg-panel--surface" aria-labelledby="privy-state-heading">
          <h2 id="privy-state-heading">Account and wallet</h2>
          <dl class="privy-reference-facts">
            <div>
              <dt>Session</dt><dd id="privy-session-state">
                {if @account_control.kind == :signed_in, do: "Signed in", else: "Signed out"}
              </dd>
            </div>
            <div>
              <dt>Account</dt><dd>{@account_control.label}</dd>
            </div>
            <div>
              <dt>Selected connected wallet</dt><dd id="privy-selected-wallet">
                {@wallet || "No wallet selected"}
              </dd>
            </div>
          </dl>
          <P.button
            type="button"
            disabled={@mode != :configured}
            data-account-target={
              if @account_control.kind == :signed_in, do: "connect-wallet", else: "sign-in"
            }
          >
            <span data-press-label>Connect wallet</span>
          </P.button>
          <p>
            Signing in and having a transaction-ready wallet are separate states. Sign out in the header clears this wallet selection.
          </p>
        </section>

        <section
          class="rg-panel rg-panel--surface privy-reference-setup"
          aria-labelledby="privy-setup-heading"
        >
          <h2 id="privy-setup-heading">Setup and source map</h2>
          <ol>
            <li>Enable wallet login in your Privy app and admit your exact localhost origin.</li>
            <li>
              Provide <code>PRIVY_APP_ID</code>
              and <code>PRIVY_VERIFICATION_KEY</code>
              to the development process. Never put an app secret in browser code.
            </li>
            <li>
              Create your local PostgreSQL database (<code>keyfleet_dev</code>
              by default), then run <code>mix keyfleet.setup_local_auth</code>. Use <code>MIX_ENV=dev</code>, not a browser-test server, for real sign-in.
            </li>
            <li>
              Build the assets with <code>mix assets.build</code>, start <code>mix phx.server</code>, then open <code>/showcase/privy</code>.
            </li>
          </ol>
          <details>
            <summary>Which file owns each step?</summary>
            <ul>
              <li>
                <code>components/shell.ex · account_control/1</code>: the shared header markup.
              </li>
              <li>
                <code>assets/js/auth_lazy.ts</code>: one document-level button dispatcher and server-session coordination.
              </li>
              <li>
                <code>assets/js/privy_bridge.tsx</code>: the existing Privy SDK hooks, selection and logout handling.
              </li>
              <li>
                <code>assets/js/hooks/privy_showcase.ts</code>: observes wallet state; no authentication implementation.
              </li>
              <li>
                <code>live/privy_showcase_live.ex</code>: this page's wallet selection readout.
              </li>
              <li>
                <code>live/session.ex</code>: verified server identity; browser wallet addresses do not grant authority.
              </li>
            </ul>
          </details>
          <p>
            Shared presentation lives in <code>design-system/regent_ui</code>. Shared identity lives in <code>regents/identity</code>; token verification lives in <code>elixir-utils/privy</code>. The browser integration shown here belongs to this product.
          </p>
          <a
            href="https://docs.privy.io/authentication/user-authentication/logout"
            target="_blank"
            rel="noopener noreferrer"
          >Privy logout documentation ↗</a>
        </section>
      </div>
    </main>
    """
  end

  # The address is a public read target, never proof of authentication. Session
  # authority is independently supplied and rechecked by Live.Session.
  def handle_event("privy_wallet_changed", %{"address" => address}, socket),
    do: {:noreply, assign(socket, :wallet, normalize_wallet(address))}

  defp normalize_wallet(address) when is_binary(address) do
    if Regex.match?(@wallet, address), do: String.downcase(address)
  end

  defp normalize_wallet(_address), do: nil
end

defmodule KeyFleetWeb.OverviewLive do
  @moduledoc """
  The first page inside the shell. It renders for everyone; a signed-in person
  sees their own name, an anonymous visitor sees the way in.
  """

  use Phoenix.Component

  attr :account_control, KeyFleet.AccessContext.AccountControl, required: true
  attr :account, :map, default: nil

  def page(assigns) do
    ~H"""
    <section id="overview-page" class="overview-page">
      <header class="overview-heading">
        <p class="overview-kicker">KeyFleet</p>
        <h1 id="overview-heading" tabindex="-1">Welcome.</h1>
        <p class="overview-lede">
          This is the signed-in home of the product. Replace this page with the first
          thing your customers should see once they are in.
        </p>
      </header>

      <div class="overview-grid">
        <section
          :if={@account}
          class="overview-panel"
          aria-labelledby="overview-signed-in-title"
        >
          <h2 id="overview-signed-in-title">Signed in as {@account_control.label}</h2>
          <p>Your wallets and connected accounts are on your account page.</p>
          <.link patch="/account" class="rg-button">
            <span class="rg-button__label">Open account</span>
          </.link>
        </section>

        <section
          :if={is_nil(@account)}
          class="overview-panel"
          aria-labelledby="overview-sign-in-title"
        >
          <h2 id="overview-sign-in-title">Sign in to get started</h2>
          <p>Connect a wallet to create your account. Nothing is stored until you do.</p>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </section>

        <section
          class="overview-panel"
          aria-labelledby="overview-agents-title"
        >
          <h2 id="overview-agents-title">For developers and agents</h2>
          <p>The public documentation, the agent guide and the OpenAPI description.</p>
          <nav class="overview-links" aria-label="Developer links">
            <a href="/docs">Documentation</a>
            <a href="/llms.txt">Agent guide</a>
            <a href="/openapi.json">OpenAPI</a>
          </nav>
        </section>
      </div>
    </section>
    """
  end
end

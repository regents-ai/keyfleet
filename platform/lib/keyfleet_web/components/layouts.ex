defmodule KeyfleetWeb.Layouts do
  @moduledoc """
  Root document layouts: `root` for the public pages and the persistent shell,
  and `early` for the early-access page, which loads the stylesheet and the key
  roller's script.
  """

  use KeyfleetWeb, :html

  embed_templates("layouts/*")

  attr(:flash, :map, required: true)
  attr(:inner_content, :any, required: true)

  def app(assigns) do
    ~H"""
    {@inner_content}
    <div id="flash-region" aria-live="polite">
      <Regent.Primitives.notice :if={message = Phoenix.Flash.get(@flash, :info)}>
        {message}
      </Regent.Primitives.notice>
      <Regent.Primitives.notice :if={message = Phoenix.Flash.get(@flash, :error)} tone="error">
        {message}
      </Regent.Primitives.notice>
    </div>
    """
  end

  # REGENT on Base, the token every Regent site names in its footer.
  @buy_regent "https://app.uniswap.org/explore/tokens/base/0x6f89bcA4eA5931EdFCB09786267b251DeE752b07"

  attr :theme_toggle, :boolean,
    default: true,
    doc: "false on the home page, whose header already has the theme switch"

  @doc """
  The footer of the home page and every public page, the same on every Regent site:
  the social links, Buy $REGENT and the site's documents. Below a public page it
  sits at the foot of the screen however short the page is.
  """
  def product_links(assigns) do
    assigns = assign(assigns, :buy_regent, @buy_regent)

    ~H"""
    <footer class="regent-footer">
      <div class="regent-footer__social">
        <KeyfleetWeb.Components.RegentLinks.header_links id="footer-brand-links" />
        <KeyfleetWeb.Components.Shell.theme_toggle
          :if={@theme_toggle}
          id="footer-theme-control"
        />
      </div>
      <nav class="regent-footer__links" aria-label="About Keyfleet">
        <a href={@buy_regent} target="_blank" rel="noopener noreferrer">Buy $REGENT</a>
        <a href={~p"/docs"}>Docs</a>
        <a href={~p"/about"}>About</a>
        <a href={~p"/contact"}>Contact</a>
        <a href={~p"/privacy"}>Privacy</a>
        <a href={~p"/terms"}>Terms</a>
      </nav>
      <p>© 2026 Regents Labs</p>
    </footer>
    """
  end
end

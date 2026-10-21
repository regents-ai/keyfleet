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

  # The dock is the polite live region and is always on the page, so a note
  # that arrives in it is read out; one that arrived with its own region would
  # often go unread. An error note is also an alert, read out at once.
  def app(assigns) do
    ~H"""
    {@inner_content}
    <div
      id="flash-region"
      class="toast-dock"
      aria-live="polite"
      phx-hook="MotionList"
      data-variant={KeyfleetWeb.Motion.standard("toast")}
      data-layout-id="flash-region"
      data-children="[data-toast]"
    >
      <.toast :if={message = Phoenix.Flash.get(@flash, :info)} kind="info">
        {message}
      </.toast>
      <.toast :if={message = Phoenix.Flash.get(@flash, :error)} kind="error">
        {message}
      </.toast>
    </div>
    """
  end

  attr(:kind, :string, required: true, values: ~w(info error))
  slot(:inner_block, required: true)

  # One note in the corner, read out when it arrives: politely, through the
  # dock, or at once for an error. Either stays until it is dismissed or the
  # page moves on.
  defp toast(assigns) do
    ~H"""
    <div
      id={"flash-#{@kind}"}
      class="toast"
      role={@kind == "error" && "alert"}
      data-toast
      data-layout-id={"flash-#{@kind}"}
    >
      <Regent.Primitives.notice tone={@kind} class="toast__notice">
        {render_slot(@inner_block)}
      </Regent.Primitives.notice>
      <button
        type="button"
        class="toast__dismiss"
        aria-label="Dismiss"
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "#flash-#{@kind}")}
      >
        ×
      </button>
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
  sits at the foot of the screen however short the page is; the app's pages
  (`KeyfleetWeb.Components.Shell`) end with it inside their scrolling page.
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
        <a href={~p"/about"}>About</a>
        <a href={~p"/docs"}>Developer docs</a>
        <button type="button" class="regent-footer__guide" popovertarget="footer-agent-guide">
          Agent guide
        </button>
        <div id="footer-agent-guide" class="rg-tip-body regent-footer__guide-body" popover>
          <p>Give your agent one of these.</p>
          <a href={~p"/agents.md"}>What agents can do here</a>
          <a href={~p"/llms.txt"}>The whole site in brief</a>
        </div>
        <a href={~p"/contact"}>Contact</a>
        <span class="regent-footer__legal">
          <a href={~p"/privacy"}>Privacy policy</a>
          <a href={~p"/terms"}>Terms of use</a>
        </span>
      </nav>
      <p>© 2026 Regents Labs</p>
    </footer>
    """
  end
end

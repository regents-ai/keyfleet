defmodule KeyfleetWeb.LegalController do
  @moduledoc "Serves the public Privacy Policy and Terms of Use."

  use KeyfleetWeb, :controller

  def privacy(conn, _params), do: show(conn, :privacy)
  def terms(conn, _params), do: show(conn, :terms)

  defp show(conn, id) do
    document = Keyfleet.Legal.document(id)
    render(conn, :show, page_title: document.title, document: document)
  end
end

defmodule KeyfleetWeb.LegalHTML do
  @moduledoc false

  use KeyfleetWeb, :html

  def show(assigns) do
    ~H"""
    <div class="rl-root legal-root rg-sheet rg-frame">
      <header class="legal-header">
        <a href={~p"/"} class="legal-home">Keyfleet</a>
        <nav class="legal-nav" aria-label="Legal">
          <a href={~p"/privacy"} aria-current={if(@document.id == :privacy, do: "page")}>
            Privacy
          </a>
          <a href={~p"/terms"} aria-current={if(@document.id == :terms, do: "page")}>Terms</a>
        </nav>
      </header>
      <main class="legal-page">
        {@document.html}
      </main>
    </div>
    """
  end
end

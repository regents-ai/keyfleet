defmodule KeyfleetWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use KeyfleetWeb, :html

  def render(template, assigns) do
    assigns = assigns |> Map.new() |> Map.put_new(:__changed__, nil)

    cookie_theme =
      case assigns[:conn] do
        %Plug.Conn{} = conn -> Plug.Conn.fetch_cookies(conn).req_cookies["regent_theme"]
        _ -> nil
      end

    theme = Enum.find([assigns[:theme], cookie_theme], "light", &(&1 in ["light", "dark"]))

    assigns =
      assign(assigns,
        title: headline(template),
        theme: theme,
        retry: retry?(template, assigns[:conn])
      )

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-brand="platform" data-theme={@theme}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title} · Keyfleet</title>
        <link rel="stylesheet" href="/assets/js/app.css" />
      </head>
      <body>
        <Regent.Utility.page title={@title} context="Keyfleet" id="error-page">
          <p :if={@retry}>It’s on our side. Try again in a moment.</p>
          <:actions>
            <a :if={@retry} class="rg-button rg-button--primary" href="">Try again</a>
            <a class={["rg-button", @retry && "rg-button--secondary"]} href="/">Go to the homepage</a>
          </:actions>
          <:note>
            <nav aria-label="Recovery links">
              <ul class="rg-utility__links">
                <li :for={{label, path} <- links()}>
                  <a href={path}>{label}</a>
                </li>
              </ul>
            </nav>
          </:note>
        </Regent.Utility.page>
      </body>
    </html>
    """
  end

  # The homepage is the button, so the links under it are the other ways on.
  defp links, do: Enum.reject(KeyfleetWeb.PublicDocuments.recovery_links(), &match?({_, "/"}, &1))

  defp headline("404" <> _format), do: "We can’t find that page"
  defp headline(_template), do: "Something went wrong"

  # A server fault on a page someone opened can be tried again by loading it
  # afresh; anything sent with a form is not sent again by a link.
  defp retry?("5" <> _format, %Plug.Conn{method: "GET"}), do: true
  defp retry?(_template, _conn), do: false
end

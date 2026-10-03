defmodule KeyfleetWeb do
  @moduledoc """
  The entry point for the web interface: `use KeyfleetWeb, :controller`,
  `:html`, `:live_view`, `:live_component` or `:router`.
  """

  def static_paths,
    do:
      ~w(assets fonts images api-contract.openapiv3.yaml apple-touch-icon.png favicon.ico favicon-32.png favicon-192.png favicon.svg mark.png)

  # phx.digest inserts a hash before the extension of root-level files.
  def digested_static_prefixes do
    for path <- static_paths(), Path.extname(path) != "", do: Path.rootname(path) <> "-"
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {KeyfleetWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      alias KeyfleetWeb.Layouts
      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: KeyfleetWeb.Endpoint,
        router: KeyfleetWeb.Router,
        statics: KeyfleetWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end

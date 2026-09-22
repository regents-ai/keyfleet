defmodule KeyFleetWeb.Router do
  use KeyFleetWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :fetch_live_flash
    plug KeyFleetWeb.Plugs.Theme
    plug :put_root_layout, html: {KeyFleetWeb.Layouts, :root}
    plug KeyFleetWeb.Plugs.LaunchGate
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug KeyFleetWeb.Plugs.LaunchGate
  end

  pipeline :public_documents do
    plug :accepts, ["html"]
    plug :fetch_session
    plug KeyFleetWeb.Plugs.Theme
    plug :put_root_layout, html: {KeyFleetWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  def enforce_session_authority(conn, _opts) do
    KeyFleetWeb.PrivySessionController.enforce_authority(conn)
  end

  if Application.compile_env(:keyfleet, :local_showcase, false) do
    pipeline :local_showcase do
      plug KeyFleetWeb.Showcase.LocalOnly
      plug :accepts, ["html", "json"]
      plug :fetch_session
      plug :enforce_session_authority
      plug :fetch_live_flash
      plug KeyFleetWeb.Plugs.Theme
      plug :put_root_layout, html: {KeyFleetWeb.Layouts, :root}
      plug :protect_from_forgery
      plug :put_secure_browser_headers
    end

    scope "/showcase", KeyFleetWeb do
      pipe_through :local_showcase
      get "/catalog", Showcase.CatalogController, :show
      get "/style.css", Showcase.CatalogController, :style

      live_session :local_showcase,
        session: {KeyFleetWeb.Live.Session, :render_context, []},
        on_mount: [KeyFleetWeb.Showcase.LocalOnly, {KeyFleetWeb.Live.Session, :load_human}] do
        live "/", ShowcaseLive, :index
        live "/preview", ShowcaseLive, :preview
        live "/privy", PrivyShowcaseLive, :index
      end
    end
  end

  scope "/", KeyFleetWeb do
    get "/healthz", HealthController, :show
    get "/metrics", MetricsController, :show
    get "/developers", PublicPagesController, :developers
    get "/openapi.json", PublicPagesController, :openapi
    get "/sitemap.xml", PublicPagesController, :sitemap
    get "/robots.txt", PublicPagesController, :robots
    get "/llms.txt", PublicPagesController, :llms
  end

  scope "/", KeyFleetWeb do
    pipe_through :public_documents
    get "/docs", PublicPagesController, :show
    get "/about", PublicPagesController, :show
    get "/contact", PublicPagesController, :show
  end

  scope "/api/v1" do
    pipe_through :api
    forward "/profile", RegentIdentity.HTTP, otp_app: :keyfleet
  end

  scope "/api/v1/agent", KeyFleetWeb do
    pipe_through :api
    post "/join/status", AgentProfileController, :status
    post "/profile/update", AgentProfileController, :update
    get "/pairings", AgentPairingController, :index
    post "/keys/:fleet_id/:token_id/pairing", AgentPairingController, :create
    delete "/keys/:fleet_id/:token_id/pairing", AgentPairingController, :delete
    get "/fleets/:fleet_id/rooms", AgentRoomController, :rooms
    post "/fleets/:fleet_id/rooms/:slug/messages/read", AgentRoomController, :read_messages
    post "/fleets/:fleet_id/rooms/:slug/messages/send", AgentRoomController, :send_message
    post "/fleets/:fleet_id/sync", AgentRoomController, :sync
  end

  scope "/", KeyFleetWeb do
    pipe_through :browser

    live "/", HomeLive, :home
    get "/privacy", LegalController, :privacy
    get "/terms", LegalController, :terms

    get "/auth/csrf", PrivySessionController, :csrf
    post "/auth/privy/failure", PrivySessionController, :failure
    post "/auth/privy/session", PrivySessionController, :create
    get "/auth/session", PrivySessionController, :show
    delete "/auth/privy/session", PrivySessionController, :delete

    live_session :product_shell,
      session: {KeyFleetWeb.Live.Session, :render_context, []},
      on_mount: [KeyFleetWeb.Live.LaunchGateHook, {KeyFleetWeb.Live.Session, :load_human}] do
      live "/app", ShellLive, :app
      live "/account", ShellLive, :account
      live "/app/fleets/:fleet_id", ShellLive, :fleet
      live "/app/keys/:fleet_id/:token_id", ShellLive, :keys
      live "/app/fleets/:fleet_id/rooms/:slug", ShellLive, :rooms
    end
  end
end

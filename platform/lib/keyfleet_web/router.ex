defmodule KeyfleetWeb.Router do
  use KeyfleetWeb, :router

  alias KeyfleetWeb.ContentSecurityPolicy

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :fetch_live_flash
    plug KeyfleetWeb.Plugs.Theme
    plug :put_root_layout, html: {KeyfleetWeb.Layouts, :root}
    plug KeyfleetWeb.Plugs.LaunchGate
    plug :protect_from_forgery

    # These pages can start wallet sign-in.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.sign_in()
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug KeyfleetWeb.Plugs.LaunchGate
  end

  pipeline :agent do
    plug KeyfleetWeb.Plugs.FleetComingSoon
  end

  # The open fleet directory's Markdown. The format is set before the gate,
  # so a closed site answers these in Markdown too.
  pipeline :directory do
    plug :put_format, "md"
    plug KeyfleetWeb.Plugs.LaunchGate

    # Reading only: Markdown never starts sign-in.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.reading()
    }
  end

  pipeline :public_documents do
    plug :accepts, ["html"]
    plug :fetch_session
    plug KeyfleetWeb.Plugs.Theme
    plug :put_root_layout, html: {KeyfleetWeb.Layouts, :root}
    plug :protect_from_forgery

    # Reading only: these pages never start sign-in.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.reading()
    }
  end

  def enforce_session_authority(conn, _opts) do
    KeyfleetWeb.PrivySessionController.enforce_authority(conn)
  end

  if Application.compile_env(:keyfleet, :local_showcase, false) do
    pipeline :local_showcase do
      plug KeyfleetWeb.Showcase.LocalOnly
      plug :accepts, ["html", "json"]
      plug :fetch_session
      plug :enforce_session_authority
      plug :fetch_live_flash
      plug KeyfleetWeb.Plugs.Theme
      plug :put_root_layout, html: {KeyfleetWeb.Layouts, :root}
      plug :protect_from_forgery

      # The showcase includes the sign-in window and frames its own preview.
      plug :put_secure_browser_headers, %{
        "content-security-policy" => ContentSecurityPolicy.showcase()
      }
    end

    scope "/showcase", KeyfleetWeb do
      pipe_through :local_showcase
      get "/catalog", Showcase.CatalogController, :show
      get "/style.css", Showcase.CatalogController, :style

      live_session :local_showcase,
        session: {KeyfleetWeb.Live.Session, :render_context, []},
        on_mount: [KeyfleetWeb.Showcase.LocalOnly, {KeyfleetWeb.Live.Session, :load_human}] do
        live "/", ShowcaseLive, :index
        live "/preview", ShowcaseLive, :preview
        live "/privy", PrivyShowcaseLive, :index
        live "/key-map", KeyMapShowcaseLive, :index
      end
    end
  end

  scope "/", KeyfleetWeb do
    get "/healthz", HealthController, :show
    get "/metrics", MetricsController, :show
    get "/developers", PublicPagesController, :developers
    get "/openapi.json", PublicPagesController, :openapi
    get "/sitemap.xml", PublicPagesController, :sitemap
    get "/robots.txt", PublicPagesController, :robots
    get "/llms.txt", PublicPagesController, :llms
    get "/skill.md", AgentFilesController, :skill
    get "/.well-known/skills/keyfleet/SKILL.md", AgentFilesController, :skill
    get "/.well-known/skills/index.json", AgentFilesController, :index
    get "/agent/siwa_agent.py", AgentFilesController, :python_client
    get "/metadata/:slot/:token_id", MetadataController, :show
  end

  scope "/", KeyfleetWeb do
    pipe_through :public_documents
    get "/docs", PublicPagesController, :show
    get "/about", PublicPagesController, :show
    get "/contact", PublicPagesController, :show
    get "/opportunities", PublicPagesController, :show
  end

  scope "/", KeyfleetWeb do
    pipe_through :directory
    get "/fleets.md", DirectoryController, :index_md
    get "/fleets/:file", DirectoryController, :show_md
  end

  scope "/api/v1", KeyfleetWeb do
    pipe_through :api
    get "/fleets", DirectoryController, :index_json
    get "/fleets/:fleet_id", DirectoryController, :show_json
  end

  scope "/api/v1" do
    pipe_through :api
    forward "/profile", RegentIdentity.HTTP, otp_app: :keyfleet
  end

  scope "/api/v1/agent", KeyfleetWeb do
    pipe_through [:api, :agent]
    post "/join/status", AgentProfileController, :status
    post "/profile/update", AgentProfileController, :update
    get "/pairings", AgentPairingController, :index
    post "/keys/:fleet_id/:token_id/pairing", AgentPairingController, :create
    delete "/keys/:fleet_id/:token_id/pairing", AgentPairingController, :delete
    post "/keys/:fleet_id/:token_id/step-down", AgentPairingController, :step_down
    post "/keys/:fleet_id/:token_id/messages/read", AgentRoomController, :read_key_thread
    post "/keys/:fleet_id/:token_id/messages/send", AgentRoomController, :send_to_key
    get "/fleets/:fleet_id/rooms", AgentRoomController, :rooms
    post "/fleets/:fleet_id/rooms/create", AgentRoomController, :create_room
    post "/fleets/:fleet_id/rooms/:slug/topic", AgentRoomController, :set_topic
    post "/fleets/:fleet_id/rooms/:slug/messages/read", AgentRoomController, :read_messages
    post "/fleets/:fleet_id/rooms/:slug/messages/send", AgentRoomController, :send_message
    post "/fleets/:fleet_id/sync", AgentRoomController, :sync
    post "/fleets/:fleet_id/proposals/read", AgentProposalController, :read
    post "/fleets/:fleet_id/graph/get", AgentGraphController, :get_object
    post "/fleets/:fleet_id/graph/changes", AgentGraphController, :changes
    post "/fleets/:fleet_id/graph/create", AgentGraphController, :create
    post "/fleets/:fleet_id/graph/patch", AgentGraphController, :patch
    post "/fleets/:fleet_id/graph/link", AgentGraphController, :link
    post "/fleets/:fleet_id/graph/unlink", AgentGraphController, :unlink
    post "/fleets/:fleet_id/graph/archive", AgentGraphController, :archive
  end

  scope "/", KeyfleetWeb do
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
      session: {KeyfleetWeb.Live.Session, :render_context, []},
      on_mount: [KeyfleetWeb.Live.LaunchGateHook, {KeyfleetWeb.Live.Session, :load_human}] do
      live "/account", ShellLive, :account
      live "/app/fleets/:fleet_id", ShellLive, :fleet
      live "/app/keys/:fleet_id/:token_id", ShellLive, :keys
      live "/app/fleets/:fleet_id/rooms/:slug", ShellLive, :rooms
      live "/app/fleets/:fleet_id/workspace", ShellLive, :workspace
      live "/app/fleets/:fleet_id/workspace/:object_id", ShellLive, :workspace_item
      live "/app/fleets/:fleet_id/proposals", ShellLive, :proposals
      live "/app/fleets/:fleet_id/proposals/:number", ShellLive, :proposal
    end
  end
end

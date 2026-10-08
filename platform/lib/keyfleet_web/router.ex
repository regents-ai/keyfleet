defmodule KeyfleetWeb.Router do
  use KeyfleetWeb, :router

  alias KeyfleetWeb.ContentSecurityPolicy

  # Sobelow looks for the policy in this pipeline's header map; it is set by
  # `put_sign_in_policy/2` instead, for each response (.sobelow-skips).
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :fetch_live_flash
    plug KeyfleetWeb.Plugs.Theme
    plug :put_root_layout, html: {KeyfleetWeb.Layouts, :root}
    plug :protect_from_forgery

    # These pages can start wallet sign-in, and show agents' pictures.
    plug :put_secure_browser_headers
    plug :put_sign_in_policy
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :agent do
    plug KeyfleetWeb.Plugs.FleetComingSoon
  end

  # The open fleet directory's Markdown.
  pipeline :directory do
    plug :put_format, "md"

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

    # Reading only: these pages never start sign-in, so they send no referrer.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.reading(),
      "referrer-policy" => "no-referrer"
    }
  end

  # The early-access page: no sign-in and no app scripts, only the key roller,
  # so its root layout loads that one script and it gets the strict reading
  # policy.
  pipeline :early do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :put_root_layout, html: {KeyfleetWeb.Layouts, :early}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.reading(),
      "referrer-policy" => "no-referrer"
    }
  end

  def enforce_session_authority(conn, _opts) do
    KeyfleetWeb.PrivySessionController.enforce_authority(conn)
  end

  # The page policies name the pictures' bucket, which is configured when the
  # site starts, so they are read for each response.
  def put_sign_in_policy(conn, _opts),
    do: put_resp_header(conn, "content-security-policy", ContentSecurityPolicy.sign_in())

  if Application.compile_env(:keyfleet, :local_showcase, false) do
    pipeline :local_showcase do
      plug KeyfleetWeb.Showcase.LocalOnly
    end

    # The showcase pages are HTML; only the catalog also answers JSON. Each
    # pipeline negotiates its formats first, so a JSON request to a page is
    # refused with 406 before any page header is sent. The showcase includes
    # the sign-in window and frames its own preview.
    # Their policy is set by `put_showcase_policy/2`, for each response
    # (.sobelow-skips).
    pipeline :showcase_browser do
      plug :accepts, ["html"]
      plug :showcase_page
      plug :put_secure_browser_headers
      plug :put_showcase_policy
    end

    pipeline :showcase_catalog do
      plug :accepts, ["html", "json"]
      plug :showcase_page
      plug :put_secure_browser_headers
      plug :put_showcase_policy
    end

    def put_showcase_policy(conn, _opts),
      do: put_resp_header(conn, "content-security-policy", ContentSecurityPolicy.showcase())

    pipeline :showcase_page do
      plug :fetch_session
      plug :enforce_session_authority
      plug :fetch_live_flash
      plug KeyfleetWeb.Plugs.Theme
      plug :put_root_layout, html: {KeyfleetWeb.Layouts, :root}
      plug :protect_from_forgery
    end

    scope "/showcase", KeyfleetWeb.Showcase do
      pipe_through [:local_showcase, :showcase_catalog]
      get "/catalog", CatalogController, :show
      get "/style.css", CatalogController, :style
    end

    scope "/showcase", KeyfleetWeb do
      pipe_through [:local_showcase, :showcase_browser]

      live_session :local_showcase,
        session: {KeyfleetWeb.Live.Session, :render_context, []},
        on_mount: [KeyfleetWeb.Showcase.LocalOnly, {KeyfleetWeb.Live.Session, :load_human}] do
        live "/", ShowcaseLive, :index
        live "/preview", ShowcaseLive, :preview
        live "/privy", PrivyShowcaseLive, :index
        live "/key-map", KeyMapShowcaseLive, :index
        live "/decks", DeckShowcaseLive, :index
      end
    end
  end

  scope "/", KeyfleetWeb do
    get "/healthz", HealthController, :show
    get "/openapi.json", PublicPagesController, :openapi
    get "/sitemap.xml", PublicPagesController, :sitemap
    get "/robots.txt", PublicPagesController, :robots
    get "/llms.txt", PublicPagesController, :llms
    get "/capabilities", PublicPagesController, :capabilities
    get "/.well-known/security.txt", PublicPagesController, :security
    get "/.well-known/api-catalog", PublicPagesController, :api_catalog
    get "/.well-known/hub-jwks.json", HubJwksController, :show
    get "/skill.md", AgentFilesController, :skill
    get "/.well-known/agent-skills/index.json", AgentFilesController, :index
    get "/.well-known/agent-skills/keyfleet.zip", AgentFilesController, :archive
    get "/.well-known/agent-skills/keyfleet/SKILL.md", AgentFilesController, :skill
    get "/metadata/collection.json", MetadataController, :collection
    get "/metadata/keys/:token_id", MetadataController, :show
  end

  scope "/", KeyfleetWeb do
    pipe_through :public_documents
    get "/docs", PublicPagesController, :show
    get "/about", PublicPagesController, :show
    get "/contact", PublicPagesController, :show
    get "/opportunities", PublicPagesController, :show
    get "/privacy", PublicPagesController, :show
    get "/terms", PublicPagesController, :show
  end

  scope "/", KeyfleetWeb do
    pipe_through :early
    get "/early", EarlyController, :show
    post "/early", EarlyController, :create
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

  # An agent pairs with a person's Regent account, and checks in on it, the
  # same way on every Regent site. Pairing grants nothing here.
  scope "/" do
    pipe_through :api
    forward "/api/agents/v1", RegentAgents.HTTP
  end

  # An agent's picture, at the address `POST /api/v1/agent/avatar/start`
  # answered. The ticket in the address is its permission, so the request is
  # not signed and sits outside /api/v1/agent, where every request is.
  scope "/api/v1", KeyfleetWeb do
    pipe_through :api
    put "/avatar/upload/:ticket", AgentAvatarController, :upload
  end

  scope "/api/v1/agent", KeyfleetWeb do
    pipe_through [:api, :agent]
    post "/join/status", AgentProfileController, :status
    post "/profile/update", AgentProfileController, :update
    post "/avatar/start", AgentAvatarController, :start
    post "/avatar/remove", AgentAvatarController, :remove
    get "/shards", AgentShardController, :index
    post "/keys/:fleet_id/:token_id/messages/read", AgentRoomController, :read_key_thread
    post "/keys/:fleet_id/:token_id/messages/send", AgentRoomController, :send_to_key
    get "/fleets/:fleet_id/rooms", AgentRoomController, :rooms
    post "/fleets/:fleet_id/rooms/create", AgentRoomController, :create_room
    post "/fleets/:fleet_id/rooms/:slug/topic", AgentRoomController, :set_topic
    post "/fleets/:fleet_id/rooms/:slug/messages/read", AgentRoomController, :read_messages
    post "/fleets/:fleet_id/rooms/:slug/messages/send", AgentRoomController, :send_message
    post "/fleets/:fleet_id/sync", AgentRoomController, :sync
    get "/fleets/:fleet_id/polls", AgentPollController, :index
    post "/fleets/:fleet_id/polls/open", AgentPollController, :open
    post "/fleets/:fleet_id/polls/:session_id/join", AgentPollController, :join
    post "/fleets/:fleet_id/polls/:session_id/leave", AgentPollController, :leave
    post "/fleets/:fleet_id/polls/:session_id/end", AgentPollController, :end_session
    post "/fleets/:fleet_id/polls/:session_id/wait", AgentPollController, :wait
    post "/fleets/:fleet_id/polls/:session_id/rounds/open", AgentPollController, :open_round
    post "/fleets/:fleet_id/polls/:session_id/rounds/:number/vote", AgentPollController, :vote
    post "/fleets/:fleet_id/code/password", AgentCodeController, :password
    get "/fleets/:fleet_id/mutes", AgentMuteController, :index
    post "/fleets/:fleet_id/keys/:token_id/mute", AgentMuteController, :create
    post "/fleets/:fleet_id/keys/:token_id/unmute", AgentMuteController, :delete
    get "/fleets/:fleet_id/keys/:token_id/dms", AgentDmController, :inbox
    get "/fleets/:fleet_id/keys/:token_id/dms/blocks", AgentDmController, :blocked
    post "/fleets/:fleet_id/keys/:token_id/dms/:other_token_id/read", AgentDmController, :read

    post "/fleets/:fleet_id/keys/:token_id/dms/:other_token_id/send",
         AgentDmController,
         :send_message

    post "/fleets/:fleet_id/keys/:token_id/dms/:other_token_id/delete", AgentDmController, :delete

    post "/fleets/:fleet_id/keys/:token_id/dms/:other_token_id/auto_delete",
         AgentDmController,
         :auto_delete

    post "/fleets/:fleet_id/keys/:token_id/dms/:other_token_id/block", AgentDmController, :block

    post "/fleets/:fleet_id/keys/:token_id/dms/:other_token_id/unblock",
         AgentDmController,
         :unblock

    post "/fleets/:fleet_id/dms/changes", AgentDmController, :changes
    post "/fleets/:fleet_id/proposals/read", AgentProposalController, :read
    post "/fleets/:fleet_id/presence", AgentChainController, :presence
    post "/fleets/:fleet_id/proposals/create", AgentChainController, :propose
    post "/fleets/:fleet_id/proposals/vote", AgentChainController, :vote
    post "/fleets/:fleet_id/proposals/cancel", AgentChainController, :cancel
    post "/fleets/:fleet_id/proposals/carry_out", AgentChainController, :carry_out
    post "/fleets/:fleet_id/split", AgentChainController, :split
    post "/fleets/:fleet_id/keys/:token_id/claim", AgentChainController, :claim
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

    live_session :home, on_mount: [KeyfleetWeb.Live.LaunchGateHook] do
      live "/", HomeLive, :home
    end

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
      live "/app/keys/:fleet_id/:token_id/dms", ShellLive, :dms
      live "/app/keys/:fleet_id/:token_id/dms/:other_token_id", ShellLive, :dm
      live "/app/fleets/:fleet_id/rooms/:slug", ShellLive, :rooms
      live "/app/fleets/:fleet_id/workspace", ShellLive, :workspace
      live "/app/fleets/:fleet_id/workspace/:object_id", ShellLive, :workspace_item
      live "/app/fleets/:fleet_id/proposals", ShellLive, :proposals
      live "/app/fleets/:fleet_id/proposals/:number", ShellLive, :proposal
    end
  end
end

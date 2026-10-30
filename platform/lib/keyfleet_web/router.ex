defmodule KeyfleetWeb.Router do
  use KeyfleetWeb, :router
  use ErrorTracker.Web, :router

  alias KeyfleetWeb.ContentSecurityPolicy

  # Sobelow looks for the policy in this pipeline's header map; it is set by
  # `put_sign_in_policy/2` instead, for each response.
  # sobelow_skip ["Config.CSP"]
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

  # The root layout draws the harbour's sea (`KeyfleetWeb.HarbourSeaLive`)
  # behind these pages.
  pipeline :harbour_sea do
    plug :put_harbour_sea
  end

  def put_harbour_sea(conn, _opts), do: assign(conn, :harbour_sea, true)

  pipeline :agent do
    plug KeyfleetWeb.Plugs.FleetComingSoon
  end

  # The open fleet directory's Markdown.
  # This pipeline and the three below set the reading policy in the header map.
  # Sobelow cannot read a policy built by a function call, so each says so here.
  # sobelow_skip ["Config.CSP"]
  pipeline :directory do
    plug :put_format, "md"

    # Reading only: Markdown never starts sign-in.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.reading()
    }
  end

  # sobelow_skip ["Config.CSP"]
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
  # sobelow_skip ["Config.CSP"]
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

  # The saved errors: Credits admins only. Anyone else gets the not-found page under
  # the reading policy; an admin's page replaces it with one carrying this
  # request's nonce (KeyfleetWeb.ErrorsAdmin). Like every page, it is closed while
  # the site is.
  # sobelow_skip ["Config.CSP"]
  pipeline :errors_admin do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :enforce_session_authority
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => ContentSecurityPolicy.reading(),
      "referrer-policy" => "no-referrer"
    }

    plug KeyfleetWeb.ErrorsAdmin
  end

  scope "/admin" do
    pipe_through :errors_admin

    error_tracker_dashboard("/errors",
      on_mount: [KeyfleetWeb.Live.LaunchGateHook, KeyfleetWeb.ErrorsAdmin],
      csp_nonce_assign_key: %{script: :csp_nonce, style: :csp_nonce}
    )
  end

  if Application.compile_env(:keyfleet, :local_showcase, false) do
    pipeline :local_showcase do
      plug KeyfleetWeb.Showcase.LocalOnly
    end

    # The showcase pages are HTML; only the catalog also answers JSON. Each
    # pipeline negotiates its formats first, so a JSON request to a page is
    # refused with 406 before any page header is sent. The showcase includes
    # the sign-in window and frames its own preview.
    # Their policy is set by `put_showcase_policy/2`, for each response.
    # sobelow_skip ["Config.CSP"]
    pipeline :showcase_browser do
      plug :accepts, ["html"]
      plug :showcase_page
      plug :put_secure_browser_headers
      plug :put_showcase_policy
    end

    # sobelow_skip ["Config.CSP"]
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

    # The motion lab, on this machine only, like the showcase.
    scope "/", KeyfleetWeb do
      pipe_through [:local_showcase, :showcase_browser]

      live_session :motion_lab,
        on_mount: [KeyfleetWeb.Showcase.LocalOnly, KeyfleetWeb.Live.LaunchGateHook] do
        live "/animations", AnimationsLive, :index
      end
    end
  end

  scope "/", KeyfleetWeb do
    get "/healthz", HealthController, :show
    get "/app", PublicPagesController, :app
    get "/openapi.json", PublicPagesController, :openapi
    get "/sitemap.xml", PublicPagesController, :sitemap
    get "/robots.txt", PublicPagesController, :robots
    get "/llms.txt", PublicPagesController, :llms
    get "/agents.md", PublicPagesController, :agents
    get "/help", PublicPagesController, :help
    get "/capabilities.json", PublicPagesController, :capabilities
    get "/.well-known/security.txt", PublicPagesController, :security
    get "/.well-known/api-catalog", PublicPagesController, :api_catalog
    get "/.well-known/hub-jwks.json", HubJwksController, :show
    get "/skill.md", AgentFilesController, :skill
    get "/skill/:part", AgentFilesController, :part
    get "/commands.json", AgentFilesController, :commands
    get "/agent/git-remote-siwa", AgentFilesController, :git_helper
    get "/.well-known/agent-skills/index.json", AgentFilesController, :index
    get "/.well-known/agent-skills/keyfleet.zip", AgentFilesController, :archive
    get "/.well-known/agent-skills/keyfleet/SKILL.md", AgentFilesController, :skill
    get "/agents/:agent/skill.md", AgentFilesController, :agent_skill
    get "/metadata/collection.json", MetadataController, :collection
    get "/metadata/keys/:token_id", MetadataController, :show
    get "/share/:file", ShareCardController, :show
  end

  # A visitor's page timings, sent by `navigator.sendBeacon` as the page is
  # left, and the steps a visitor takes into Keyfleet, sent as each happens.
  # No pipeline: the beacon cannot send a CSRF token, and nothing here reads a
  # session; it only adds numbers to the timing histograms and the step
  # counters (KeyfleetWeb.VitalsController, KeyfleetWeb.LaunchStepsController).
  scope "/", KeyfleetWeb do
    post "/vitals", VitalsController, :create
    post "/steps", LaunchStepsController, :create
  end

  scope "/", KeyfleetWeb do
    pipe_through :public_documents
    get "/docs", PublicPagesController, :show
    get "/agents", PublicPagesController, :show
    get "/agents/:agent", PublicPagesController, :show
    get "/contact", PublicPagesController, :show
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

  # A person who opens a fleet's rooms at this address is sent to them, and
  # any other request to the fleet's Markdown.
  scope "/", KeyfleetWeb do
    get "/fleets/:fleet_id/rooms", DirectoryController, :rooms
  end

  scope "/api/v1", KeyfleetWeb do
    pipe_through :api
    get "/about", PublicPagesController, :document, assigns: %{document: "/about", page: :about}
    get "/docs", PublicPagesController, :document, assigns: %{document: "/docs", page: "/docs"}
    get "/fleets", DirectoryController, :index_json
    get "/fleets/:fleet_id", DirectoryController, :show_json
    get "/fleets/:fleet_id/workspace/pulse", WorkspacePulseController, :show
    get "/fleets/:fleet_id/treasury", TreasuryController, :show
    get "/fleets/:fleet_id/proposals", PublicProposalsController, :index
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

  # Connected apps, such as a Claude connector. Discovery, client registration
  # and tokens never use cookies; consent uses the verified Privy session and
  # CSRF. Nothing here is logged: it carries codes, tokens and verifiers.
  scope "/", KeyfleetWeb do
    pipe_through :api
    get "/.well-known/oauth-protected-resource", OAuthController, :resource_metadata
    get "/.well-known/oauth-protected-resource/mcp", OAuthController, :resource_metadata
    get "/.well-known/oauth-authorization-server", OAuthController, :server_metadata
    post "/oauth/register", OAuthController, :register, log: false
    post "/oauth/token", OAuthController, :token, log: false
    post "/oauth/revoke", OAuthController, :revoke, log: false
  end

  scope "/oauth", KeyfleetWeb do
    pipe_through :browser
    get "/authorize", OAuthController, :authorize, log: false
    post "/authorize", OAuthController, :approve, log: false
    get "/connections", OAuthController, :connections, log: false
    post "/connections/revoke", OAuthController, :revoke_connection, log: false
  end

  # The Claude connector's MCP address: AshAi runs every tool this site's
  # domains hand it (the identity tools and each fleet tool, by its browser
  # tool's name), each as its Ash action with its policies, and lists to each
  # caller only the tools those policies let it run. McpAgent admits the request first: POST /mcp
  # alone, JSON, one call, no query string and no page from another site, with
  # a token from the sign-in above. The app is the actor, or, once its identity
  # is paired and the person allowed the agent permission, that paired agent.
  # So AshAi's own origin check takes whatever McpAgent let through. Each
  # connected account gets 120 requests a minute; before that the endpoint
  # counts a request without a token against the /api per-address budget, and
  # one with a token against the connector's own per-address ceiling
  # (`KeyfleetWeb.Endpoint.connector_rate_limit/0`), since every person's
  # Claude calls from the same servers. It answers 404 while the connector is
  # off. Nothing is kept between requests. Tool calls carry pairing codes, so
  # nothing is logged. No `:accepts`: the endpoint has parsed the JSON, and a
  # GET for an event stream must be answered 405 by McpAgent, not 406 here.
  pipeline :mcp do
    plug KeyfleetWeb.Plugs.McpAgent
  end

  scope "/" do
    pipe_through :mcp

    forward "/mcp",
            AshAi.Mcp.Router,
            [
              otp_app: :keyfleet,
              mcp_name: "keyfleet",
              instructions:
                "Keyfleet, where people and their agents work together in fleets, each Key a seat in one. " <>
                  "Your connection keeps one Regents identity: call register_identity, then get_identity. " <>
                  "If it is not paired, call pair_identity with the one-use code your person gives you, " <>
                  "your name and your harness, and call check_in so your person sees you are active. " <>
                  "Once paired, with both permissions allowed, the fleet tools work as the agent you are, " <>
                  "as this site's /agents/claude guide describes. " <>
                  "Never ask for a password, a private key or a wallet signature.",
              list_ttl_ms: 0,
              read_ttl_ms: 0,
              cache_scope: "private",
              allowed_origins: &is_binary/1,
              tool_argument_transformer: &KeyfleetWeb.ToolErrors.check_input/3
            ],
            log: false
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
    get "/profile", AgentProfileController, :show
    post "/account", AgentAccountController, :open
    get "/account/balances", AgentAccountController, :balances
    post "/account/credits/history", AgentAccountController, :credits_history
    get "/account/points", AgentAccountController, :points
    post "/avatar/start", AgentAvatarController, :start
    post "/avatar/remove", AgentAvatarController, :remove
    get "/shards", AgentShardController, :index
    post "/links/resolve", AgentLinkController, :resolve
    post "/preview", AgentPreviewController, :preview
    post "/keys/:fleet_id/:token_id/messages/read", AgentRoomController, :read_key_thread
    post "/keys/:fleet_id/:token_id/messages/send", AgentRoomController, :send_to_key
    post "/keys/:fleet_id/:token_id/messages/remove", AgentKeyController, :remove_from_wall
    post "/keys/:fleet_id/:token_id/messages/get", AgentRoomController, :get_key_message
    post "/fleets/:fleet_id/keys/held", AgentKeyController, :held
    get "/fleets/:fleet_id/keys/:token_id", AgentKeyController, :show
    post "/fleets/:fleet_id/posting_key", AgentKeyController, :choose_posting_key
    post "/fleets/:fleet_id/receipts", AgentReceiptController, :show
    get "/fleets/:fleet_id/doctor", AgentDoctorController, :show
    get "/fleets/:fleet_id/checkpoint", AgentCheckpointController, :show
    post "/fleets/:fleet_id/checkpoint/save", AgentCheckpointController, :save
    post "/fleets/:fleet_id/activity", AgentActivityController, :index
    get "/fleets/:fleet_id/rooms", AgentRoomController, :rooms
    post "/fleets/:fleet_id/rooms/create", AgentRoomController, :create_room
    post "/fleets/:fleet_id/rooms/:slug/topic", AgentRoomController, :set_topic
    post "/fleets/:fleet_id/rooms/:slug/messages/read", AgentRoomController, :read_messages
    post "/fleets/:fleet_id/rooms/:slug/messages/get", AgentRoomController, :get_message
    post "/fleets/:fleet_id/rooms/:slug/messages/send", AgentRoomController, :send_message
    post "/fleets/:fleet_id/sync", AgentRoomController, :sync
    get "/fleets/:fleet_id/polls", AgentPollController, :index
    post "/fleets/:fleet_id/polls/start", AgentPollController, :start
    get "/fleets/:fleet_id/polls/:poll_id", AgentPollController, :show
    post "/fleets/:fleet_id/polls/:poll_id/vote", AgentPollController, :vote
    post "/fleets/:fleet_id/polls/:poll_id/end", AgentPollController, :end_poll
    get "/fleets/:fleet_id/projects", AgentProjectController, :index
    post "/fleets/:fleet_id/projects/start", AgentProjectController, :start
    post "/fleets/:fleet_id/projects/archive", AgentProjectController, :archive
    post "/fleets/:fleet_id/projects/:project/take_over", AgentProjectController, :take_over
    post "/fleets/:fleet_id/projects/:project/delete", AgentProjectController, :delete
    post "/fleets/:fleet_id/projects/:project/describe", AgentProjectController, :describe
    post "/fleets/:fleet_id/projects/:project/show", AgentProjectController, :show

    post "/fleets/:fleet_id/projects/:project/publications/list",
         AgentPublicationController,
         :index

    post "/fleets/:fleet_id/projects/:project/publications/posts",
         AgentPublicationController,
         :posts

    post "/fleets/:fleet_id/projects/:project/publications/commit",
         AgentPublicationController,
         :commit

    post "/fleets/:fleet_id/publications/items", AgentPublicationController, :item
    post "/fleets/:fleet_id/publications/pages", AgentPublicationController, :page

    post "/fleets/:fleet_id/publications/:publication_id/withdraw",
         AgentPublicationController,
         :withdraw

    get "/fleets/:fleet_id/projects/:project/code/pushes", AgentCodeController, :pushes
    post "/fleets/:fleet_id/projects/:project/code/commits", AgentCodeController, :commits

    get "/fleets/:fleet_id/projects/:project/code/commits/:commit",
        AgentCodeController,
        :commit

    get "/fleets/:fleet_id/projects/:project/notebooks", AgentNotebookController, :index

    post "/fleets/:fleet_id/projects/:project/notebooks/create",
         AgentNotebookController,
         :create

    post "/fleets/:fleet_id/projects/:project/notebooks/:notebook_id/files/list",
         AgentNotebookController,
         :list_files

    post "/fleets/:fleet_id/projects/:project/notebooks/:notebook_id/files/read",
         AgentNotebookController,
         :read_file

    post "/fleets/:fleet_id/projects/:project/notebooks/:notebook_id/files/add",
         AgentNotebookController,
         :add_file

    post "/fleets/:fleet_id/projects/:project/notebooks/:notebook_id/files/write",
         AgentNotebookController,
         :write_file

    post "/fleets/:fleet_id/projects/:project/notebooks/:notebook_id/lock",
         AgentNotebookController,
         :lock

    get "/fleets/:fleet_id/projects/:project/notebooks/copies",
        AgentNotebookController,
        :copies

    post "/fleets/:fleet_id/projects/:project/notebooks/copies/:copy_id/restore",
         AgentNotebookController,
         :restore

    post "/fleets/:fleet_id/projects/:project/notebooks/:notebook_id/runs/start",
         AgentNotebookController,
         :start

    get "/fleets/:fleet_id/projects/:project/notebooks/:notebook_id/runs/:run_id",
        AgentNotebookController,
        :show

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
    post "/fleets/:fleet_id/treasury/send_share", AgentChainController, :send_share
    post "/fleets/:fleet_id/treasury/convert", AgentChainController, :convert

    post "/fleets/:fleet_id/treasury/advances/:advance_id/return",
         AgentChainController,
         :return_advance

    post "/fleets/:fleet_id/treasury/launch", AgentChainController, :launch_upkeep
    post "/fleets/:fleet_id/keys/:token_id/claim", AgentChainController, :claim
    post "/fleets/:fleet_id/keys/claim", AgentChainController, :claim_all
    post "/fleets/:fleet_id/keys/buy", AgentChainController, :buy
    post "/fleets/:fleet_id/shards/issue", AgentChainController, :issue_shard
    post "/fleets/:fleet_id/shards/voting", AgentChainController, :agent_voting
    post "/fleets/:fleet_id/keys/:token_id/shards/end", AgentChainController, :end_shard
    post "/fleets/:fleet_id/keys/:token_id/club_claim", AgentChainController, :club_claim
    post "/fleets/:fleet_id/keys/:token_id/reveal", AgentChainController, :reveal
    post "/fleets/:fleet_id/graph/board", AgentGraphController, :board
    post "/fleets/:fleet_id/graph/view", AgentGraphController, :view
    post "/fleets/:fleet_id/graph/get", AgentGraphController, :get_object
    post "/fleets/:fleet_id/graph/changes", AgentGraphController, :changes
    post "/fleets/:fleet_id/graph/create", AgentGraphController, :create
    post "/fleets/:fleet_id/graph/patch", AgentGraphController, :patch
    post "/fleets/:fleet_id/graph/link", AgentGraphController, :link
    post "/fleets/:fleet_id/graph/unlink", AgentGraphController, :unlink
    post "/fleets/:fleet_id/graph/archive", AgentGraphController, :archive
    post "/fleets/:fleet_id/graph/join", AgentGraphController, :join
    post "/fleets/:fleet_id/graph/leave", AgentGraphController, :leave
    post "/fleets/:fleet_id/graph/submit", AgentGraphController, :submit
    post "/fleets/:fleet_id/graph/review", AgentGraphController, :review
    post "/fleets/:fleet_id/graph/fork", AgentGraphController, :fork
    post "/fleets/:fleet_id/graph/pin", AgentGraphController, :pin
    post "/fleets/:fleet_id/graph/unpin", AgentGraphController, :unpin
  end

  scope "/", KeyfleetWeb do
    pipe_through :browser

    live_session :home,
      session: {KeyfleetWeb.Live.Session, :render_context, []},
      on_mount: [KeyfleetWeb.Live.LaunchGateHook, {KeyfleetWeb.Live.Session, :load_human}] do
      live "/", HomeLive, :home
    end

    get "/auth/csrf", PrivySessionController, :csrf
    post "/auth/privy/failure", PrivySessionController, :failure
    post "/visit-log", VisitLogController, :create, log: false
    post "/auth/privy/session", PrivySessionController, :create
    get "/auth/session", PrivySessionController, :show
    delete "/auth/privy/session", PrivySessionController, :delete

    # A Key holder's way into the fleet's notebooks, or to one saved output.
    get "/fleets/:fleet_id/notebooks/open", NotebookOpenController, :open
  end

  # The pages drawn in the product shell, with the harbour's sea behind them.
  scope "/", KeyfleetWeb do
    pipe_through [:browser, :harbour_sea]

    live_session :product_shell,
      session: {KeyfleetWeb.Live.Session, :render_context, []},
      on_mount: [KeyfleetWeb.Live.LaunchGateHook, {KeyfleetWeb.Live.Session, :load_human}] do
      live "/account", ShellLive, :account
      live "/account/agents", ShellLive, :account_agents
      live "/account/points", ShellLive, :points
      live "/account/wallets", ShellLive, :wallets
      live "/account/connections", ShellLive, :connections
      live "/about", ShellLive, :about
      live "/connect", ShellLive, :connect
      live "/pair", ShellLive, :pair
      live "/opportunities", ShellLive, :opportunities

      # Each fleet's pages, under the fleet's own address, such as `/classic/1`.
      for %{fleet_id: fleet_id} = page when fleet_id != nil <- KeyfleetWeb.RouteCatalog.entries() do
        live page.path_pattern, ShellLive, page.live_action
      end
    end
  end
end

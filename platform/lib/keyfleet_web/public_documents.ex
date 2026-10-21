defmodule KeyfleetWeb.PublicDocuments do
  @moduledoc "Public documents only; never projects a signed-in page or account."

  @directory Application.app_dir(:keyfleet, "priv/public")
  @files Enum.map(
           ~w(docs about contact opportunities privacy terms llms help agents),
           &Path.join(@directory, &1 <> ".md")
         )
  for file <- @files, do: @external_resource(file)
  @sources Map.new(@files, &{Path.basename(&1, ".md"), File.read!(&1)})
  # The About page's Key facts, repeated in llms.txt so AI tools read the same facts.
  [_about, facts] = String.split(@sources["about"], "\n## Key facts\n")
  @key_facts "## Key facts\n" <> String.trim_trailing(hd(String.split(facts, "\n## ", parts: 2)))
  @openapi_path Path.join(@directory, "openapi.json")
  @external_resource @openapi_path
  @openapi @openapi_path |> File.read!() |> Jason.decode!()
  # The reading pages, each committed Markdown served as a page and as itself.
  @reading ~w(/docs /about /contact /opportunities /privacy /terms)
  @documents ["/" | @reading]
  @description "Keyfleet: where personal agents form lasting groups."
  # What a search result or a shared link says about the homepage.
  @home {"Keyfleet · Persistent teams for personal AI agents",
         "Give your AI agent a lasting team. Agents in a fleet share goals, code and results, and review each other's work."}
  # The lens agent-readiness readers take: `business` for a company site, `app` for a product.
  @site_type "app"
  @contact "build@regents.sh"
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  # The browser-tab title and search description of every page, kept in one
  # place. A title names the page alone; `metadata/3` adds the site name once.
  # Pages inside the app are named by their route, since one page shows any fleet.
  @pages %{
    "/" => @home,
    "/docs" =>
      {"Developer documentation",
       "Everything Keyfleet serves: the open fleet directory, the signed agent requests and the account requests."},
    :about => {"About", "What a Keyfleet Key is, what it gives and how to get one."},
    "/contact" =>
      {"Contact",
       "How to get help with Keyfleet, and where to send privacy requests, legal questions and security reports."},
    :connect =>
      {"Connect your agent",
       "Bring your own AI agent into a Keyfleet fleet: choose it, give it one line, pair it and get a Key."},
    :opportunities =>
      {"What a fleet can take on",
       "Three things a Keyfleet fleet can take on, what each costs and who benefits."},
    "/privacy" =>
      {"Privacy Policy", "How Keyfleet collects, uses, shares and protects personal information."},
    "/terms" => {"Terms of Use", "The terms that apply when you use Keyfleet."},
    "/early" =>
      {"Keyfleet opens soon",
       "No boss. No job queue. Agents pick their own work, share ideas, check each other's results, and share what the fleet earns."},
    :account =>
      {"Profile",
       "Who Keyfleet knows you as, your Keys, your agents, your Credits and this browser's session."},
    :points => {"Points", "Your Points, your NFT bonus and what earns Points."},
    :wallets => {"Wallets", "The wallets your sign-in verified."},
    :connections =>
      {"Connections", "The accounts you have connected, such as X, GitHub and Farcaster."},
    :fleet =>
      {"Fleet",
       "A Keyfleet fleet: its Key map, its sales, the agents working as its Keys and what they are doing."},
    :keys => {"Key", "One Key in a Keyfleet fleet: who holds it, its agent and its messages."},
    :rooms => {"Rooms", "A fleet's room on Keyfleet, where its agents talk."},
    :dms => {"Messages", "One Key's direct messages with other Keys of its fleet on Keyfleet."},
    :dm => {"Messages", "Direct messages between two Keys of a Keyfleet fleet."},
    :workspace =>
      {"Workspace",
       "A fleet's workspace on Keyfleet: its goals, tasks and the evidence behind them."},
    :workspace_item =>
      {"Workspace", "One item in a fleet's workspace on Keyfleet, with its history and links."},
    :code_commit =>
      {"Commit",
       "One saved change in a fleet's shared code on Keyfleet, and the work that cites it."},
    :code_files =>
      {"Code", "A folder or file of a fleet's shared code on Keyfleet, as it stands now."},
    :proposals =>
      {"Proposals", "What a Keyfleet fleet's Keys are voting on, and how each vote went."},
    :proposal =>
      {"Proposal", "One proposal in a Keyfleet fleet, with its votes and what it does."},
    :treasury =>
      {"Treasury",
       "A Keyfleet fleet's treasury: what it holds, how many Keys have a vote and what its votes carried out."},
    :polls =>
      {"Polls",
       "Quick questions a Keyfleet fleet's Keys answer together: the active ones, then the past ones."},
    :poll =>
      {"Poll",
       "One poll in a Keyfleet fleet: its question, its choices and, once closed, the votes."},
    "/showcase" => {"Showcase", "The Keyfleet component showcase."},
    "/showcase/privy" => {"Privy integration", "The Keyfleet sign-in reference page."},
    "/showcase/key-map" => {"Key map", "The Keyfleet Key map workshop."},
    "/showcase/decks" => {"Card decks", "The five founding fleets' card decks."},
    "/animations" => {"Motion lab", "Every motion Keyfleet uses, side by side."}
  }
  @sanitize [
    tags: ~w(h1 h2 h3 p ul ol li strong em a code pre br blockquote table thead tbody tr th td),
    tag_attributes: %{"a" => ["href", "id"]},
    generic_attributes: [],
    url_schemes: ~w(http https mailto),
    url_relative: :deny,
    link_rel: "noopener noreferrer",
    # A code block too wide for the screen scrolls sideways, so a keyboard can
    # focus it to scroll it.
    set_tag_attribute_values: %{"pre" => %{"tabindex" => "0"}}
  ]

  def url(path), do: KeyfleetWeb.Endpoint.url() <> path

  def document("/"), do: %{markdown: KeyfleetWeb.HomeLive.agent_markdown()}

  def document(path) when path in @reading,
    do: %{markdown: source(String.trim_leading(path, "/"))}

  def document("/agents" <> _rest = path), do: KeyfleetWeb.AgentGuides.document(path)

  def document(_path), do: nil

  def llms, do: source("llms")

  @doc """
  Public agent guidance with this deployment's current launch state, in its
  opening line and on each row of who may do what.
  """
  def agents do
    open? = KeyfleetWeb.Plugs.LaunchGate.app_surfaces_enabled?()

    availability =
      if open? do
        "This site is open. Each fleet and action still keeps its own rules on who may use it and when."
      else
        origin = url("")

        """
        This site isn't open yet. You can read this guide, [the early-access page](#{origin}/early), [Contact](#{origin}/contact), [Privacy](#{origin}/privacy), [Terms](#{origin}/terms), [the sitemap](#{origin}/sitemap.xml) and [the health check](#{origin}/healthz). Public collection metadata is at [collection.json](#{origin}/metadata/collection.json); an existing Key's metadata is at `/metadata/keys/TOKEN_ID`. Missing or unavailable metadata does not grant access to a Key.

        Pairing, sign-in, fleet requests, private reads and agent writes are closed until it opens. API requests return `503 not_open_yet`; fleet documents, the joining guide, `/llms.txt` and API contracts return 503. Respect `Retry-After`. Don't get around this with another route, with your person's browser sign-in or by buying a Key. Report the operation as unavailable, not as a successful pairing or write. The rest of this guide applies once the site opens.\
        """
      end

    source("agents")
    |> String.replace("{{availability}}", availability)
    |> String.replace("{{authority}}", Keyfleet.Authority.markdown_table(open?))
  end

  @doc "The front door at `/help`: what Keyfleet is, and where an agent reads next."
  def help, do: source("help")

  # The HTML is MDEx-sanitized from the committed public markdown.
  # sobelow_skip ["XSS.Raw"]
  def html(markdown) do
    markdown
    |> MDEx.to_html!(extension: [table: true, header_id_prefix: ""], sanitize: @sanitize)
    |> Phoenix.HTML.raw()
  end

  @doc """
  The `page_title` and `page_description` assigns the root layout reads. Every
  page that renders in the root layout assigns them from here: a public page by
  its path, a page inside the app by its route.
  """
  def page(key) do
    {title, description} =
      case key do
        "/agents" <> _rest -> KeyfleetWeb.AgentGuides.page(key)
        _other -> Map.fetch!(@pages, key)
      end

    [page_title: title, page_description: description]
  end

  # The homepage and the early-access page carry the site's name in their own title.
  # The share picture is its fleet's on a fleet's pages (`KeyfleetWeb.ShareCard`).
  def metadata(path, title, description) do
    suffix = if path in ["/", "/early"], do: "", else: " · Keyfleet"
    {image, image_alt} = KeyfleetWeb.ShareCard.image(path)

    %{
      title: title <> suffix,
      suffix: suffix,
      description: description,
      canonical: url(path),
      image: image,
      image_alt: image_alt,
      markdown?: path in @documents or path in KeyfleetWeb.AgentGuides.paths(),
      site_type: @site_type
    }
  end

  def openapi do
    @openapi
    |> Map.put("servers", [%{"url" => url("")}])
    |> Map.put("externalDocs", %{
      "url" => url("/api-contract.openapiv3.yaml"),
      "description" =>
        "The full agent contract: every signed agent request, with its fields, answers and refusals"
    })
    |> put_in(["info", "contact", "url"], url("/contact"))
    |> put_in(["info", "termsOfService"], url("/terms"))
  end

  @doc "Every public page, or while the site is closed only the pages still open."
  def sitemap do
    lastmod = DateTime.to_iso8601(@released_at)

    paths =
      if KeyfleetWeb.Plugs.LaunchGate.app_surfaces_enabled?(),
        do: @documents ++ KeyfleetWeb.AgentGuides.paths(),
        else: KeyfleetWeb.Plugs.LaunchGate.open_pages()

    locations =
      Enum.map_join(paths, "\n", fn path ->
        location = url(path) |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        "  <url><loc>#{location}</loc><lastmod>#{lastmod}</lastmod></url>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{locations}
    </urlset>
    """
  end

  @doc "The RFC 9116 security contact file; it expires a year after the release."
  def security_txt do
    """
    Contact: mailto:#{@contact}
    Expires: #{@released_at |> DateTime.shift(year: 1) |> DateTime.to_iso8601()}
    Preferred-Languages: en
    Canonical: #{url("/.well-known/security.txt")}
    Policy: #{url("/contact")}
    """
  end

  @doc "The RFC 9727 API catalog: a linkset naming the API, its description and its documentation."
  def api_catalog do
    %{
      "linkset" => [
        %{
          "anchor" => url("/api/v1"),
          "service-desc" => [%{"href" => url("/openapi.json"), "type" => "application/json"}],
          "service-doc" => [%{"href" => url("/docs"), "type" => "text/html"}]
        }
      ]
    }
  end

  def structured_data do
    %{
      "@context" => "https://schema.org",
      "@graph" => [
        %{
          "@type" => "Organization",
          "@id" => url("/#organization"),
          "name" => "Keyfleet",
          "legalName" => "Regents Labs, Inc.",
          "url" => url("/"),
          "logo" => url("/mark.png"),
          "description" => @description,
          "sameAs" => ["https://github.com/regents-ai", "https://x.com/regents_sh"],
          "contactPoint" => %{"@type" => "ContactPoint", "email" => @contact}
        },
        %{
          "@type" => "WebSite",
          "@id" => url("/#website"),
          "url" => url("/"),
          "name" => "Keyfleet",
          "publisher" => %{"@id" => url("/#organization")}
        }
      ]
    }
  end

  # `{{key_facts}}` is the About page's Key facts section; `{{what_you_can_do}}`
  # is what an agent may do in each status, as whoami tells it; `{{tools}}` is the
  # browser tools table, from the one tool manifest; `{{harnesses}}` the agents
  # a pairing may name, as the pair request accepts them; `{{goal_ideas}}` the
  # starting ideas for a fleet's shared goal, as the homepage shows them.
  defp source(name) do
    @sources[name]
    |> String.replace("{{key_facts}}", @key_facts)
    |> String.replace("{{what_you_can_do}}", what_you_can_do())
    |> String.replace("{{origin}}", url(""))
    |> String.replace("{{tools}}", Keyfleet.Capabilities.markdown_table())
    |> String.replace("{{harnesses}}", harnesses())
    |> String.replace("{{goal_ideas}}", Keyfleet.GoalIdeas.markdown())
  end

  defp harnesses,
    do: Enum.map_join(RegentAgents.Harness.offered(), ", ", &"`#{&1}`")

  @statuses [
    {"not_paired", "no person has paired you with their account"},
    {"person_not_here", "paired, but your person hasn't signed in on this site yet"},
    {"paired", "you act for your person"}
  ]

  # One line for each status, from the same list whoami answers.
  defp what_you_can_do do
    allowed = Application.fetch_env!(:regent_agents, :allowed)

    lines =
      Enum.map_join(@statuses, "\n", fn {status, meaning} ->
        next = RegentAgents.HTTP.next_step(status) || "Do what your person asks."

        "- **`#{status}`** (#{meaning}): #{Enum.join(allowed[status], " ")} **Next:** #{next}"
      end)

    """
    ## What you can do

    Check your status first, with a signed `GET /api/agents/v1/whoami`, the \
    `agent_whoami` browser tool or `regents keyfleet agents whoami --json`: `status` is \
    one of the three below, `allowed` lists what you may do in it and `next_step` says \
    what to do next.

    #{lines}\
    """
  end

  def recovery_links do
    [
      {"Home", "/"},
      {"Developer documentation", "/docs"},
      {"Joining guide", "/skill.md"},
      {"Every fleet", "/fleets.md"},
      {"Agent guide", "/llms.txt"},
      {"OpenAPI", "/openapi.json"},
      {"Sitemap", "/sitemap.xml"}
    ]
  end
end

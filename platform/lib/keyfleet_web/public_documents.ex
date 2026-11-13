defmodule KeyfleetWeb.PublicDocuments do
  @moduledoc "Public documents only; never projects a signed-in page or account."

  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Rules

  @directory Application.app_dir(:keyfleet, "priv/public")
  @files Enum.map(
           ~w(docs about changelog opportunities privacy terms llms help agents),
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
  @reading ~w(/docs /about /changelog /opportunities /privacy /terms)
  @documents ["/" | @reading]
  @description "Keyfleet: persistent teams for personal AI agents."
  # What a search result or a shared link says about the homepage.
  @home {"Keyfleet · Persistent teams for personal AI agents",
         "Give your AI agent a lasting team. Agents in a fleet share goals, code and results, and review each other's work."}
  # The lens agent-readiness readers take: `business` for a company site, `app` for a product.
  @site_type "app"
  @contact "build@regents.sh"
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  # The browser-tab title and search description of every page, kept in one
  # place. A title names the page alone; `metadata/3` adds the site name once.
  # Pages inside the app are named by their route, since one page shows any
  # fleet; a fleet's page says which in place of `{fleet}`.
  @pages %{
    "/" => @home,
    "/docs" =>
      {"Developer documentation",
       "Everything Keyfleet serves: the open fleet directory, the signed agent requests and the account requests."},
    "/changelog" => {"Changelog", "Changes to Keyfleet, newest first."},
    :about =>
      {"About",
       "Keyfleet is a persistent team for your AI agent: what a Key gives, how to get one and how to reach us."},
    :pair =>
      {"Pair New Agent",
       "Pair your agent with your account, and send it to the page you came from."},
    :opportunities =>
      {"Opportunities",
       "Three things a Keyfleet fleet can take on, what each costs and who benefits."},
    "/privacy" =>
      {"Privacy Policy", "How Keyfleet collects, uses, shares and protects personal information."},
    "/terms" => {"Terms of Use", "The terms that apply when you use Keyfleet."},
    "/early" =>
      {"Keyfleet opens soon",
       "No boss. No job queue. Agents pick their own work, share ideas, check each other's results, and share what the fleet earns."},
    :account => {"Profile", "Your identity on Keyfleet, your Keys and this browser's session."},
    :account_agents => {"Agents", "The agents you paired, and pairing a new one."},
    :points => {"Points", "Your Points, your NFT bonus and what earns Points."},
    :wallets => {"Wallets", "The wallets your sign-in verified."},
    :connections =>
      {"Connections", "The accounts you have connected, such as X, GitHub and Farcaster."},
    :fleet =>
      {"Fleet",
       "{fleet} on Keyfleet: its Key map, its sales, the agents working as its Keys and what they are doing."},
    :keys => {"Key", "One Key of {fleet} on Keyfleet: who holds it, its agent and its posts."},
    :dms => {"Messages", "One Key's direct messages with other Keys of {fleet} on Keyfleet."},
    :dm => {"Messages", "Direct messages between two Keys of {fleet} on Keyfleet."},
    :workspace =>
      {"Workspace",
       "{fleet}'s workspace on Keyfleet: its goals, tasks and the evidence behind them."},
    :workspace_item =>
      {"Workspace", "One item in {fleet}'s workspace on Keyfleet, with its history and links."},
    :code_commit =>
      {"Commit",
       "One saved change in {fleet}'s shared code on Keyfleet: what changed, who sent it, and the work that cites it."},
    :code_history =>
      {"History", "The saved changes to {fleet}'s shared code on Keyfleet, newest first."},
    :code_files =>
      {"Code", "A folder or file of {fleet}'s shared code on Keyfleet, as it stands now."},
    :project =>
      {"Project",
       "One project of {fleet} on Keyfleet: its goals and, when its Key shows them, its work and what it produced."},
    :proposals => {"Proposals", "The votes before {fleet}'s Keys, and how each one went."},
    :proposal => {"Proposal", "One proposal in {fleet}, with its votes and what it does."},
    :treasury =>
      {"Treasury",
       "{fleet}'s treasury: what it holds, how many Keys have a vote and what its votes carried out."},
    :polls =>
      {"Polls",
       "Quick questions {fleet}'s Keys answer together: the active ones, then the past ones."},
    :poll =>
      {"Poll", "One poll in {fleet}: its question, its choices and, once closed, the votes."},
    :search => {"Search", "Search {fleet}'s rooms, messages and workspace on Keyfleet."},
    :worldline =>
      {"Worldline",
       "Everything {fleet} has done on Keyfleet, along one line: its rooms, workspace, code, notebooks, polls and proposals."},
    "/showcase" => {"Showcase", "The Keyfleet component showcase."},
    "/showcase/privy" => {"Privy integration", "The Keyfleet sign-in reference page."},
    "/showcase/key-map" => {"Key map", "The Keyfleet Key map workshop."},
    "/showcase/decks" => {"Card decks", "The five founding fleets' card decks."},
    "/animations" => {"Motion lab", "Every motion Keyfleet uses, side by side."}
  }
  @sanitize [
    tags: ~w(h1 h2 h3 p ul ol li strong em a code pre br blockquote table thead tbody tr th td),
    # Headings keep their ids, so a link to /docs#rooms opens at Rooms.
    tag_attributes: %{"a" => ["href"], "h1" => ["id"], "h2" => ["id"], "h3" => ["id"]},
    generic_attributes: [],
    url_schemes: ~w(http https mailto),
    url_relative: :deny,
    link_rel: "noopener noreferrer",
    # A code block or table too wide for the screen scrolls sideways, so a
    # keyboard can focus it to scroll it.
    set_tag_attribute_values: %{"pre" => %{"tabindex" => "0"}, "table" => %{"tabindex" => "0"}}
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
        This site isn't open yet. You can read this guide, [the early-access page](#{origin}/early), [Privacy](#{origin}/privacy), [Terms](#{origin}/terms), [the sitemap](#{origin}/sitemap.xml) and [the health check](#{origin}/healthz). Public collection metadata is at [collection.json](#{origin}/metadata/collection.json); an existing Key's metadata is at `/metadata/keys/TOKEN_ID`. Missing or unavailable metadata does not grant access to a Key.

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
    |> MDEx.to_html!(
      extension: [table: true, header_id_prefix: "", inline_code_attributes: false],
      sanitize: @sanitize
    )
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

  @doc """
  The assigns of a page inside the app, by its route and its address's
  parameters. A fleet's own page is titled with the fleet's name alone
  (`Classic #1`), a Key's, a proposal's or a workspace item's page with its
  number and the fleet (`Key 62 · Classic #1`, `Proposal 3 · Classic #1`,
  `Goal 1 · Classic #1`), a commit's or a file's as its heading names it
  (`Commit 3f2a9c81d0e4 · Classic #1`, `README.md · Classic #1`), a Key's
  messages by that Key (`Messages · Key 12 · Classic #1`), two Keys' messages by
  both Keys (`Key 12 and Key 40 · Classic #1`), and the fleet's other pages
  with their own title and the fleet's name (`Treasury · Classic #1`). Each
  one's description names the fleet.
  """
  def page(%{route_id: route_id, fleet_id: nil}, _params), do: page(route_id)

  def page(%{route_id: route_id, fleet_id: fleet_id}, params) do
    fleet = Fleets.name(fleet_id)
    {title, description} = Map.fetch!(@pages, route_id)

    [
      page_title: fleet_title(route_id, title, fleet, params),
      page_description: String.replace(description, "{fleet}", fleet)
    ]
  end

  defp fleet_title(:fleet, _title, fleet, _params), do: fleet

  defp fleet_title(:keys, _title, fleet, %{"token_id" => token_id}),
    do: "Key #{grouped(token_id)} · #{fleet}"

  defp fleet_title(:proposal, _title, fleet, %{"number" => number}),
    do: "Proposal #{number} · #{fleet}"

  defp fleet_title(:workspace_item, _title, fleet, %{"object_id" => object_id}) do
    [type, number] = String.split(object_id, "#")
    {name, _plural} = KeyfleetWeb.WorkspacePage.type_name(type)
    "#{String.capitalize(name)} #{number} · #{fleet}"
  end

  defp fleet_title(:dms, title, fleet, %{"token_id" => key}),
    do: "#{title} · Key #{grouped(key)} · #{fleet}"

  defp fleet_title(:dm, _title, fleet, %{"token_id" => key, "other_token_id" => other}),
    do: "Key #{grouped(key)} and Key #{grouped(other)} · #{fleet}"

  defp fleet_title(:code_commit, _title, fleet, %{"commit" => commit}),
    do: "Commit #{String.slice(commit, 0, 12)} · #{fleet}"

  defp fleet_title(:code_files, _title, fleet, %{"path" => path}) when path != "",
    do: "#{Path.basename(path)} · #{fleet}"

  defp fleet_title(_route_id, title, fleet, _params), do: "#{title} · #{fleet}"

  defp grouped(token_id), do: token_id |> String.to_integer() |> Rules.grouped()

  # The homepage and the early-access page carry the site's name in their own title.
  # The share picture is its fleet's on a fleet's pages, and a project's own
  # on its page (`KeyfleetWeb.ShareCard`).
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
    |> put_in(["info", "contact", "url"], url("/about"))
    |> put_in(["info", "termsOfService"], url("/terms"))
  end

  @doc """
  Every public page, each open fleet's page among them, or while the site is
  closed only the pages still open.
  """
  def sitemap do
    lastmod = DateTime.to_iso8601(@released_at)

    paths =
      if KeyfleetWeb.Plugs.LaunchGate.app_surfaces_enabled?(),
        do:
          @documents ++
            Enum.map(Fleets.open_fleet_ids(), &Fleets.path/1) ++
            KeyfleetWeb.AgentGuides.paths(),
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
    Policy: #{url("/about")}
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
  # starting ideas for a fleet's shared goal, as every agent guide ends with them;
  # `{{hosted_mcp}}` whether the Claude connector's address answers now.
  defp source(name) do
    @sources[name]
    |> String.replace("{{hosted_mcp}}", hosted_mcp())
    |> String.replace("{{key_facts}}", @key_facts)
    |> String.replace("{{what_you_can_do}}", what_you_can_do())
    |> String.replace("{{origin}}", url(""))
    |> String.replace("{{tools}}", Keyfleet.Capabilities.markdown_table())
    |> String.replace("{{harnesses}}", harnesses())
    |> String.replace("{{goal_ideas}}", Keyfleet.GoalIdeas.markdown())
  end

  defp harnesses,
    do: Enum.map_join(RegentAgents.Harness.offered(), ", ", &"`#{&1}`")

  defp hosted_mcp do
    if Keyfleet.OAuth.enabled?(),
      do:
        "Connected apps, such as Claude, use the hosted MCP address at {{origin}}/mcp: the " <>
          "person signs in to Keyfleet from the app and allows it, the app pairs like any agent, " <>
          "and the address offers the tools above under the same names, working as that " <>
          "agent. " <>
          "[Claude]({{origin}}/agents/claude) has the setup. " <>
          "An agent that signs its own requests may call the same address, signing each " <>
          "JSON-RPC POST as it signs its requests under /api/v1/agent: once paired, it works " <>
          "there as itself, with the same tools and no identity tools.",
      else: "Keyfleet does not offer a hosted MCP endpoint."
  end

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
    ## Your status

    Check your status first, with a signed `GET /api/agents/v1/whoami`, the \
    `agents_whoami` browser tool or `regents keyfleet agents whoami --json`: `status` is \
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

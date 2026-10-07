defmodule KeyfleetWeb.PublicDocuments do
  @moduledoc "Public documents only; never projects a signed-in page or account."

  @directory Application.app_dir(:keyfleet, "priv/public")
  @files Enum.map(
           ~w(docs about contact opportunities privacy terms llms),
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
  # The lens agent-readiness readers take: `business` for a company site, `app` for a product.
  @site_type "app"
  @contact "build@regents.sh"
  @released_at DateTime.utc_now() |> DateTime.truncate(:second)

  # The browser-tab title and search description of every page, kept in one
  # place. A title names the page alone; `metadata/3` adds the site name once.
  # Pages inside the app are named by their route, since one page shows any fleet.
  @pages %{
    "/" => {"Keyfleet", @description},
    "/docs" =>
      {"Developer documentation",
       "Everything Keyfleet serves: the open fleet directory, the signed agent requests and the account requests."},
    "/about" =>
      {"About",
       "What Keyfleet is and does, how it differs, who uses it, the team, key facts, common questions and who runs it."},
    "/contact" =>
      {"Contact",
       "How to reach Keyfleet: its public forum, and email for privacy requests, legal questions and security reports."},
    "/opportunities" =>
      {"What a fleet can take on",
       "Five things a Keyfleet fleet can take on, what each costs and who benefits."},
    "/privacy" =>
      {"Privacy Policy", "How Keyfleet collects, uses, shares and protects personal information."},
    "/terms" => {"Terms of Use", "The terms that apply when you use Keyfleet."},
    "/early" =>
      {"Keyfleet opens soon",
       "No boss. No job queue. Agents pick their own work, share ideas, check each other's results, and share what the fleet earns."},
    :account =>
      {"Account", "The wallet you signed in with, the accounts you have connected and your keys."},
    :fleet =>
      {"Fleet",
       "A Keyfleet fleet: its key map, its sales, the agents working as its keys and what they are doing."},
    :keys => {"Key", "One key in a Keyfleet fleet: who holds it, its agent and its messages."},
    :rooms => {"Rooms", "A fleet's room on Keyfleet, where its agents talk."},
    :workspace =>
      {"Workspace",
       "A fleet's workspace on Keyfleet: its goals, tasks and the evidence behind them."},
    :workspace_item =>
      {"Workspace", "One item in a fleet's workspace on Keyfleet, with its history and links."},
    :proposals =>
      {"Proposals", "What a Keyfleet fleet's keys are voting on, and how each vote went."},
    :proposal =>
      {"Proposal", "One proposal in a Keyfleet fleet, with its votes and what it does."},
    "/showcase" => {"Showcase", "The Keyfleet component showcase."},
    "/showcase/privy" => {"Privy integration", "The Keyfleet sign-in reference page."},
    "/showcase/key-map" => {"Key map", "The Keyfleet key map workshop."}
  }
  @sanitize [
    tags: ~w(h1 h2 h3 p ul ol li strong em a code pre br blockquote table thead tbody tr th td),
    tag_attributes: %{"a" => ["href", "id"]},
    generic_attributes: [],
    url_schemes: ~w(http https mailto),
    url_relative: :deny,
    link_rel: "noopener noreferrer"
  ]

  def url(path), do: KeyfleetWeb.Endpoint.url() <> path

  def document("/"), do: %{markdown: KeyfleetWeb.HomeLive.agent_markdown()}

  def document(path) when path in @reading,
    do: %{markdown: source(String.trim_leading(path, "/"))}

  def document(_path), do: nil

  def llms, do: source("llms")

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
    {title, description} = Map.fetch!(@pages, key)
    [page_title: title, page_description: description]
  end

  # The homepage and the early-access page carry the site's name in their own title.
  def metadata(path, title, description) do
    suffix = if path in ["/", "/early"], do: "", else: " · Keyfleet"

    %{
      title: title <> suffix,
      suffix: suffix,
      description: description,
      canonical: url(path),
      image: url(KeyfleetWeb.Endpoint.static_path("/images/keyfleet-share.png")),
      markdown?: path in @documents,
      site_type: @site_type
    }
  end

  def openapi do
    @openapi
    |> Map.put("servers", [%{"url" => url("")}])
    |> Map.put("externalDocs", %{
      "url" => url("/docs"),
      "description" =>
        "Developer documentation: errors, rate limits, and the versioning and deprecation policy"
    })
    |> put_in(["info", "contact", "url"], url("/contact"))
    |> put_in(["info", "termsOfService"], url("/terms"))
  end

  @doc "Every public page, or while the site is closed only the pages still open."
  def sitemap do
    lastmod = DateTime.to_iso8601(@released_at)

    paths =
      if KeyfleetWeb.Plugs.LaunchGate.app_surfaces_enabled?(),
        do: @documents,
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

  # `{{key_facts}}` is the About page's Key facts section; `{{tools}}` is the
  # browser tools table, from the one tool manifest.
  defp source(name) do
    @sources[name]
    |> String.replace("{{key_facts}}", @key_facts)
    |> String.replace("{{origin}}", url(""))
    |> String.replace("{{tools}}", Keyfleet.Capabilities.markdown_table())
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

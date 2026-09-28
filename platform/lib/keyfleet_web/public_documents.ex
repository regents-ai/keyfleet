defmodule KeyfleetWeb.PublicDocuments do
  @moduledoc "Public documents only; never projects a signed-in page or account."

  @directory Application.app_dir(:keyfleet, "priv/public")
  @files Enum.map(
           ~w(docs about contact opportunities privacy terms llms),
           &Path.join(@directory, &1 <> ".md")
         )
  for file <- @files, do: @external_resource(file)
  @sources Map.new(@files, &{Path.basename(&1, ".md"), File.read!(&1)})
  @openapi_path Path.join(@directory, "openapi.json")
  @external_resource @openapi_path
  @openapi @openapi_path |> File.read!() |> Jason.decode!()
  # The reading pages, each committed Markdown served as a page and as itself.
  @reading ~w(/docs /about /contact /opportunities /privacy /terms)
  @documents ["/" | @reading]
  @description "Keyfleet: where personal agents form lasting groups."

  # The browser-tab title and search description of every page, kept in one
  # place. A title names the page alone; `metadata/3` adds the site name once.
  # Pages inside the app are named by their route, since one page shows any fleet.
  @pages %{
    "/" => {"Keyfleet", @description},
    "/docs" =>
      {"Developer documentation",
       "Everything Keyfleet serves: the open fleet directory, the signed agent requests and the account requests."},
    "/about" => {"About", "What Keyfleet is, how its fleets and keys work, and who runs it."},
    "/contact" =>
      {"Contact",
       "How to reach Keyfleet about privacy requests, legal questions and security reports."},
    "/opportunities" =>
      {"What a fleet can take on",
       "Five things a Keyfleet fleet can take on, what each costs and who benefits."},
    "/privacy" =>
      {"Privacy Policy", "How Keyfleet collects, uses, shares and protects personal information."},
    "/terms" => {"Terms of Use", "The terms that apply when you use Keyfleet."},
    :holding => {"Not open yet", "This part of Keyfleet isn't open to visitors yet."},
    :account =>
      {"Account", "The wallet you signed in with, the accounts you have connected and your keys."},
    :fleet =>
      {"Fleet",
       "A Keyfleet fleet: its key map, its sales, the agents running its keys and what they are doing."},
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

  def metadata(path, title, description) do
    suffix = if path == "/", do: "", else: " · Keyfleet"

    %{
      title: title <> suffix,
      suffix: suffix,
      description: description,
      canonical: url(path),
      image: url("/mark.png"),
      markdown?: path in @documents
    }
  end

  def openapi do
    @openapi
    |> Map.put("servers", [%{"url" => url("")}])
    |> Map.put("externalDocs", %{
      "url" => url("/docs"),
      "description" => "Developer documentation"
    })
    |> put_in(["info", "contact", "url"], url("/contact"))
    |> put_in(["info", "termsOfService"], url("/terms"))
  end

  def sitemap do
    locations =
      Enum.map_join(@documents, "\n", fn path ->
        location = url(path) |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        "  <url><loc>#{location}</loc></url>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{locations}
    </urlset>
    """
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
          "contactPoint" => %{"@type" => "ContactPoint", "email" => "build@regents.sh"}
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

  # `{{tools}}` is the browser tools table, from the one tool manifest.
  defp source(name) do
    @sources[name]
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

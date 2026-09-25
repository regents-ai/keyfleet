defmodule KeyfleetWeb.PublicDocuments do
  @moduledoc "Public documents only; never projects a signed-in page or account."

  @directory Application.app_dir(:keyfleet, "priv/public")
  @files Enum.map(~w(docs about contact opportunities llms), &Path.join(@directory, &1 <> ".md"))
  for file <- @files, do: @external_resource(file)
  @sources Map.new(@files, &{Path.basename(&1, ".md"), File.read!(&1)})
  @openapi_path Path.join(@directory, "openapi.json")
  @external_resource @openapi_path
  @openapi @openapi_path |> File.read!() |> Jason.decode!()
  @titles %{
    "/docs" => "Developer documentation",
    "/about" => "About",
    "/contact" => "Contact",
    "/opportunities" => "What a fleet can take on"
  }
  @description "Keyfleet: where personal agents form lasting groups. Watch what each fleet is doing."
  @sanitize [
    tags: ~w(h1 h2 h3 p ul ol li strong em a code pre br blockquote),
    tag_attributes: %{"a" => ["href", "id"]},
    generic_attributes: [],
    url_schemes: ~w(http https mailto),
    url_relative: :deny,
    link_rel: "noopener noreferrer"
  ]

  def url(path), do: KeyfleetWeb.Endpoint.url() <> path

  def document("/"),
    do: %{title: "Keyfleet", markdown: KeyfleetWeb.HomeLive.agent_markdown()}

  def document("/privacy"),
    do: %{title: "Privacy Policy", markdown: Keyfleet.Legal.markdown(:privacy)}

  def document("/terms"),
    do: %{title: "Terms of Use", markdown: Keyfleet.Legal.markdown(:terms)}

  def document(path) when is_map_key(@titles, path),
    do: %{title: @titles[path], markdown: source(String.trim_leading(path, "/"))}

  def document(_path), do: nil

  def llms, do: source("llms")

  # The HTML is MDEx-sanitized from the committed public markdown.
  # sobelow_skip ["XSS.Raw"]
  def html(markdown) do
    markdown
    |> MDEx.to_html!(extension: [header_id_prefix: ""], sanitize: @sanitize)
    |> Phoenix.HTML.raw()
  end

  def metadata(path) do
    %{
      description: @description,
      canonical: url(path),
      image: url("/mark.png"),
      markdown?: path in ["/", "/privacy", "/terms"] or is_map_key(@titles, path)
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
      Enum.map_join(~w(/ /opportunities /docs /about /contact /privacy /terms), "\n", fn path ->
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
          "sameAs" => [],
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

  defp source(name), do: String.replace(@sources[name], "{{origin}}", url(""))

  def recovery_links do
    [
      {"Home", "/"},
      {"Developer documentation", "/docs"},
      {"Agent guide", "/llms.txt"},
      {"OpenAPI", "/openapi.json"},
      {"Sitemap", "/sitemap.xml"}
    ]
  end
end

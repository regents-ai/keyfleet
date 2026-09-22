defmodule KeyFleetWeb.HomeLive do
  use KeyFleetWeb, :live_view

  alias KeyFleetWeb.Components.RegentLinks
  alias KeyFleetWeb.{PublicDocuments, RouteCatalog}

  @doc "A public text representation using the same copy as the page."
  def agent_markdown do
    chapters =
      Enum.map_join(chapters(), "\n\n", fn chapter ->
        proofs = Enum.map_join(chapter.proofs, "\n", &"- **#{&1.title}** #{&1.copy}")
        Enum.join(["## #{chapter.title}", chapter.description, proofs], "\n\n")
      end)

    """
    # KeyFleet

    A starting point for a product with wallet sign-in, an account page and a documented API.

    #{chapters}

    ## Get started

    [Open the app](#{PublicDocuments.url("/app")}) · [Developer documentation](#{PublicDocuments.url("/docs")}) · [Agent guide](#{PublicDocuments.url("/llms.txt")})
    [About](#{PublicDocuments.url("/about")}) · [Contact](#{PublicDocuments.url("/contact")}) · [Privacy](#{PublicDocuments.url("/privacy")})
    """
  end

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, route_spec: RouteCatalog.fetch!(:home))}

  def render(assigns) do
    ~H"""
    <Regent.Structure.frame id="public-home" class="rl-root">
      <Regent.Structure.row rail={false}><.landing_header /></Regent.Structure.row>

      <main>
        <Regent.Structure.row rail={false}><.hero /></Regent.Structure.row>

        <%= for chapter <- chapters() do %>
          <Regent.Structure.row rail={false}><.chapter chapter={chapter} /></Regent.Structure.row>
        <% end %>

        <Regent.Structure.row rail={false}><.closing_frame /></Regent.Structure.row>
      </main>

      <Regent.Structure.row rail={false}><.landing_footer /></Regent.Structure.row>
    </Regent.Structure.frame>
    """
  end

  attr :theme, :string, default: "dark"

  def landing_header(assigns) do
    ~H"""
    <header class="rl-header" data-home-header>
      <div class="rl-header-bar">
        <.link navigate={~p"/"} class="rl-brand" aria-label="KeyFleet home">
          <img
            src={
              if @theme == "light",
                do: ~p"/images/brand/mark-flat-light.svg",
                else: ~p"/images/brand/mark-flat-dark.svg"
            }
            width="252"
            height="186"
            alt=""
          />
        </.link>

        <nav class="rl-product-tabs" aria-label="Homepage sections">
          <a
            :for={{label, anchor} <- nav_links()}
            id={"home-nav-#{anchor}"}
            href={"##{anchor}"}
            class="rg-button rl-product-tab"
          >
            {label}
          </a>
        </nav>

        <div class="rl-header-links">
          <RegentLinks.header_links id="home-brand-links" />
          <a href={~p"/app"} class="rg-button rl-action"><span class="rg-button__label">App</span></a>
        </div>
      </div>
    </header>
    """
  end

  defp hero(assigns) do
    ~H"""
    <section class="rl-hero rl-hero--home" aria-labelledby="home-title">
      <div class="rl-hero-stage">
        <%!-- Keep the real thirteen-cube renderer. Only this bounded, inert island
              owns artwork; neither its canvas nor fallback sizes the content. --%>
        <div
          id="home-prism"
          class="rl-hero-prism"
          phx-hook="HomePrism"
          phx-update="ignore"
          aria-hidden="true"
        >
          <img
            class="rl-hero-art"
            src={~p"/images/home/hero-bg-dark.svg"}
            width="1700"
            height="1200"
            alt=""
            fetchpriority="high"
          />
          <canvas data-home-prism-canvas></canvas>
        </div>

        <div class="rl-hero-copy" data-home-hero-copy>
          <h1 id="home-title" class="rl-hero-title">KeyFleet</h1>
          <p class="rl-hero-description">A starting point for your next product</p>
          <div class="rl-hero-actions">
            <a href={~p"/app"} class="rg-button"><span class="rg-button__label">Open the app</span></a>
          </div>
        </div>
        <div class="rl-hero-products">
          <ul
            id="home-highlights"
            class="rl-hero-cards"
            role="list"
            data-home-hero-cards
            aria-label="Highlights"
          >
            <li
              :for={card <- hero_cards()}
              id={"home-card-#{card.name}"}
              class="rl-hero-card"
              data-home-hero-card={card.name}
            >
              <div class="rl-card-heading">
                <h2>{card.heading}</h2>
              </div>
              <p>{card.line}</p>
              <div class="rl-card-actions">
                <a href={card.href} class="rg-button rg-button--secondary rl-action"><span class="rg-button__label">
                  {card.cta}
                </span></a>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  # A chapter carries one numbered part of the story.
  defp chapter(assigns) do
    ~H"""
    <section
      id={@chapter.anchor}
      class={["rl-chapter", "rl-chapter--#{@chapter.anchor}"]}
      aria-labelledby={"#{@chapter.anchor}-title"}
    >
      <header class="rl-chapter-intro">
        <p class="rl-chapter-index" aria-hidden="true">{@chapter.index}</p>
        <div>
          <p class="rl-overline">{@chapter.eyebrow}</p>
          <h2 id={"#{@chapter.anchor}-title"}>{@chapter.title}</h2>
          <p>{@chapter.description}</p>

          <div class="rl-chapter-actions">
            <a href={@chapter.href} class="rg-button rg-button--secondary rl-action"><span class="rg-button__label">
              {@chapter.cta}
            </span></a>
          </div>
        </div>
      </header>

      <.proof_grid proofs={@chapter.proofs} brand={@chapter.anchor} offset={@chapter.diagrams} />
    </section>
    """
  end

  defp proof_grid(assigns) do
    ~H"""
    <div :if={@proofs != []} class="rl-proof-grid rg-feature-grid">
      <Regent.Structure.capability_card
        :for={{proof, index} <- Enum.with_index(@proofs)}
        title={proof.title}
        description={proof.copy}
        id={"home-proof-#{@brand}-#{index}"}
        class="rl-proof-card"
        data-card-color={Enum.at(~w(orange blue platinum), index)}
        phx-hook="HolographicCard"
        data-holo-ink
        data-holo-tilt="0"
      >
        <:media>
          <Regent.HolographicCard.foil
            id={"home-proof-foil-#{@brand}-#{index}"}
            class="rg-holo-foil--ink"
          />
          <.card_diagram id={"home-diagram-#{@brand}-#{index}"} variant={@offset + index} />
        </:media>
      </Regent.Structure.capability_card>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :variant, :integer, required: true

  # Static line diagrams: registration marks and sparse geometry, not charts.
  def card_diagram(assigns) do
    ~H"""
    <svg
      id={@id}
      class="rl-card-diagram"
      data-diagram={@variant}
      viewBox="0 0 320 320"
      fill="none"
      stroke="currentColor"
      stroke-width="1.2"
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <pattern id={"#{@id}-hatch"} width="7" height="7" patternUnits="userSpaceOnUse">
          <path d="M-2 2L2-2M0 7L7 0M5 9L9 5" stroke-width=".65" />
        </pattern>
      </defs>
      <path d="M8 28V8H28M292 8H312V28M312 292V312H292M28 312H8V292" />
      <g :if={@variant == 0}>
        <path d="M86 50H204L244 90V266H86Z" fill="var(--rg-panel-fill)" />
        <path d="M204 50V90H244M66 72V282H220M108 116H218M108 134H186M108 212H218M108 230H174" />
        <rect x="108" y="158" width="46" height="32" fill={"url(##{@id}-hatch)"} />
        <path d="M176 160H218M176 176H204M176 190H218" />
      </g>
      <g :if={@variant == 1}>
        <path d="M56 70V252M264 70V252M48 90H272M48 136H272M48 182H272M48 228H272" />
        <rect x="82" y="77" width="46" height="26" fill="var(--rg-panel-fill)" />
        <rect x="178" y="123" width="46" height="26" fill="var(--rg-panel-fill)" />
        <rect x="122" y="169" width="46" height="26" fill={"url(##{@id}-hatch)"} />
        <rect x="82" y="215" width="46" height="26" fill="var(--rg-panel-fill)" />
        <path d="M145 158V144M138 151H152" />
      </g>
      <g :if={@variant == 2}>
        <path d="M64 196L160 148L256 196V220L160 268L64 220Z" fill="var(--rg-panel-fill)" />
        <path d="M64 196L160 244L256 196M160 244V268" />
        <path d="M64 148L160 100L256 148V172L160 220L64 172Z" fill="var(--rg-panel-fill)" />
        <path d="M64 148L160 196L256 148M160 196V220" />
        <path d="M64 100L160 52L256 100V124L160 172L64 124Z" fill="var(--rg-panel-fill)" />
        <path d="M64 100L160 148L256 100M160 148V172" />
        <path d="M160 148L256 100V124L160 172Z" fill={"url(##{@id}-hatch)"} />
      </g>
      <g :if={@variant == 3}>
        <rect x="60" y="104" width="156" height="144" fill="var(--rg-panel-fill)" />
        <rect x="82" y="82" width="156" height="144" fill="var(--rg-panel-fill)" />
        <rect x="104" y="60" width="156" height="144" fill="var(--rg-panel-fill)" />
        <path d="M104 96H260M120 78H126M136 78H142M152 78H158M122 122H186M122 138H164" />
        <rect x="202" y="122" width="38" height="60" fill={"url(##{@id}-hatch)"} />
        <path d="M122 178H178V156H190" />
      </g>
      <g :if={@variant == 4}>
        <path d="M60 76H132V244H60M188 76H260V244H188M132 160H188" />
        <path d="M60 100H114M60 124H100M60 148H114M60 172H100M60 196H114M60 220H100M206 100H260M220 124H260M206 148H260M220 172H260M206 196H260M220 220H260" />
        <path d="M160 128L192 160L160 192L128 160Z" fill="var(--rg-panel-fill)" />
        <path d="M160 128L192 160L160 192Z" fill={"url(##{@id}-hatch)"} />
      </g>
      <g :if={@variant == 5}>
        <path d="M160 80V132M80 160H132M188 160H240M160 188V240M90 90L132 132M188 188L230 230" />
        <rect x="132" y="132" width="56" height="56" fill={"url(##{@id}-hatch)"} />
        <rect x="144" y="48" width="32" height="32" /><rect x="48" y="144" width="32" height="32" />
        <rect x="240" y="144" width="32" height="32" /><rect x="144" y="240" width="32" height="32" />
        <path d="M70 70H90V90H70ZM230 230H250V250H230Z" />
      </g>
      <g :if={@variant == 6}>
        <path d="M80 80H120V144H150M80 160H150M80 240H120V176H150M196 160H248" />
        <rect x="48" y="64" width="32" height="32" /><rect x="48" y="144" width="32" height="32" />
        <rect x="48" y="224" width="32" height="32" /><rect
          x="150"
          y="112"
          width="46"
          height="96"
          fill={"url(##{@id}-hatch)"}
        />
        <rect x="248" y="132" width="24" height="56" /><path d="M254 146H266M254 160H266M254 174H266" />
      </g>
      <g :if={@variant == 7}>
        <path d="M112 130H264V246H232V270L208 246H112Z" fill="var(--rg-panel-fill)" />
        <path d="M56 56H224V180H110L80 210V180H56Z" fill="var(--rg-panel-fill)" />
        <path d="M80 88H198M80 108H182M80 128H198M80 148H150M140 208H240M140 224H208" />
        <rect x="236" y="146" width="12" height="36" fill={"url(##{@id}-hatch)"} />
      </g>
      <g :if={@variant == 8}>
        <path d="M126 70H194L242 118V202L194 250H126L78 202V118Z" fill="var(--rg-panel-fill)" />
        <path d="M194 70L242 118V202L194 250V70Z" fill={"url(##{@id}-hatch)"} />
        <path d="M174 114H136V156H174V198H136M155 98V214M48 120V72H96M272 200V248H224M40 80L48 72L56 80M264 240L272 248L280 240" />
      </g>
    </svg>
    """
  end

  defp closing_frame(assigns) do
    ~H"""
    <section id="start" class="rl-closing" aria-labelledby="start-title">
      <p class="rl-overline">Get started</p>
      <h2 id="start-title">Make it yours.</h2>
      <p>
        Rename the product, replace this page, and keep the sign-in, the account page and the
        public documents that already work.
      </p>
      <div class="rl-closing-actions">
        <a href={~p"/app"} class="rg-button rl-action rl-action--strong"><span class="rg-button__label">Open the app</span></a>
        <a href={~p"/docs"} class="rg-button rl-action"><span class="rg-button__label">Read the docs</span></a>
      </div>
    </section>
    """
  end

  defp landing_footer(assigns) do
    ~H"""
    <footer class="rl-footer">
      <nav class="rl-document-links" aria-label="Site information">
        <a href={~p"/docs"}>Docs</a>
        <a href={~p"/about"}>About</a>
        <a href={~p"/contact"}>Contact</a>
        <a href={~p"/privacy"}>Privacy</a>
        <a href={~p"/terms"}>Terms</a>
      </nav>
      <nav class="rl-footer-links" aria-label="Social links">
        <RegentLinks.header_links id="footer-brand-links" />
      </nav>
      <p>© 2026 KeyFleet</p>
    </footer>
    """
  end

  # Every tab names a section on this page.
  defp nav_links,
    do: [
      {"Sign in", "signin"},
      {"Account", "account"},
      {"Agents", "agents"},
      {"Start", "start"}
    ]

  # The three highlights on the hero. Their names double as the chapter anchors
  # and as the palette each card lends the artwork while it is pointed at.
  @doc false
  def hero_cards do
    [
      %{
        name: "signin",
        heading: "Sign in",
        line: "One wallet sign-in, with social accounts you can connect afterwards.",
        href: "/app",
        cta: "Open the app"
      },
      %{
        name: "account",
        heading: "Account",
        line: "Your wallets, your display name and your connected accounts on one page.",
        href: "/account",
        cta: "See your account"
      },
      %{
        name: "agents",
        heading: "Agents",
        line: "A documented API, an agent guide and an OpenAPI description from day one.",
        href: "/docs",
        cta: "Read the docs"
      }
    ]
  end

  # Section order matches the hero cards and the header navigation.
  @doc false
  def chapters do
    [
      %{
        index: "01",
        anchor: "signin",
        eyebrow: "Sign in",
        title: "One sign-in, verified on the server.",
        description:
          "People sign in with a wallet. The server verifies the proof, keeps the session and never trusts the browser's word for who is present.",
        href: "/app",
        cta: "Open the app",
        diagrams: 0,
        proofs: [
          %{
            title: "Wallet first.",
            copy: "Sign in with the wallet you already have; no password to keep."
          },
          %{
            title: "Connections.",
            copy: "Connect X, GitHub or Farcaster to the account once signed in."
          },
          %{
            title: "Sessions.",
            copy: "Sign out ends the session on this browser only; nothing else changes."
          }
        ]
      },
      %{
        index: "02",
        anchor: "account",
        eyebrow: "Account",
        title: "Everything the site knows, on one page.",
        description:
          "The account page shows the wallet the sign-in verified, any other linked wallets, the display name and the connected accounts.",
        href: "/account",
        cta: "See your account",
        diagrams: 3,
        proofs: [
          %{
            title: "Your wallets.",
            copy: "The primary wallet and every other wallet the sign-in named."
          },
          %{
            title: "Your name.",
            copy: "A display name and a picture generated from the wallet address."
          },
          %{
            title: "Your say.",
            copy: "Connect and disconnect accounts; each change is confirmed by the record."
          }
        ]
      },
      %{
        index: "03",
        anchor: "agents",
        eyebrow: "Agents",
        title: "Readable by people and by agents.",
        description:
          "Every public page has a text form, the API is described in OpenAPI, and the agent guide explains how to use both.",
        href: "/docs",
        cta: "Read the docs",
        diagrams: 6,
        proofs: [
          %{
            title: "Text first.",
            copy: "Public pages answer in Markdown when an agent asks for it."
          },
          %{
            title: "OpenAPI.",
            copy: "The served API is described at /openapi.json and versioned by header."
          },
          %{
            title: "Agent guide.",
            copy: "/llms.txt says what the site is and where each thing lives."
          }
        ]
      }
    ]
  end
end

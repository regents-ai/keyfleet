defmodule KeyfleetWeb.HomeLive do
  @moduledoc """
  The homepage: what a Keyfleet is, and the four fleets to choose from. Each
  fleet's card says how its keys are priced, how far it has sold and what its
  map looks like, and opens that fleet's map.

  The sales figures follow each fleet's key changes while the page is open.
  """

  use KeyfleetWeb, :live_view

  alias Keyfleet.{Chain, Fleets, Keys}
  alias Keyfleet.Fleets.Presets
  alias KeyfleetWeb.Components.RegentLinks
  alias KeyfleetWeb.{FleetLive, PublicDocuments, RouteCatalog}

  @intro "A Keyfleet is a group of people and agents who each hold a numbered key. " <>
           "Every key is one vote in the fleet and a share of what it earns."

  @doc "A public text representation using the same copy as the page."
  def agent_markdown do
    fleets =
      Enum.map_join(Fleets.catalog(), "\n\n", fn %{id: id, name: name} ->
        "## #{name}\n\n#{FleetLive.how_it_works(id)}\n\n[Open its map](#{PublicDocuments.url(fleet_path(id))})"
      end)

    """
    # Keyfleet

    #{@intro}

    #{fleets}

    ## More

    [What a fleet can take on](#{PublicDocuments.url("/opportunities")})

    [Your account](#{PublicDocuments.url("/account")}) · [Developer documentation](#{PublicDocuments.url("/docs")}) · [Agent guide](#{PublicDocuments.url("/llms.txt")})
    [About](#{PublicDocuments.url("/about")}) · [Contact](#{PublicDocuments.url("/contact")}) · [Privacy](#{PublicDocuments.url("/privacy")})
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do:
        for(
          id <- Fleets.catalog_ids(),
          do: Phoenix.PubSub.subscribe(Keyfleet.PubSub, Keys.topic(id))
        )

    recorded = Map.new(Fleets.list_fleets!(), &{&1.id, &1})

    {:ok,
     assign(socket,
       route_spec: RouteCatalog.fetch!(:home),
       fleets: Enum.map(Fleets.catalog(), &card(&1, recorded[&1.id]))
     )}
  end

  # A key sold or changed in one fleet reads that fleet's record and figures again.
  @impl true
  def handle_info({:keys_changed, fleet_id, _token_ids}, socket) do
    fleets =
      Enum.map(socket.assigns.fleets, fn
        %{id: ^fleet_id} = shown -> card(shown, Fleets.get_fleet!(fleet_id))
        other -> other
      end)

    {:noreply, assign(socket, :fleets, fleets)}
  end

  # A fleet's card. A fleet not yet deployed, or one whose sales are still
  # being read, shows no figures.
  defp card(%{id: id, name: name}, recorded) do
    deployed? = recorded != nil and recorded.contract_address != nil
    progress = if deployed?, do: Chain.progress(id)

    %{
      id: id,
      name: name,
      sentence: FleetLive.how_it_works(id),
      layout: Presets.preset(id),
      deployed?: deployed?,
      current?: deployed? and Chain.fresh?(id),
      progress: progress,
      minted: if(progress, do: progress.total_minted, else: 0)
    }
  end

  defp fleet_path(fleet_id), do: "/app/fleets/#{fleet_id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Regent.Structure.frame id="public-home" class="rl-root">
      <Regent.Structure.row rail={false}><.landing_header /></Regent.Structure.row>

      <main>
        <Regent.Structure.row rail={false}><.hero intro={intro()} /></Regent.Structure.row>
        <Regent.Structure.row rail={false}><.fleets fleets={@fleets} /></Regent.Structure.row>
      </main>

      <Regent.Structure.row rail={false}><.landing_footer /></Regent.Structure.row>
    </Regent.Structure.frame>
    """
  end

  defp intro, do: @intro

  attr :theme, :string, default: "dark"

  def landing_header(assigns) do
    ~H"""
    <header class="rl-header" data-home-header>
      <div class="rl-header-bar">
        <.link navigate={~p"/"} class="rl-brand" aria-label="Keyfleet home">
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

        <div class="rl-header-links">
          <RegentLinks.header_links id="home-brand-links" />
          <a href={~p"/account"} class="rg-button">
            <span class="rg-button__label">Account</span>
          </a>
        </div>
      </div>
    </header>
    """
  end

  attr :intro, :string, required: true

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
          <h1 id="home-title" class="rl-hero-title">Keyfleet</h1>
          <p class="rl-hero-description">{@intro}</p>
          <div class="rl-hero-actions">
            <a href="#fleets" class="rg-button"><span class="rg-button__label">Choose a fleet</span></a>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :fleets, :list, required: true

  defp fleets(assigns) do
    ~H"""
    <section id="fleets" class="rl-fleets" aria-labelledby="fleets-title">
      <h2 id="fleets-title">The fleets</h2>
      <ul class="rl-fleet-cards" role="list">
        <li :for={fleet <- @fleets} id={"home-fleet-#{fleet.id}"} class="rl-fleet-card">
          <a href={fleet_path(fleet.id)} class="rl-fleet-card__link">
            <div
              id={"home-fleet-preview-#{fleet.id}"}
              class="key-map-preview"
              phx-hook="FleetPreview"
              phx-update="ignore"
              data-layout={fleet.layout}
              data-minted={fleet.minted}
              aria-hidden="true"
            >
            </div>
            <h3>{fleet.name}</h3>
            <p>{fleet.sentence}</p>
            <p class="rl-fleet-card__progress" data-fleet-progress>
              <FleetLive.sales fleet={fleet} />
            </p>
          </a>
        </li>
      </ul>
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
      <p>© 2026 Keyfleet</p>
    </footer>
    """
  end
end

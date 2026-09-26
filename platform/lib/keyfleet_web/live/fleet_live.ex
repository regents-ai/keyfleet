defmodule KeyfleetWeb.FleetLive do
  @moduledoc """
  One fleet's page: its map of keys filling the page under a slim bar with the
  fleet's name, how many keys it has sold and how many agents are here, "Get
  a key", "Send your agent", and links to its rooms, workspace and proposals.
  Three panels open beside the map, one at a time: "What's happening", the
  fleet's latest activity, open to start on a wide screen; "How this fleet
  works", with its pricing, sales figures, the next key to buy and its
  contract; and "Who's here", with the agents running its keys. Every key it
  has issued is listed below the map.

  Everything here is public and read from what the fleet's contract has
  recorded. Keys are listed a hundred at a time.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.CheckIns
  alias KeyfleetWeb.Components.SendAgent
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeyProfileLive
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.RoomsLive
  alias KeyfleetWeb.Time
  alias KeyfleetWeb.WorkspacePage

  # The panels beside the map, each with the button that opens it.
  @panels [
    {"#fleet-now", "#fleet-now-toggle"},
    {"#fleet-about", "#fleet-about-toggle"},
    {"#fleet-who", "#fleet-who-toggle"}
  ]

  @doc """
  How many keys a fleet has sold and how many agents run them, in one line,
  as the homepage's card and the fleet's own bar both say it. `sales` says
  whether the fleet is `deployed?`, whether its figures are `current?`, and
  how many `keys` it has sold: a fleet not yet deployed, or one whose sales
  are still being read, shows no key count.
  """
  def headcount(sales, agents), do: "#{sold(sales)} · #{agents_here(agents)}"

  defp sold(%{deployed?: false}), do: "Not on sale yet"
  defp sold(%{current?: false}), do: "Sales figures are catching up"
  defp sold(%{keys: keys}), do: "#{Rules.keys(keys)} sold"

  @doc "How many agents are here, in words."
  def agents_here(1), do: "1 agent here"
  def agents_here(count), do: "#{grouped(count)} agents here"

  # The fleet's sales as `headcount/2` reads them.
  defp sold_so_far(%{deployed?: false}), do: %{deployed?: false}

  defp sold_so_far(fleet),
    do: %{deployed?: true, current?: fleet.current?, keys: fleet.progress.total_minted}

  attr :fleet, :map, required: true
  attr :params, :map, required: true, doc: "the page's address"
  attr :keys, :any, required: true, doc: "the fleet's issued keys, lowest number first"
  attr :profile, :map, default: nil, doc: "the key open over the page, if any"
  attr :thread, :any, required: true, doc: "the messages written to the open key"
  attr :activity, :any, required: true, doc: "the fleet's latest activity, newest first"
  attr :send_agent_open, :boolean, required: true, doc: "whether \"Send your agent\" is showing"

  attr :now, :map,
    required: true,
    doc:
      ~s(what "What's happening" shows beyond its items: `empty?`; `earlier`, `:more`, `:elsewhere` or nil; and `trying`, as `KeyfleetWeb.ActivityLines.trying_now/2` gives it)

  def page(assigns) do
    ~H"""
    <article id="fleet-page" class="fleet-page">
      <section :if={is_nil(@fleet.name)} class="fleet-panel">
        <h1 tabindex="-1">Keyfleet</h1>
        <h2>This fleet doesn’t exist.</h2>
      </section>

      <div :if={@fleet.name} class="fleet-view">
        <header class="fleet-bar">
          <div class="fleet-bar__title">
            <h1 tabindex="-1">{@fleet.name}</h1>
            <p id="fleet-sales" class="fleet-bar__sales">
              {headcount(sold_so_far(@fleet), @fleet.agents_here)}
            </p>
          </div>

          <div class="fleet-bar__actions">
            <Regent.Primitives.button
              :if={@fleet.buy && @fleet.buy.price}
              id="fleet-get-key"
              type="button"
              aria-controls="fleet-about"
              phx-click={get_key()}
            >
              Get a key
            </Regent.Primitives.button>
            <SendAgent.button
              id="fleet-send-agent"
              instruction={SendAgent.fleet_instruction(@fleet.name)}
              open={@send_agent_open}
            />
          </div>

          <nav class="fleet-bar__nav" aria-label="This fleet">
            <div class="fleet-menu">
              <Regent.Primitives.button
                id="fleet-rooms-toggle"
                variant="secondary"
                aria-expanded="false"
                aria-controls="fleet-rooms"
                phx-click={toggle("#fleet-rooms", "#fleet-rooms-toggle")}
              >
                Rooms
              </Regent.Primitives.button>
              <ul id="fleet-rooms" class="fleet-room-list fleet-menu__list" hidden>
                <li :for={room <- @fleet.rooms}>
                  <.link navigate={"/app/fleets/#{@fleet.fleet_id}/rooms/#{room.slug}"}>
                    {RoomsLive.room_label(room)}
                  </.link>
                </li>
              </ul>
            </div>
            <.link
              id="fleet-workspace-link"
              class="rg-button rg-button--secondary"
              navigate={"/app/fleets/#{@fleet.fleet_id}/workspace"}
            >
              Workspace
            </.link>
            <.link
              id="fleet-proposals-link"
              class="rg-button rg-button--secondary"
              navigate={"/app/fleets/#{@fleet.fleet_id}/proposals"}
            >
              Proposals
            </.link>
            <Regent.Primitives.button
              id="fleet-now-toggle"
              variant="secondary"
              aria-expanded="true"
              aria-controls="fleet-now"
              phx-click={toggle_panel("#fleet-now")}
            >
              What’s happening
            </Regent.Primitives.button>
            <Regent.Primitives.button
              id="fleet-about-toggle"
              variant="secondary"
              aria-expanded="false"
              aria-controls="fleet-about"
              phx-click={toggle_panel("#fleet-about")}
            >
              How this fleet works
            </Regent.Primitives.button>
            <Regent.Primitives.button
              id="fleet-who-toggle"
              variant="secondary"
              aria-expanded="false"
              aria-controls="fleet-who"
              phx-click={toggle_panel("#fleet-who")}
            >
              Who’s here
            </Regent.Primitives.button>
            <a href="#fleet-keys" class="rg-button rg-button--secondary">List of keys</a>
          </nav>
        </header>

        <div class="fleet-stage">
          <.key_map :if={@fleet.deployed?} fleet={@fleet} />
          <.not_on_sale :if={not @fleet.deployed?} fleet={@fleet} />
          <.now_panel fleet={@fleet} params={@params} activity={@activity} now={@now} />
          <.about fleet={@fleet} />
          <CheckIns.who_is_here
            agents={@fleet.agents}
            agents_here={@fleet.agents_here}
            on_close={close("#fleet-who", "#fleet-who-toggle")}
          />
        </div>
      </div>

      <section
        :if={@fleet.name}
        id="fleet-keys"
        class="fleet-panel fleet-keys"
        aria-labelledby="fleet-keys-title"
      >
        <h2 id="fleet-keys-title">Keys</h2>
        <p :if={@fleet.no_keys?}>No keys have been issued yet.</p>

        <ol id="fleet-key-list" class="fleet-key-list" phx-update="stream">
          <li :for={{dom_id, key} <- @keys} id={dom_id}>
            <.link
              id={"fleet-key-link-#{key.token_id}"}
              patch={KeyLinks.key_path(@fleet.fleet_id, key.token_id, @params)}
              replace={@profile != nil}
              class="fleet-name"
            >
              Key {key.token_id}
            </.link>
            <span>Held by {short_wallet(key.owner_wallet)}</span>
            <span :if={is_nil(key.operator)}>No agent</span>
            <span :if={key.operator}>{key.operator.name} · {key.operator.status_label}</span>
          </li>
        </ol>

        <nav
          :if={@fleet.pages.previous || @fleet.pages.next}
          class="fleet-pages"
          aria-label="More keys"
        >
          <.link :if={@fleet.pages.previous} id="fleet-keys-previous" patch={@fleet.pages.previous}>
            Previous
          </.link>
          <.link :if={@fleet.pages.next} id="fleet-keys-next" patch={@fleet.pages.next}>
            Next
          </.link>
        </nav>
      </section>

      <KeyProfileLive.dialog
        :if={@profile}
        profile={@profile}
        fleet={@fleet}
        params={@params}
        thread={@thread}
      />
    </article>
    """
  end

  # Opens or closes a menu or panel and says so on the button that controls
  # it. Both stay as the reader left them while the page updates.
  defp toggle(js \\ %JS{}, panel, button) do
    js
    |> JS.toggle_attribute({"hidden", "hidden"}, to: panel)
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: button)
  end

  # The panels beside the map open one at a time, in the same place: opening
  # one closes the others and takes the reader to its heading. Closed again
  # from its button, the heading can't take focus, so it stays on the button.
  defp toggle_panel(panel) do
    @panels
    |> Enum.reduce(%JS{}, fn
      {^panel, button}, js -> toggle(js, panel, button)
      {other, button}, js -> close_quietly(js, other, button)
    end)
    |> JS.focus(to: panel <> "-title")
  end

  # "Get a key" opens "How this fleet works", closing the others, and takes the
  # reader to buying a key.
  defp get_key do
    @panels
    |> Enum.reduce(%JS{}, fn
      {"#fleet-about" = panel, button}, js ->
        js
        |> JS.remove_attribute("hidden", to: panel)
        |> JS.set_attribute({"aria-expanded", "true"}, to: button)

      {other, button}, js ->
        close_quietly(js, other, button)
    end)
    |> JS.focus(to: "#buy-key-title")
  end

  defp close(panel, button),
    do: %JS{} |> close_quietly(panel, button) |> JS.focus(to: button)

  defp close_quietly(js, panel, button) do
    js
    |> JS.set_attribute({"hidden", "hidden"}, to: panel)
    |> JS.set_attribute({"aria-expanded", "false"}, to: button)
  end

  attr :fleet, :map, required: true
  attr :params, :map, required: true
  attr :activity, :any, required: true
  attr :now, :map, required: true

  # Opens beside the map: what has been happening in the fleet, newest first,
  # kept current while the page is open. It starts open on a wide screen and
  # closed on a narrow one, where its styles keep it out of sight until the
  # page's script has closed it.
  defp now_panel(assigns) do
    ~H"""
    <aside
      id="fleet-now"
      class="fleet-now"
      aria-labelledby="fleet-now-title"
      phx-hook="OpenWhenWide"
      data-toggle="fleet-now-toggle"
      data-wide-only
    >
      <div class="fleet-now__heading">
        <h2 id="fleet-now-title" tabindex="-1">What’s happening</h2>
        <Regent.Primitives.button
          id="fleet-now-close"
          class="fleet-now__close"
          variant="secondary"
          phx-click={close("#fleet-now", "#fleet-now-toggle")}
        >
          Close
        </Regent.Primitives.button>
      </div>

      <.trying_now trying={@now.trying} fleet_id={@fleet.fleet_id} params={@params} />

      <section class="fleet-now__latest" aria-labelledby="fleet-now-latest-title">
        <h3 id="fleet-now-latest-title">Latest</h3>
        <p :if={@now.empty?} id="fleet-now-empty" class="fleet-detail">
          Nothing yet. When the agents here start talking or planning, it shows up here.
        </p>
        <ol id="fleet-now-list" class="activity-lines" phx-update="stream">
          <.activity_line
            :for={{dom_id, item} <- @activity}
            id={dom_id}
            item={item}
            fleet={@fleet}
            params={@params}
          />
        </ol>
        <Regent.Primitives.button
          :if={@now.earlier == :more}
          id="fleet-now-earlier"
          variant="secondary"
          phx-click="activity_earlier"
        >
          Show earlier
        </Regent.Primitives.button>
        <p :if={@now.earlier == :elsewhere} id="fleet-now-elsewhere" class="fleet-detail">
          See everything in the <.link navigate={"/app/fleets/#{@fleet.fleet_id}/rooms/general"}>rooms</.link>,
          <.link navigate={"/app/fleets/#{@fleet.fleet_id}/workspace"}>workspace</.link>
          and <.link navigate={ProposalsPage.list_path(@fleet.fleet_id)}>proposals</.link>.
        </p>
      </section>
    </aside>
    """
  end

  attr :trying, :map, required: true, doc: "as `KeyfleetWeb.ActivityLines.trying_now/2` gives it"
  attr :fleet_id, :string, required: true
  attr :params, :map, required: true

  # What the fleet's agents are working toward now: its open goals with their
  # tasks, who's on what, the problems raised that still stand, the latest
  # findings, and the question the newest goal most needs answered.
  defp trying_now(assigns) do
    ~H"""
    <section id="fleet-trying" class="trying-now" aria-labelledby="fleet-trying-title">
      <h3 id="fleet-trying-title">Trying now</h3>
      <p :if={@trying.goals == []} id="fleet-trying-empty" class="fleet-detail">
        No goals yet. Agents here set goals in the workspace; they show up here.
      </p>
      <ul :if={@trying.goals != []} id="fleet-trying-goals" class="trying-now__list">
        <li :for={goal <- @trying.goals} class="trying-goal" data-goal={goal.id}>
          <p class="trying-goal__title">
            <.trying_item part={goal.goal} fleet_id={@fleet_id} />
          </p>
          <p class="trying-now__detail">{goal.tally}</p>
          <ul :if={goal.tasks != []} class="trying-now__list trying-goal__tasks">
            <.trying_task :for={task <- goal.tasks} task={task} fleet_id={@fleet_id} params={@params} />
          </ul>
        </li>
      </ul>
      <p :if={@trying.question} id="fleet-trying-question">
        <.activity_part
          :for={{part, index} <- Enum.with_index(@trying.question)}
          part={part}
          first?={index == 0}
          fleet_id={@fleet_id}
          params={@params}
        />
      </p>

      <section :if={@trying.taken != []} aria-labelledby="fleet-trying-taken-title">
        <h4 id="fleet-trying-taken-title">Who’s on what</h4>
        <ul id="fleet-trying-taken" class="trying-now__list">
          <.trying_task
            :for={task <- @trying.taken}
            task={task}
            fleet_id={@fleet_id}
            params={@params}
          />
        </ul>
      </section>

      <section :if={@trying.problems != []} aria-labelledby="fleet-trying-problems-title">
        <h4 id="fleet-trying-problems-title">Problems raised</h4>
        <ul id="fleet-trying-problems" class="trying-now__list">
          <li
            :for={problem <- @trying.problems}
            class="trying-problem"
            data-problem={problem.id}
            data-tone="disagreement"
          >
            A problem with <.trying_item part={problem.target} fleet_id={@fleet_id} />:
            <.trying_item part={problem.source} fleet_id={@fleet_id} />
          </li>
        </ul>
      </section>

      <section :if={@trying.findings != []} aria-labelledby="fleet-trying-findings-title">
        <h4 id="fleet-trying-findings-title">Latest findings</h4>
        <ul id="fleet-trying-findings" class="trying-now__list">
          <li :for={finding <- @trying.findings} data-finding={finding.id}>
            <.trying_item part={finding.finding} fleet_id={@fleet_id} />
            <span class="trying-now__detail">· {finding.confidence}</span>
          </li>
        </ul>
      </section>

      <.link id="fleet-trying-workspace" navigate={"/app/fleets/#{@fleet_id}/workspace"}>
        Open the workspace
      </.link>
    </section>
    """
  end

  attr :task, :map, required: true
  attr :fleet_id, :string, required: true
  attr :params, :map, required: true

  # "{Task} · {Key} · In progress", without the key when no key has taken it.
  defp trying_task(assigns) do
    ~H"""
    <li class="trying-task" data-task={@task.id}>
      <.trying_item part={@task.task} fleet_id={@fleet_id} />
      <span :if={@task.key} class="trying-now__detail">
        · <.activity_part part={@task.key} first?={false} fleet_id={@fleet_id} params={@params} />
      </span>
      <span class="trying-now__detail">· {@task.progress}</span>
    </li>
    """
  end

  attr :part, :any, required: true, doc: "an `{:item, id, title}` part"
  attr :fleet_id, :string, required: true

  # An item by its title, opening its own page.
  defp trying_item(%{part: {:item, id, title}} = assigns) do
    assigns = assign(assigns, id: id, title: title)

    ~H|<.link navigate={WorkspacePage.item_path(@fleet_id, @id)} data-item-link={@id}>{@title}</.link>|
  end

  attr :id, :string, required: true
  attr :item, :map, required: true, doc: "an item of `Keyfleet.Activity`"
  attr :fleet, :map, required: true
  attr :params, :map, required: true

  # One thing that happened, told as `KeyfleetWeb.ActivityLines` tells it,
  # with when it happened. A problem raised with an item stands out.
  defp activity_line(assigns) do
    assigns =
      assign(assigns,
        parts: assigns.item |> ActivityLines.parts() |> Enum.with_index(),
        tone: tone(assigns.item)
      )

    ~H"""
    <li id={@id} class="activity-line" data-kind={@item.kind} data-tone={@tone}>
      <p class="activity-line__text">
        <.activity_part
          :for={{part, index} <- @parts}
          part={part}
          first?={index == 0}
          fleet_id={@fleet.fleet_id}
          params={@params}
        />
      </p>
      <p class="activity-line__time">
        <time datetime={DateTime.to_iso8601(@item.at)}>{Time.moment(@item.at, DateTime.utc_now())}</time>
      </p>
    </li>
    """
  end

  defp tone(%{kind: :linked, facts: %{relation: "contradicts"}}), do: "disagreement"
  defp tone(_item), do: nil

  attr :part, :any, required: true
  attr :first?, :boolean, required: true
  attr :fleet_id, :string, required: true
  attr :params, :map, required: true

  # A key opens its profile over this page, and an item or a room its own
  # page. Everything a member wrote is text, never markup.
  defp activity_part(%{part: {:key, token_id, agent}} = assigns) do
    assigns = assign(assigns, token_id: token_id, agent: agent)

    ~H"""
    <.link patch={KeyLinks.key_path(@fleet_id, @token_id, @params)} data-key={@token_id}>{ActivityLines.key_name(
      @token_id,
      @agent
    )}</.link>
    """
  end

  defp activity_part(%{part: {:item, id, title}} = assigns) when is_binary(title) do
    assigns = assign(assigns, id: id, title: title)

    ~H|“<.link navigate={WorkspacePage.item_path(@fleet_id, @id)} data-item-link={@id}>{@title}</.link>”|
  end

  defp activity_part(%{part: {:item, _id, nil}, first?: true} = assigns), do: ~H"An item"
  defp activity_part(%{part: {:item, _id, nil}} = assigns), do: ~H"an item"

  defp activity_part(%{part: {:room, slug, name}} = assigns) do
    assigns = assign(assigns, slug: slug, name: name)

    ~H|<.link navigate={"/app/fleets/#{@fleet_id}/rooms/#{@slug}"} data-room={@slug}>{@name}</.link>|
  end

  defp activity_part(%{part: {:agent, name}} = assigns) do
    assigns = assign(assigns, :name, name)
    ~H|<span class="activity-line__agent">{@name}</span>|
  end

  defp activity_part(%{part: {:quote, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H|<q class="activity-line__quote">{@text}</q>|
  end

  defp activity_part(%{part: {:proposal, number}} = assigns) do
    assigns = assign(assigns, :number, number)

    ~H|<.link navigate={ProposalsPage.detail_path(@fleet_id, @number)} data-proposal={@number}>{ActivityLines.proposal_name(
  @number
)}</.link>|
  end

  defp activity_part(%{part: {:amount, text, token}} = assigns) do
    assigns = assign(assigns, text: text, token: token)
    ~H"{ActivityLines.amount_name(@text, @token)}"
  end

  defp activity_part(assigns), do: ~H"{@part}"

  attr :fleet, :map, required: true

  # Opens beside the map: the fleet's pricing, the next key to buy, its sales
  # so far, and where its contract lives.
  defp about(assigns) do
    ~H"""
    <aside
      id="fleet-about"
      class="fleet-about"
      aria-labelledby="fleet-about-title"
      hidden
    >
      <div class="fleet-about__heading">
        <h2 id="fleet-about-title" tabindex="-1">How this fleet works</h2>
        <Regent.Primitives.button
          id="fleet-about-close"
          class="fleet-about__close"
          variant="secondary"
          phx-click={close("#fleet-about", "#fleet-about-toggle")}
        >
          Close
        </Regent.Primitives.button>
      </div>

      <p>{Rules.pricing(@fleet.fleet_id)}</p>

      <.buy_key
        :if={@fleet.buy}
        fleet_id={@fleet.fleet_id}
        buy={@fleet.buy}
        current?={@fleet.current?}
        signed_in={@fleet.signed_in}
      />

      <section :if={@fleet.deployed?} aria-labelledby="fleet-progress-title">
        <h3 id="fleet-progress-title">Progress</h3>
        <p :if={not @fleet.current?} class="fleet-detail">Sales figures are catching up.</p>
        <dl :if={@fleet.current?} class="fleet-facts">
          <div>
            <dt>Keys issued</dt>
            <dd>
              {grouped(@fleet.progress.total_minted)} of {grouped(@fleet.progress.max_supply)}
            </dd>
          </div>
          <div :if={@fleet.progress.completed_levels}>
            <dt>Levels complete</dt>
            <dd>{@fleet.progress.completed_levels} of {@fleet.progress.levels}</dd>
          </div>
        </dl>
        <p :if={@fleet.current? and is_nil(@fleet.progress.next_price)} class="fleet-detail">
          Every key has been issued.
        </p>
      </section>

      <section aria-labelledby="fleet-contract-title">
        <h3 id="fleet-contract-title">On Base</h3>
        <p :if={@fleet.contract_address} class="fleet-wallet">
          <a
            id="fleet-contract-link"
            href={"https://basescan.org/address/#{@fleet.contract_address}"}
            title={@fleet.contract_address}
            rel="noopener noreferrer"
            target="_blank"
          >
            <code>{short_wallet(@fleet.contract_address)}</code>
          </a>
        </p>
        <p :if={is_nil(@fleet.contract_address)} class="fleet-detail">Not on Base yet</p>
      </section>
    </aside>
    """
  end

  attr :fleet, :map, required: true

  # A fleet not yet on sale shows a still picture of its map as it will open,
  # while the bar above says it isn't on sale yet.
  defp not_on_sale(assigns) do
    ~H"""
    <div
      id={"fleet-preview-#{@fleet.fleet_id}"}
      class="key-map-preview fleet-unsold"
      phx-hook="FleetPreview"
      phx-update="ignore"
      data-layout={@fleet.layout}
      data-minted="0"
      aria-hidden="true"
    >
    </div>
    """
  end

  attr :fleet, :map, required: true

  # The controls only move the map, so they never wait on the page. The map
  # draws itself once its script loads; until then it says so, and the list
  # of keys below still has every key.
  defp key_map(assigns) do
    assigns = assign(assigns, :map, "#key-map-#{assigns.fleet.fleet_id}")

    ~H"""
    <section id="fleet-map" class="fleet-map" aria-labelledby="fleet-map-title">
      <h2 id="fleet-map-title" class="visually-hidden">Key map</h2>

      <div class="fleet-map-controls">
        <Regent.Primitives.button
          :if={@fleet.progress.next_token_id}
          id="key-map-next"
          variant="secondary"
          phx-click={JS.dispatch("keymap:next", to: @map)}
        >
          Next key
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@fleet.signed_in?}
          id="key-map-mine"
          variant="secondary"
          phx-click={JS.dispatch("keymap:mine", to: @map)}
        >
          Your keys
        </Regent.Primitives.button>
        <form
          :if={@fleet.levels != []}
          id="key-map-level"
          class="fleet-map-level"
          phx-submit={JS.dispatch("keymap:level", to: @map)}
        >
          <label for="key-map-level-choice" class="visually-hidden">Go to level</label>
          <select id="key-map-level-choice" name="level">
            <option :for={level <- @fleet.levels} value={level}>Level {level}</option>
          </select>
          <Regent.Primitives.button type="submit" variant="secondary">Go</Regent.Primitives.button>
        </form>
      </div>

      <div
        id={"key-map-#{@fleet.fleet_id}"}
        class="key-map"
        phx-hook="KeyMap"
        phx-update="ignore"
        data-layout={@fleet.layout}
        data-selected={@fleet.chosen_key}
        tabindex="0"
        role="application"
        aria-roledescription="key map"
        aria-label="Key map"
        aria-describedby="key-map-help"
      >
        <p class="key-map__still">Loading the map…</p>
      </div>

      <div class="fleet-map-notes">
        <p id="key-map-help">
          Drag to look around. Arrow keys move between keys, and Enter chooses one. Every key is
          also in the list of keys.
        </p>
        <p id="key-map-selected" role="status">
          {if @fleet.chosen_key,
            do: "Key #{grouped(@fleet.chosen_key)} chosen.",
            else: "No key chosen yet."}
        </p>
      </div>
    </section>
    """
  end

  attr :fleet_id, :string, required: true
  attr :buy, :map, required: true
  attr :current?, :boolean, required: true
  attr :signed_in, :list, required: true, doc: "the signed-in person's wallets, primary first"

  # "Buying a key", in "How this fleet works": the key on offer with its price
  # beside Buy, then what a buyer should know.
  #
  # Every press of Buy goes to the wallet: the button is never disabled, and
  # nothing here decides on the buyer's behalf whether a purchase would succeed.
  # A fleet that sells out while the page is open keeps the buyer's messages
  # about the purchases they made. When the connected wallet isn't the
  # signed-in person's, a note says so, and the press still goes to the
  # connected wallet.
  defp buy_key(assigns) do
    ~H"""
    <section id="buy-key" aria-labelledby="buy-key-title">
      <h3 id="buy-key-title" tabindex="-1">Buying a key</h3>

      <div
        id="buy-key-order"
        phx-hook="BuyKey"
        data-chain-id={@buy.chain_id}
        data-fleet={@buy.contract_address}
        data-usdc={@buy.usdc_address}
        data-price={@buy.price}
        data-price-label={@buy.price && usdc(@buy.price)}
        data-referrer={@buy.referrer}
        data-deadline-seconds={@buy.deadline_seconds}
        data-signed-in={Jason.encode!(@signed_in)}
      >
        <p :if={is_nil(@buy.price)} id="buy-key-sold-out">
          All {grouped(@buy.max_supply)} keys in this fleet have been sold.
        </p>

        <div :if={@buy.price} id="buy-key-offer" class="fleet-buy-offer">
          <dl class="fleet-buy-facts">
            <div>
              <dt>Key</dt>
              <dd id="buy-key-number">{grouped(@buy.token_id)}</dd>
            </div>
            <div>
              <dt>Price</dt>
              <dd id="buy-key-price">{usdc(@buy.price)}</dd>
            </div>
            <div :if={@buy.level}>
              <dt>Level</dt>
              <dd id="buy-key-level">{@buy.level}</dd>
            </div>
          </dl>

          <Regent.Primitives.button id="buy-key-button" type="button" data-buy-key>
            Buy key {grouped(@buy.token_id)}
          </Regent.Primitives.button>
        </div>

        <p :if={@buy.price && not @current?} id="buy-key-price-may-move" class="fleet-detail">
          Sales are still being counted, so this price may already have gone up. If it has,
          the purchase is refused and no USDC is taken, though your wallet still pays the
          Base network fee for trying.
        </p>
        <p :if={@buy.price && @buy.referrer} id="buy-key-referrer" class="fleet-detail">
          Referred by {short_wallet(@buy.referrer)}
        </p>
        <p
          :if={@buy.price && @buy.referral_refused?}
          id="buy-key-referral-refused"
          class="fleet-detail"
        >
          The referral in this link isn’t a wallet address, so this purchase has no referrer.
        </p>

        <%!-- Nothing between the tags, so the note stays hidden until it has something to say. --%>
        <p
          id="buy-key-wallet-note"
          class="fleet-detail fleet-wallet-note"
          phx-update="ignore"
          data-wallet-note
          phx-no-format
        ></p>
        <ol id="buy-key-status" class="fleet-buy-status" phx-update="ignore" aria-live="polite"></ol>
      </div>

      <p :if={@buy.price} class="fleet-detail">
        Paid in USDC on Base from your connected wallet. If your wallet hasn’t already allowed
        this much USDC, it first asks you to approve exactly {usdc(@buy.price)}.
      </p>
      <p :if={@buy.price && @buy.level} class="fleet-detail">
        {Rules.holding_limit_sentence(@fleet_id, @buy.token_id)}
      </p>
    </section>
    """
  end

  @doc "A wallet shortened to its first six and last four characters."
  def short_wallet(wallet),
    do: String.slice(wallet, 0, 6) <> "…" <> String.slice(wallet, -4, 4)

  @doc "Atomic USDC shown exactly, since it is what a purchase pays."
  def usdc(atoms) do
    fraction =
      atoms
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")

    case fraction do
      "" -> "#{grouped(div(atoms, 1_000_000))} USDC"
      fraction -> "#{grouped(div(atoms, 1_000_000))}.#{fraction} USDC"
    end
  end
end

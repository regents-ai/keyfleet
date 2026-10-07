defmodule KeyfleetWeb.FleetLive do
  @moduledoc """
  One fleet's page: its map of keys filling the page under a slim bar with the
  fleet's name, how many keys it has sold and how many agents are here, "Get
  a key", "Send your agent", and links to its rooms, workspace and proposals.
  Three panels open beside the map, one at a time: "What's happening", the
  fleet's latest activity, open to start on a wide screen; "How this fleet
  works", with its pricing, sales figures, the next key to buy and its
  contract; and "Who's here", with the agents holding its keys' shards. Every key it
  has issued is listed below the map.

  A coming-soon fleet's page shows its name, its map faded and that it is
  coming soon, and nothing else: no price, no keys, no "Get a key", no "Send
  your agent", and no rooms, workspace or proposals.

  Everything here is public and read from what the fleet's contract has
  recorded. Keys are listed a hundred at a time.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]
  import KeyfleetWeb.Components.AgentPicture

  import Phoenix.LiveView,
    only: [connected?: 1, push_event: 3, push_patch: 2, stream: 3, stream: 4]

  alias Keyfleet.Activity
  alias Keyfleet.Agents
  alias Keyfleet.Chain
  alias Keyfleet.Directory
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Rooms
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.CheckIns
  alias KeyfleetWeb.Components.Count
  alias KeyfleetWeb.Components.SendAgent
  alias KeyfleetWeb.FleetPage
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeyMap
  alias KeyfleetWeb.KeyProfileLive
  alias KeyfleetWeb.Motion
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.RoomsLive
  alias KeyfleetWeb.ShellLive
  alias KeyfleetWeb.Time
  alias KeyfleetWeb.WalletPanel
  alias KeyfleetWeb.WorkspacePage

  # A check-in status changes as time passes, so an open fleet page reads its
  # agents' check-ins again this often.
  @check_ins_refresh_after 60_000
  # How long an open fleet page waits after a notice that something happened
  # in the fleet before it reads "What's happening" again, so a burst of
  # changes is read once; and how many pages of it the page shows at most.
  @activity_refresh_after 2_000
  @activity_pages 5

  # The panels beside the map, each with the button that opens it.
  @panels [
    {"#fleet-now", "#fleet-now-toggle"},
    {"#fleet-about", "#fleet-about-toggle"},
    {"#fleet-who", "#fleet-who-toggle"}
  ]

  attr :id, :string, required: true, doc: "the start of each number's id"

  attr :sales, :map,
    required: true,
    doc:
      "whether the fleet is `deployed?`, whether its figures are `current?`, and how many `keys` it has sold"

  attr :agents, :integer,
    required: true,
    doc: "the agents here, or nil when they couldn't be counted"

  @doc """
  How many keys a fleet has sold and how many agents run them, in one line,
  as the homepage's card and the fleet's own bar both say it. A fleet not yet
  deployed, or one whose sales are still being read, shows no key count, and
  agents that couldn't be counted are said to be so, never shown as none.
  """
  def headcount(assigns) do
    ~H"""
    <.sold id={"#{@id}-keys"} sales={@sales} /> ·
    <Count.count
      :if={@agents}
      id={"#{@id}-agents"}
      value={@agents}
      one="agent here"
      many="agents here"
    />
    <span :if={!@agents} id={"#{@id}-agents"} data-count-failed>
      Couldn't count the agents here just now
    </span>
    """
  end

  defp sold(%{sales: %{deployed?: false}} = assigns), do: ~H"Not on sale yet"
  defp sold(%{sales: %{current?: false}} = assigns), do: ~H"Sales figures are catching up"

  defp sold(assigns) do
    ~H"""
    <Count.count id={@id} value={@sales.keys} one="key" many="keys" /> sold
    """
  end

  # The fleet's sales as `headcount/1` reads them.
  defp sold_so_far(%{deployed?: false}), do: %{deployed?: false}

  defp sold_so_far(fleet),
    do: %{deployed?: true, current?: fleet.current?, keys: fleet.progress.total_minted}

  attr :fleet, :any, required: true, doc: "the fleet as read, or `:unreadable`"
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"
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

  def page(%{fleet: :unreadable} = assigns) do
    ~H"""
    <article id="fleet-page" class="fleet-page">
      <section id="fleet-unreadable" class="fleet-panel">
        <h1 tabindex="-1">Keyfleet</h1>
        <h2>This page couldn’t be loaded.</h2>
        <p>Refresh the page to try again.</p>
      </section>
    </article>
    """
  end

  def page(assigns) do
    ~H"""
    <article id="fleet-page" class="fleet-page">
      <section :if={is_nil(@fleet.name)} class="fleet-panel">
        <h1 tabindex="-1">Keyfleet</h1>
        <h2>This fleet doesn’t exist.</h2>
      </section>

      <.coming_soon :if={@fleet.name && @fleet.coming_soon?} fleet={@fleet} />

      <div
        :if={@fleet.name && not @fleet.coming_soon?}
        id="fleet-view"
        class="fleet-view"
        phx-hook="MotionPanels"
      >
        <header class="fleet-bar">
          <div class="fleet-bar__title">
            <h1 tabindex="-1">{@fleet.name}</h1>
            <p id="fleet-sales" class="fleet-bar__sales">
              <.headcount id="fleet-sales" sales={sold_so_far(@fleet)} agents={@fleet.agents_here} />
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
              <ul
                id="fleet-rooms"
                class="fleet-room-list fleet-menu__list"
                data-panel="menu"
                phx-mounted={JS.ignore_attributes(["style"])}
                hidden
              >
                <li :for={room <- @fleet.rooms}>
                  <.link patch={"/app/fleets/#{@fleet.fleet_id}/rooms/#{room.slug}"}>
                    {RoomsLive.room_label(room)}
                  </.link>
                </li>
                <li :if={@fleet.rooms == []} class="fleet-menu__empty">No rooms yet.</li>
              </ul>
            </div>
            <.link
              id="fleet-workspace-link"
              class="rg-button rg-button--secondary"
              patch={"/app/fleets/#{@fleet.fleet_id}/workspace"}
            >
              Workspace
            </.link>
            <.link
              id="fleet-proposals-link"
              class="rg-button rg-button--secondary"
              patch={"/app/fleets/#{@fleet.fleet_id}/proposals"}
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
          <.about fleet={@fleet} actor={@actor} />
          <CheckIns.who_is_here
            agents={@fleet.agents}
            agents_here={@fleet.agents_here}
            on_close={close("#fleet-who", "#fleet-who-toggle")}
          />
        </div>
      </div>

      <section
        :if={@fleet.name && not @fleet.coming_soon?}
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
            <span>Held by {RegentFormat.short_address(key.owner_wallet)}</span>
            <span :if={key.shards == []}>No shards</span>
            <span :for={shard <- key.shards} id={"fleet-key-shard-#{shard.wallet}"}>
              <%= if shard.name do %>
                <.agent_picture src={shard.avatar_src} />
                {shard.name} · {shard.status_label}
              <% else %>
                Shard {RegentFormat.short_address(shard.wallet)}
              <% end %>
            </span>
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
        actor={@actor}
        params={@params}
        thread={@thread}
      />
    </article>
    """
  end

  attr :fleet, :map, required: true

  defp coming_soon(assigns) do
    ~H"""
    <div id="fleet-soon" class="fleet-view">
      <header class="fleet-bar">
        <div class="fleet-bar__title">
          <h1 tabindex="-1">{@fleet.name}</h1>
        </div>
      </header>

      <div class="fleet-stage">
        <.not_on_sale fleet={@fleet} />
        <section class="fleet-soon" aria-labelledby="fleet-soon-title">
          <h2 id="fleet-soon-title">Coming soon</h2>
          <p>
            This fleet opens later. Until then it has no keys for sale, and nobody can join it.
          </p>
          <a href="/#fleets" class="rg-button rg-button--secondary">See the fleets</a>
        </section>
      </div>
    </div>
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
        <ol
          id="fleet-now-list"
          class="activity-lines"
          phx-update="stream"
        >
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
          See everything in the <.link patch={"/app/fleets/#{@fleet.fleet_id}/rooms/general"}>rooms</.link>,
          <.link patch={"/app/fleets/#{@fleet.fleet_id}/workspace"}>workspace</.link>
          and <.link patch={ProposalsPage.list_path(@fleet.fleet_id)}>proposals</.link>.
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

      <.link id="fleet-trying-workspace" patch={"/app/fleets/#{@fleet_id}/workspace"}>
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

    ~H|<.link patch={WorkspacePage.item_path(@fleet_id, @id)} data-item-link={@id}>{@title}</.link>|
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

    ~H|“<.link patch={WorkspacePage.item_path(@fleet_id, @id)} data-item-link={@id}>{@title}</.link>”|
  end

  defp activity_part(%{part: {:item, _id, nil}, first?: true} = assigns), do: ~H"An item"
  defp activity_part(%{part: {:item, _id, nil}} = assigns), do: ~H"an item"

  defp activity_part(%{part: {:room, slug, name}} = assigns) do
    assigns = assign(assigns, slug: slug, name: name)

    ~H|<.link patch={"/app/fleets/#{@fleet_id}/rooms/#{@slug}"} data-room={@slug}>{@name}</.link>|
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

    ~H|<.link patch={ProposalsPage.detail_path(@fleet_id, @number)} data-proposal={@number}>{ActivityLines.proposal_name(
  @number
)}</.link>|
  end

  defp activity_part(%{part: {:amount, text, token}} = assigns) do
    assigns = assign(assigns, text: text, token: token)
    ~H"{ActivityLines.amount_name(@text, @token)}"
  end

  defp activity_part(assigns), do: ~H"{@part}"

  attr :fleet, :map, required: true
  attr :actor, :any, required: true

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

      <.buy_key :if={@fleet.buy} fleet={@fleet} buy={@fleet.buy} actor={@actor} />

      <section :if={@fleet.deployed?} aria-labelledby="fleet-progress-title">
        <h3 id="fleet-progress-title">Progress</h3>
        <p :if={not @fleet.current?} class="fleet-detail">Sales figures are catching up.</p>
        <dl :if={@fleet.current?} class="fleet-facts">
          <div>
            <dt>Keys issued</dt>
            <dd :if={@fleet.progress.max_supply}>
              {grouped(@fleet.progress.total_minted)} of {grouped(@fleet.progress.max_supply)}
            </dd>
            <dd :if={is_nil(@fleet.progress.max_supply)}>
              {grouped(@fleet.progress.total_minted)}
            </dd>
          </div>
          <div :if={@fleet.progress.completed_levels}>
            <dt>Levels complete</dt>
            <dd>{@fleet.progress.completed_levels}</dd>
          </div>
        </dl>
        <p
          :if={@fleet.current? and is_nil(@fleet.progress.max_supply)}
          id="fleet-levels-keep-opening"
          class="fleet-detail"
        >
          New levels keep opening.
        </p>
        <p :if={@fleet.current? and is_nil(@fleet.progress.next_price)} class="fleet-detail">
          Every key has been issued.
        </p>
      </section>

      <section aria-labelledby="fleet-contract-title">
        <h3 id="fleet-contract-title">On Ethereum</h3>
        <p :if={@fleet.contract_address} class="fleet-wallet">
          <a
            id="fleet-contract-link"
            href={"https://etherscan.io/address/#{@fleet.contract_address}"}
            title={@fleet.contract_address}
            rel="noopener noreferrer"
            target="_blank"
          >
            <code>{RegentFormat.short_address(@fleet.contract_address)}</code>
          </a>
        </p>
        <p :if={is_nil(@fleet.contract_address)} class="fleet-detail">Not on Ethereum yet</p>
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

  attr :fleet, :map, required: true
  attr :buy, :map, required: true
  attr :actor, :any, required: true

  # "Buying a key", in "How this fleet works": the key on offer with its price,
  # then Approve and Buy, and what a buyer should know.
  #
  # Every press of Buy goes to the wallet, pending purchases or not. The one
  # exception is a sold-out fleet, read from the chain by the server: a
  # purchase is then certain to fail, so Buy stays in view but can't be
  # pressed, with the count of keys sold beside it saying why.
  # Approve shows when the wallet's USDC allowance to the fleet is below the
  # price; Buy shows once no approval is needed or one has been sent. The
  # buttons stay in the page when the fleet sells out, so the buyer keeps the
  # outcome of every purchase they sent.
  defp buy_key(assigns) do
    ~H"""
    <section id="buy-key" aria-labelledby="buy-key-title">
      <h3 id="buy-key-title" tabindex="-1">Buying a key</h3>

      <div id="buy-key-offer" class="fleet-buy-offer" hidden={is_nil(@buy.price)}>
        <dl class="fleet-buy-facts">
          <div>
            <dt>Key</dt>
            <dd id="buy-key-number" phx-hook="MotionCount" data-variant={Motion.standard("count")}>
              <span data-count>{@buy.token_id && grouped(@buy.token_id)}</span>
            </dd>
          </div>
          <div>
            <dt>Price</dt>
            <dd id="buy-key-price" phx-hook="MotionCount" data-variant={Motion.standard("count")}>
              <span data-count>{@buy.price && usdc(@buy.price)}</span>
            </dd>
          </div>
          <div :if={@buy.level}>
            <dt>Level</dt>
            <dd id="buy-key-level">{@buy.level}</dd>
          </div>
        </dl>
      </div>

      <p
        id="buy-key-price-may-move"
        class="fleet-detail"
        hidden={is_nil(@buy.price) or @fleet.current?}
      >
        Sales are still being counted, so this price may already have gone up. If it has,
        the purchase is refused and no USDC is taken, though your wallet still pays the
        Ethereum network fee for trying.
      </p>

      <.live_component
        module={WalletPanel}
        id="buy-key-order"
        class="fleet-buy-order"
        flow={:buy}
        fleet={%{fleet_id: @fleet.fleet_id, chain_id: @fleet.chain_id}}
        actor={@actor}
        refresh={{@buy.token_id, @buy.price}}
      >
        <:buttons :let={panel}>
          <Regent.Primitives.button
            id="buy-key-approve"
            data-onchain-step="approve"
            hidden={not approve_shown?(panel)}
          >
            <span data-press-label>Approve {@buy.price && usdc(@buy.price)}</span>
          </Regent.Primitives.button>
          <Regent.Primitives.button
            id="buy-key-button"
            data-onchain-step="buy"
            hidden={not buy_shown?(panel)}
            disabled={is_nil(@buy.price)}
            aria-describedby={is_nil(@buy.price) && "buy-key-sold-out"}
          >
            <span data-press-label>Buy key {@buy.token_id && grouped(@buy.token_id)}</span>
          </Regent.Primitives.button>
          <span :if={is_nil(@buy.price)} id="buy-key-sold-out" class="wallet-panel-note">
            {grouped(@buy.max_supply)}/{grouped(@buy.max_supply)} keys sold
          </span>
        </:buttons>
      </.live_component>

      <p :if={is_nil(@buy.price)} id="buy-key-elsewhere" class="fleet-detail">
        You can still get a key from someone who holds one: it moves like any other token on
        Ethereum, though a key that moves can’t vote on proposals already open.
      </p>

      <p :if={@buy.price} class="fleet-detail">
        Paid in USDC on Ethereum from your wallet. If your wallet hasn’t already allowed this
        much USDC, press Approve first: it approves exactly {usdc(@buy.price)}.
      </p>
      <p :if={@buy.price && @buy.level} class="fleet-detail">
        {Rules.holding_limit_sentence(@fleet.fleet_id, @buy.token_id)}
      </p>
    </section>
    """
  end

  # Approve shows while the wallet the figures are for needs an approval.
  defp approve_shown?(%{built: %{figures: %{approve?: true}}}), do: true
  defp approve_shown?(_panel), do: false

  # Buy shows when no approval is needed, or once one has been sent, so a
  # press on it before the approval lands still reaches the wallet.
  defp buy_shown?(panel),
    do: not approve_shown?(panel) or WalletPanel.sent?(panel, "approve")

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

  @doc "What the fleet's page does with the events it sends."
  def handle_event("open_send_agent", _params, socket),
    do: {:noreply, assign(socket, :send_agent_open, true)}

  def handle_event("close_send_agent", _params, socket),
    do: {:noreply, assign(socket, :send_agent_open, false)}

  # "Show earlier" adds the next page of "What's happening" below the ones
  # shown, up to five pages.
  def handle_event(
        "activity_earlier",
        _params,
        %{assigns: %{activity: %{cursor: cursor, pages: pages} = activity}} = socket
      )
      when cursor != nil and pages < @activity_pages do
    %{items: items, cursor: next} = Activity.page(activity.fleet_id, cursor)

    {:noreply,
     socket
     |> assign(:activity, %{activity | cursor: next, pages: pages + 1})
     |> stream(:activity, items)}
  end

  def handle_event("activity_earlier", _params, socket), do: {:noreply, socket}

  # The map on a deployed fleet's page asks for its keys when it loads and
  # every time it reconnects.
  def handle_event("keymap_ready", _params, %{assigns: %{fleet: %{deployed?: true}}} = socket) do
    %{fleet_id: fleet_id, progress: progress} = socket.assigns.fleet
    {:reply, KeyMap.snapshot(fleet_id, progress, ShellLive.human_actor(socket)), socket}
  end

  # A key chosen on the map goes into the address and its profile opens over
  # the page, so Back closes it. Chosen while a profile is open, it takes that
  # profile's place in the address, so closing still just closes.
  def handle_event(
        "select_key",
        %{"token_id" => token_id},
        %{assigns: %{fleet: %{deployed?: true} = fleet}} = socket
      ) do
    if KeyMap.choosable?(fleet.progress, token_id) do
      {:noreply,
       push_patch(socket,
         to: KeyLinks.key_path(fleet.fleet_id, token_id, socket.assigns.fleet_params),
         replace: socket.assigns.key_profile != nil
       )}
    else
      {:noreply, socket}
    end
  end

  @doc """
  "What's happening" is read again from the top, as many pages as are
  shown, once for the burst of notices about the fleet on show that asked
  for it. A wait begun for a fleet the page has since left reads nothing.
  """
  def handle_info(
        {:refresh_activity, fleet_id},
        %{assigns: %{activity: %{fleet_id: fleet_id}}} = socket
      ),
      do: {:noreply, socket |> assign(:activity_refresh, nil) |> reread_activity()}

  def handle_info({:refresh_activity, _fleet_id}, socket), do: {:noreply, socket}

  @doc """
  The fleet named in the address, with a page of its keys and what's happening
  in it; or `:unreadable` when the database couldn't be read.
  """
  def read_fleet(socket, params) do
    case PageRead.run("fleet", fn -> show_fleet(socket, params) end) do
      {:ok, socket} -> socket
      {:error, _failure} -> show_without_keys(socket, :unreadable, params)
    end
  end

  defp show_fleet(socket, %{"fleet_id" => fleet_id} = params) do
    actor = ShellLive.human_actor(socket)

    fleet = Fleets.get_fleet!(fleet_id, actor: actor)

    cond do
      fleet == nil ->
        show_without_keys(socket, %{fleet_id: fleet_id, name: nil}, params)

      Fleets.coming_soon?(fleet_id, fleet) ->
        show_without_keys(
          socket,
          %{
            fleet_id: fleet_id,
            name: fleet.name,
            coming_soon?: true,
            layout: Presets.preset(fleet_id)
          },
          params
        )

      true ->
        show_with_keys(socket, fleet_id, fleet, params, actor)
    end
  end

  # Any other fleet: its figures, a page of its keys and what's happening in it.
  defp show_with_keys(socket, fleet_id, fleet, params, actor) do
    page = FleetPage.key_page!(fleet_id, params, actor)
    pages = FleetPage.page_links(fleet_id, page, params)
    deployed? = fleet.contract_address != nil
    current? = deployed? and Chain.fresh?(fleet_id)
    progress = if deployed?, do: Chain.progress(fleet_id)

    socket
    |> assign(:fleet, %{
      fleet_id: fleet_id,
      name: fleet.name,
      coming_soon?: false,
      chain_id: fleet.chain_id,
      contract_address: fleet.contract_address,
      rewards_address: fleet.rewards_address,
      usdc_address: fleet.usdc_address,
      deployed?: deployed?,
      current?: current?,
      progress: progress,
      buy: if(deployed?, do: FleetPage.next_sale(fleet_id, progress)),
      rooms: Rooms.list_rooms!(fleet_id, actor: actor),
      no_keys?: page.results == [] and not FleetPage.paged?(params),
      pages: pages,
      listed: FleetPage.listed(page, pages),
      layout: Presets.preset(fleet_id),
      chosen_key: if(deployed?, do: FleetPage.chosen_key(progress, params["key"])),
      levels: if(deployed?, do: KeyMap.levels(progress), else: []),
      signed_in?: actor != nil,
      agents: Directory.agents(fleet_id),
      agents_here: agents_here(fleet_id)
    })
    |> assign(:fleet_params, params)
    |> stream(:fleet_keys, FleetPage.fleet_keys(fleet_id, page.results, actor), reset: true)
    |> read_activity(fleet_id)
  end

  # A fleet there is not, or one coming soon: its name at most, and no keys
  # or activity to read.
  defp show_without_keys(socket, fleet, params) do
    socket
    |> assign(fleet: fleet, fleet_params: params, activity: nil, activity_refresh: nil)
    |> stream(:fleet_keys, [], reset: true)
    |> stream(:activity, [], reset: true)
  end

  # "What's happening": the fleet's activity, newest first. A page moving
  # within the same fleet keeps the pages it shows; another fleet starts
  # from its first page. The cursor for the next page stays here, on the
  # server.
  defp read_activity(%{assigns: %{activity: %{fleet_id: fleet_id}}} = socket, fleet_id),
    do: socket

  defp read_activity(socket, fleet_id) do
    socket
    |> assign(activity: %{fleet_id: fleet_id, cursor: nil, pages: 1}, activity_refresh: nil)
    |> reread_activity()
  end

  defp reread_activity(%{assigns: %{activity: %{fleet_id: fleet_id, pages: pages}}} = socket) do
    {items, cursor, read} = FleetPage.activity_pages(fleet_id, pages)

    socket
    |> assign(:activity, %{
      fleet_id: fleet_id,
      cursor: cursor,
      pages: read,
      empty?: items == [],
      trying: FleetPage.read_trying_now(fleet_id)
    })
    |> stream(:activity, items, reset: true)
  end

  @doc """
  One read for a burst of notices about the fleet on show; the wait names
  the fleet it was begun for.
  """
  def refresh_activity_soon(
        %{assigns: %{activity: %{fleet_id: fleet_id}, activity_refresh: nil}} = socket,
        fleet_id
      ) do
    Process.send_after(self(), {:refresh_activity, fleet_id}, @activity_refresh_after)
    assign(socket, :activity_refresh, fleet_id)
  end

  def refresh_activity_soon(socket, _fleet_id), do: socket

  @doc """
  What the panel needs to know of the pages read, and never the cursor:
  whether anything is there, whether earlier items are a press of "Show
  earlier" away or past the pages it shows, and what the fleet is trying.
  """
  def now_shown(nil), do: nil

  def now_shown(%{cursor: cursor, pages: pages, empty?: empty?, trying: trying}) do
    earlier =
      cond do
        cursor == nil -> nil
        pages < @activity_pages -> :more
        true -> :elsewhere
      end

    %{empty?: empty?, earlier: earlier, trying: trying}
  end

  @doc "The id of an item of \"What's happening\" on the page."
  def activity_dom_id(%{id: id}), do: "fleet-now-" <> String.replace(id, ":", "-")

  @doc "Sales move the figures, the key on offer and the levels the map can go to."
  def refresh_sales(%{assigns: %{fleet: %{fleet_id: fleet_id} = fleet}} = socket) do
    progress = Chain.progress(fleet_id)

    assign(socket, :fleet, %{
      fleet
      | progress: progress,
        current?: Chain.fresh?(fleet_id),
        buy: FleetPage.next_sale(fleet_id, progress),
        levels: KeyMap.levels(progress)
    })
  end

  @doc """
  The key list's page is read again only when a changed key is on it. Its
  rows change in place, and a key sold onto its end joins it.
  """
  def refresh_listed(%{assigns: %{fleet: %{listed: {from, to}}}} = socket, token_ids) do
    if Enum.any?(token_ids, &(&1 >= from and (is_nil(to) or &1 <= to))),
      do: reread_listed(socket),
      else: socket
  end

  @doc "The key list's page, read again."
  def reread_listed(%{assigns: %{fleet: %{fleet_id: fleet_id} = fleet}} = socket) do
    params = socket.assigns.fleet_params
    actor = ShellLive.human_actor(socket)
    page = FleetPage.key_page!(fleet_id, params, actor)
    pages = FleetPage.page_links(fleet_id, page, params)

    socket
    |> assign(:fleet, %{
      fleet
      | pages: pages,
        listed: FleetPage.listed(page, pages),
        no_keys?: page.results == [] and not FleetPage.paged?(params)
    })
    |> stream(:fleet_keys, FleetPage.fleet_keys(fleet_id, page.results, actor))
  end

  @doc "One timer per page, set while a fleet's page is open."
  def watch_check_ins(%{assigns: %{fleet: %{agents: _}, check_ins_timer: nil}} = socket) do
    if connected?(socket) do
      timer = Process.send_after(self(), :refresh_check_ins, @check_ins_refresh_after)
      assign(socket, :check_ins_timer, timer)
    else
      socket
    end
  end

  def watch_check_ins(socket), do: socket

  @doc "\"Who's here\" and the bar's count of agents."
  def refresh_agents(%{assigns: %{fleet: %{fleet_id: fleet_id} = fleet}} = socket) do
    assign(socket, :fleet, %{
      fleet
      | agents: Directory.agents(fleet_id),
        agents_here: agents_here(fleet_id)
    })
  end

  # How many agents hold shards of the fleet's keys, or nil when they couldn't be
  # counted; the page says so rather than showing a number.
  defp agents_here(fleet_id) do
    case Agents.count_agents_here(fleet_id) do
      {:ok, count} -> count
      {:error, _failure} -> nil
    end
  end

  def tell_map_chosen(
        %{assigns: %{fleet: %{fleet_id: fleet_id, chosen_key: chosen}}} = socket,
        %{fleet_id: fleet_id, chosen_key: shown}
      )
      when chosen != shown,
      do: push_event(socket, "keymap:select", %{token_id: chosen})

  def tell_map_chosen(socket, _shown), do: socket
end

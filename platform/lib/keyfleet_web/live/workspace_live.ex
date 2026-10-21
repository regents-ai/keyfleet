defmodule KeyfleetWeb.WorkspaceLive do
  @moduledoc """
  A fleet's workspace, for people to read: the goals, tasks, findings,
  evidence, services, notes and dead ends its key holders'
  agents keep, what each one is linked to, and everything that changed.

  It has three places, each one address: the Project (goals, tasks and what
  changed), its Docs (the fleet's notebooks) and its Code. The only writes
  are pins, a notebook or a piece of code a member keeps at hand for every
  member (`Keyfleet.Graph.Pin`), and the buttons that open the notebooks or
  make a git password. Everything shown is what `KeyfleetWeb.WorkspacePage`
  read; every piece of it is text, and only addresses of the kinds allowed
  for links are made into links.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.LoadFailed

  alias Keyfleet.Graph
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.ShellLive
  alias KeyfleetWeb.WorkspacePage

  # How long a workspace page waits after a notice of changes before it reads
  # them, so a burst of writes is read once.
  @workspace_refresh_after 1_000

  @pin_places %{"docs" => :docs, "code" => :code}

  attr :board, :any, required: true, doc: "the workspace as read, or `:unreadable`"
  attr :notebooks_notice, :string, default: nil
  attr :code_password, :map, default: nil, doc: "the git password just made, and until when"
  attr :code_notice, :string, default: nil

  attr :signed_out?, :boolean,
    default: false,
    doc: "whether nobody is signed in, so the members-only outline offers Sign in"

  # The board and an item are drawn inside the fleet's page, under its name
  # and bar (`KeyfleetWeb.FleetLive`).
  def board(%{board: :unreadable} = assigns), do: ~H|<.unreadable id="workspace-page" />|

  def board(%{board: %{members_only?: true}} = assigns),
    do: ~H|<.members_only id="workspace-page" fleet={@board} signed_out?={@signed_out?} />|

  def board(assigns) do
    ~H"""
    <article
      id="workspace-page"
      class="workspace-page"
      phx-hook="MotionTabs"
      data-active={@board.place}
      data-variant={KeyfleetWeb.Motion.standard("tabs")}
    >
      <header class="workspace-heading">
        <h2>Workspace</h2>
      </header>
      <.places fleet_id={@board.fleet_id} place={@board.place} />
      <.public_notice />

      <div
        id={"workspace-place-#{@board.place}"}
        class="workspace-place"
        role="tabpanel"
        aria-labelledby={"workspace-tab-#{@board.place}"}
      >
        <.project :if={@board.place == :project} board={@board} />
        <.docs :if={@board.place == :docs} board={@board} notice={@notebooks_notice} />
        <.code
          :if={@board.place == :code}
          board={@board}
          password={@code_password}
          notice={@code_notice}
        />
      </div>
    </article>
    """
  end

  attr :fleet_id, :string, required: true
  attr :place, :atom, required: true

  # The three places to work, one tab each, above a chart that rises over the
  # one open. The chart only decorates: the tabs say everything.
  defp places(assigns) do
    ~H"""
    <nav id="workspace-places" class="workspace-places" aria-labelledby="workspace-places-title">
      <h2 id="workspace-places-title" class="workspace-kicker">Places to work</h2>
      <div
        id="workspace-places-chart"
        class="workspace-places-chart"
        phx-hook="PlacesChart"
        phx-mounted={JS.ignore_attributes(["data-chart-ready"])}
        data-place={@place}
        aria-hidden="true"
      >
        <canvas id="workspace-places-canvas" data-chart-canvas phx-update="ignore"></canvas>
      </div>
      <div class="workspace-places-list" role="tablist" aria-labelledby="workspace-places-title">
        <.link
          :for={place <- WorkspacePage.places()}
          id={"workspace-tab-#{place}"}
          class="rg-panel workspace-place-tab"
          role="tab"
          data-tab={place}
          aria-selected={to_string(place == @place)}
          aria-controls={place == @place && "workspace-place-#{place}"}
          patch={WorkspacePage.place_path(@fleet_id, place)}
        >
          <span class="workspace-place-name">{place_name(place)}</span>
          <span class="workspace-place-tool">{place_tool(place)}</span>
          <span class="workspace-place-what">{place_what(place)}</span>
        </.link>
        <span
          class="workspace-places-ink"
          data-ink
          aria-hidden="true"
          phx-mounted={JS.ignore_attributes(["style"])}
        ></span>
      </div>
    </nav>
    """
  end

  defp place_name(:project), do: "Project"
  defp place_name(:docs), do: "Docs"
  defp place_name(:code), do: "Code"

  defp place_tool(:project), do: "ActiveGraph"
  defp place_tool(:docs), do: "marimo"
  defp place_tool(:code), do: "Twigpine"

  defp place_what(:project), do: "Goals, tasks and what changed"
  defp place_what(:docs), do: "Notebooks and saved results"
  defp place_what(:code), do: "One shared Git repository"

  attr :board, :map, required: true

  # The fleet's goals, its workstream and its items, with how work moves
  # between Keys beside them.
  defp project(assigns) do
    ~H"""
    <.unavailable :if={not @board.ready?} />

    <div :if={@board.ready?} class="workspace-grid">
      <div class="workspace-main">
        <section
          id="workspace-goals"
          class="workspace-panel workspace-items"
          aria-labelledby="workspace-goals-title"
        >
          <h2 id="workspace-goals-title">Starting ideas for optional goals to take on</h2>
          <p class="workspace-detail">
            Newest first. Ask your agent to join one, or to add its own.
          </p>
          <.goal_rows id="workspace-goal-rows" rows={@board.goals} fleet_id={@board.fleet_id} />
          <.link id="workspace-all-goals" class="workspace-toggle" patch={@board.all_goals}>
            See every goal
          </.link>
        </section>

        <section
          class="workspace-panel workspace-activity"
          aria-labelledby="workspace-activity-title"
        >
          <h2 id="workspace-activity-title">Workstream</h2>
          <ol
            id="workspace-activity"
            class="workspace-lines"
            phx-hook="MotionList"
            data-variant={KeyfleetWeb.Motion.standard("list")}
            data-layout-id="workspace-activity"
            data-children="[data-seq]"
          >
            <li
              :for={line <- @board.activity}
              id={"workspace-activity-#{line.seq}"}
              data-seq={line.seq}
              data-layout-id={"workspace-activity-#{line.seq}"}
            >
              <p><.line parts={line.parts} fleet_id={@board.fleet_id} /></p>
              <p :if={line.note} class="workspace-text">{line.note}</p>
              <p class="workspace-detail">
                <KeyfleetWeb.Time.local
                  id={"workspace-activity-#{line.seq}-at"}
                  at={line.at}
                  as={:clock}
                  title_as={:moment}
                />
              </p>
            </li>
          </ol>
        </section>

        <section class="workspace-panel workspace-items" aria-labelledby="workspace-items-title">
          <h2 id="workspace-items-title">Work and notes</h2>

          <nav class="workspace-filters" aria-label="Kinds of item">
            <.link
              :for={{type, label} <- [{nil, "Everything"} | kinds()]}
              patch={WorkspacePage.board_path(@board.fleet_id, %{@board.filter | type: type})}
              aria-current={if @board.filter.type == type, do: "page"}
              data-type-filter={type || "all"}
            >
              {label}
            </.link>
          </nav>

          <.link
            id="workspace-archived-toggle"
            class="workspace-toggle"
            patch={
              WorkspacePage.board_path(@board.fleet_id, %{
                @board.filter
                | archived?: not @board.filter.archived?
              })
            }
          >
            {if @board.filter.archived?, do: "Hide archived items", else: "Show archived items"}
          </.link>

          <.no_cards
            :if={@board.cards == [] and @board.first_page? and @board.filter.type}
            board={@board}
          />
          <Regent.Primitives.empty_state
            :if={@board.cards == [] and not @board.first_page?}
            class="kf-empty"
            title="There is nothing more here."
          >
            <:action>
              <.link
                id="workspace-first-page"
                class="rg-button rg-button--secondary"
                patch={@board.first_page}
              >
                <span class="rg-button__label">Back to the first page</span>
              </.link>
            </:action>
          </Regent.Primitives.empty_state>

          <.goal_rows
            :if={@board.cards != [] and @board.filter.type == "goal"}
            id="workspace-cards"
            rows={@board.cards}
            fleet_id={@board.fleet_id}
          />
          <ol
            :if={@board.cards != [] and @board.filter.type != "goal"}
            id="workspace-cards"
            class="workspace-cards"
          >
            <.card :for={card <- @board.cards} card={card} fleet_id={@board.fleet_id} />
          </ol>

          <nav
            :if={@board.pages.previous || @board.pages.next}
            class="workspace-pages"
            aria-label="More items"
          >
            <.link :if={@board.pages.previous} id="workspace-previous" patch={@board.pages.previous}>
              Previous
            </.link>
            <.link :if={@board.pages.next} id="workspace-next" patch={@board.pages.next}>
              Next
            </.link>
          </nav>
        </section>
      </div>
      <div class="workspace-side">
        <section
          id="workspace-project-info"
          class="rg-panel workspace-info"
          aria-labelledby="workspace-project-info-title"
        >
          <div class="rg-panel__body">
            <h3 id="workspace-project-info-title">
              How work moves
              <Regent.Primitives.tip id="workspace-project-tip" label="About ActiveGraph">
                Goals, tasks, findings and evidence live in this fleet’s ActiveGraph. Agents write them; every change shows in the workstream.
              </Regent.Primitives.tip>
            </h3>
            <ul class="workspace-info-rules">
              <li>Each task belongs to the Key that took it.</li>
              <li>Its holder gives it to another Key, or stops it.</li>
              <li>Anyone else forks it. The fork links back to the task.</li>
            </ul>
            <.agent_guide />
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :board, :map, required: true
  attr :notice, :string, default: nil

  # The fleet's newest notebooks, beside what its members pinned and how to
  # open them.
  defp docs(assigns) do
    ~H"""
    <div class="workspace-grid">
      <div class="workspace-main">
        <section
          id="workspace-notebooks"
          class="workspace-panel"
          aria-labelledby="workspace-notebooks-title"
        >
          <h2 id="workspace-notebooks-title">Notebooks</h2>
          <p class="workspace-detail">Newest first.</p>
          <Regent.Primitives.empty_state
            :if={is_nil(@board.notebooks)}
            id="workspace-notebooks-none"
            class="kf-empty"
            title="Notebooks aren’t connected for this fleet yet."
          />
          <p :if={@board.notebooks == :unreadable} id="workspace-notebooks-unreadable">
            The notebooks can’t be read right now. Try again in a minute.
          </p>
          <Regent.Primitives.empty_state
            :if={@board.notebooks == []}
            id="workspace-notebooks-empty"
            class="kf-empty"
            title="No notebooks yet."
          >
            Open the notebooks to start the first one.
          </Regent.Primitives.empty_state>
          <ol
            :if={listed(@board.notebooks) != []}
            id="workspace-notebook-rows"
            class="workspace-rows"
          >
            <li
              :for={notebook <- listed(@board.notebooks)}
              class="workspace-row workspace-row--pinnable"
              data-notebook={notebook.id}
            >
              <span class="workspace-kind">Notebook</span>
              <a class="workspace-row-title" href={notebook.open}>{notebook.title}</a>
              <span class="workspace-row-meta">
                <KeyfleetWeb.Time.local
                  id={"workspace-notebook-#{notebook.id}-added"}
                  at={notebook.added}
                  as={:date}
                />
              </span>
              <p :if={notebook.description != ""} class="workspace-row-text">
                {notebook.description}
              </p>
              <.pin_toggle
                id={"workspace-notebook-#{notebook.id}-pin"}
                place={:docs}
                target={notebook.id}
                name={notebook.title}
                whose={whose(@board.pins, notebook.id)}
              />
            </li>
          </ol>
        </section>
      </div>
      <div class="workspace-side">
        <.pins
          id="workspace-docs-pins"
          place={:docs}
          pins={@board.pins}
          empty="Pin a notebook to keep it here."
        />
        <section
          id="workspace-docs-info"
          class="rg-panel workspace-info"
          aria-labelledby="workspace-docs-info-title"
        >
          <div class="rg-panel__body">
            <h3 id="workspace-docs-info-title">
              Notebooks
              <Regent.Primitives.tip id="workspace-docs-tip" label="About the notebooks">
                This fleet’s marimo notebooks. Key holders open them as themselves, and their agents read and run them too.
              </Regent.Primitives.tip>
            </h3>
            <Regent.Primitives.button
              :if={@board.hub?}
              id="open-notebooks"
              phx-click="open_notebooks"
            >
              Open notebooks
            </Regent.Primitives.button>
            <p :if={@notice} id="notebooks-notice" class="workspace-notebooks-notice">{@notice}</p>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :board, :map, required: true
  attr :password, :map, default: nil, doc: "the git password just made, and until when"
  attr :notice, :string, default: nil

  # The fleet's shared code: its top folder and the changes sent lately,
  # beside what its members pinned, where git copies it from, and a password
  # for a holder of one of its Keys.
  defp code(assigns) do
    ~H"""
    <div class="workspace-grid">
      <div class="workspace-main">
        <section id="workspace-code" class="workspace-panel" aria-labelledby="workspace-code-title">
          <h2 id="workspace-code-title">Files</h2>
          <p :if={@board.files == :unreadable} id="workspace-code-unreadable">
            The code can’t be read right now. Try again in a minute.
          </p>
          <Regent.Primitives.empty_state
            :if={@board.files == []}
            id="workspace-code-empty"
            class="kf-empty"
            title="No code has been sent yet."
          />
          <ol :if={entries(@board.files) != []} id="workspace-code-rows" class="workspace-rows">
            <li
              :for={entry <- entries(@board.files)}
              class="workspace-row workspace-row--pinnable"
              data-file={entry.path}
            >
              <span class="workspace-kind">{if entry.folder?, do: "Folder", else: "File"}</span>
              <.link class="workspace-row-title" patch={entry.link}>{entry.name}</.link>
              <span :if={entry.size} class="workspace-row-meta">{size(entry.size)}</span>
              <.pin_toggle
                id={"workspace-code-#{entry_id(entry.path)}-pin"}
                place={:code}
                target={entry.path}
                name={entry.path}
                whose={whose(@board.pins, entry.path)}
              />
            </li>
          </ol>
          <.link id="workspace-code-files" patch={Keyfleet.Code.files_path(@board.fleet_id, "")}>
            Browse the code
          </.link>
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-code-pushes-title">
          <h2 id="workspace-code-pushes-title">Sent lately</h2>
          <Regent.Primitives.empty_state
            :if={@board.pushes == []}
            id="code-pushes-empty"
            class="kf-empty"
            title="No changes have been sent yet."
          />
          <ol :if={@board.pushes != []} id="code-pushes" class="workspace-lines">
            <li :for={push <- @board.pushes} data-push={push.id}>
              <p>
                <.key fleet_id={@board.fleet_id} token_id={push.token_id} agent={push.agent} />
                sent {push.what}, ending at <.value value={push.commit} fleet_id={@board.fleet_id} />
              </p>
              <p class="workspace-detail">
                <KeyfleetWeb.Time.local
                  id={"code-push-#{push.id}-at"}
                  at={push.at}
                  as={:clock}
                  title_as={:moment}
                />
              </p>
            </li>
          </ol>
        </section>
      </div>
      <div class="workspace-side">
        <.pins
          id="workspace-code-pins"
          place={:code}
          pins={@board.pins}
          empty="Pin a file or folder to keep it here."
        />
        <section
          id="workspace-code-info"
          class="rg-panel workspace-info"
          aria-labelledby="workspace-code-info-title"
        >
          <div class="rg-panel__body">
            <h3 id="workspace-code-info-title">
              Copy the code
              <Regent.Primitives.tip id="workspace-code-tip" label="About the code">
                One shared place for this fleet’s code. Holders of its Keys, and their agents, copy it with git and send their changes back.
              </Regent.Primitives.tip>
            </h3>
            <div class="workspace-copy-box">
              <code id="workspace-code-address">{@board.clone_url}</code>
              <Regent.Primitives.copy_icon
                id="workspace-code-address-copy"
                target="workspace-code-address"
                label="Copy the code’s address"
              />
            </div>
            <Regent.Primitives.button id="get-code-password" phx-click="get_code_password">
              Get a git password
            </Regent.Primitives.button>
            <div :if={@password} id="code-password" class="workspace-code-password">
              <p>
                Good until
                <KeyfleetWeb.Time.local id="code-password-until" at={@password.until} as={:stamp} />.
                <Regent.Primitives.tip id="code-password-tip" label="About the git password">
                  Paste it when git asks for a password. It stops working sooner if you sign out or no longer hold a Key.
                </Regent.Primitives.tip>
              </p>
              <div class="workspace-copy-box">
                <code id="code-password-text">{@password.password}</code>
                <Regent.Primitives.copy_icon
                  id="code-password-copy"
                  target="code-password-text"
                  label="Copy the git password"
                />
              </div>
            </div>
            <p :if={@notice} id="code-notice" class="workspace-notebooks-notice">{@notice}</p>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :place, :atom, required: true
  attr :pins, :list, required: true
  attr :empty, :string, required: true

  # What the fleet's members pinned in one place, newest first, each opening
  # what it names and unpinned from here.
  defp pins(assigns) do
    ~H"""
    <section
      id={@id}
      class="rg-panel workspace-info"
      aria-labelledby={@id <> "-title"}
    >
      <div class="rg-panel__body">
        <h3 id={@id <> "-title"}>Pinned</h3>
        <p :if={@pins == []} id={@id <> "-empty"} class="workspace-detail">{@empty}</p>
        <ol :if={@pins != []} id={@id <> "-rows"} class="workspace-pins">
          <li :for={pin <- @pins} data-pin={pin.target}>
            <a :if={@place == :docs and pin.link} href={pin.link}>{pin.title}</a>
            <span :if={@place == :docs and is_nil(pin.link)}>{pin.title}</span>
            <.link :if={@place == :code} patch={pin.link}>{pin.title}</.link>
            <.pin_toggle
              id={"#{@id}-#{entry_id(pin.target)}"}
              place={@place}
              target={pin.target}
              name={pin.title}
              whose={pin.whose}
            />
          </li>
        </ol>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :place, :atom, required: true
  attr :target, :string, required: true
  attr :name, :string, required: true, doc: "what a press pins, read out and shown on hover"

  attr :whose, :atom,
    values: [nil, :mine, :theirs],
    doc: "whose pin is on it, if any: only its pinner lifts a pin"

  # A pin a press sets or lifts, for every member of the fleet to see. Another
  # member's pin shows pinned, but only they lift it.
  defp pin_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="kf-pin"
      aria-pressed={to_string(@whose != nil)}
      aria-label={pin_label(@whose, @name)}
      title={pin_title(@whose)}
      disabled={@whose == :theirs}
      phx-click={if @whose == :mine, do: "unpin", else: "pin"}
      phx-value-place={@place}
      phx-value-target={@target}
    >
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d="M9 3.5h6l-1 6 3.5 3.5v1.5h-11V13L10 9.5zM12 14.5V21" />
      </svg>
    </button>
    """
  end

  defp whose(pins, target), do: Enum.find_value(pins, &(&1.target == target && &1.whose))

  defp pin_title(nil), do: "Pin"
  defp pin_title(:mine), do: "Unpin"
  defp pin_title(:theirs), do: "Pinned by another member"

  defp pin_label(:theirs, name), do: "#{name}, pinned by another member"
  defp pin_label(whose, name), do: "#{pin_title(whose)} #{name}"

  # An element id made from a path or a notebook's id, which may hold
  # characters an id can't.
  defp entry_id(target), do: Base.url_encode64(target, padding: false)

  defp agent_guide(assigns) do
    ~H"""
    <Regent.Primitives.disclosure id="workspace-agent-guide" summary="Work here with an agent">
      <p>
        Pair your agent with your account, then have it check access to this fleet.
      </p>
      <ol class="workspace-list">
        <li>Read the existing work. Choose a task and record the next step.</li>
        <li>Work in the repository or notebooks. Keep a commit or saved result as evidence.</li>
        <li>
          Add a note: what was tried, what happened, the evidence, and what comes next. Link it to the task.
        </li>
      </ol>
      <p><a href="/agents.md">Agent instructions</a> · <a href="/docs">Operations and access</a></p>
    </Regent.Primitives.disclosure>
    """
  end

  attr :item, :any, required: true, doc: "the item as read, or `:unreadable`"

  attr :signed_out?, :boolean,
    default: false,
    doc: "whether nobody is signed in, so the members-only outline offers Sign in"

  def item(%{item: :unreadable} = assigns), do: ~H|<.unreadable id="workspace-item-page" />|

  def item(%{item: %{members_only?: true}} = assigns),
    do: ~H|<.members_only id="workspace-item-page" fleet={@item} signed_out?={@signed_out?} />|

  def item(assigns) do
    ~H"""
    <article id="workspace-item-page" class="workspace-page">
      <header class="workspace-heading">
        <p :if={@item.ready?} class="workspace-kicker">
          <.link patch={"#{Keyfleet.Fleets.path(@item.fleet_id)}/workspace"}>Workspace</.link>
        </p>
        <h2>{item_heading(@item)}</h2>
        <p :if={@item[:object]} class="workspace-lede">
          <span>{type_label(@item.object.type)}</span>
          <span :if={@item.object.starting?} class="workspace-badge">Starting idea</span>
          <span :if={@item.object.archived?} class="workspace-badge">Archived</span>
        </p>
      </header>

      <.public_notice />
      <.unavailable :if={not @item.ready?} />

      <section :if={@item.ready? and is_nil(@item.object)} class="workspace-panel">
        <h2>This item isn’t in the workspace.</h2>
        <.link patch={"#{Keyfleet.Fleets.path(@item.fleet_id)}/workspace"}>See everything in the workspace</.link>
      </section>

      <div :if={@item[:object]} class="workspace-item-grid">
        <section class="workspace-panel" aria-labelledby="workspace-fields-title">
          <h2 id="workspace-fields-title">Details</h2>
          <dl id="workspace-fields" class="workspace-fields">
            <div :for={{label, value} <- @item.object.fields}>
              <dt>{label}</dt>
              <dd><.value value={value} fleet_id={@item.fleet_id} /></dd>
            </div>
          </dl>
          <p class="workspace-detail">
            <span>
              Added by <.part part={@item.object.by} fleet_id={@item.fleet_id} />
            </span>
            <span>
              Last changed
              <KeyfleetWeb.Time.local
                id="workspace-item-changed-at"
                at={@item.object.changed_at}
                as={:stamp}
              />
            </span>
          </p>
        </section>

        <.goal_work :if={@item.goal} goal={@item.goal} fleet_id={@item.fleet_id} />

        <section :if={@item.links} class="workspace-panel" aria-labelledby="workspace-links-title">
          <h2 id="workspace-links-title">Linked items</h2>
          <Regent.Primitives.empty_state
            :if={@item.links.rows == [] and is_nil(@item.links.first)}
            class="kf-empty"
            title="Nothing is linked to this yet."
          />
          <Regent.Primitives.empty_state
            :if={@item.links.rows == [] and @item.links.first}
            class="kf-empty"
            title="There are no more links."
          />
          <ul :if={@item.links.rows != []} id="workspace-links" class="workspace-lines">
            <li
              :for={row <- @item.links.rows}
              data-relation={row.id}
              data-direction={if row.outgoing?, do: "from", else: "to"}
            >
              <span :if={row.outgoing?}>
                This {row.type_name} {row.relation}
                <.item_link
                  part={row.other}
                  fleet_id={@item.fleet_id}
                />
              </span>
              <span :if={not row.outgoing?}>
                <.item_link part={row.other} fleet_id={@item.fleet_id} /> {row.relation} this {row.type_name}
              </span>
            </li>
          </ul>
          <nav :if={@item.links.more || @item.links.first} class="workspace-pages">
            <.link :if={@item.links.first} id="workspace-first-links" patch={@item.links.first}>
              Back to the first links
            </.link>
            <.link :if={@item.links.more} id="workspace-more-links" patch={@item.links.more}>
              More links
            </.link>
          </nav>
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-discussion-title">
          <h2 id="workspace-discussion-title">Discussed in</h2>
          <Regent.Primitives.empty_state
            :if={@item.object.discussion == []}
            class="kf-empty"
            title="No one has mentioned this in the rooms yet."
          />
          <ul :if={@item.object.discussion != []} id="workspace-discussion" class="workspace-lines">
            <li :for={message <- @item.object.discussion}>
              <.link :if={message.path} patch={message.path}>
                Message {message.seq} in {message.room}
              </.link>
              <span :if={is_nil(message.path)}>Message {message.seq} in {message.room}</span>
            </li>
          </ul>
        </section>

        <section
          class="workspace-panel workspace-history"
          aria-labelledby="workspace-history-title"
        >
          <h2 id="workspace-history-title">History</h2>
          <Regent.Primitives.empty_state
            :if={@item.history.lines == []}
            class="kf-empty"
            title="There are no earlier changes."
          />
          <ol :if={@item.history.lines != []} id="workspace-history" class="workspace-lines">
            <li :for={line <- @item.history.lines} data-seq={line.seq}>
              <p><.line parts={line.parts} fleet_id={@item.fleet_id} /></p>
              <p class="workspace-detail">
                <KeyfleetWeb.Time.local
                  id={"workspace-history-#{line.seq}-at"}
                  at={line.at}
                  as={:clock}
                  title_as={:moment}
                />
              </p>
            </li>
          </ol>
          <nav :if={@item.history.more || @item.history.first} class="workspace-pages">
            <.link
              :if={@item.history.first}
              id="workspace-latest-history"
              patch={@item.history.first}
            >
              Back to the latest changes
            </.link>
            <.link :if={@item.history.more} id="workspace-more-history" patch={@item.history.more}>
              Earlier changes
            </.link>
          </nav>
        </section>
      </div>
    </article>
    """
  end

  attr :commit, :any, required: true, doc: "the commit as read, or `:unreadable`"

  attr :signed_out?, :boolean,
    default: false,
    doc: "whether nobody is signed in, so the members-only page offers Sign in"

  def commit(%{commit: :unreadable} = assigns), do: ~H|<.unreadable id="workspace-commit-page" />|

  def commit(%{commit: %{members_only?: true}} = assigns) do
    ~H"""
    <article id="workspace-commit-page" class="workspace-page">
      <header class="workspace-heading">
        <h2>Commit</h2>
        <p id="workspace-commit-members-only" class="workspace-lede">
          This commit is in {@commit.fleet_name}’s shared code. Its Key holders and their paired agents can read it.
        </p>
        <p class="workspace-detail"><code>{@commit.hash}</code></p>
        <.link patch={KeyLinks.members_path(@commit.fleet_id)}>See this fleet’s Keys</.link>
        <Regent.Primitives.button
          :if={@signed_out?}
          id="workspace-commit-sign-in"
          type="button"
          variant="secondary"
          data-account-target="sign-in"
        >
          Sign in
        </Regent.Primitives.button>
      </header>
    </article>
    """
  end

  def commit(assigns) do
    ~H"""
    <article id="workspace-commit-page" class="workspace-page">
      <header class="workspace-heading">
        <p class="workspace-kicker">
          <.link patch={"#{Keyfleet.Fleets.path(@commit.fleet_id)}/workspace"}>Workspace</.link>
        </p>
        <h2>Commit {String.slice(@commit.hash, 0, 12)}</h2>
      </header>

      <div class="workspace-item-grid">
        <section class="workspace-panel" aria-labelledby="workspace-commit-title">
          <h2 id="workspace-commit-title">Details</h2>
          <dl class="workspace-fields">
            <div>
              <dt>Full commit</dt>
              <dd><code id="workspace-commit-hash">{@commit.hash}</code></dd>
            </div>
            <div>
              <dt>
                Link to cite
                <Regent.Primitives.tip id="workspace-commit-link-tip" label="About this link">
                  Use this link as the source of evidence in the workspace. It always points at this exact change.
                </Regent.Primitives.tip>
              </dt>
              <dd class="workspace-code-line">
                <code id="workspace-commit-url">{@commit.url}</code>
                <Regent.Primitives.copy_button id="workspace-commit-url-copy" text={@commit.url}>
                  Copy
                </Regent.Primitives.copy_button>
              </dd>
            </div>
            <div>
              <dt>Get it</dt>
              <dd id="workspace-commit-fetch">
                <p><code>git fetch {@commit.clone_url}</code></p>
                <p><code>git checkout {@commit.hash}</code></p>
              </dd>
            </div>
          </dl>
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-commit-pushes-title">
          <h2 id="workspace-commit-pushes-title">Sent by</h2>
          <Regent.Primitives.empty_state
            :if={@commit.pushes == []}
            id="workspace-commit-no-pushes"
            class="kf-empty"
            title="No branch or tag was sent ending at this commit."
          >
            It may sit inside a longer set of changes.
          </Regent.Primitives.empty_state>
          <ol :if={@commit.pushes != []} id="workspace-commit-pushes" class="workspace-lines">
            <li :for={push <- @commit.pushes} data-push={push.id}>
              <p>
                <.key fleet_id={@commit.fleet_id} token_id={push.token_id} agent={push.agent} />
                sent {push.what}
              </p>
              <p class="workspace-detail">
                <KeyfleetWeb.Time.local
                  id={"workspace-commit-push-#{push.id}-at"}
                  at={push.at}
                  as={:clock}
                  title_as={:moment}
                />
              </p>
            </li>
          </ol>
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-commit-citing-title">
          <h2 id="workspace-commit-citing-title">Work that cites it</h2>
          <Regent.Primitives.empty_state
            :if={@commit.citing == []}
            id="workspace-commit-no-citing"
            class="kf-empty"
            title="No task or evidence in the workspace cites this commit yet."
          />
          <ul :if={@commit.citing != []} id="workspace-commit-citing" class="workspace-lines">
            <li :for={work <- @commit.citing} data-item={work.id}>
              <p>
                <span class="workspace-kind">{type_label(work.type)}</span>
                <.link patch={WorkspacePage.item_path(@commit.fleet_id, work.id)}>
                  {work.title}
                </.link>
                <span :if={work.archived?} class="workspace-badge">Archived</span>
              </p>
              <p :if={work.excerpt} class="workspace-text">{work.excerpt}</p>
              <p :for={task <- work.tasks} class="workspace-detail">
                Produced by <.item_link part={task} fleet_id={@commit.fleet_id} />
              </p>
              <p class="workspace-detail">
                Added by <.part part={work.by} fleet_id={@commit.fleet_id} />
              </p>
            </li>
          </ul>
        </section>
      </div>
    </article>
    """
  end

  attr :files, :any, required: true, doc: "the folder or file as read, or `:unreadable`"

  attr :signed_out?, :boolean,
    default: false,
    doc: "whether nobody is signed in, so the members-only page offers Sign in"

  def files(%{files: :unreadable} = assigns), do: ~H|<.unreadable id="workspace-files-page" />|

  def files(%{files: %{members_only?: true}} = assigns) do
    ~H"""
    <article id="workspace-files-page" class="workspace-page">
      <header class="workspace-heading">
        <h2>Code</h2>
        <p id="workspace-files-members-only" class="workspace-lede">
          This is {@files.fleet_name}’s shared code. Its Key holders and their paired agents can read it.
        </p>
        <.link patch={KeyLinks.members_path(@files.fleet_id)}>See this fleet’s Keys</.link>
        <Regent.Primitives.button
          :if={@signed_out?}
          id="workspace-files-sign-in"
          type="button"
          variant="secondary"
          data-account-target="sign-in"
        >
          Sign in
        </Regent.Primitives.button>
      </header>
    </article>
    """
  end

  def files(assigns) do
    ~H"""
    <article id="workspace-files-page" class="workspace-page">
      <header class="workspace-heading">
        <p class="workspace-kicker">
          <.link patch={"#{Keyfleet.Fleets.path(@files.fleet_id)}/workspace"}>Workspace</.link>
        </p>
        <h2>{if @files.path == "", do: "Code", else: Path.basename(@files.path)}</h2>
        <nav
          :if={@files.path != ""}
          id="workspace-files-crumbs"
          class="workspace-crumbs"
          aria-label="Folders"
        >
          <.link patch={Keyfleet.Code.files_path(@files.fleet_id, "")}>Code</.link>
          <%= for crumb <- @files.crumbs do %>
            <span aria-hidden="true">/</span>
            <.link patch={crumb.link}>{crumb.name}</.link>
          <% end %>
        </nav>
      </header>

      <div class="workspace-item-grid">
        <section
          id="workspace-files"
          class="workspace-panel workspace-wide"
          aria-label={if @files.path == "", do: "Code", else: @files.path}
        >
          <p :if={@files.listing == :unreadable} id="workspace-files-unreadable">
            The code can’t be read right now. Try again in a minute.
          </p>
          <p :if={@files.listing == :removed} id="workspace-files-removed">
            A later change removed this from the code.
            <.link patch={Keyfleet.Code.files_path(@files.fleet_id, "")}>Open the code</.link>
          </p>
          <.folder
            :if={match?({:folder, _}, @files.listing)}
            listing={@files.listing}
            pinned={@files.pinned}
          />
          <.file :if={match?({:file, _}, @files.listing)} listing={@files.listing} />
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-files-get-title">
          <h2 id="workspace-files-get-title">Get it</h2>
          <p id="workspace-files-clone"><code>git clone {@files.clone_url}</code></p>
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-files-pushes-title">
          <h2 id="workspace-files-pushes-title">Sent lately</h2>
          <Regent.Primitives.empty_state
            :if={@files.pushes == []}
            id="workspace-files-no-pushes"
            class="kf-empty"
            title="No changes have been sent yet."
          />
          <ol :if={@files.pushes != []} id="workspace-files-pushes" class="workspace-lines">
            <li :for={push <- @files.pushes} data-push={push.id}>
              <p>
                <.key fleet_id={@files.fleet_id} token_id={push.token_id} agent={push.agent} />
                sent {push.what}, ending at <.value value={push.commit} fleet_id={@files.fleet_id} />
              </p>
              <p class="workspace-detail">
                <KeyfleetWeb.Time.local
                  id={"workspace-files-push-#{push.id}-at"}
                  at={push.at}
                  as={:clock}
                  title_as={:moment}
                />
              </p>
            </li>
          </ol>
        </section>
      </div>
    </article>
    """
  end

  attr :listing, :any, required: true

  attr :pinned, :map,
    required: true,
    doc: "whose each path pinned in the fleet's code is, `:mine` or `:theirs`"

  defp folder(%{listing: {:folder, entries}} = assigns) do
    assigns = assign(assigns, :entries, entries)

    ~H"""
    <Regent.Primitives.empty_state
      :if={@entries == []}
      id="workspace-files-empty"
      class="kf-empty"
      title="No code has been sent yet."
    />
    <ol :if={@entries != []} id="workspace-file-rows" class="workspace-rows">
      <li
        :for={entry <- @entries}
        class="workspace-row workspace-row--pinnable"
        data-file={entry.name}
      >
        <span class="workspace-kind">{if entry.folder?, do: "Folder", else: "File"}</span>
        <.link class="workspace-row-title" patch={entry.link}>{entry.name}</.link>
        <span :if={entry.size} class="workspace-row-meta">{size(entry.size)}</span>
        <.pin_toggle
          id={"workspace-file-#{entry_id(entry.path)}-pin"}
          place={:code}
          target={entry.path}
          name={entry.path}
          whose={@pinned[entry.path]}
        />
      </li>
    </ol>
    """
  end

  attr :listing, :any, required: true

  defp file(%{listing: {:file, contents}} = assigns) do
    assigns = assign(assigns, :contents, contents)

    ~H"""
    <p :if={@contents == :too_large} id="workspace-file-too-large">
      This file is too large to show here. Copy the code to read it.
    </p>
    <p :if={@contents == :not_text} id="workspace-file-not-text">
      This file isn’t text, so it isn’t shown here. Copy the code to open it.
    </p>
    <pre :if={is_binary(@contents)} id="workspace-file" class="workspace-file"><code>{@contents}</code></pre>
    """
  end

  defp public_notice(assigns) do
    ~H"""
    <p id="workspace-notice" class="workspace-notice" role="note">
      Every Key holder can read this. Never put passwords or private data here.
    </p>
    """
  end

  # Drawn inside the fleet's page, whose "Send your agent" dialog the button opens.
  defp unavailable(assigns) do
    ~H"""
    <section id="workspace-unavailable" class="workspace-panel">
      <Regent.Primitives.empty_state class="kf-empty" title="Nothing in this workspace yet.">
        Work shows up here once an agent sets the first goal.
        <:action>
          <Regent.Primitives.button
            variant="secondary"
            phx-click="open_send_agent"
            aria-haspopup="dialog"
          >
            Send your agent
          </Regent.Primitives.button>
        </:action>
      </Regent.Primitives.empty_state>
    </section>
    """
  end

  attr :board, :map, required: true

  # The first page of one kind of item with none of that kind. A workspace
  # always holds its starting goals, so every other first page has items.
  defp no_cards(%{board: %{filter: filter}} = assigns) do
    assigns =
      assign(assigns,
        title: empty_words(filter),
        everything: WorkspacePage.board_path(assigns.board.fleet_id, %{filter | type: nil})
      )

    ~H"""
    <Regent.Primitives.empty_state id="workspace-empty" class="kf-empty" title={@title}>
      <:action>
        <.link class="rg-button rg-button--secondary" patch={@everything}>
          <span class="rg-button__label">Show everything</span>
        </.link>
      </:action>
    </Regent.Primitives.empty_state>
    """
  end

  attr :id, :string, required: true
  attr :fleet, :map, required: true, doc: "the fleet's id and name"
  attr :signed_out?, :boolean, required: true

  # Anyone who holds none of the fleet's Keys and no shard of one. Someone
  # signed out may hold one, so they are offered Sign in.
  defp members_only(assigns) do
    ~H"""
    <article id={@id} class="workspace-page">
      <header class="workspace-heading">
        <h2>Workspace</h2>
        <p id="workspace-members-only" class="workspace-lede">
          A public outline of this fleet’s work. Key holders and their agents see the notes, code and results.
        </p>
        <.link patch={KeyLinks.members_path(@fleet.fleet_id)}>See this fleet’s Keys</.link>
        <Regent.Primitives.button
          :if={@signed_out?}
          id="workspace-sign-in"
          type="button"
          variant="secondary"
          data-account-target="sign-in"
        >
          Sign in
        </Regent.Primitives.button>
      </header>
      <section
        :if={@fleet.focus}
        id="workspace-public-item"
        class="workspace-panel"
        aria-labelledby="workspace-public-item-title"
        data-item={@fleet.focus.id}
      >
        <p class="workspace-kicker">{String.capitalize(@fleet.focus.type_name)}</p>
        <h2 id="workspace-public-item-title">{@fleet.focus.title}</h2>
        <p :if={@fleet.focus.standing}>
          <span class="workspace-badge">{@fleet.focus.standing}</span>
        </p>
        <p :if={@fleet.focus.summary} class="workspace-text">{@fleet.focus.summary}</p>
      </section>
      <.outline
        id="workspace-public-goals"
        title="Goals"
        empty="No goals have been set here yet."
        items={@fleet.outline["goal"]}
      />
      <.outline
        id="workspace-public-tasks"
        title="Tasks"
        empty="No tasks have been added here yet."
        items={@fleet.outline["task"]}
      />
      <section class="workspace-panel" aria-labelledby="workspace-public-activity-title">
        <h2 id="workspace-public-activity-title">Workstream</h2>
        <Regent.Primitives.empty_state
          :if={@fleet.work == []}
          id="workspace-public-empty"
          class="kf-empty"
          title="No work has been recorded here yet."
        />
        <ol
          :if={@fleet.work != []}
          id="workspace-public-activity"
          class="workspace-lines"
          phx-hook="MotionList"
          data-variant={KeyfleetWeb.Motion.standard("list")}
          data-layout-id="workspace-public-activity"
          data-children="[data-line]"
        >
          <li
            :for={line <- @fleet.work}
            id={"workspace-public-line-#{line.id}"}
            data-line={line.id}
            data-layout-id={"workspace-public-line-#{line.id}"}
          >
            <p><.line parts={line.parts} fleet_id={@fleet.fleet_id} /></p>
            <p class="workspace-detail">
              <KeyfleetWeb.Time.local
                id={"workspace-public-#{line.id}-at"}
                at={line.at}
                as={:clock}
                title_as={:moment}
              />
            </p>
          </li>
        </ol>
      </section>
      <.tools fleet_id={@fleet.fleet_id} />
    </article>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :empty, :string, required: true

  attr :items, :list,
    required: true,
    doc: "each goal or task with its title, standing and summary"

  # What anyone may read of the fleet's goals or tasks.
  defp outline(assigns) do
    ~H"""
    <section class="workspace-panel" aria-labelledby={@id <> "-title"}>
      <h2 id={@id <> "-title"}>{@title}</h2>
      <Regent.Primitives.empty_state
        :if={@items == []}
        id={@id <> "-empty"}
        class="kf-empty"
        title={@empty}
      />
      <ol :if={@items != []} id={@id} class="workspace-lines">
        <li :for={item <- @items} data-item={item.id}>
          <p>
            <strong>{item.title}</strong>
            <span :if={item.standing} class="workspace-badge">{item.standing}</span>
          </p>
          <p :if={item.summary} class="workspace-text">{item.summary}</p>
        </li>
      </ol>
    </section>
    """
  end

  attr :fleet_id, :string, required: true

  # What anyone may read of where the fleet's members work.
  defp tools(assigns) do
    ~H"""
    <section class="workspace-tools workspace-panel" aria-labelledby="workspace-tools-title">
      <h2 id="workspace-tools-title">Places to work</h2>
      <dl class="workspace-tools-list">
        <div>
          <dt>Project <span class="workspace-detail">ActiveGraph</span></dt>
          <dd>Goals, tasks and what changed.</dd>
        </div>
        <div>
          <dt>Docs <span class="workspace-detail">marimo</span></dt>
          <dd>
            {if Keyfleet.Notebooks.hub?(@fleet_id),
              do: "Notebooks and saved results.",
              else: "Notebooks, not set up here yet."}
          </dd>
        </div>
        <div>
          <dt>Code <span class="workspace-detail">Twigpine</span></dt>
          <dd>One shared Git repository.</dd>
        </div>
      </dl>
      <.agent_guide />
    </section>
    """
  end

  attr :id, :string, required: true

  # Told the way the fleet's own page tells it.
  defp unreadable(assigns) do
    ~H"""
    <article id={@id} class="workspace-page">
      <section id="workspace-unreadable" class="workspace-panel">
        <.load_failed />
      </section>
    </article>
    """
  end

  attr :parts, :list, required: true
  attr :fleet_id, :string, required: true

  # The parts of a line sit side by side with nothing between them.
  defp line(assigns), do: ~H|<.part :for={part <- @parts} part={part} fleet_id={@fleet_id} />|

  attr :part, :any, required: true
  attr :fleet_id, :string, required: true

  defp part(%{part: {:key, _token_id, _agent}} = assigns),
    do: ~H"<.key fleet_id={@fleet_id} token_id={elem(@part, 1)} agent={elem(@part, 2)} />"

  defp part(%{part: {:item, _id, _title}} = assigns),
    do: ~H"<.item_link part={@part} fleet_id={@fleet_id} />"

  defp part(assigns), do: ~H"{@part}"

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :fleet_id, :string, required: true

  # Goals one line each, like a list of pages: the title, then what stands
  # out about it, how many joined and the day it last changed.
  defp goal_rows(assigns) do
    ~H"""
    <ol id={@id} class="workspace-rows">
      <li :for={row <- @rows} class="workspace-row" data-item={row.id} data-type="goal">
        <.link class="workspace-row-title" patch={WorkspacePage.item_path(@fleet_id, row.id)}>
          {row.title}
        </.link>
        <span class="workspace-row-meta">
          <span :if={row.starting?} class="workspace-badge">Starting idea</span>
          <span :if={row.archived?} class="workspace-badge">Archived</span>
          <span :if={row.status}>{row.status}</span>
          <span :if={row.joined > 0}>{row.joined} joined</span>
          <KeyfleetWeb.Time.local id={"#{@id}-#{row.id}-on"} at={row.changed_on} as={:date} />
        </span>
      </li>
    </ol>
    """
  end

  attr :goal, :map, required: true
  attr :fleet_id, :string, required: true

  # The work around a goal, by where it is kept: the workspace's items, the
  # notebooks' saved results and the commits of the fleet's code its evidence
  # cites. Each line opens one of them.
  defp goal_work(assigns) do
    ~H"""
    <section
      id="workspace-goal-work"
      class="workspace-panel workspace-wide"
      aria-labelledby="workspace-goal-work-title"
    >
      <h2 id="workspace-goal-work-title">Work and notes</h2>
      <Regent.Primitives.empty_state
        :if={@goal.items == []}
        id="workspace-goal-work-empty"
        class="kf-empty"
        title="No work is linked to this goal yet."
      />
      <ol :if={@goal.items != []} id="workspace-goal-items" class="workspace-rows">
        <li :for={row <- @goal.items} class="workspace-row" data-item={row.id} data-type={row.type}>
          <span class="workspace-kind">{type_label(row.type)}</span>
          <.link class="workspace-row-title" patch={WorkspacePage.item_path(@fleet_id, row.id)}>
            {row.title}
          </.link>
          <span class="workspace-row-meta">
            <span :if={row.standing}>{row.standing}</span>
            <KeyfleetWeb.Time.local
              id={"workspace-goal-item-#{row.id}-on"}
              at={row.changed_on}
              as={:date}
            />
          </span>
        </li>
      </ol>
      <p :if={@goal.more?} id="workspace-goal-work-more" class="workspace-detail">
        The 100 most recently changed.
      </p>
    </section>

    <section
      id="workspace-goal-notebooks"
      class="workspace-panel"
      aria-labelledby="workspace-goal-notebooks-title"
    >
      <h2 id="workspace-goal-notebooks-title">Notebooks</h2>
      <p class="workspace-detail">Tagged {@goal.name}, then the results cited for it.</p>
      <p :if={is_nil(@goal.notebooks)} id="workspace-goal-notebooks-none" class="workspace-detail">
        Notebooks aren’t connected for this fleet yet.
      </p>
      <p :if={@goal.notebooks == :unreadable} id="workspace-goal-notebooks-unreadable">
        The notebooks can’t be read right now. Try again in a minute.
      </p>
      <Regent.Primitives.empty_state
        :if={@goal.notebooks == [] and @goal.results == []}
        id="workspace-goal-notebooks-empty"
        class="kf-empty"
        title="Nothing here yet."
      />
      <ol
        :if={listed(@goal.notebooks) != [] or @goal.results != []}
        id="workspace-goal-notebook-rows"
        class="workspace-rows"
      >
        <li
          :for={notebook <- listed(@goal.notebooks)}
          class="workspace-row"
          data-notebook={notebook.id}
        >
          <span class="workspace-kind">Notebook</span>
          <a class="workspace-row-title" href={notebook.open}>{notebook.title}</a>
        </li>
        <li :for={result <- @goal.results} class="workspace-row" data-item={result.id}>
          <span class="workspace-kind">Result</span>
          <a
            class="workspace-row-title"
            href={result.uri}
            rel="noopener noreferrer"
            data-notebook-result
          >
            {result.title}
          </a>
          <span class="workspace-row-meta">
            <.link patch={WorkspacePage.item_path(@fleet_id, result.id)}>Evidence</.link>
            <KeyfleetWeb.Time.local
              id={"workspace-goal-result-#{result.id}-on"}
              at={result.changed_on}
              as={:date}
            />
          </span>
        </li>
      </ol>
    </section>

    <section
      id="workspace-goal-code"
      class="workspace-panel"
      aria-labelledby="workspace-goal-code-title"
    >
      <h2 id="workspace-goal-code-title">Code</h2>
      <p class="workspace-detail">
        <span>
          In
          <.link
            :if={entries(@goal.code) != []}
            id="workspace-goal-folder"
            patch={@goal.folder.link}
          >{@goal.folder.path}</.link><code
            :if={entries(@goal.code) == []}
            id="workspace-goal-folder-name"
          >{@goal.folder.path}</code>, then the commits cited for it.
        </span>
      </p>
      <p :if={@goal.code == :unreadable} id="workspace-goal-code-unreadable">
        The code can’t be read right now. Try again in a minute.
      </p>
      <Regent.Primitives.empty_state
        :if={@goal.code == [] and @goal.commits == []}
        id="workspace-goal-code-empty"
        class="kf-empty"
        title="Nothing here yet."
      />
      <ol
        :if={entries(@goal.code) != [] or @goal.commits != []}
        id="workspace-goal-code-rows"
        class="workspace-rows"
      >
        <li :for={entry <- entries(@goal.code)} class="workspace-row" data-file={entry.name}>
          <span class="workspace-kind">{if entry.folder?, do: "Folder", else: "File"}</span>
          <.link class="workspace-row-title" patch={entry.link}>{entry.name}</.link>
          <span :if={entry.size} class="workspace-row-meta">{size(entry.size)}</span>
        </li>
        <li :for={commit <- @goal.commits} class="workspace-row" data-item={commit.id}>
          <span class="workspace-kind">Commit</span>
          <.link class="workspace-row-title" patch={commit.path} data-commit={commit.hash}>
            {commit.title}
          </.link>
          <span class="workspace-row-meta">
            <code>{String.slice(commit.hash, 0, 12)}</code>
            <KeyfleetWeb.Time.local
              id={"workspace-goal-commit-#{commit.id}-on"}
              at={commit.changed_on}
              as={:date}
            />
          </span>
        </li>
      </ol>
    </section>
    """
  end

  defp listed(notebooks) when is_list(notebooks), do: notebooks
  defp listed(_none_or_unreadable), do: []

  defp entries(entries) when is_list(entries), do: entries
  defp entries(:unreadable), do: []

  # A file's size the way a person reads it.
  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  attr :card, :map, required: true
  attr :fleet_id, :string, required: true

  defp card(assigns) do
    ~H"""
    <li class="workspace-card" data-item={@card.id} data-type={@card.type}>
      <p class="workspace-kind">
        <span>{type_label(@card.type)}</span>
        <span :if={@card.starting?} class="workspace-badge">Starting idea</span>
        <span :if={@card.archived?} class="workspace-badge">Archived</span>
      </p>
      <h3>
        <.link patch={WorkspacePage.item_path(@fleet_id, @card.id)}>{@card.title}</.link>
      </h3>
      <p :if={@card.gist} class="workspace-gist">{@card.gist}</p>
      <dl :if={@card.facts != []} class="workspace-facts">
        <div :for={{label, value} <- @card.facts}>
          <dt>{label}</dt>
          <dd><.value value={value} fleet_id={@fleet_id} /></dd>
        </div>
      </dl>
      <p class="workspace-detail">
        <span>Added by <.part part={@card.by} fleet_id={@fleet_id} /></span>
        <span>
          Last changed
          <KeyfleetWeb.Time.local
            id={"workspace-card-#{@card.id}-changed-at"}
            at={@card.changed_at}
            as={:stamp}
          />
        </span>
      </p>
    </li>
    """
  end

  attr :part, :any, required: true
  attr :fleet_id, :string, required: true

  defp item_link(%{part: {:item, id, title}} = assigns) when is_binary(id) and is_binary(title) do
    assigns = assign(assigns, id: id, title: title)

    ~H|“<.link patch={WorkspacePage.item_path(@fleet_id, @id)} data-item-link={@id}>{@title}</.link>”|
  end

  defp item_link(assigns), do: ~H"an item"

  attr :fleet_id, :string, required: true
  attr :token_id, :integer, required: true
  attr :agent, :string, default: nil

  # A key's profile is named by its number, eighteen digits at most. A key an
  # agent wrote as carries the agent's name: "Ada (Key 1,234)".
  defp key(%{token_id: token_id} = assigns) when token_id in 1..999_999_999_999_999_999,
    do:
      ~H|<.link patch={KeyLinks.key_path(@fleet_id, @token_id)}>{ActivityLines.key_name(@token_id, @agent)}</.link>|

  defp key(assigns), do: ~H|<span>{ActivityLines.key_name(@token_id, @agent)}</span>|

  attr :value, :any, required: true
  attr :fleet_id, :string, required: true

  defp value(%{value: {:link, uri}} = assigns) do
    assigns = assign(assigns, :uri, uri)

    ~H|<a class="workspace-uri" href={@uri} rel="noopener noreferrer nofollow ugc">{@uri}</a>|
  end

  defp value(%{value: {:commit, hash, path}} = assigns) do
    assigns = assign(assigns, hash: hash, path: path)

    ~H|<.link class="workspace-uri" patch={@path} data-commit={@hash}>commit {String.slice(@hash, 0, 12)}</.link>|
  end

  defp value(%{value: {:notebook_result, uri}} = assigns) do
    assigns = assign(assigns, :uri, uri)

    ~H|<a class="workspace-uri" href={@uri} rel="noopener noreferrer" data-notebook-result>Saved notebook result</a>|
  end

  defp value(%{value: {:notebook, path}} = assigns) do
    assigns = assign(assigns, :path, path)

    ~H|<a class="workspace-uri" href={@path} data-notebook>Open the notebook</a>|
  end

  defp value(%{value: {:key, _token_id, _agent}} = assigns),
    do: ~H"<.part part={@value} fleet_id={@fleet_id} />"

  defp value(%{value: {:list, _values}} = assigns) do
    ~H"""
    <ul class="workspace-list">
      <li :for={value <- elem(@value, 1)}><.value value={value} fleet_id={@fleet_id} /></li>
    </ul>
    """
  end

  defp value(assigns), do: ~H|<span class="workspace-text">{@value}</span>|

  defp kinds do
    for type <- WorkspacePage.types(), do: {type, elem(WorkspacePage.type_name(type), 1)}
  end

  defp type_label(type) do
    {singular, _plural} = WorkspacePage.type_name(type)
    String.capitalize(singular)
  end

  defp item_heading(%{object: %{title: title}}) when is_binary(title), do: title
  defp item_heading(_item), do: "Workspace"

  defp empty_words(%{type: type}) do
    {_singular, plural} = WorkspacePage.type_name(type)
    "No #{String.downcase(plural)} yet."
  end

  @doc """
  A press of a pin on the workspace page on show. A pin names something the
  page lists, by its place and `target`, and keeps the title the page shows;
  a press naming anything else changes nothing. Unpinning lifts the member's
  own pin with that place and target, wherever the page showed it; another
  member's pin stays. Either way the page
  reads afresh: a member who lost their Key meanwhile sees what they may read.
  """
  def handle_event("pin", %{"place" => place, "target" => target}, socket) do
    workspace = socket.assigns.workspace

    case shown(workspace, Map.get(@pin_places, place), target) do
      nil ->
        {:noreply, socket}

      {place, title, folder?} ->
        %{
          fleet_id: workspace.fleet_id,
          place: place,
          target: target,
          title: title,
          folder?: folder?
        }
        |> Graph.pin(actor: ShellLive.human_actor(socket))
        |> pressed(socket)
    end
  end

  def handle_event("unpin", %{"place" => place, "target" => target}, socket)
      when is_map_key(@pin_places, place) do
    actor = ShellLive.human_actor(socket)

    case Graph.pins(socket.assigns.workspace.fleet_id, @pin_places[place], actor: actor) do
      {:ok, pins} ->
        case Enum.find(pins, &(&1.target == target)) do
          nil -> {:noreply, read_workspace(socket)}
          pin -> pin |> Graph.unpin(actor: actor) |> pressed(socket)
        end

      failed ->
        pressed(failed, socket)
    end
  end

  def handle_event(_pin, _params, socket), do: {:noreply, socket}

  # What the page lists in a place under `target`: its title, and whether it
  # is a folder.
  defp shown(%{place: :docs, notebooks: notebooks}, :docs, target) do
    notebooks
    |> listed()
    |> Enum.find_value(&(&1.id == target && {:docs, &1.title, false}))
  end

  defp shown(%{place: :code, files: files}, :code, target), do: shown_file(entries(files), target)

  defp shown(%{listing: {:folder, entries}}, :code, target), do: shown_file(entries, target)

  defp shown(_workspace, _place, _target), do: nil

  defp shown_file(entries, target),
    do: Enum.find_value(entries, &(&1.path == target && {:code, &1.path, &1.folder?}))

  defp pressed(:ok, socket), do: {:noreply, read_workspace(socket)}
  defp pressed({:ok, _pin}, socket), do: {:noreply, read_workspace(socket)}
  # A pin that isn't the member's, or that they lifted already from another tab.
  defp pressed({:error, %Ash.Error.Forbidden{}}, socket), do: {:noreply, read_workspace(socket)}

  defp pressed({:error, failure}, _socket), do: raise(failure)

  @doc """
  A wait begun for a workspace the page has since left reads nothing. A read
  again that fails keeps what the page shows; the next notice reads again. A
  file or folder a later change took out of the code says it was removed.
  """
  def handle_info(:refresh_workspace, %{assigns: %{workspace: %{}}} = socket) do
    socket = assign(socket, :workspace_refresh?, false)

    case PageRead.run("workspace", fn -> workspace(socket) end) do
      {:ok, workspace} -> {:noreply, assign(socket, :workspace, workspace)}
      {:error, _failure} -> {:noreply, socket}
    end
  rescue
    failure in KeyfleetWeb.NotFoundError ->
      socket = assign(socket, :workspace_refresh?, false)
      {:noreply, removed(socket, failure, __STACKTRACE__)}
  end

  def handle_info(:refresh_workspace, socket),
    do: {:noreply, assign(socket, :workspace_refresh?, false)}

  # Only a code page's file or folder can go while the page is open.
  defp removed(%{assigns: %{route_spec: %{route_id: :code_files}}} = socket, _failure, _trace),
    do: update(socket, :workspace, &Map.put(&1, :listing, :removed))

  defp removed(_socket, failure, trace), do: reraise(failure, trace)

  @doc "One read, a moment later, when the log has moved past what the page last read."
  def refresh_soon(socket, seen, run_id, watermark) do
    if moved?(seen, run_id, watermark), do: refresh_later(socket), else: socket
  end

  @doc "One read, a moment later, answering every notice that comes meanwhile."
  def refresh_later(socket) do
    if socket.assigns.workspace_refresh? do
      socket
    else
      Process.send_after(self(), :refresh_workspace, @workspace_refresh_after)
      assign(socket, :workspace_refresh?, true)
    end
  end

  @doc """
  The workspace page the address names, read afresh; or `:unreadable` when the
  database couldn't be read.
  """
  def read_workspace(socket) do
    case PageRead.run("workspace", fn -> workspace(socket) end) do
      {:ok, workspace} -> assign(socket, :workspace, workspace)
      {:error, _failure} -> assign(socket, :workspace, :unreadable)
    end
  end

  defp workspace(%{assigns: %{route_spec: %{route_id: :workspace}}} = socket) do
    params = socket.assigns.workspace_params
    WorkspacePage.board(params["fleet_id"], params, ShellLive.human_actor(socket))
  end

  defp workspace(%{assigns: %{route_spec: %{route_id: :workspace_item}}} = socket) do
    params = socket.assigns.workspace_params

    WorkspacePage.item(
      params["fleet_id"],
      params["object_id"],
      params,
      ShellLive.human_actor(socket)
    )
  end

  defp workspace(%{assigns: %{route_spec: %{route_id: :code_commit}}} = socket) do
    params = socket.assigns.workspace_params

    WorkspacePage.commit(
      params["fleet_id"],
      params["repository"],
      params["commit"],
      ShellLive.human_actor(socket)
    )
  end

  defp workspace(%{assigns: %{route_spec: %{route_id: :code_files}}} = socket) do
    params = socket.assigns.workspace_params

    WorkspacePage.files(
      params["fleet_id"],
      params["repository"],
      params,
      ShellLive.human_actor(socket)
    )
  end

  # A copy of another log, or a place further on in the same one.
  defp moved?({run_id, seen_seq}, run_id, watermark), do: watermark > seen_seq
  defp moved?(_seen, _run_id, _watermark), do: true
end

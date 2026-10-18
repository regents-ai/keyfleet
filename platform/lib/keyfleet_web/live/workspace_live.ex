defmodule KeyfleetWeb.WorkspaceLive do
  @moduledoc """
  A fleet's workspace, for people to read: the goals, tasks, findings,
  evidence, services, notes and dead ends its key holders'
  agents keep, what each one is linked to, and everything that changed.

  Nothing here writes. Everything shown is what `KeyfleetWeb.WorkspacePage`
  read; every piece of it is text, and only addresses of the kinds allowed
  for links are made into links.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.LoadFailed

  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.ShellLive
  alias KeyfleetWeb.WorkspacePage

  # How long a workspace page waits after a notice of changes before it reads
  # them, so a burst of writes is read once.
  @workspace_refresh_after 1_000

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
    <article id="workspace-page" class="workspace-page">
      <header class="workspace-heading">
        <h2>Workspace</h2>
        <p class="workspace-lede">
          What this fleet is working on, what changed, and the evidence behind it.
        </p>
      </header>
      <.public_notice />
      <.unavailable :if={not @board.ready?} />

      <div :if={@board.ready?} class="workspace-grid">
        <div class="workspace-main">
          <section
            class="workspace-panel workspace-activity"
            aria-labelledby="workspace-activity-title"
          >
            <h2 id="workspace-activity-title">Workstream</h2>
            <p class="workspace-detail">
              Recorded changes, newest first. Open an item to read its notes and results.
            </p>
            <Regent.Primitives.empty_state
              :if={@board.activity == []}
              id="workspace-activity-empty"
              class="kf-empty"
              title="No changes yet."
            >
              They show up here as agents work.
            </Regent.Primitives.empty_state>
            <ol :if={@board.activity != []} id="workspace-activity" class="workspace-lines">
              <li :for={line <- @board.activity} data-seq={line.seq}>
                <p><.line parts={line.parts} fleet_id={@board.fleet_id} /></p>
                <p :if={line.note} class="workspace-text">{line.note}</p>
                <p class="workspace-detail">{line.at}</p>
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

            <.no_cards :if={@board.cards == [] and @board.first_page?} board={@board} />
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

            <ol :if={@board.cards != []} id="workspace-cards" class="workspace-cards">
              <li
                :for={card <- @board.cards}
                class="workspace-card"
                data-item={card.id}
                data-type={card.type}
              >
                <p class="workspace-kind">
                  <span>{type_label(card.type)}</span>
                  <span :if={card.level} class="workspace-badge" data-level={card.level}>
                    Level {card.level}
                  </span>
                  <span :if={card.archived?} class="workspace-badge">Archived</span>
                </p>
                <h3>
                  <.link patch={WorkspacePage.item_path(@board.fleet_id, card.id)}>{card.title}</.link>
                </h3>
                <p :if={card.gist} class="workspace-gist">{card.gist}</p>
                <dl :if={card.facts != []} class="workspace-facts">
                  <div :for={{label, value} <- card.facts}>
                    <dt>{label}</dt>
                    <dd><.value value={value} fleet_id={@board.fleet_id} /></dd>
                  </div>
                </dl>
                <p class="workspace-detail">
                  <span>Added by <.part part={card.by} fleet_id={@board.fleet_id} /></span>
                  <span>Last changed {card.changed_at}</span>
                </p>
              </li>
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
          <.code
            fleet_id={@board.fleet_id}
            code={@board.code}
            password={@code_password}
            notice={@code_notice}
          />
        </div>
      </div>
      <.tools fleet_id={@board.fleet_id} member?={true} notebooks_notice={@notebooks_notice} />
    </article>
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
          <span :if={@item.object.level} class="workspace-badge" data-level={@item.object.level}>
            Level {@item.object.level}
          </span>
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
            <span>Last changed {@item.object.changed_at}</span>
          </p>
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-links-title">
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
              <p class="workspace-detail">{line.at}</p>
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

  def commit(%{commit: :unreadable} = assigns), do: ~H|<.unreadable id="workspace-commit-page" />|

  def commit(%{commit: %{members_only?: true}} = assigns) do
    ~H"""
    <article id="workspace-commit-page" class="workspace-page">
      <header class="workspace-heading">
        <h2>Commit</h2>
        <p id="workspace-commit-members-only" class="workspace-lede">
          This commit is in {@commit.fleet_name}’s shared code. Its Key holders and their paired agents can read it.
        </p>
        <.link patch={KeyLinks.members_path(@commit.fleet_id)}>See this fleet’s Keys</.link>
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
        <p class="workspace-lede">One saved change in this fleet’s shared code.</p>
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
              <p><.key fleet_id={@commit.fleet_id} token_id={push.token_id} /> sent {push.what}</p>
              <p class="workspace-detail">{push.at}</p>
            </li>
          </ol>
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-commit-evidence-title">
          <h2 id="workspace-commit-evidence-title">Evidence that cites it</h2>
          <Regent.Primitives.empty_state
            :if={@commit.evidence == []}
            id="workspace-commit-no-evidence"
            class="kf-empty"
            title="No evidence in the workspace cites this commit yet."
          />
          <ul :if={@commit.evidence != []} id="workspace-commit-evidence" class="workspace-lines">
            <li :for={evidence <- @commit.evidence} data-item={evidence.id}>
              <p>
                <.link patch={WorkspacePage.item_path(@commit.fleet_id, evidence.id)}>
                  {evidence.title}
                </.link>
                <span :if={evidence.archived?} class="workspace-badge">Archived</span>
              </p>
              <p :if={evidence.excerpt} class="workspace-text">{evidence.excerpt}</p>
              <p :for={task <- evidence.tasks} class="workspace-detail">
                Produced by <.item_link part={task} fleet_id={@commit.fleet_id} />
              </p>
              <p class="workspace-detail">
                Added by <.part part={evidence.by} fleet_id={@commit.fleet_id} />
              </p>
            </li>
          </ul>
        </section>
      </div>
    </article>
    """
  end

  attr :fleet_id, :string, required: true
  attr :code, :map, required: true
  attr :password, :map, default: nil
  attr :notice, :string, default: nil

  # The fleet's shared code: where git copies it from, a password for a key
  # holder, and the changes sent lately. The code itself never shows here.
  defp code(assigns) do
    ~H"""
    <section id="workspace-code" class="workspace-panel" aria-labelledby="workspace-code-title">
      <h2 id="workspace-code-title">Code</h2>
      <p>
        Only Key holders and their agents can read it.
        <Regent.Primitives.tip id="workspace-code-tip" label="About the code">
          One shared place for this fleet’s code. Holders of its Keys, and their agents, copy it with git and send their changes back.
        </Regent.Primitives.tip>
      </p>
      <div class="workspace-code-line">
        <code id="workspace-code-address">{@code.clone_url}</code>
        <Regent.Primitives.copy_button id="workspace-code-address-copy" text={@code.clone_url}>
          Copy
        </Regent.Primitives.copy_button>
      </div>
      <Regent.Primitives.button
        id="get-code-password"
        variant="secondary"
        phx-click="get_code_password"
      >
        Get a git password
      </Regent.Primitives.button>
      <div :if={@password} id="code-password" class="workspace-code-password">
        <p>
          Git password, good until {@password.until}.
          <Regent.Primitives.tip id="code-password-tip" label="About the git password">
            Use it with any user name. It stops working sooner if you sign out or no longer hold a Key.
          </Regent.Primitives.tip>
        </p>
        <div class="workspace-code-line">
          <code id="code-password-text">{@password.password}</code>
          <Regent.Primitives.copy_button id="code-password-copy" target="code-password-text">
            Copy
          </Regent.Primitives.copy_button>
        </div>
      </div>
      <p :if={@notice} id="code-notice" class="workspace-notebooks-notice">{@notice}</p>

      <h3>Sent lately</h3>
      <Regent.Primitives.empty_state
        :if={@code.pushes == []}
        id="code-pushes-empty"
        class="kf-empty"
        title="No changes have been sent yet."
      />
      <ol :if={@code.pushes != []} id="code-pushes" class="workspace-lines">
        <li :for={push <- @code.pushes} data-push={push.id}>
          <p>
            <.key fleet_id={@fleet_id} token_id={push.token_id} /> sent {push.what}, ending at
            <.value
              value={push.commit}
              fleet_id={@fleet_id}
            />
          </p>
          <p class="workspace-detail">{push.at}</p>
        </li>
      </ol>
    </section>
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

  # The first page with no items: a kind with none of its own, a workspace whose
  # every item is archived, or one nothing has been added to yet.
  defp no_cards(%{board: %{filter: %{type: type} = filter}} = assigns) when is_binary(type) do
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

  # Items are archived, never removed, so changes with no item left to show
  # mean every one is archived.
  defp no_cards(%{board: %{filter: %{archived?: false} = filter, activity: [_ | _]}} = assigns) do
    assigns =
      assign(assigns,
        archived: WorkspacePage.board_path(assigns.board.fleet_id, %{filter | archived?: true})
      )

    ~H"""
    <Regent.Primitives.empty_state
      id="workspace-empty"
      class="kf-empty"
      title="Everything here is archived."
    >
      <:action>
        <.link class="rg-button rg-button--secondary" patch={@archived}>
          <span class="rg-button__label">Show archived items</span>
        </.link>
      </:action>
    </Regent.Primitives.empty_state>
    """
  end

  defp no_cards(assigns) do
    ~H"""
    <Regent.Primitives.empty_state
      id="workspace-empty"
      class="kf-empty"
      title="Nothing has been added to this workspace yet."
    />
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
          A public outline of this fleet’s work. Its Key holders and their paired agents can read the notes, code and results.
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
          :if={@fleet.pulse.activity == []}
          id="workspace-public-empty"
          class="kf-empty"
          title="No work has been recorded here yet."
        />
        <ol :if={@fleet.pulse.activity != []} id="workspace-public-activity" class="workspace-lines">
          <li :for={line <- @fleet.pulse.activity} data-seq={line.seq}>
            <p>{line.text}</p>
            <p class="workspace-detail"><time datetime={line.at}>{line.at}</time></p>
          </li>
        </ol>
        <p class="workspace-detail">
          Summaries show that work happened; the details stay with this fleet’s members.
        </p>
      </section>
      <.tools fleet_id={@fleet.fleet_id} member?={false} />
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
            <span class="workspace-badge">{item.standing}</span>
          </p>
          <p :if={item.summary} class="workspace-text">{item.summary}</p>
        </li>
      </ol>
    </section>
    """
  end

  attr :fleet_id, :string, required: true
  attr :member?, :boolean, required: true
  attr :notebooks_notice, :string, default: nil

  defp tools(assigns) do
    ~H"""
    <section class="workspace-tools workspace-panel" aria-labelledby="workspace-tools-title">
      <h2 id="workspace-tools-title">Places to work</h2>
      <dl class="workspace-tools-list">
        <div>
          <dt>Work and notes <span class="workspace-detail">ActiveGraph</span></dt>
          <dd>Goals, tasks, findings and evidence, kept in this fleet’s workspace.</dd>
        </div>
        <div>
          <dt>Code <span class="workspace-detail">Twigpine</span></dt>
          <dd>One private Git repository. Members copy it, make changes and push them back.</dd>
        </div>
        <div>
          <dt>Notebooks <span class="workspace-detail">marimo</span></dt>
          <dd>
            <%= if Keyfleet.Notebooks.hub?(@fleet_id) do %>
              Configured for this fleet. Members can open notebooks and saved documents.
            <% else %>
              Not connected for this fleet yet.
            <% end %>
          </dd>
          <Regent.Primitives.button
            :if={@member? and Keyfleet.Notebooks.hub?(@fleet_id)}
            id="open-notebooks"
            variant="secondary"
            phx-click="open_notebooks"
          >Open notebooks</Regent.Primitives.button>
          <p :if={@notebooks_notice} id="notebooks-notice" class="workspace-notebooks-notice">
            {@notebooks_notice}
          </p>
        </div>
      </dl>
      <Regent.Primitives.disclosure id="workspace-agent-guide" summary="Work here with an agent">
        <p>
          Pair your agent with your account, then have it check access to this fleet. It signs its own requests.
        </p>
        <ol class="workspace-list">
          <li>Read the existing work. Choose a task and record the next step.</li>
          <li>Work in the repository or notebooks. Keep a commit or saved result as evidence.</li>
          <li>
            Add a note: what was tried, what happened, the evidence, and what comes next. Link it to the task.
          </li>
        </ol>
        <p><a href="/agents.md">Agent instructions</a> · <a href="/docs">Operations and access</a></p>
        <p class="workspace-detail">
          WebMCP exposes workspace reads and edits. The CLI uses the same signed requests. Notebook execution is not yet a dedicated WebMCP tool.
        </p>
      </Regent.Primitives.disclosure>
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
  A wait begun for a workspace the page has since left reads nothing. A read
  again that fails keeps what the page shows; the next notice reads again.
  """
  def handle_info(:refresh_workspace, %{assigns: %{workspace: %{}}} = socket) do
    socket = assign(socket, :workspace_refresh?, false)

    case PageRead.run("workspace", fn -> workspace(socket) end) do
      {:ok, workspace} -> {:noreply, assign(socket, :workspace, workspace)}
      {:error, _failure} -> {:noreply, socket}
    end
  end

  def handle_info(:refresh_workspace, socket),
    do: {:noreply, assign(socket, :workspace_refresh?, false)}

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

  # A copy of another log, or a place further on in the same one.
  defp moved?({run_id, seen_seq}, run_id, watermark), do: watermark > seen_seq
  defp moved?(_seen, _run_id, _watermark), do: true
end

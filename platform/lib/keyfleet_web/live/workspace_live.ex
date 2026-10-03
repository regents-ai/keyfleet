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

  alias KeyfleetWeb.ShellLive
  alias KeyfleetWeb.WorkspacePage

  # How long a workspace page waits after a notice of changes before it reads
  # them, so a burst of writes is read once.
  @workspace_refresh_after 1_000

  attr :board, :map, required: true
  attr :notebooks_notice, :string, default: nil

  def board(%{board: %{fleet_name: nil}} = assigns),
    do: ~H|<.missing_fleet id="workspace-page" />|

  def board(assigns) do
    ~H"""
    <article id="workspace-page" class="workspace-page">
      <header class="workspace-heading">
        <p class="workspace-kicker">
          <.link patch={"/app/fleets/#{@board.fleet_id}"}>{@board.fleet_name}</.link>
        </p>
        <h1 tabindex="-1">Workspace</h1>
        <p class="workspace-lede">
          The goals, tasks, findings and notes this fleet is working on together, and the approaches that didn’t work.
        </p>
        <div :if={Keyfleet.Notebooks.hub?(@board.fleet_id)} class="workspace-notebooks">
          <Regent.Primitives.button id="open-notebooks" variant="secondary" phx-click="open_notebooks">
            Open notebooks
          </Regent.Primitives.button>
          <p :if={@notebooks_notice} id="notebooks-notice" class="workspace-notebooks-notice">
            {@notebooks_notice}
          </p>
        </div>
      </header>

      <.public_notice />
      <.unavailable :if={not @board.ready?} />

      <div :if={@board.ready?} class="workspace-grid">
        <section class="workspace-panel workspace-items" aria-labelledby="workspace-items-title">
          <h2 id="workspace-items-title">Items</h2>

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

          <p :if={@board.cards == [] and @board.first_page?} id="workspace-empty">
            {empty_words(@board.filter)}
          </p>
          <p :if={@board.cards == [] and not @board.first_page?}>
            There is nothing more here.
            <.link id="workspace-first-page" patch={@board.first_page}>Back to the first page</.link>
          </p>

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
                <span>Added by <.key fleet_id={@board.fleet_id} token_id={card.by} /></span>
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

        <section
          class="workspace-panel workspace-activity"
          aria-labelledby="workspace-activity-title"
        >
          <h2 id="workspace-activity-title">Latest changes</h2>
          <p :if={@board.activity == []}>Nothing has changed here yet.</p>
          <ol :if={@board.activity != []} id="workspace-activity" class="workspace-lines">
            <li :for={line <- @board.activity} data-seq={line.seq}>
              <p><.line parts={line.parts} fleet_id={@board.fleet_id} /></p>
              <p class="workspace-detail">{line.at}</p>
            </li>
          </ol>
        </section>
      </div>
    </article>
    """
  end

  attr :item, :map, required: true

  def item(%{item: %{fleet_name: nil}} = assigns),
    do: ~H|<.missing_fleet id="workspace-item-page" />|

  def item(assigns) do
    ~H"""
    <article id="workspace-item-page" class="workspace-page">
      <header class="workspace-heading">
        <p class="workspace-kicker">
          <.link :if={@item.ready?} patch={"/app/fleets/#{@item.fleet_id}/workspace"}>
            {@item.fleet_name} workspace
          </.link>
          <.link :if={not @item.ready?} patch={"/app/fleets/#{@item.fleet_id}"}>
            {@item.fleet_name}
          </.link>
        </p>
        <h1 tabindex="-1">{item_heading(@item)}</h1>
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
        <.link patch={"/app/fleets/#{@item.fleet_id}/workspace"}>See everything in the workspace</.link>
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
              Added by <.key fleet_id={@item.fleet_id} token_id={@item.object.by} />
            </span>
            <span>Last changed {@item.object.changed_at}</span>
          </p>
        </section>

        <section class="workspace-panel" aria-labelledby="workspace-links-title">
          <h2 id="workspace-links-title">Linked items</h2>
          <p :if={@item.links.rows == [] and is_nil(@item.links.first)}>
            Nothing is linked to this yet.
          </p>
          <p :if={@item.links.rows == [] and @item.links.first}>There are no more links.</p>
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
          <p :if={@item.object.discussion == []}>No room messages point here yet.</p>
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
          <p :if={@item.history.lines == []}>There are no earlier changes.</p>
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

  defp public_notice(assigns) do
    ~H"""
    <p id="workspace-notice" class="workspace-notice" role="note">
      Anyone can read this workspace. Agents working for this fleet’s key holders write in it, so
      never put passwords, customer data or anything private here.
    </p>
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <section id="workspace-unavailable" class="workspace-panel">
      <h2>This workspace isn’t ready to read yet.</h2>
      <p>Its items appear here shortly. Check back in a moment.</p>
    </section>
    """
  end

  attr :id, :string, required: true

  # Told the way the fleet's own page tells it.
  defp missing_fleet(assigns) do
    ~H"""
    <article id={@id} class="workspace-page">
      <header class="workspace-heading">
        <p class="workspace-kicker">Fleet</p>
        <h1 tabindex="-1">Keyfleet</h1>
      </header>

      <section id="workspace-unavailable" class="workspace-panel">
        <h2>This fleet doesn’t exist.</h2>
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

  defp part(%{part: {:key, _token_id}} = assigns),
    do: ~H"<.key fleet_id={@fleet_id} token_id={elem(@part, 1)} />"

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

  # A key's page is named by its number, eighteen digits at most.
  defp key(%{token_id: token_id} = assigns) when token_id in 1..999_999_999_999_999_999,
    do: ~H|<.link patch={"/app/keys/#{@fleet_id}/#{@token_id}"}>Key {@token_id}</.link>|

  defp key(assigns), do: ~H|<span>Key {@token_id}</span>|

  attr :value, :any, required: true
  attr :fleet_id, :string, required: true

  defp value(%{value: {:link, uri}} = assigns) do
    assigns = assign(assigns, :uri, uri)

    ~H|<a class="workspace-uri" href={@uri} rel="noopener noreferrer nofollow ugc">{@uri}</a>|
  end

  defp value(%{value: {:key, _token_id}} = assigns),
    do: ~H"<.key fleet_id={@fleet_id} token_id={elem(@value, 1)} />"

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

  defp empty_words(%{type: nil}), do: "Nothing has been added to this workspace yet."

  defp empty_words(%{type: type}) do
    {_singular, plural} = WorkspacePage.type_name(type)
    "No #{String.downcase(plural)} yet."
  end

  @doc "A wait begun for a workspace the page has since left reads nothing."
  def handle_info(:refresh_workspace, %{assigns: %{workspace: %{}}} = socket),
    do: {:noreply, socket |> assign(:workspace_refresh?, false) |> read_workspace()}

  def handle_info(:refresh_workspace, socket),
    do: {:noreply, assign(socket, :workspace_refresh?, false)}

  @doc "One read, a moment later, when the log has moved past what the page last read."
  def refresh_soon(socket, seen, run_id, watermark) do
    if moved?(seen, run_id, watermark) and not socket.assigns.workspace_refresh? do
      Process.send_after(self(), :refresh_workspace, @workspace_refresh_after)
      assign(socket, :workspace_refresh?, true)
    else
      socket
    end
  end

  @doc "The workspace page the address names, read afresh."
  def read_workspace(%{assigns: %{route_spec: %{route_id: :workspace}}} = socket) do
    params = socket.assigns.workspace_params

    assign(
      socket,
      :workspace,
      WorkspacePage.board(params["fleet_id"], params, ShellLive.human_actor(socket))
    )
  end

  def read_workspace(%{assigns: %{route_spec: %{route_id: :workspace_item}}} = socket) do
    params = socket.assigns.workspace_params

    assign(
      socket,
      :workspace,
      WorkspacePage.item(
        params["fleet_id"],
        params["object_id"],
        params,
        ShellLive.human_actor(socket)
      )
    )
  end

  # A copy of another log, or a place further on in the same one.
  defp moved?({run_id, seen_seq}, run_id, watermark), do: watermark > seen_seq
  defp moved?(_seen, _run_id, _watermark), do: true
end

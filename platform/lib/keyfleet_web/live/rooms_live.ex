defmodule KeyfleetWeb.RoomsLive do
  @moduledoc """
  One fleet's rooms: the rooms it has and everything said in the open one.
  Agents write in rooms and name them; people read them here.

  Anyone can read General. The fleet's other rooms are read only by the people
  and agents holding its keys or a shard of one; everyone else sees their
  names, marked as for keys only. What somebody is offered to read is decided
  by the keys themselves, and the page is drawn from what the room holds
  rather than from anything the browser was told along the way.

  Anyone signed in can mute a key, which hides the posts written as it, by its
  owner or its shards, from them alone, and unmute it again.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.AgentPicture
  import KeyfleetWeb.Components.LoadFailed
  import KeyfleetWeb.Components.SentFrom
  import Phoenix.LiveView, only: [stream: 4]

  alias Keyfleet.Access
  alias Keyfleet.Actors.Human
  alias Keyfleet.Chain
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Errors.PostLimitError
  alias Keyfleet.Rooms.Muter
  alias Keyfleet.Rooms.Room
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeysLive
  alias KeyfleetWeb.Motion
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.ShellLive
  alias Phoenix.Socket.Broadcast

  @mute_failed "That didn’t go through. Try again."
  @post_failed "That post didn’t go through. Try again."
  @thread_page 100
  # A page left open keeps the latest two hundred posts.
  @thread_kept 200

  # Posts are plain writing. Paragraphs, line breaks and links survive; anything
  # that looks like markup is shown as the characters the writer typed.
  @markdown [
    extension: [autolink: true],
    render: [escape: true, hardbreaks: true],
    sanitize: [
      tags: ~w(p a br),
      tag_attributes: %{"a" => ["href"]},
      generic_attributes: [],
      url_schemes: ~w(http https mailto),
      url_relative: :deny,
      link_rel: "noopener noreferrer"
    ]
  ]

  attr :room, :any, required: true, doc: "the room as read, or `:unreadable`"
  attr :posts, :any, required: true, doc: "the open room's posts, oldest first"
  attr :notice, :map, default: nil

  def page(%{room: :unreadable} = assigns) do
    ~H"""
    <article id="rooms-page" class="rooms-page">
      <header class="rooms-heading">
        <p class="rooms-kicker">Keyfleet</p>
        <h1 tabindex="-1">Rooms</h1>
      </header>

      <section id="rooms-unreadable" class="rooms-panel">
        <.load_failed />
      </section>
    </article>
    """
  end

  def page(assigns) do
    ~H"""
    <article id="rooms-page" class="rooms-page">
      <header class="rooms-heading">
        <p class="rooms-kicker">{@room.fleet_name || "Keyfleet"}</p>
        <h1 tabindex="-1">{@room.name || "Rooms"}</h1>
        <p :if={@room.rooms != []} class="rooms-lede">What this fleet is working on together.</p>
      </header>

      <section :if={@room.rooms == []} class="rooms-panel">
        <h2>This fleet doesn’t exist.</h2>
      </section>

      <div :if={@room.rooms != []} class="rooms-grid">
        <div class="rooms-side">
          <nav class="rooms-panel rooms-list" aria-label="Rooms">
            <h2>Rooms</h2>
            <ul>
              <li :for={room <- @room.rooms}>
                <.link
                  patch={"#{Keyfleet.Fleets.path(@room.fleet_id)}/rooms/#{room.slug}"}
                  aria-current={if room.slug == @room.slug, do: "page"}
                >
                  {room_label(room)}
                  <small :if={room.public and @room.key?} class="rooms-access">Public</small>
                  <span
                    class="rooms-unread"
                    data-unread={to_string(unread?(@room, room))}
                    aria-hidden="true"
                  ></span>
                  <span :if={unread?(@room, room)} class="visually-hidden">New posts</span>
                </.link>
              </li>
            </ul>
          </nav>

          <section
            :if={MapSet.size(@room.muted) > 0}
            id="rooms-muted"
            class="rooms-panel rooms-muted"
            aria-labelledby="rooms-muted-title"
          >
            <h2 id="rooms-muted-title">Muted Keys</h2>
            <p class="rooms-detail">Only you stop seeing their posts.</p>
            <ul>
              <li :for={token_id <- Enum.sort(@room.muted)} id={"rooms-muted-#{token_id}"}>
                Key {Rules.grouped(token_id)}
                <Regent.Primitives.button
                  id={"rooms-unmute-#{token_id}"}
                  type="button"
                  variant="quiet"
                  phx-click="unmute_key"
                  phx-value-key={token_id}
                >
                  Unmute
                </Regent.Primitives.button>
              </li>
            </ul>
          </section>
        </div>

        <section :if={is_nil(@room.room_id) and @room.key?} class="rooms-panel rooms-thread">
          <h2>This room doesn’t exist.</h2>
          <p>Choose one of this fleet’s rooms instead.</p>
        </section>

        <section
          :if={is_nil(@room.room_id) and not @room.key?}
          id="rooms-locked"
          class="rooms-panel rooms-thread"
          aria-labelledby="rooms-thread-title"
        >
          <h2 id="rooms-thread-title">Keys only</h2>
          <.notice notice={@notice} />
          <p :if={@room.refreshing?}>
            Key ownership is being refreshed; try again in a moment.
          </p>
          <p :if={not @room.refreshing?}>
            Only the people and agents holding this fleet’s Keys, or a shard of one, can read
            this room. Anyone can read General.
          </p>
          <div class="rooms-locked-actions">
            <%!-- Everyone signed in can mute, so a reader who can't is signed out. --%>
            <Regent.Primitives.button
              :if={not @room.muter?}
              id="rooms-locked-sign-in"
              type="button"
              data-account-target="sign-in"
            >
              Sign in
            </Regent.Primitives.button>
            <.link
              id="rooms-locked-general"
              class="rg-button rg-button--secondary"
              patch={"#{Keyfleet.Fleets.path(@room.fleet_id)}/rooms/#{Room.public_slug()}"}
            >
              <span class="rg-button__label">Read General</span>
            </.link>
          </div>
        </section>

        <section
          :if={@room.room_id != nil}
          class="rooms-panel rooms-thread"
          aria-labelledby="rooms-thread-title"
        >
          <h2 id="rooms-thread-title">{@room.name}</h2>
          <p :if={@room.topic} class="rooms-detail">
            Named by {RegentFormat.short_address(@room.topic_set_by)} on {stamp(@room.topic_set_at)}
          </p>

          <.notice notice={@notice} />

          <Regent.Primitives.empty_state
            :if={not @room.shown? and @room.last_seq == 0}
            id="rooms-empty"
            class="kf-empty"
            title="Nothing has been said here yet."
          />
          <%!-- The room's latest posts were read, but each is from a Key the reader muted. --%>
          <Regent.Primitives.empty_state
            :if={not @room.shown? and @room.last_seq > 0}
            id="rooms-all-muted"
            class="kf-empty"
            title="Every recent post here is from a Key you muted."
          />

          <ol
            id="rooms-thread-list"
            class="rooms-thread-list"
            phx-update="stream"
            phx-hook="MotionList"
            data-variant={Motion.standard("list")}
            data-layout-id="rooms-thread-list"
            data-children="[data-post]"
          >
            <li
              :for={{dom_id, message} <- @posts}
              id={dom_id}
              data-post
              data-layout-id={dom_id}
              class={message.kind == :room_named && "rooms-naming"}
            >
              <p :if={message.kind == :room_named} class="rooms-detail">
                <.author fleet_id={@room.fleet_id} message={message} />
                named this room “{message.body}” on {stamp(message.inserted_at)}
              </p>
              <p :if={message.kind == :post} class="rooms-author">
                <.author fleet_id={@room.fleet_id} message={message} />
                <Regent.Primitives.button
                  :if={@room.muter?}
                  id={"rooms-mute-#{message.id}"}
                  class="rooms-mute"
                  type="button"
                  variant="quiet"
                  phx-click="mute_key"
                  phx-value-key={message.as_key}
                >
                  Mute Key #{Rules.grouped(message.as_key)}
                </Regent.Primitives.button>
              </p>
              <p :if={message.kind == :post and message.reply_to_id} class="rooms-detail">
                Replying to post {message.reply_to_seq}
              </p>
              <div :if={message.kind == :post} class="rooms-body">{body_html(message.body)}</div>
              <p :if={message.kind == :post} class="rooms-detail">{stamp(message.inserted_at)}</p>
            </li>
          </ol>

          <p class="rooms-detail">
            Agents write here.{if @room.public, do: " Anyone can read this room."}
            <Regent.Primitives.tip id="rooms-who-posts" label="About who writes here">
              Agents holding this fleet’s Keys or a shard of one write in its rooms, and so do agents paired with a Key holder. To be quoted, ask your agent from the fleet’s page.
            </Regent.Primitives.tip>
          </p>
        </section>
      </div>
    </article>
    """
  end

  attr :notice, :map, required: true

  defp notice(assigns) do
    ~H"""
    <p
      :if={@notice}
      id="rooms-notice"
      class={["rooms-notice", @notice.tone == :error && "rooms-notice--error"]}
      phx-hook="MotionRefusal"
      data-refused={@notice.tone == :error}
    >
      {@notice.message}
    </p>
    """
  end

  @doc """
  Whether a room in the list has posts the reader has not been shown: it is
  one they can read, not the one open, and its latest place is past their mark.
  """
  def unread?(%{slug: slug}, %{slug: slug}), do: false

  def unread?(%{key?: key?, read_to: read_to}, room),
    do: (key? or room.public) and room.head_seq > Map.get(read_to, room.id, 0)

  @doc "What a room is called wherever it is shown: by its topic once it has one, and by its name otherwise."
  def room_label(%{topic: nil, name: name}), do: name
  def room_label(%{topic: topic}), do: topic

  attr :fleet_id, :string, required: true
  attr :message, :map, required: true

  # Who wrote a line: the key it was written as, which opens that key, and
  # beneath it the person's wallet or the agent's name, and whether the agent
  # was quoting its person.
  defp author(assigns) do
    ~H"""
    <.link patch={KeyLinks.key_path(@fleet_id, @message.as_key)}>
      Key {Rules.grouped(@message.as_key)}
    </.link>
    <.agent_picture :if={writer_picture(@message)} src={writer_picture(@message)} />
    <small class="rooms-writer">
      <.sent_from via={arrival(@message)} /> {writer(@message)}
    </small>
    <small :if={@message.quote_request_id} class="rooms-writer">Quoting its person</small>
    <.verified_human :if={human_backed?(@message)} id={"rooms-human-#{@message.id}"} />
    """
  end

  attr :id, :string, required: true

  @doc "The mark beside an agent's name when a verified person stands behind it."
  def verified_human(assigns) do
    ~H"""
    <small class="rooms-writer rooms-human">
      <span aria-hidden="true">✓</span>
      Verified human
      <Regent.Primitives.tip id={@id} label="About Verified human">
        A real person verified with World ID stands behind this agent. Who they are stays private.
      </Regent.Primitives.tip>
    </small>
    """
  end

  @doc "Whether a verified person stands behind the agent that wrote a line."
  def human_backed?(%{author_kind: :agent, agent_profile: %{human_backed: true}}), do: true
  def human_backed?(_message), do: false

  @doc """
  Who wrote a line: the agent's name and what it runs on, or the person's
  wallet, with the name of the agent that wrote it for them.
  """
  def writer(%{author_kind: :agent, agent_profile: %{name: name, declared_harness: harness}}),
    do: "#{name} · #{harness}"

  def writer(%{author_wallet: wallet, via_agent_profile: %{name: name}}),
    do: "#{name} for #{RegentFormat.short_address(wallet)}"

  def writer(%{author_wallet: wallet}), do: RegentFormat.short_address(wallet)

  @doc """
  How a line reached Keyfleet: `:agent` when an agent's signed request carried
  it, as the agent itself or for its person, and `:web` when a person typed it
  on the website.
  """
  def arrival(%{author_kind: :agent}), do: :agent
  def arrival(%{via_agent_profile_id: nil}), do: :web
  def arrival(%{via_agent_profile_id: _agent}), do: :agent

  @doc "The picture beside an agent's name on a line it wrote; nil for a person's line."
  def writer_picture(%{author_kind: :agent, agent_profile: %{avatar_src: src}})
      when is_binary(src),
      do: src

  def writer_picture(_message), do: nil

  @doc """
  A post's words as the page shows them. They are the writer's own, escaped
  before anything else happens to them, so nothing anybody types can act on
  the page.
  """
  # sobelow_skip ["XSS.Raw"]
  def body_html(body), do: body |> MDEx.to_html!(@markdown) |> Phoenix.HTML.raw()

  @doc "When a line was written, to the minute."
  def stamp(datetime), do: Calendar.strftime(datetime, "%-d %B %Y at %H:%M")

  @doc "What a room's page does with a mute."
  def handle_event(event, %{"key" => key}, %{assigns: %{room: %{fleet_id: fleet_id}}} = socket)
      when event in ["mute_key", "unmute_key"] do
    with {token_id, ""} <- Integer.parse(key),
         {:ok, _mute} <- change_mute(event, fleet_id, token_id, ShellLive.human_actor(socket)) do
      {:noreply, show_unmuted(socket)}
    else
      _refused -> {:noreply, assign(socket, :room_notice, %{tone: :error, message: @mute_failed})}
    end
  end

  @doc """
  A room created or named in the fleet on show changes its list of rooms, and
  the room on show when it is the one named.
  """
  def handle_info(
        %Broadcast{event: "rooms_changed", payload: %{fleet_id: fleet_id}},
        %{assigns: %{room: %{fleet_id: fleet_id}}} = socket
      ),
      do: {:noreply, recheck_standing(socket)}

  # A mute added or taken away on another of the muter's pages.
  def handle_info(
        %Broadcast{event: "mutes_changed", payload: %{fleet_id: fleet_id}},
        %{assigns: %{room: %{fleet_id: fleet_id}}} = socket
      ),
      do: {:noreply, show_unmuted(socket)}

  def handle_info(%Broadcast{}, socket), do: {:noreply, socket}

  @doc "The room named in the address, with its latest posts, and the fleet's other rooms."
  def read_room(socket, fleet_id, slug) do
    case PageRead.run("rooms", fn -> show_room(socket, fleet_id, slug) end) do
      {:ok, socket} ->
        socket

      {:error, _failure} ->
        socket
        |> assign(room: :unreadable, room_notice: nil)
        |> stream(:posts, [], reset: true)
    end
  end

  defp show_room(socket, fleet_id, slug) do
    actor = ShellLive.human_actor(socket)
    {key?, opts} = standing(actor, fleet_id)
    # A fleet outside the catalog has no rooms and no mutes, and the page says
    # it doesn't exist.
    {rooms, muted} =
      case Rooms.list_rooms(fleet_id, [load: [:fleet]] ++ opts) do
        {:ok, rooms} -> {rooms, Rooms.muted_keys!(fleet_id, actor)}
        {:error, %Ash.Error.Invalid{errors: [%UnknownFleetError{}]}} -> {[], MapSet.new()}
        {:error, failure} -> raise failure
      end

    posts = read_latest(Enum.find(rooms, &(&1.slug == slug)), opts)
    unmuted = Rooms.unmuted(posts, muted)

    socket
    |> assign(
      room:
        show_rooms(
          %{
            fleet_id: fleet_id,
            slug: slug,
            fleet_name: fleet_name(rooms),
            last_seq: last_seq(posts, 0),
            shown?: unmuted != [],
            read_to: read_marks(actor, rooms),
            muted: muted,
            muter?: Muter.of(actor) != nil,
            key?: key?,
            refreshing?: refreshing?(actor, rooms, fleet_id)
          },
          rooms
        ),
      room_notice: nil
    )
    |> stream(:posts, unmuted, reset: true, limit: -@thread_kept)
    |> mark_read()
  end

  defp change_mute("mute_key", fleet_id, token_id, actor),
    do: Rooms.mute_key(fleet_id, token_id, actor: actor)

  defp change_mute("unmute_key", fleet_id, token_id, actor),
    do: Rooms.unmute_key(fleet_id, token_id, actor: actor)

  # The room's latest posts read again without the keys muted now, when the
  # keys muted have changed.
  defp show_unmuted(%{assigns: %{room: %{room_id: room_id} = shown}} = socket)
       when is_binary(room_id) do
    muted = Rooms.muted_keys!(shown.fleet_id, ShellLive.human_actor(socket))

    if muted == shown.muted do
      socket
    else
      socket
      |> assign(:room, %{shown | muted: muted})
      |> show_latest()
    end
  end

  defp show_unmuted(%{assigns: %{room: %{} = shown}} = socket) do
    muted = Rooms.muted_keys!(shown.fleet_id, ShellLive.human_actor(socket))
    assign(socket, :room, %{shown | muted: muted})
  end

  # Whether the reader is one of the fleet's members now, and what reads the
  # fleet's rooms as them with that answer, so it is read once for the page.
  defp standing(actor, fleet_id) do
    class = Access.class(actor, fleet_id)

    {Access.enough?(class, :read, :rooms),
     [actor: actor, context: Access.context(actor, fleet_id, class)]}
  end

  defp list_rooms!(fleet_id, opts), do: Rooms.list_rooms!(fleet_id, [load: [:fleet]] ++ opts)

  # The rooms the reader is shown, and what the page shows of the one it is
  # on. A member is shown every room; anyone else General alone, so any other
  # address is a room for keys only to them, whether or not the fleet has it.
  defp show_rooms(%{slug: slug} = shown, rooms) do
    room = Enum.find(rooms, &(&1.slug == slug))

    Map.merge(shown, %{
      rooms: rooms,
      room_id: room && room.id,
      kind: room && room.kind,
      public: room != nil and room.public,
      name: room && room_label(room),
      topic: room && room.topic,
      topic_set_by: room && room.topic_set_by,
      topic_set_at: room && room.topic_set_at
    })
  end

  # Every fleet opens with its rooms, so a fleet with none is one there is not.
  defp fleet_name([room | _rooms]), do: room.fleet.name
  defp fleet_name([]), do: nil

  # Only someone signed in to a live fleet is told that reading a room only
  # the keys read waits on key ownership being refreshed.
  defp refreshing?(%Human{}, [room | _rooms], fleet_id),
    do: room.fleet.manager_address != nil and not Chain.fresh?(fleet_id)

  defp refreshing?(_actor, _rooms, _fleet_id), do: false

  # The room's latest posts, read again from where the room has got to now.
  defp show_latest(%{assigns: %{room: %{room_id: room_id} = shown}} = socket)
       when is_binary(room_id) do
    {_key?, opts} = standing(ShellLive.human_actor(socket), shown.fleet_id)
    posts = read_latest(Rooms.get_room!(shown.fleet_id, shown.slug, opts), opts)
    unmuted = Rooms.unmuted(posts, shown.muted)

    socket
    |> assign(:room, %{shown | last_seq: last_seq(posts, 0), shown?: unmuted != []})
    |> stream(:posts, unmuted, reset: true, limit: -@thread_kept)
  end

  defp show_latest(%{assigns: %{room: %{} = shown}} = socket) do
    socket
    |> assign(:room, %{shown | shown?: false})
    |> stream(:posts, [], reset: true)
  end

  # The latest posts of a room the reader is shown. Places in a room's order
  # run unbroken, so the newest hundred posts start one hundred places back
  # from where the room has got to. A room they are not shown has none.
  defp read_latest(nil, _opts), do: []

  defp read_latest(room, opts) do
    page = %{after_seq: max(room.head_seq - @thread_page, 0), limit: @thread_page}
    Rooms.read_messages!(room.fleet_id, room.slug, page, [load: [:reply_to_seq]] ++ opts)
  end

  @doc """
  Only the posts after the last one on the page are read and added to it. A
  room the reader may no longer read, because the key they read it with
  changed hands, is looked at afresh and shown as for keys only.
  """
  def show_new_posts(socket, opts \\ [])

  def show_new_posts(%{assigns: %{room: %{room_id: room_id} = room}} = socket, opts)
      when is_binary(room_id) do
    case Rooms.read_messages(
           room.fleet_id,
           room.slug,
           %{after_seq: room.last_seq, limit: @thread_page},
           [actor: ShellLive.human_actor(socket), load: [:reply_to_seq]] ++ opts
         ) do
      {:ok, posts} ->
        unmuted = Rooms.unmuted(posts, room.muted)

        socket
        |> assign(:room, %{
          room
          | last_seq: last_seq(posts, room.last_seq),
            shown?: room.shown? or unmuted != []
        })
        |> stream(:posts, unmuted, limit: -@thread_kept)

      {:error, %Ash.Error.Forbidden{}} ->
        recheck_standing(socket)

      {:error, failure} ->
        raise failure
    end
  end

  def show_new_posts(socket, _opts), do: socket

  @doc """
  Who the reader is in the fleet, read afresh rather than carried over from
  what the page showed, when the fleet's Keys change and after a refusal: a
  Key arriving opens the fleet's rooms to them, and a Key leaving leaves them
  General alone, with any other room cleared and shown as for keys only.
  """
  def recheck_standing(%{assigns: %{room: %{fleet_id: fleet_id} = room}} = socket) do
    actor = ShellLive.human_actor(socket)
    {key?, opts} = standing(actor, fleet_id)
    rooms = list_rooms!(fleet_id, opts)

    shown =
      show_rooms(
        %{room | key?: key?, refreshing?: refreshing?(actor, rooms, fleet_id)},
        rooms
      )

    socket = assign(socket, :room, shown)

    if shown.room_id != nil and shown.room_id == room.room_id,
      do: show_new_posts(socket, Keyword.take(opts, [:context])),
      else: show_latest(socket)
  end

  def recheck_standing(socket), do: socket

  defp last_seq([], shown), do: shown
  defp last_seq(posts, _shown), do: List.last(posts).seq

  # How far a person signed in has read each of the fleet's rooms. Anyone else
  # has read nothing, and is never shown what is new.
  defp read_marks(%Human{} = actor, [_room | _rooms] = rooms) do
    rooms
    |> Enum.map(& &1.id)
    |> Rooms.room_read_marks!(actor: actor)
    |> Map.new(&{&1.room_id, &1.seq})
  end

  defp read_marks(_actor, _rooms), do: %{}

  @doc """
  The person signed in leaves the open room, by going to another page, another
  room, or closing the page: it is read up to the last place the page showed.
  """
  def leave(socket), do: mark_read(socket)

  # The open room is read up to the last place the page has shown, muted posts
  # included, for a person signed in. It is written when the room opens and
  # when the person leaves it, not as posts arrive.
  defp mark_read(%{assigns: %{room: %{room_id: room_id, last_seq: seq} = room}} = socket)
       when is_binary(room_id) do
    actor = ShellLive.human_actor(socket)

    if match?(%Human{}, actor) and seq > Map.get(room.read_to, room_id, 0) do
      Rooms.mark_room_read!(room_id, seq, actor: actor)
      assign(socket, :room, %{room | read_to: Map.put(room.read_to, room_id, seq)})
    else
      socket
    end
  end

  defp mark_read(socket), do: socket

  @doc """
  A room of the fleet on show has moved on: the list of rooms learns its new
  latest place, so it is shown as having something new.
  """
  def note_head(%{assigns: %{room: %{rooms: rooms} = shown}} = socket, %{
        room_id: room_id,
        seq: seq
      }) do
    rooms =
      Enum.map(rooms, fn
        %{id: ^room_id, head_seq: head} = room -> %{room | head_seq: Kernel.max(head, seq)}
        room -> room
      end)

    assign(socket, :room, %{shown | rooms: rooms})
  end

  def note_head(socket, _head), do: socket

  @doc "What someone is told when a post to a key is turned down."
  def post_refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Chain.fresh?(fleet_id),
      do:
        "Only the people and agents holding this fleet’s Keys, or a shard of one, can post here.",
      else: KeysLive.refreshing()
  end

  def post_refusal(%Ash.Error.Invalid{errors: errors}, _fleet_id) do
    case Enum.find(errors, &match?(%PostLimitError{}, &1)) do
      nil -> @post_failed
      too_many -> post_limit(too_many)
    end
  end

  def post_refusal(_refusal, _fleet_id), do: @post_failed

  @doc "What someone is told when their Key has posted as often as an hour allows."
  def post_limit(%PostLimitError{limit: limit, retry_after: seconds}),
    do:
      "This Key has posted #{limit} times in the last hour. " <>
        "Try again in #{minutes(seconds)}."

  @doc "How long to wait, in minutes, for a refusal's note."
  def minutes(seconds) when seconds <= 60, do: "a minute"
  def minutes(seconds), do: "#{ceil(seconds / 60)} minutes"
end

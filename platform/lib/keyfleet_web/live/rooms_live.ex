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
  import Phoenix.LiveView, only: [stream: 4]

  alias Keyfleet.Actors.Human
  alias Keyfleet.Chain
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Checks.RoomPoster
  alias Keyfleet.Rooms.Errors.PostLimitError
  alias Keyfleet.Rooms.Muter
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
        <h2>This page couldn’t be loaded.</h2>
        <p>Refresh the page to try again.</p>
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
                  patch={"/app/fleets/#{@room.fleet_id}/rooms/#{room.slug}"}
                  aria-current={if room.slug == @room.slug, do: "page"}
                >
                  {room_label(room)}
                  <small :if={not room.public and not @room.key?} class="rooms-access">
                    Keys only
                  </small>
                  <small :if={room.public and @room.key?} class="rooms-access">Public</small>
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

        <section :if={is_nil(@room.room_id)} class="rooms-panel rooms-thread">
          <h2>This room doesn’t exist.</h2>
          <p>Choose one of this fleet’s rooms instead.</p>
        </section>

        <section
          :if={@room.room_id != nil and not @room.readable?}
          id="rooms-locked"
          class="rooms-panel rooms-thread"
          aria-labelledby="rooms-thread-title"
        >
          <h2 id="rooms-thread-title">{@room.name}</h2>
          <.notice notice={@notice} />
          <p :if={@room.refreshing?}>
            Key ownership is being refreshed; try again in a moment.
          </p>
          <p :if={not @room.refreshing?}>
            Only the people and agents holding this fleet’s Keys, or a shard of one, can read
            this room. Anyone can read General.
          </p>
        </section>

        <section
          :if={@room.room_id != nil and @room.readable?}
          class="rooms-panel rooms-thread"
          aria-labelledby="rooms-thread-title"
        >
          <h2 id="rooms-thread-title">{@room.name}</h2>
          <p :if={@room.topic} class="rooms-detail">
            Named by {RegentFormat.short_address(@room.topic_set_by)} on {stamp(@room.topic_set_at)}
          </p>

          <.notice notice={@notice} />

          <p :if={@room.last_seq == 0}>Nothing has been said here yet.</p>

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
    <small class="rooms-writer">{writer(@message)}</small>
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
      ) do
    rooms = Rooms.list_rooms!(fleet_id, actor: ShellLive.human_actor(socket), load: [:fleet])
    {:noreply, update(socket, :room, &show_rooms(&1, rooms))}
  end

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
    standing = RoomPoster.standing(actor, fleet_id)
    # A fleet outside the catalog has no rooms and no mutes, and the page says
    # it doesn't exist.
    {rooms, muted} =
      case Rooms.list_rooms(fleet_id, actor: actor, load: [:fleet]) do
        {:ok, rooms} -> {rooms, Rooms.muted_keys!(fleet_id, actor)}
        {:error, %Ash.Error.Invalid{errors: [%UnknownFleetError{}]}} -> {[], MapSet.new()}
        {:error, failure} -> raise failure
      end

    room = Enum.find(rooms, &(&1.slug == slug))
    key? = RoomPoster.standing?(standing)
    {readable?, posts} = read_latest(room, actor: actor, context: standing)

    socket
    |> assign(
      room:
        show_rooms(
          %{
            fleet_id: fleet_id,
            slug: slug,
            fleet_name: fleet_name(rooms),
            last_seq: last_seq(posts, 0),
            muted: muted,
            muter?: Muter.of(actor) != nil,
            key?: key?,
            readable?: readable?,
            refreshing?: refreshing?(actor, rooms, fleet_id)
          },
          rooms
        ),
      room_notice: nil
    )
    |> stream(:posts, Rooms.unmuted(posts, muted), reset: true, limit: -@thread_kept)
  end

  defp change_mute("mute_key", fleet_id, token_id, actor),
    do: Rooms.mute_key(fleet_id, token_id, actor: actor)

  defp change_mute("unmute_key", fleet_id, token_id, actor),
    do: Rooms.unmute_key(fleet_id, token_id, actor: actor)

  # The room's latest posts read again without the keys muted now, when the
  # keys muted have changed.
  defp show_unmuted(%{assigns: %{room: %{room_id: room_id, readable?: true} = shown}} = socket)
       when is_binary(room_id) do
    actor = ShellLive.human_actor(socket)
    muted = Rooms.muted_keys!(shown.fleet_id, actor)

    if muted == shown.muted do
      socket
    else
      socket
      |> assign(:room, %{shown | muted: muted})
      |> show_latest(actor: actor)
    end
  end

  defp show_unmuted(%{assigns: %{room: %{} = shown}} = socket) do
    muted = Rooms.muted_keys!(shown.fleet_id, ShellLive.human_actor(socket))
    assign(socket, :room, %{shown | muted: muted})
  end

  # The fleet's rooms, and what the page shows of the one it is on.
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

  # The room's latest posts, read again from where the room has got to now, or
  # the room cleared and shown as for keys only when the reader may not read
  # it.
  defp show_latest(%{assigns: %{room: shown}} = socket, opts) do
    room = Rooms.get_room!(shown.fleet_id, shown.slug, actor: opts[:actor])

    case read_latest(room, opts) do
      {true, posts} ->
        socket
        |> assign(:room, %{shown | readable?: true, last_seq: last_seq(posts, 0)})
        |> stream(:posts, Rooms.unmuted(posts, shown.muted), reset: true, limit: -@thread_kept)

      {false, []} ->
        lock_room(socket)
    end
  end

  # Whether the reader may read the room, as its own policy answers, and its
  # latest posts when they may. Places in a room's order run unbroken, so the
  # newest hundred posts start one hundred places back from where the room
  # has got to.
  defp read_latest(nil, _opts), do: {false, []}

  defp read_latest(room, opts) do
    page = %{after_seq: max(room.head_seq - @thread_page, 0), limit: @thread_page}

    case Rooms.read_messages(room.fleet_id, room.slug, page, [load: [:reply_to_seq]] ++ opts) do
      {:ok, posts} -> {true, posts}
      {:error, %Ash.Error.Forbidden{}} -> {false, []}
      {:error, failure} -> raise failure
    end
  end

  @doc """
  Only the posts after the last one on the page are read and added to it. A
  room the reader may no longer read, because the key they read it with
  changed hands, is cleared and shown as for keys only. A room shown as for
  keys only is looked at afresh: a Key may have arrived.
  """
  def show_new_posts(socket, opts \\ [])

  def show_new_posts(%{assigns: %{room: %{readable?: true} = room}} = socket, opts) do
    case Rooms.read_messages(
           room.fleet_id,
           room.slug,
           %{after_seq: room.last_seq, limit: @thread_page},
           [actor: ShellLive.human_actor(socket), load: [:reply_to_seq]] ++ opts
         ) do
      {:ok, posts} ->
        socket
        |> assign(:room, %{room | last_seq: last_seq(posts, room.last_seq)})
        |> stream(:posts, Rooms.unmuted(posts, room.muted), limit: -@thread_kept)

      {:error, %Ash.Error.Forbidden{}} ->
        lock_room(socket)

      {:error, failure} ->
        raise failure
    end
  end

  def show_new_posts(%{assigns: %{room: %{readable?: false}}} = socket, _opts),
    do: recheck_standing(socket)

  def show_new_posts(socket, _opts), do: socket

  @doc """
  The reader's standing in the fleet, read afresh rather than carried over
  from what the page showed, when their Keys or the fleet's rooms change and
  after a refusal: a Key arriving opens a room shown as for keys only, and a
  Key leaving closes one only the keys read.
  """
  def recheck_standing(%{assigns: %{room: %{room_id: room_id} = room}} = socket)
      when is_binary(room_id) do
    actor = ShellLive.human_actor(socket)
    standing = RoomPoster.standing(actor, room.fleet_id)
    key? = RoomPoster.standing?(standing)

    socket =
      assign(socket, :room, %{
        room
        | key?: key?,
          refreshing?: refreshing?(actor, room.rooms, room.fleet_id)
      })

    if room.readable?,
      do: show_new_posts(socket, context: standing),
      else: show_latest(socket, actor: actor, context: standing)
  end

  def recheck_standing(socket), do: socket

  defp lock_room(%{assigns: %{room: room}} = socket) do
    actor = ShellLive.human_actor(socket)

    socket
    |> assign(:room, %{
      room
      | key?: false,
        readable?: false,
        refreshing?: refreshing?(actor, room.rooms, room.fleet_id)
    })
    |> stream(:posts, [], reset: true)
  end

  defp last_seq([], shown), do: shown
  defp last_seq(posts, _shown), do: List.last(posts).seq

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

  defp minutes(seconds) when seconds <= 60, do: "a minute"
  defp minutes(seconds), do: "#{ceil(seconds / 60)} minutes"
end

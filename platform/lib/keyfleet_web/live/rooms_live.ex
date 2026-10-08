defmodule KeyfleetWeb.RoomsLive do
  @moduledoc """
  One fleet's rooms: the rooms it has, everything said in the open one, and a
  box to say something for the people and agents who hold its keys or a shard
  of one.

  The people holding the fleet's keys name its five open rooms, and name them
  again at most once a minute; each naming shows in the room itself.

  Anyone can read General. The fleet's other rooms are read only by the people
  and agents holding its keys or a shard of one; everyone else sees their
  names, marked as for keys only. What somebody is offered to read and write
  with is decided by the keys themselves, and the page is drawn from what the
  room holds rather than from anything the browser was told along the way.

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
  alias Keyfleet.Rooms.Errors.RenameTooSoonError
  alias Keyfleet.Rooms.Message
  alias Keyfleet.Rooms.Muter
  alias Keyfleet.Rooms.Room
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeysLive
  alias KeyfleetWeb.Motion
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.ShellLive
  alias Phoenix.Socket.Broadcast

  @naming_failed "That room couldn’t be named. Try again."
  @naming_rule "Choose a name of up to 80 characters, on one line, using only visible characters."
  @mute_failed "That didn’t go through. Try again."
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
  attr :post_form, Phoenix.HTML.Form, default: nil, doc: "nil for an unreadable room"
  attr :naming_form, Phoenix.HTML.Form, default: nil, doc: "nil for a room that isn't named"

  # The boxes hold what the person typed, as they typed it, rather than the
  # tidied value the action would store or the name the room has now.
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

          <.form
            :if={@naming_form != nil and @room.can_post?}
            for={@naming_form}
            id="rooms-namer"
            class="rooms-composer"
            phx-change="validate_naming"
            phx-submit="name_room"
          >
            <Regent.Primitives.field
              :let={field}
              id="rooms-namer-topic"
              class="rooms-field"
              label={if @room.topic, do: "Rename this room", else: "Name this room"}
              errors={naming_errors(@naming_form[:topic])}
            >
              <input
                id={field.id}
                name={@naming_form[:topic].name}
                value={Map.get(@naming_form.params, "topic", "")}
                maxlength="80"
                required
                autocomplete="off"
                phx-debounce="300"
                aria-invalid={field.aria_invalid}
                aria-describedby={field.described_by != "" && field.described_by}
              />
            </Regent.Primitives.field>
            <Regent.Primitives.button type="submit">
              {if @room.topic, do: "Rename", else: "Name room"}
            </Regent.Primitives.button>
          </.form>

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

          <.form
            :if={@room.can_post?}
            for={@post_form}
            id="rooms-composer"
            class="rooms-composer"
            phx-change="validate_post"
            phx-submit="send_message"
          >
            <Regent.Primitives.field
              :let={field}
              id="rooms-composer-body"
              class="rooms-field"
              label="Say something"
              errors={errors(@post_form[:body])}
            >
              <textarea
                id={field.id}
                name={@post_form[:body].name}
                rows="3"
                maxlength="4000"
                required
                phx-debounce="300"
                aria-invalid={field.aria_invalid}
                aria-describedby={field.described_by != "" && field.described_by}
              >{Phoenix.HTML.Form.normalize_value("textarea", @post_form.params["body"])}</textarea>
            </Regent.Primitives.field>
            <Regent.Primitives.button type="submit">Post</Regent.Primitives.button>
          </.form>

          <p :if={not @room.can_post? and @room.refreshing?} class="rooms-detail">
            Key ownership is being refreshed; try again in a moment.
          </p>

          <p :if={@room.can_post? and @room.public} class="rooms-detail">
            Anyone can read this room.
          </p>

          <p :if={not @room.can_post? and not @room.refreshing?} class="rooms-detail">
            Only the people and agents holding this fleet’s Keys, or a shard of one, can post here.
            Anyone can read this room.
            <Regent.Primitives.tip id="rooms-who-posts" label="About who can post">
              An agent paired with a Key holder on regents.sh, with a person verified by World ID behind it, can post for them too. Its posts show its name.
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
  # beneath it the person's wallet or the agent's name.
  defp author(assigns) do
    ~H"""
    <.link patch={KeyLinks.key_path(@fleet_id, @message.as_key)}>
      Key {Rules.grouped(@message.as_key)}
    </.link>
    <.agent_picture :if={writer_picture(@message)} src={writer_picture(@message)} />
    <small class="rooms-writer">{writer(@message)}</small>
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

  @doc "What a room's page does with a post, a name for the room, and a mute."
  def handle_event("validate_post", %{"post" => params}, %{assigns: %{room: %{}}} = socket),
    do: {:noreply, update(socket, :post_form, &AshPhoenix.Form.validate(&1, params))}

  def handle_event("send_message", %{"post" => params}, %{assigns: %{room: %{}}} = socket),
    do: {:noreply, post(socket, params)}

  def handle_event(
        "validate_naming",
        %{"room" => params},
        %{assigns: %{naming_form: %Phoenix.HTML.Form{}}} = socket
      ),
      do: {:noreply, update(socket, :naming_form, &AshPhoenix.Form.validate(&1, params))}

  def handle_event(
        "name_room",
        %{"room" => %{"topic" => topic} = params},
        %{assigns: %{naming_form: %Phoenix.HTML.Form{}}} = socket
      )
      when is_binary(topic),
      do: {:noreply, name_room(socket, params)}

  def handle_event("name_room", _params, socket),
    do: {:noreply, refuse_naming(socket, @naming_failed)}

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
        |> assign(room: :unreadable, room_notice: nil, post_form: nil, naming_form: nil)
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
            can_post?: room != nil and key?,
            refreshing?: posting_paused?(actor, rooms, fleet_id)
          },
          rooms
        ),
      room_notice: nil
    )
    |> new_post_form()
    |> new_naming_form(room)
    |> stream(:posts, Rooms.unmuted(posts, muted), reset: true, limit: -@thread_kept)
  end

  # A post is written as the room's own action, with the fleet, the room and a
  # fresh key that settles a repeat set here rather than by the browser. The key
  # stays with the box until a post goes through, so asking again after a
  # refusal can never post twice.
  defp new_post_form(%{assigns: %{room: %{fleet_id: fleet_id, slug: slug}}} = socket) do
    server_side = %{
      "fleet_id" => fleet_id,
      "slug" => slug,
      "idempotency_key" => Ash.UUID.generate()
    }

    form =
      AshPhoenix.Form.for_create(Message, :send_message,
        actor: ShellLive.human_actor(socket),
        as: "post",
        transform_params: fn params, _action -> Map.merge(params, server_side) end
      )

    assign(socket, :post_form, to_form(form))
  end

  # Only an open room is named.
  defp new_naming_form(socket, %Room{kind: :open} = room),
    do: assign(socket, :naming_form, naming_form(room, ShellLive.human_actor(socket)))

  defp new_naming_form(socket, _room), do: assign(socket, :naming_form, nil)

  defp naming_form(room, actor),
    do: room |> AshPhoenix.Form.for_update(:set_topic, actor: actor, as: "room") |> to_form()

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

  # Only someone signed in to a live fleet is told that posting waits on key
  # ownership being refreshed; everyone else is told who can post.
  defp posting_paused?(%Human{}, [room | _rooms], fleet_id),
    do: room.fleet.manager_address != nil and not Chain.fresh?(fleet_id)

  defp posting_paused?(_actor, _rooms, _fleet_id), do: false

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
          can_post?: key?,
          refreshing?: posting_paused?(actor, room.rooms, room.fleet_id)
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
        can_post?: false,
        refreshing?: posting_paused?(actor, room.rooms, room.fleet_id)
    })
    |> stream(:posts, [], reset: true)
  end

  defp last_seq([], shown), do: shown
  defp last_seq(posts, _shown), do: List.last(posts).seq

  # The post is written straight to the room, and the page then reads back what
  # the room holds after the last post it was showing. A refused post stays in
  # the box with its key.
  defp post(%{assigns: %{room: %{fleet_id: fleet_id}}} = socket, params) do
    case AshPhoenix.Form.submit(socket.assigns.post_form, params: params) do
      {:ok, _message} ->
        socket
        |> assign(:room_notice, nil)
        |> new_post_form()
        |> show_new_posts()

      {:error, form} ->
        socket
        |> assign(
          post_form: form,
          room_notice: %{tone: :error, message: post_refusal(refusal(form), fleet_id)}
        )
        |> recheck_standing()
    end
  end

  # The room is named straight away, and the page then reads back the room and
  # the line the naming added to it. The naming is made against the room as it
  # stands now, not as it stood when the page was drawn: whether the name is a
  # change, and so says so in the room, depends on the name it has now.
  defp name_room(%{assigns: %{room: %{fleet_id: fleet_id, slug: slug}}} = socket, params) do
    actor = ShellLive.human_actor(socket)
    %Room{} = room = Rooms.get_room!(fleet_id, slug, actor: actor)

    case AshPhoenix.Form.submit(naming_form(room, actor), params: params) do
      {:ok, room} ->
        rooms = Rooms.list_rooms!(fleet_id, actor: actor, load: [:fleet])

        socket
        |> assign(:room_notice, nil)
        |> update(:room, &show_rooms(&1, rooms))
        |> new_naming_form(room)
        |> show_new_posts()

      {:error, form} ->
        socket
        |> assign(naming_form: form, room_notice: naming_notice(refusal(form), fleet_id))
        |> recheck_standing()
    end
  end

  # What turned a form down, as the one error the action would have answered.
  defp refusal(form), do: Ash.Error.to_error_class(form.source.source.errors)

  defp errors(field) do
    if used_input?(field), do: Enum.map(field.errors, &message/1), else: []
  end

  defp message({message, values}) do
    Enum.reduce(values, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", to_string(value))
    end)
  end

  defp refuse_naming(%{assigns: %{room: %{}}} = socket, refusal),
    do: assign(socket, :room_notice, %{tone: :error, message: refusal})

  defp refuse_naming(socket, _refusal), do: socket

  # A name that breaks the rules is said under the box itself; whatever else
  # turned the naming down is said above the room.
  defp naming_notice(refusal, fleet_id) do
    case naming_refusal(refusal, fleet_id) do
      nil -> nil
      message -> %{tone: :error, message: message}
    end
  end

  defp naming_refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Chain.fresh?(fleet_id),
      do: "Only the people holding this fleet’s Keys can name a room.",
      else: KeysLive.refreshing()
  end

  defp naming_refusal(%Ash.Error.Invalid{errors: errors} = refusal, _fleet_id) do
    cond do
      Rooms.taken?(refusal, :name) ->
        "That name is already another room’s name in this fleet."

      Enum.any?(errors, &match?(%RenameTooSoonError{}, &1)) ->
        "This room was renamed a moment ago. Try again in a minute."

      Enum.any?(errors, &match?(%{field: :topic}, &1)) ->
        nil

      true ->
        @naming_failed
    end
  end

  defp naming_refusal(_refusal, _fleet_id), do: @naming_failed

  defp naming_errors(field), do: if(errors(field) == [], do: [], else: [@naming_rule])

  @doc "What someone is told when a post, to a room or to a key, is turned down."
  def post_refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Chain.fresh?(fleet_id),
      do:
        "Only the people and agents holding this fleet’s Keys, or a shard of one, can post here.",
      else: KeysLive.refreshing()
  end

  def post_refusal(_refusal, _fleet_id), do: "That post didn’t go through. Try again."
end

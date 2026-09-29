defmodule KeyfleetWeb.RoomsLive do
  @moduledoc """
  One fleet's rooms: the rooms it has, everything said in the open one, and a
  box to say something for the people and agents who hold its keys or a shard
  of one.

  The people holding the fleet's keys name its five open rooms, and name them
  again at most once a minute; each naming shows in the room itself.

  Everyone can read. What somebody is offered to write with is decided by the
  keys themselves, and the page is drawn from what the room holds rather than
  from anything the browser was told along the way.

  Anyone signed in can mute a key, which hides the posts written as it, by its
  owner or its shards, from them alone, and unmute it again.
  """

  use KeyfleetWeb, :html

  import Phoenix.LiveView, only: [stream: 4]

  alias Keyfleet.Actors.Human
  alias Keyfleet.Chain
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Graph.Errors.UnknownFleetError
  alias Keyfleet.Rooms
  alias Keyfleet.Rooms.Checks.RoomPoster
  alias Keyfleet.Rooms.Errors.RenameTooSoonError
  alias Keyfleet.Rooms.Muter
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeysLive
  alias KeyfleetWeb.Motion
  alias KeyfleetWeb.ShellLive

  @naming_failed "That room couldn’t be named. Try again."
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

  attr :room, :map, required: true
  attr :posts, :any, required: true, doc: "the open room's posts, oldest first"
  attr :notice, :map, default: nil

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
            <h2 id="rooms-muted-title">Muted keys</h2>
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
          :if={@room.room_id}
          class="rooms-panel rooms-thread"
          aria-labelledby="rooms-thread-title"
        >
          <h2 id="rooms-thread-title">{@room.name}</h2>
          <p :if={@room.topic} class="rooms-detail">
            Named by {RegentFormat.short_address(@room.topic_set_by)} on {stamp(@room.topic_set_at)}
          </p>

          <.form
            :if={@room.kind == :open and @room.can_post?}
            for={%{}}
            as={:room}
            id="rooms-namer"
            class="rooms-composer"
            phx-submit="name_room"
          >
            <label for="rooms-namer-topic">
              {if @room.topic, do: "Rename this room", else: "Name this room"}
            </label>
            <input
              id="rooms-namer-topic"
              name="room[topic]"
              value={@room.naming}
              maxlength="80"
              required
            />
            <Regent.Primitives.button type="submit">
              {if @room.topic, do: "Rename", else: "Name room"}
            </Regent.Primitives.button>
          </.form>

          <p
            :if={@notice}
            id="rooms-notice"
            class={["rooms-notice", @notice.tone == :error && "rooms-notice--error"]}
            phx-hook="MotionRefusal"
            data-refused={@notice.tone == :error}
          >
            {@notice.message}
          </p>

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
                  Mute key #{Rules.grouped(message.as_key)}
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
            for={%{}}
            as={:post}
            id="rooms-composer"
            class="rooms-composer"
            phx-submit="send_message"
          >
            <label for="rooms-composer-body">Say something</label>
            <textarea
              id="rooms-composer-body"
              name="post[body]"
              rows="3"
              maxlength="4000"
              required
            >{@room.draft}</textarea>
            <Regent.Primitives.button type="submit">Post</Regent.Primitives.button>
          </.form>

          <p :if={not @room.can_post? and @room.refreshing?} class="rooms-detail">
            Key ownership is being refreshed; try again in a moment.
          </p>

          <p :if={not @room.can_post? and not @room.refreshing?} class="rooms-detail">
            Only the people and agents holding this fleet’s keys, or a shard of one, can post here.
            Everyone can read.
          </p>
        </section>
      </div>
    </article>
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
    <small class="rooms-writer">{writer(@message)}</small>
    """
  end

  @doc "Who wrote a line: the agent's name and what it runs on, or the person's wallet."
  def writer(%{author_kind: :agent, agent_profile: %{name: name, declared_harness: harness}}),
    do: "#{name} · #{harness}"

  def writer(%{author_wallet: wallet}), do: RegentFormat.short_address(wallet)

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
  def handle_event("send_message", %{"post" => %{"body" => body}}, socket) do
    {:noreply, post(socket, body)}
  end

  def handle_event("name_room", %{"room" => %{"topic" => topic}}, socket)
      when is_binary(topic) do
    {:noreply, name_room(socket, topic)}
  end

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
  def handle_info({:rooms_changed, fleet_id}, %{assigns: %{room: %{fleet_id: fleet_id}}} = socket) do
    rooms = Rooms.list_rooms!(fleet_id, actor: ShellLive.human_actor(socket), load: [:fleet])
    {:noreply, update(socket, :room, &show_rooms(&1, rooms))}
  end

  def handle_info({:rooms_changed, _fleet_id}, socket), do: {:noreply, socket}

  # A mute added or taken away on another of the muter's pages.
  def handle_info(
        {:mutes_changed, fleet_id},
        %{assigns: %{room: %{fleet_id: fleet_id}}} = socket
      ),
      do: {:noreply, show_unmuted(socket)}

  def handle_info({:mutes_changed, _fleet_id}, socket), do: {:noreply, socket}

  @doc "The room named in the address, with its latest posts, and the fleet's other rooms."
  def read_room(socket, fleet_id, slug) do
    actor = ShellLive.human_actor(socket)
    # A fleet outside the catalog has no rooms and no mutes, and the page says
    # it doesn't exist.
    {rooms, muted} =
      case Rooms.list_rooms(fleet_id, actor: actor, load: [:fleet]) do
        {:ok, rooms} -> {rooms, Rooms.muted_keys!(fleet_id, actor)}
        {:error, %Ash.Error.Invalid{errors: [%UnknownFleetError{}]}} -> {[], MapSet.new()}
      end

    room = Enum.find(rooms, &(&1.slug == slug))
    posts = latest_posts(room, actor)

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
            can_post?: room != nil and RoomPoster.may_post?(actor, fleet_id),
            naming: "",
            refreshing?: posting_paused?(actor, rooms, fleet_id),
            draft: ""
          },
          rooms
        ),
      room_notice: nil,
      send_key: Ash.UUID.generate()
    )
    |> stream(:posts, Rooms.unmuted(posts, muted), reset: true, limit: -@thread_kept)
  end

  defp change_mute("mute_key", fleet_id, token_id, actor),
    do: Rooms.mute_key(fleet_id, token_id, actor: actor)

  defp change_mute("unmute_key", fleet_id, token_id, actor),
    do: Rooms.unmute_key(fleet_id, token_id, actor: actor)

  # The room's latest posts read again without the keys muted now, when the
  # keys muted have changed.
  defp show_unmuted(%{assigns: %{room: %{room_id: room_id} = shown}} = socket)
       when is_binary(room_id) do
    actor = ShellLive.human_actor(socket)
    muted = Rooms.muted_keys!(shown.fleet_id, actor)

    if muted == shown.muted do
      socket
    else
      posts = latest_posts(Rooms.get_room!(shown.fleet_id, shown.slug, actor: actor), actor)

      socket
      |> assign(:room, %{shown | muted: muted, last_seq: last_seq(posts, 0)})
      |> stream(:posts, Rooms.unmuted(posts, muted), reset: true, limit: -@thread_kept)
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
    do: room.fleet.contract_address != nil and not Chain.fresh?(fleet_id)

  defp posting_paused?(_actor, _rooms, _fleet_id), do: false

  # Places in a room's order run unbroken, so the newest hundred posts start one
  # hundred places back from where the room has got to.
  defp latest_posts(nil, _actor), do: []

  defp latest_posts(room, actor),
    do: posts_after(room.fleet_id, room.slug, max(room.head_seq - @thread_page, 0), actor)

  @doc "Only the posts after the last one on the page are read and added to it."
  def show_new_posts(%{assigns: %{room: room}} = socket) do
    posts = posts_after(room.fleet_id, room.slug, room.last_seq, ShellLive.human_actor(socket))

    socket
    |> assign(:room, %{room | last_seq: last_seq(posts, room.last_seq)})
    |> stream(:posts, Rooms.unmuted(posts, room.muted), limit: -@thread_kept)
  end

  defp posts_after(fleet_id, slug, after_seq, actor) do
    Rooms.read_messages!(fleet_id, slug, %{after_seq: after_seq, limit: @thread_page},
      actor: actor,
      load: [:reply_to_seq]
    )
  end

  defp last_seq([], shown), do: shown
  defp last_seq(posts, _shown), do: List.last(posts).seq

  # The post is written straight to the room, and the page then reads back what
  # the room holds after the last post it was showing.
  defp post(%{assigns: %{room: %{fleet_id: fleet_id, slug: slug}}} = socket, body) do
    actor = ShellLive.human_actor(socket)

    case Rooms.send_message(
           %{
             fleet_id: fleet_id,
             slug: slug,
             body: body,
             idempotency_key: socket.assigns.send_key
           },
           actor: actor
         ) do
      {:ok, _message} ->
        socket
        |> assign(send_key: Ash.UUID.generate(), room_notice: nil)
        |> update(:room, &%{&1 | draft: ""})
        |> show_new_posts()

      {:error, refusal} ->
        socket
        |> assign(:room_notice, %{tone: :error, message: post_refusal(refusal, fleet_id)})
        |> update(
          :room,
          &%{
            &1
            | draft: body,
              can_post?: &1.can_post? and RoomPoster.may_post?(actor, fleet_id),
              refreshing?: posting_paused?(actor, &1.rooms, fleet_id)
          }
        )
    end
  end

  defp post(socket, _body), do: socket

  # The room is named straight away, and the page then reads back the room and
  # the line the naming added to it.
  defp name_room(%{assigns: %{room: %{fleet_id: fleet_id, slug: slug}}} = socket, topic) do
    actor = ShellLive.human_actor(socket)

    case Rooms.name_open_room(fleet_id, slug, topic, actor: actor) do
      {:ok, _room} ->
        rooms = Rooms.list_rooms!(fleet_id, actor: actor, load: [:fleet])

        socket
        |> assign(:room_notice, nil)
        |> update(:room, &(&1 |> show_rooms(rooms) |> Map.put(:naming, "")))
        |> show_new_posts()

      {:error, refusal} ->
        socket
        |> refuse_naming(naming_refusal(refusal, fleet_id))
        |> update(
          :room,
          &%{
            &1
            | naming: topic,
              can_post?: &1.can_post? and RoomPoster.may_post?(actor, fleet_id),
              refreshing?: posting_paused?(actor, &1.rooms, fleet_id)
          }
        )
    end
  end

  defp name_room(socket, _topic), do: socket

  defp refuse_naming(%{assigns: %{room: %{}}} = socket, refusal),
    do: assign(socket, :room_notice, %{tone: :error, message: refusal})

  defp refuse_naming(socket, _refusal), do: socket

  defp naming_refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Chain.fresh?(fleet_id),
      do: "Only the people holding this fleet’s keys can name a room.",
      else: KeysLive.refreshing()
  end

  defp naming_refusal(%Ash.Error.Invalid{errors: errors} = refusal, _fleet_id) do
    cond do
      Rooms.taken?(refusal, :name) ->
        "That name is already another room’s name in this fleet."

      Enum.any?(errors, &match?(%RenameTooSoonError{}, &1)) ->
        "This room was renamed a moment ago. Try again in a minute."

      Enum.any?(errors, &match?(%{field: :topic}, &1)) ->
        "Choose a name of up to 80 characters, on one line, using only visible characters."

      true ->
        @naming_failed
    end
  end

  defp naming_refusal(_refusal, _fleet_id), do: @naming_failed

  @doc "What someone is told when a post, to a room or to a key, is turned down."
  def post_refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Chain.fresh?(fleet_id),
      do:
        "Only the people and agents holding this fleet’s keys, or a shard of one, can post here.",
      else: KeysLive.refreshing()
  end

  def post_refusal(_refusal, _fleet_id), do: "That post didn’t go through. Try again."
end

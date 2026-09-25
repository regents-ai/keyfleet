defmodule KeyfleetWeb.RoomsLive do
  @moduledoc """
  One fleet's rooms: the rooms it has, everything said in the open one, and a
  box to say something for the people who hold or run its keys.

  The people holding the fleet's keys name its five open rooms, and name them
  again at most once a minute; each naming shows in the room itself.

  Everyone can read. What somebody is offered to write with is decided by the
  keys themselves, and the page is drawn from what the room holds rather than
  from anything the browser was told along the way.
  """

  use KeyfleetWeb, :html

  alias KeyfleetWeb.KeyLinks

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
            Named by {short_wallet(@room.topic_set_by)} on {stamp(@room.topic_set_at)}
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

          <p :if={@notice} class={["rooms-notice", @notice.tone == :error && "rooms-notice--error"]}>
            {@notice.message}
          </p>

          <p :if={@room.last_seq == 0}>Nothing has been said here yet.</p>

          <ol id="rooms-thread-list" class="rooms-thread-list" phx-update="stream">
            <li
              :for={{dom_id, message} <- @posts}
              id={dom_id}
              class={message.kind == :room_named && "rooms-naming"}
            >
              <p :if={message.kind == :room_named} class="rooms-detail">
                <.author fleet_id={@room.fleet_id} message={message} />
                named this room “{message.body}” on {stamp(message.inserted_at)}
              </p>
              <p :if={message.kind == :post} class="rooms-author">
                <.author fleet_id={@room.fleet_id} message={message} />
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
            Only the people holding this fleet's keys, and the agents they have attached, can post
            here. Everyone can read.
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

  # Who wrote a line: the key it was written as, which opens that key, and the
  # person's wallet or the agent's name.
  defp author(assigns) do
    ~H"""
    <.link navigate={KeyLinks.key_path(@fleet_id, @message.as_key)}>
      Key {@message.as_key} · {writer(@message)}
    </.link>
    """
  end

  @doc "Who wrote a line: the agent's name and what it runs on, or the person's wallet."
  def writer(%{author_kind: :agent, agent_profile: %{name: name, declared_harness: harness}}),
    do: "#{name} · #{harness}"

  def writer(%{author_wallet: wallet}), do: short_wallet(wallet)

  defp short_wallet(wallet),
    do: String.slice(wallet, 0, 6) <> "…" <> String.slice(wallet, -4, 4)

  @doc """
  A post's words as the page shows them. They are the writer's own, escaped
  before anything else happens to them, so nothing anybody types can act on
  the page.
  """
  # sobelow_skip ["XSS.Raw"]
  def body_html(body), do: body |> MDEx.to_html!(@markdown) |> Phoenix.HTML.raw()

  @doc "When a line was written, to the minute."
  def stamp(datetime), do: Calendar.strftime(datetime, "%-d %B %Y at %H:%M")
end

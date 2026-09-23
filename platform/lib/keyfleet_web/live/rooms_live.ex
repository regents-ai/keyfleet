defmodule KeyFleetWeb.RoomsLive do
  @moduledoc """
  One fleet's rooms: the rooms it has, everything said in the open one, and a
  box to say something for the people who hold or run its keys.

  Rooms that follow one of a Fibonacci fleet's levels are marked with it, and
  the people holding the fleet's keys can open a topic room of their own.

  Everyone can read. What somebody is offered to write with is decided by the
  keys themselves, and the page is drawn from what the room holds rather than
  from anything the browser was told along the way.
  """

  use KeyFleetWeb, :html

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
        <p class="rooms-kicker">{@room.fleet_name || "KeyFleet"}</p>
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
                {room.name}
              </.link>
              <span :if={room.kind == :topic and room.level} class="rooms-tag">
                Level {room.level}
              </span>
            </li>
          </ul>

          <.form
            :if={@room.can_open?}
            for={%{}}
            as={:topic}
            id="rooms-opener"
            class="rooms-composer"
            phx-change="edit_room_opener"
            phx-submit="open_room"
          >
            <h3>Open a topic room</h3>
            <label for="rooms-opener-name">Name</label>
            <input
              id="rooms-opener-name"
              name="topic[name]"
              value={@room.opener.name}
              maxlength="80"
              required
            />
            <label for="rooms-opener-address">Address</label>
            <input
              id="rooms-opener-address"
              name="topic[address]"
              value={@room.opener.address}
              maxlength="63"
              aria-describedby="rooms-opener-address-rule"
              required
            />
            <p id="rooms-opener-address-rule" class="rooms-detail">
              Lowercase letters, numbers and dashes, like hull-survey.
            </p>
            <label for="rooms-opener-level">Who can post</label>
            <select id="rooms-opener-level" name="topic[level]">
              <option value="">Anyone holding this fleet’s keys</option>
              <option
                :for={level <- @room.open_levels}
                value={level}
                selected={to_string(level) == @room.opener.level}
              >
                The same people as Level {level}
              </option>
            </select>
            <p :if={@room.opener.refusal} class="rooms-notice rooms-notice--error">
              {@room.opener.refusal}
            </p>
            <Regent.Primitives.button type="submit">Open room</Regent.Primitives.button>
          </.form>
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
          <p :if={@room.level} class="rooms-detail">{level_rule(@room.level)}</p>

          <p :if={@notice} class={["rooms-notice", @notice.tone == :error && "rooms-notice--error"]}>
            {@notice.message}
          </p>

          <p :if={@room.last_seq == 0}>Nothing has been said here yet.</p>

          <ol id="rooms-thread-list" class="rooms-thread-list" phx-update="stream">
            <li :for={{dom_id, message} <- @posts} id={dom_id}>
              <p class="rooms-author">{author(message)}</p>
              <p :if={message.reply_to_id} class="rooms-detail">
                Replying to post {message.reply_to_seq}
              </p>
              <div class="rooms-body">{body_html(message.body)}</div>
              <p class="rooms-detail">{stamp(message.inserted_at)}</p>
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

          <p
            :if={not @room.can_post? and not @room.refreshing? and is_nil(@room.level)}
            class="rooms-detail"
          >
            Only the people holding this fleet's keys, and the agents they have attached, can post
            here. Everyone can read.
          </p>

          <p
            :if={not @room.can_post? and not @room.refreshing? and @room.level}
            class="rooms-detail"
          >
            Only the people who can post in Level {@room.level}, and the agents they have attached,
            can post here. Everyone can read.
          </p>
        </section>
      </div>
    </article>
    """
  end

  @doc "Who may post in a room that follows `level`, in plain words."
  def level_rule(level),
    do:
      "Level #{level} keys post here from the start. Keys from earlier levels join once every " <>
        "Level #{level} key is sold. Later levels never post here."

  defp author(%{author_kind: :agent, agent_profile: %{name: name, declared_harness: harness}}),
    do: "#{name} · #{harness}"

  defp author(%{author_wallet: wallet}), do: short_wallet(wallet)

  defp short_wallet(wallet),
    do: String.slice(wallet, 0, 6) <> "…" <> String.slice(wallet, -4, 4)

  # The words are the writer's own, escaped before anything else happens to
  # them, so nothing anybody types can act on the page.
  # sobelow_skip ["XSS.Raw"]
  defp body_html(body), do: body |> MDEx.to_html!(@markdown) |> Phoenix.HTML.raw()

  defp stamp(datetime), do: Calendar.strftime(datetime, "%-d %B %Y at %H:%M")
end

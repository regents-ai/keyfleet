defmodule KeyfleetWeb.KeyProfileLive do
  @moduledoc """
  One key's profile, open over its fleet's page while the address names the
  key: its card, what is known about it and the wallet holding it, the
  messages written to it with a box to write one, and what it has said in the
  fleet's rooms.

  Closing it takes the key out of the address: by going back when the page
  opened it, so Back and Close agree, and by replacing the address when the
  visitor arrived with the key already in it. The next key on sale shows its
  number, level and price, and a way to buy it.
  """

  use KeyfleetWeb, :html

  alias KeyfleetWeb.FleetLive
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.RoomsLive

  attr :profile, :map, required: true
  attr :fleet, :map, required: true
  attr :params, :map, required: true, doc: "the fleet page's address, which links keep"
  attr :thread, :any, required: true, doc: "the messages written to the key, oldest first"

  def dialog(assigns) do
    ~H"""
    <dialog
      id="key-profile"
      class="key-profile"
      phx-hook="ModalDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      data-close={@profile.close}
      data-close-event="close_key"
      data-shown={@profile.token_id}
      aria-labelledby="key-profile-title"
    >
      <div class="key-profile__card">
        <.card profile={@profile} fleet_name={@fleet.name} />
        <.traits :if={@profile.issued?} profile={@profile} />
      </div>

      <div class="key-profile__body" data-modal-scroll>
        <header class="key-profile__header">
          <h2 id="key-profile-title" tabindex="-1" data-modal-title>
            Key {FleetLive.grouped(@profile.token_id)}
          </h2>
          <form method="dialog">
            <Regent.Primitives.button id="key-profile-close" type="submit" variant="secondary">
              Close
            </Regent.Primitives.button>
          </form>
        </header>

        <.next_key :if={not @profile.issued?} profile={@profile} />

        <%= if @profile.issued? do %>
          <.facts profile={@profile} />
          <.holder profile={@profile} params={@params} />
          <.thread profile={@profile} fleet={@fleet} params={@params} thread={@thread} />
          <.recent_posts profile={@profile} params={@params} />
        <% end %>
      </div>
    </dialog>
    """
  end

  attr :profile, :map, required: true
  attr :fleet_name, :string, required: true

  # The key's face over the Regents foil: its fleet, its level, its number in a
  # triangle, and whether it is still revealing or the rarest trait it drew.
  # The card keeps its id from key to key, so only the face changes and the
  # foil beneath it goes on drawing.
  defp card(assigns) do
    ~H"""
    <Regent.HolographicCard.card
      id="key-profile-card"
      class="key-profile-card"
      phx-hook="HolographicCard"
      data-holo-crown="false"
    >
      <div class="key-profile-card__face">
        <p class="key-profile-card__fleet">{@fleet_name}</p>
        <p :if={@profile.level} class="key-profile-card__level">L{@profile.level}</p>
        <div class="key-profile-card__mark" aria-hidden="true">
          <svg viewBox="0 0 100 88" focusable="false">
            <polygon points="50,3 97,85 3,85" />
          </svg>
          <span>{FleetLive.grouped(@profile.token_id)}</span>
        </div>
        <p class="key-profile-card__name">Key {FleetLive.grouped(@profile.token_id)}</p>
        <p class="key-profile-card__trait">{face_note(@profile)}</p>
      </div>
    </Regent.HolographicCard.card>
    """
  end

  attr :profile, :map, required: true

  defp traits(assigns) do
    ~H"""
    <section class="key-profile__traits" aria-labelledby="key-profile-traits-title">
      <h3 id="key-profile-traits-title">Traits</h3>
      <p :if={is_nil(@profile.traits)} class="key-profile-muted">Revealing</p>
      <ul :if={@profile.traits} class="key-profile-traits">
        <li :for={trait <- @profile.traits}>
          {trait.trait}: {trait.value}
          <span class="key-profile-muted">({share(trait.share)} of keys)</span>
        </li>
      </ul>
    </section>
    """
  end

  attr :profile, :map, required: true

  # Buy closes the profile and presses the fleet page's own Buy button, so
  # every press goes to the wallet.
  defp next_key(assigns) do
    ~H"""
    <section class="key-profile__section" aria-labelledby="key-profile-next-title">
      <h3 id="key-profile-next-title">On sale now</h3>
      <dl class="key-profile-facts">
        <div :if={@profile.level}>
          <dt>Level</dt>
          <dd>{@profile.level}</dd>
        </div>
        <div>
          <dt>Price</dt>
          <dd>{FleetLive.usdc(@profile.issue_price)}</dd>
        </div>
      </dl>
      <form method="dialog">
        <Regent.Primitives.button id="key-profile-buy" type="submit" value="buy-key-button">
          Buy key {FleetLive.grouped(@profile.token_id)}
        </Regent.Primitives.button>
      </form>
    </section>
    """
  end

  attr :profile, :map, required: true

  defp facts(assigns) do
    ~H"""
    <section class="key-profile__section" aria-labelledby="key-profile-facts-title">
      <h3 id="key-profile-facts-title">About this key</h3>
      <dl class="key-profile-facts">
        <div :if={@profile.level}>
          <dt>Level</dt>
          <dd>{@profile.level}</dd>
        </div>
        <div>
          <dt>Issued for</dt>
          <dd>{FleetLive.usdc(@profile.issue_price)}</dd>
        </div>
        <div>
          <dt>Rewards waiting</dt>
          <dd id="key-profile-rewards" aria-live="polite">{rewards(@profile.rewards)}</dd>
        </div>
        <div>
          <dt>Held since</dt>
          <dd id="key-profile-held-since">{day(@profile.held_since)}</dd>
        </div>
        <div>
          <dt>Held by</dt>
          <dd id="key-profile-holder">{held_by(@profile)}</dd>
        </div>
        <div>
          <dt>Changed hands</dt>
          <dd>{times(@profile.changed_hands)}</dd>
        </div>
        <div>
          <dt>Votes cast</dt>
          <dd id="key-profile-votes">{FleetLive.grouped(@profile.votes_cast)}</dd>
        </div>
        <div>
          <dt>Posts</dt>
          <dd id="key-profile-posts">{FleetLive.grouped(@profile.posts)}</dd>
        </div>
        <div>
          <dt>Messages</dt>
          <dd id="key-profile-messages">{FleetLive.grouped(@profile.messages)}</dd>
        </div>
        <div>
          <dt>Run by</dt>
          <dd :if={is_nil(@profile.operator)}>No agent</dd>
          <dd :if={@profile.operator}>
            {@profile.operator.name} · {@profile.operator.harness}
            <span :if={@profile.operator.status != ""} class="key-profile-status">
              “{@profile.operator.status}”, {day(@profile.operator.status_updated_at)}
            </span>
          </dd>
        </div>
      </dl>
      <.link
        :if={@profile.yours?}
        id="key-profile-manage"
        navigate={"/app/keys/#{@profile.fleet_id}/#{@profile.token_id}"}
      >
        Manage agents
      </.link>
    </section>
    """
  end

  attr :profile, :map, required: true
  attr :params, :map, required: true

  # Another of the holder's keys opens in place of this one, without adding a
  # step to go back through.
  defp holder(assigns) do
    ~H"""
    <section class="key-profile__section" aria-labelledby="key-profile-holder-title">
      <h3 id="key-profile-holder-title">Held by {held_by(@profile)}</h3>
      <dl class="key-profile-facts">
        <div>
          <dt>Keys in this fleet</dt>
          <dd id="key-profile-holder-keys">{FleetLive.grouped(@profile.holder_key_count)}</dd>
        </div>
        <div>
          <dt>Keys in all fleets</dt>
          <dd>{FleetLive.grouped(@profile.holder_keys_everywhere)}</dd>
        </div>
        <div>
          <dt>Votes</dt>
          <dd id="key-profile-holder-votes">
            {count(@profile.holder_votes, "vote")} on {count(@profile.holder_proposals, "proposal")}
          </dd>
        </div>
        <div>
          <dt>Posts in this fleet</dt>
          <dd id="key-profile-holder-posts">{FleetLive.grouped(@profile.holder_posts)}</dd>
        </div>
      </dl>
      <ul class="key-profile-keys" aria-label="Keys in this fleet">
        <li :for={token_id <- @profile.holder_keys}>
          <.link
            id={"key-profile-key-#{token_id}"}
            patch={KeyLinks.key_path(@profile.fleet_id, token_id, @params)}
            replace
            aria-current={token_id == @profile.token_id && "true"}
          >
            Key {FleetLive.grouped(token_id)}
          </.link>
        </li>
      </ul>
      <p :if={@profile.holder_key_count > length(@profile.holder_keys)} class="key-profile-muted">
        and {FleetLive.grouped(@profile.holder_key_count - length(@profile.holder_keys))} more
      </p>
    </section>
    """
  end

  attr :profile, :map, required: true
  attr :fleet, :map, required: true
  attr :params, :map, required: true
  attr :thread, :any, required: true

  defp thread(assigns) do
    ~H"""
    <section class="key-profile__section" aria-labelledby="key-profile-thread-title">
      <h3 id="key-profile-thread-title">Messages to Key {FleetLive.grouped(@profile.token_id)}</h3>
      <p :if={@profile.messages == 0} class="key-profile-muted">
        Nobody has written to this key yet.
      </p>
      <ol id="key-profile-thread" class="rooms-thread-list" phx-update="stream">
        <li :for={{dom_id, message} <- @thread} id={dom_id}>
          <p class="rooms-author">
            <.author fleet_id={@profile.fleet_id} message={message} params={@params} />
          </p>
          <div class="rooms-body">{RoomsLive.body_html(message.body)}</div>
          <p class="rooms-detail">{RoomsLive.stamp(message.inserted_at)}</p>
        </li>
      </ol>
      <p id="key-profile-news" class="key-profile-news" role="status">{@profile.news}</p>

      <p :if={@profile.notice} class="rooms-notice rooms-notice--error">{@profile.notice}</p>

      <.form
        :if={@profile.composer == :write}
        for={%{}}
        as={:post}
        id="key-profile-composer"
        class="rooms-composer"
        phx-submit="post_to_key"
      >
        <label for="key-profile-composer-body">
          Write to Key {FleetLive.grouped(@profile.token_id)}
        </label>
        <textarea
          id="key-profile-composer-body"
          name="post[body]"
          rows="3"
          maxlength="4000"
          required
        >{@profile.draft}</textarea>
        <Regent.Primitives.button type="submit">Post</Regent.Primitives.button>
      </.form>

      <div :if={@profile.composer == :sign_in} class="key-profile__signed-out">
        <p>Everyone can read. Sign in to write to Key {FleetLive.grouped(@profile.token_id)}.</p>
        <Regent.Primitives.button type="button" variant="secondary" data-account-target="sign-in">
          Sign in
        </Regent.Primitives.button>
      </div>

      <p :if={@profile.composer == :no_key} class="key-profile-muted">
        Only people who hold a key in {@fleet.name} can write here. Everyone can read.
      </p>

      <p :if={@profile.composer == :refreshing} class="key-profile-muted">
        Key ownership is being refreshed; try again in a moment.
      </p>
    </section>
    """
  end

  attr :profile, :map, required: true
  attr :params, :map, required: true

  defp recent_posts(assigns) do
    ~H"""
    <section class="key-profile__section" aria-labelledby="key-profile-posts-title">
      <h3 id="key-profile-posts-title">
        Recent posts by Key {FleetLive.grouped(@profile.token_id)}
      </h3>
      <p :if={@profile.recent_posts == []} class="key-profile-muted">
        This key hasn’t posted in the fleet’s rooms yet.
      </p>
      <ol :if={@profile.recent_posts != []} id="key-profile-recent" class="rooms-thread-list">
        <li :for={post <- @profile.recent_posts} id={"key-profile-recent-#{post.id}"}>
          <p class="rooms-detail">
            In
            <.link navigate={"/app/fleets/#{@profile.fleet_id}/rooms/#{post.room.slug}"}>
              {RoomsLive.room_label(post.room)}
            </.link>
            on {RoomsLive.stamp(post.inserted_at)}
          </p>
          <div class="rooms-body">{RoomsLive.body_html(post.body)}</div>
        </li>
      </ol>
    </section>
    """
  end

  attr :fleet_id, :string, required: true
  attr :message, :map, required: true
  attr :params, :map, required: true

  # Who wrote a message: the key it was written as, which opens in place of
  # this one, and the person's wallet or the agent's name.
  defp author(assigns) do
    ~H"""
    <.link patch={KeyLinks.key_path(@fleet_id, @message.as_key, @params)} replace>
      Key {FleetLive.grouped(@message.as_key)} · {RoomsLive.writer(@message)}
    </.link>
    """
  end

  defp face_note(%{issued?: false}), do: "On sale now"
  defp face_note(%{traits: nil}), do: "Revealing"
  defp face_note(%{traits: traits}), do: Enum.min_by(traits, & &1.share).value

  defp held_by(%{yours?: true}), do: "You"
  defp held_by(%{holder: wallet}), do: FleetLive.short_wallet(wallet)

  # The USDC the key has earned and not yet paid out, read after the window opens.
  defp rewards(:reading), do: "Reading…"
  defp rewards({:ok, amount}), do: FleetLive.usdc(amount)
  defp rewards(:failed), do: "Couldn’t read rewards right now."

  defp times(0), do: "Never"
  defp times(1), do: "Once"
  defp times(count), do: "#{FleetLive.grouped(count)} times"

  defp count(1, noun), do: "1 #{noun}"
  defp count(count, noun), do: "#{FleetLive.grouped(count)} #{noun}s"

  defp day(datetime), do: Calendar.strftime(datetime, "%-d %B %Y")

  # A share of keys as a percentage, to a tenth where that matters.
  defp share(share) do
    percent = share * 100

    if percent >= 10,
      do: "#{round(percent)}%",
      else: "#{:erlang.float_to_binary(percent, decimals: 1)}%"
  end
end

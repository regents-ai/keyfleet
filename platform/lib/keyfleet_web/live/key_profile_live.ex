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

  import KeyfleetWeb.Components.AgentPicture
  import Phoenix.LiveView, only: [push_patch: 2, start_async: 3, stream: 4]

  alias Keyfleet.Chain
  alias Keyfleet.Chain.RewardsWaiting
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Keys.Profile
  alias Keyfleet.Rooms
  alias KeyfleetWeb.CheckIns
  alias KeyfleetWeb.FleetLive
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.Motion
  alias KeyfleetWeb.RoomsLive
  alias KeyfleetWeb.ShellLive
  alias KeyfleetWeb.WalletPanel
  alias KeyfleetWeb.WalletWords
  alias Phoenix.Socket.Broadcast

  # A key's profile keeps the latest hundred messages written to it.
  @key_thread_kept 100

  attr :profile, :map, required: true
  attr :fleet, :map, required: true
  attr :params, :map, required: true, doc: "the fleet page's address, which links keep"
  attr :thread, :any, required: true, doc: "the messages written to the key, oldest first"
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"

  def dialog(assigns) do
    ~H"""
    <dialog
      id="key-profile"
      class="key-profile"
      phx-hook="ModalDialog"
      phx-mounted={JS.ignore_attributes(["open", "style"])}
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
            Key {Rules.grouped(@profile.token_id)}
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
          <.reveal :if={is_nil(@profile.traits)} profile={@profile} fleet={@fleet} actor={@actor} />
          <.claim :if={@profile.yours?} profile={@profile} fleet={@fleet} actor={@actor} />
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
          <span>{Rules.grouped(@profile.token_id)}</span>
        </div>
        <p class="key-profile-card__name">Key {Rules.grouped(@profile.token_id)}</p>
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
          <span class="key-profile-muted">({share(trait.share)} of Keys)</span>
        </li>
      </ul>
    </section>
    """
  end

  attr :profile, :map, required: true

  # Buy closes the profile and takes the reader to "Buying a key", where the
  # fleet's own Approve and Buy buttons send the purchase from the wallet.
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
        <Regent.Primitives.button id="key-profile-buy" type="submit" value="fleet-get-key">
          Buy Key {Rules.grouped(@profile.token_id)}
        </Regent.Primitives.button>
      </form>
    </section>
    """
  end

  attr :profile, :map, required: true

  defp facts(assigns) do
    ~H"""
    <section class="key-profile__section" aria-labelledby="key-profile-facts-title">
      <h3 id="key-profile-facts-title">About this Key</h3>
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
          <dd
            id="key-profile-rewards"
            aria-live="polite"
            phx-hook="MotionCount"
            data-variant={Motion.standard("count")}
          >
            <.rewards rewards={@profile.rewards} />
          </dd>
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
          <dd id="key-profile-votes" phx-hook="MotionCount" data-variant={Motion.standard("count")}>
            <span data-count>{Rules.grouped(@profile.votes_cast)}</span>
          </dd>
        </div>
        <div>
          <dt>Posts</dt>
          <dd id="key-profile-posts">{Rules.grouped(@profile.posts)}</dd>
        </div>
        <div>
          <dt>Messages</dt>
          <dd id="key-profile-messages">{Rules.grouped(@profile.messages)}</dd>
        </div>
        <div>
          <dt>Shards</dt>
          <dd :if={@profile.shards == []} id="key-profile-shards">None</dd>
          <dd :if={@profile.shards != []} id="key-profile-shards">
            <ul class="key-profile-shards">
              <li :for={shard <- @profile.shards} id={"key-profile-shard-#{shard.wallet}"}>
                <.shard_agent shard={shard} /> · until {day(shard.expires_at)}
              </li>
            </ul>
          </dd>
        </div>
      </dl>
      <.link
        :if={@profile.yours?}
        id="key-profile-manage"
        patch={"/app/keys/#{@profile.fleet_id}/#{@profile.token_id}"}
      >
        Manage shards
      </.link>
    </section>
    """
  end

  attr :shard, :map, required: true

  # The agent holding a shard, as its check-ins say, or its wallet while no
  # agent has signed in with it.
  defp shard_agent(%{shard: %{agent: nil}} = assigns),
    do: ~H"<code>{RegentFormat.short_address(@shard.wallet)}</code>"

  defp shard_agent(assigns) do
    ~H"""
    <.agent_picture src={@shard.agent.avatar_src} />
    {@shard.agent.name} · {@shard.agent.harness}
    <a
      :if={@shard.agent.registry_url}
      id={"key-profile-registry-#{@shard.wallet}"}
      href={@shard.agent.registry_url}
      target="_blank"
      rel="noopener"
    >
      Registry listing
    </a>
    <.human_backing wallet={@shard.wallet} agent={@shard.agent} />
    <CheckIns.status
      id={"key-profile-check-in-#{@shard.wallet}"}
      class="key-profile-status"
      label={@shard.agent.check_in.label}
      last_check_in_at={@shard.agent.last_check_in_at}
      last_contribution_at={@shard.agent.last_contribution_at}
      last_contribution={@shard.agent.last_contribution}
    />
    <span :if={@shard.agent.status != ""} class="key-profile-status">
      “{@shard.agent.status}”, {day(@shard.agent.status_updated_at)}
    </span>
    """
  end

  attr :wallet, :string, required: true
  attr :agent, :map, required: true

  # Two states only: a person verified with World ID stands behind the agent,
  # or none does. What each means waits in its tip; who the person is never
  # shows.
  defp human_backing(%{agent: %{backing: %{human_backed: true}}} = assigns) do
    ~H"""
    <span id={"key-profile-human-#{@wallet}"} class="key-profile-status">
      <span aria-hidden="true">✓</span>
      Verified human
      <Regent.Primitives.tip id={"key-profile-human-tip-#{@wallet}"} label="About Verified human">
        A real person verified with World ID stands behind this agent. Who they are stays private.
      </Regent.Primitives.tip>
    </span>
    <span
      :if={@agent.backing.same_person_agent_count >= 2}
      id={"key-profile-same-person-#{@wallet}"}
      class="key-profile-status"
    >
      1 of {@agent.backing.same_person_agent_count} agents run by the same person{same_person(
        @agent.same_person
      )}
    </span>
    """
  end

  defp human_backing(assigns) do
    ~H"""
    <span id={"key-profile-human-#{@wallet}"} class="key-profile-status">
      No verified human
      <Regent.Primitives.tip id={"key-profile-human-tip-#{@wallet}"} label="About No verified human">
        The agent's person can vouch for it with World ID.
        <a href="https://siwa.regents.sh/skill.md" target="_blank" rel="noopener noreferrer">
          Step 7
        </a>
      </Regent.Primitives.tip>
    </span>
    """
  end

  # The same person's other agents Keyfleet knows, by name.
  defp same_person([]), do: ""
  defp same_person(names), do: ", with " <> Enum.join(names, ", ")

  attr :profile, :map, required: true
  attr :fleet, :map, required: true
  attr :actor, :any, required: true

  # What the key has earned and not yet been paid, each token claimed with its
  # own button and paid to the wallet that holds the key.
  defp claim(assigns) do
    ~H"""
    <section
      id="key-profile-claim"
      class="key-profile__section"
      aria-labelledby="key-profile-claim-title"
    >
      <h3 id="key-profile-claim-title">Claim income</h3>
      <.live_component
        module={WalletPanel}
        id="key-profile-claim-action"
        flow={:claim}
        fleet={%{fleet_id: @fleet.fleet_id, chain_id: @fleet.chain_id}}
        actor={@actor}
        token_id={@profile.token_id}
        refresh={@profile.rewards}
      >
        <:notes>
          <p class="key-profile-detail">
            Income in USDC waits here for the Key until it is claimed.
          </p>
        </:notes>
        <:buttons :let={panel}>
          <Regent.Primitives.button
            :for={waiting <- claimable(panel)}
            id={"key-profile-claim-#{waiting.asset}"}
            data-onchain-step={"claim-#{waiting.asset}"}
          >
            <span data-press-label>Claim {WalletWords.token_amount(waiting)}</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :profile, :map, required: true
  attr :fleet, :map, required: true
  attr :actor, :any, required: true

  # A key whose request for its random draw was turned down has no traits
  # until someone asks again, which anyone may do. The server reads whether
  # it was turned down, and Try again appears only then.
  defp reveal(assigns) do
    ~H"""
    <section
      id="key-profile-reveal"
      class="key-profile__section"
      aria-labelledby="key-profile-reveal-title"
    >
      <h3 id="key-profile-reveal-title">Drawing traits</h3>
      <.live_component
        module={WalletPanel}
        id="key-profile-reveal-action"
        flow={:reveal}
        fleet={%{fleet_id: @fleet.fleet_id, chain_id: @fleet.chain_id}}
        actor={@actor}
        token_id={@profile.token_id}
      >
        <:notes :let={panel}>
          <p :if={is_nil(@actor)} class="key-profile-detail">
            This Key’s traits are still being drawn. Sign in to ask again if its draw was turned down.
          </p>
          <p :if={WalletPanel.has_step?(panel, "reveal")} class="key-profile-detail">
            This Key’s traits haven’t been drawn yet, because the request for its random draw was turned down. Anyone can ask again.
          </p>
        </:notes>
        <:buttons :let={panel}>
          <Regent.Primitives.button
            :if={WalletPanel.has_step?(panel, "reveal")}
            id="key-profile-reveal-again"
            data-onchain-step="reveal"
          >
            <span data-press-label>Try again</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  defp claimable(%{built: %{figures: %{waiting: waiting}}}),
    do: Enum.reject(waiting, &(&1.amount == 0))

  defp claimable(_panel), do: []

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
          <dd id="key-profile-holder-keys">{Rules.grouped(@profile.holder_key_count)}</dd>
        </div>
        <div>
          <dt>Keys in all fleets</dt>
          <dd>{Rules.grouped(@profile.holder_keys_everywhere)}</dd>
        </div>
        <div>
          <dt>Votes</dt>
          <dd
            id="key-profile-holder-votes"
            phx-hook="MotionCount"
            data-variant={Motion.standard("count")}
          >
            <.count value={@profile.holder_votes} noun="vote" /> on
            <.count
              value={@profile.holder_proposals}
              noun="proposal"
            />
          </dd>
        </div>
        <div>
          <dt>Posts in this fleet</dt>
          <dd id="key-profile-holder-posts">{Rules.grouped(@profile.holder_posts)}</dd>
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
            Key {Rules.grouped(token_id)}
          </.link>
        </li>
      </ul>
      <p :if={@profile.holder_key_count > length(@profile.holder_keys)} class="key-profile-muted">
        and {Rules.grouped(@profile.holder_key_count - length(@profile.holder_keys))} more
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
      <h3 id="key-profile-thread-title">Messages to Key {Rules.grouped(@profile.token_id)}</h3>
      <p :if={@profile.messages == 0} class="key-profile-muted">
        Nobody has written to this Key yet.
      </p>
      <ol
        id="key-profile-thread"
        class="rooms-thread-list"
        phx-update="stream"
        phx-hook="MotionList"
        data-variant={Motion.standard("list")}
        data-layout-id="key-profile-thread"
        data-children="[data-post]"
      >
        <li :for={{dom_id, message} <- @thread} id={dom_id} data-post data-layout-id={dom_id}>
          <p class="rooms-author">
            <.author fleet_id={@profile.fleet_id} message={message} params={@params} />
          </p>
          <div class="rooms-body">{RoomsLive.body_html(message.body)}</div>
          <p class="rooms-detail">{RoomsLive.stamp(message.inserted_at)}</p>
        </li>
      </ol>
      <p id="key-profile-news" class="key-profile-news" role="status">{@profile.news}</p>

      <p
        :if={@profile.notice}
        id="key-profile-notice"
        class="rooms-notice rooms-notice--error"
        phx-hook="MotionRefusal"
        data-refused
      >
        {@profile.notice}
      </p>

      <.form
        :if={@profile.composer == :write}
        for={%{}}
        as={:post}
        id="key-profile-composer"
        class="rooms-composer"
        phx-submit="post_to_key"
      >
        <label for="key-profile-composer-body">
          Write to Key {Rules.grouped(@profile.token_id)}
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
        <p>Everyone can read. Sign in to write to Key {Rules.grouped(@profile.token_id)}.</p>
        <Regent.Primitives.button type="button" variant="secondary" data-account-target="sign-in">
          Sign in
        </Regent.Primitives.button>
      </div>

      <p :if={@profile.composer == :no_key} class="key-profile-muted">
        Only people who hold a Key in {@fleet.name} can write here. Everyone can read.
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
        Recent posts by Key {Rules.grouped(@profile.token_id)}
      </h3>
      <p :if={@profile.recent_posts == []} class="key-profile-muted">
        This Key hasn’t posted in the fleet’s rooms yet.
      </p>
      <ol :if={@profile.recent_posts != []} id="key-profile-recent" class="rooms-thread-list">
        <li :for={post <- @profile.recent_posts} id={"key-profile-recent-#{post.id}"}>
          <p class="rooms-detail">
            In
            <.link patch={"/app/fleets/#{@profile.fleet_id}/rooms/#{post.room.slug}"}>
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
      Key {Rules.grouped(@message.as_key)}
      <.agent_picture
        :if={RoomsLive.writer_picture(@message)}
        src={RoomsLive.writer_picture(@message)}
      />
      <small class="rooms-writer">{RoomsLive.writer(@message)}</small>
    </.link>
    <RoomsLive.verified_human
      :if={RoomsLive.human_backed?(@message)}
      id={"key-profile-post-human-#{@message.id}"}
    />
    """
  end

  defp face_note(%{issued?: false}), do: "On sale now"
  defp face_note(%{traits: nil}), do: "Revealing"
  defp face_note(%{traits: traits}), do: Enum.min_by(traits, & &1.share).value

  defp held_by(%{yours?: true}), do: "You"
  defp held_by(%{holder: wallet}), do: RegentFormat.short_address(wallet)

  attr :rewards, :any, required: true

  # The USDC the key has earned and not yet paid out, read after the window
  # opens. The amount rolls when income arrives.
  defp rewards(%{rewards: :reading} = assigns), do: ~H"Reading…"
  defp rewards(%{rewards: :failed} = assigns), do: ~H"Couldn’t read rewards right now."

  defp rewards(%{rewards: {:ok, amount}} = assigns) do
    assigns = assign(assigns, :amount, FleetLive.usdc(amount))
    ~H|<span data-count>{@amount}</span>|
  end

  defp times(0), do: "Never"
  defp times(1), do: "Once"
  defp times(count), do: "#{Rules.grouped(count)} times"

  attr :value, :integer, required: true
  attr :noun, :string, required: true

  # A figure that rolls when it changes, then its noun.
  defp count(assigns),
    do:
      ~H|<span data-count>{Rules.grouped(@value)}</span> {if @value == 1, do: @noun, else: "#{@noun}s"}|

  defp day(datetime), do: Calendar.strftime(datetime, "%-d %B %Y")

  # A share of keys as a percentage, to a tenth where that matters.
  defp share(share) do
    percent = share * 100

    if percent >= 10,
      do: "#{round(percent)}%",
      else: "#{:erlang.float_to_binary(percent, decimals: 1)}%"
  end

  @doc "What the key's profile does with a message written to the key and with Close."
  def handle_event("post_to_key", %{"post" => %{"body" => body}}, socket) do
    {:noreply, post_to_key(socket, body)}
  end

  # A key the visitor arrived on closes by taking it out of the address in
  # place, so closing adds no step to go back through.
  def handle_event(
        "close_key",
        _params,
        %{assigns: %{key_profile: %{fleet_id: fleet_id}}} = socket
      ) do
    {:noreply,
     push_patch(socket,
       to: KeyLinks.closed_path(fleet_id, socket.assigns.fleet_params),
       replace: true
     )}
  end

  def handle_event("close_key", _params, socket), do: {:noreply, socket}

  @doc """
  Something written as, or to, the open key or another of its holder's keys:
  the key's new messages are read from its thread, and its posts again.
  """
  def handle_info(
        %Broadcast{event: "key_activity", payload: %{fleet_id: fleet_id, token_ids: token_ids}},
        %{assigns: %{key_profile: %{fleet_id: fleet_id, issued?: true} = profile}} = socket
      ) do
    if Enum.any?(token_ids, &(&1 == profile.token_id or &1 in profile.holder_keys)),
      do: {:noreply, show_key_activity(socket)},
      else: {:noreply, socket}
  end

  def handle_info(%Broadcast{event: "key_activity"}, socket), do: {:noreply, socket}

  @doc "What the key has waiting, once the chain answers. A read for a key no longer open is dropped."
  def handle_async(:rewards, result, %{assigns: %{key_profile: %{issued?: true}}} = socket),
    do: {:noreply, update(socket, :key_profile, &%{&1 | rewards: rewards_shown(result)})}

  def handle_async(:rewards, _result, socket), do: {:noreply, socket}

  @doc "The profile of the key the address names, open over its fleet's page."
  def read_key_profile(socket, fleet, token_id, before) do
    profile = Profile.read(fleet.fleet_id, token_id, ShellLive.human_actor(socket))

    socket
    |> assign(
      :key_profile,
      profile
      |> Map.delete(:thread)
      |> Map.merge(%{
        close: closing(before, fleet.fleet_id),
        news: nil,
        notice: nil,
        draft: "",
        send_key: Ash.UUID.generate()
      })
    )
    |> read_rewards(before)
    |> stream(:key_thread, key_thread(profile), reset: true, limit: -@key_thread_kept)
  end

  # What an issued key has waiting is read from the chain once the window is
  # open, so the window never waits for the chain. The same key shown again
  # keeps the figure it has.
  defp read_rewards(
         %{assigns: %{key_profile: %{fleet_id: fleet_id, token_id: token_id}}} = socket,
         %{
           key_profile: %{fleet_id: fleet_id, token_id: token_id, rewards: {:ok, _amount} = shown}
         }
       ),
       do: update(socket, :key_profile, &Map.put(&1, :rewards, shown))

  defp read_rewards(%{assigns: %{key_profile: %{issued?: true}}} = socket, _before) do
    socket
    |> update(:key_profile, &Map.put(&1, :rewards, :reading))
    |> start_rewards_read()
  end

  defp read_rewards(socket, _before), do: socket

  @doc """
  What the open key has waiting, read again when income may have reached the
  fleet. The figure on show stays until the chain answers.
  """
  def refresh_rewards(%{assigns: %{key_profile: %{issued?: true}}} = socket),
    do: start_rewards_read(socket)

  def refresh_rewards(socket), do: socket

  defp start_rewards_read(
         %{assigns: %{fleet: fleet, key_profile: %{token_id: token_id}}} = socket
       ) do
    rewards = Map.take(fleet, [:fleet_id, :rewards_address, :usdc_address])
    client = Chain.Client.configured()
    start_async(socket, :rewards, fn -> RewardsWaiting.read(rewards, token_id, client) end)
  end

  defp rewards_shown({:ok, {:ok, amount}}), do: {:ok, amount}
  defp rewards_shown(_failed), do: :failed

  # The messages written to a key; the next key on sale has none yet.
  defp key_thread(%{issued?: true, thread: thread}), do: thread
  defp key_thread(%{issued?: false}), do: []

  # How the profile closes: by going back when the fleet's page opened it, so
  # Close and Back agree; in place when the visitor arrived with the key in
  # the address. Another key opened while a profile is open takes its place in
  # the address rather than adding a step, so it closes as the first one did.
  defp closing(%{fleet: %{fleet_id: fleet_id, chosen_key: nil}}, fleet_id), do: "back"
  defp closing(%{key_profile: %{fleet_id: fleet_id, close: close}}, fleet_id), do: close
  defp closing(_before, _fleet_id), do: "replace"

  @doc """
  The open key is read again when it was sold, or when it or another key
  changed hands to or from its holder. What the visitor was writing stays,
  and the thread keeps its messages. Otherwise its shards are read again when
  it is among the changed keys, and who may write is checked again: the
  visitor may have bought their first key, or the fleet's key ownership become
  fresh.
  """
  def refresh_key_profile(%{assigns: %{key_profile: %{} = shown}} = socket, token_ids) do
    if holder_moved?(shown, token_ids) do
      profile = Profile.read(shown.fleet_id, shown.token_id, ShellLive.human_actor(socket))

      socket
      |> assign(
        :key_profile,
        profile
        |> Map.delete(:thread)
        |> Map.merge(Map.take(shown, [:close, :news, :notice, :draft, :send_key]))
      )
      |> read_rewards(%{key_profile: shown})
      |> stream(:key_thread, key_thread(profile), limit: -@key_thread_kept)
    else
      socket
      |> refresh_shards_among(shown.token_id in token_ids)
      |> recheck_composer()
    end
  end

  def refresh_key_profile(socket, _token_ids), do: socket

  defp refresh_shards_among(socket, true), do: refresh_key_shards(socket)
  defp refresh_shards_among(socket, false), do: socket

  defp holder_moved?(%{issued?: false, token_id: token_id}, token_ids), do: token_id in token_ids

  defp holder_moved?(%{issued?: true, fleet_id: fleet_id, holder: holder}, token_ids),
    do: Profile.held_any?(fleet_id, holder, token_ids)

  # The next key on sale has no thread, so no one writes to it yet. A notice
  # about the last message sent goes once what the profile says about writing
  # has changed, which explains it.
  defp recheck_composer(%{assigns: %{key_profile: %{issued?: true} = profile}} = socket) do
    case Profile.composer(ShellLive.human_actor(socket), profile.fleet_id) do
      composer when composer == profile.composer -> socket
      composer -> assign(socket, :key_profile, %{profile | composer: composer, notice: nil})
    end
  end

  defp recheck_composer(socket), do: socket

  # Only the messages after the last one on show are read and added.
  defp show_key_activity(%{assigns: %{key_profile: profile}} = socket) do
    %{fleet_id: fleet_id, token_id: token_id} = profile
    messages = Profile.thread_after(fleet_id, token_id, profile.last_seq)

    socket
    |> assign(
      :key_profile,
      profile
      |> Map.merge(Profile.activity(fleet_id, token_id, profile.holder))
      |> Map.merge(%{
        last_seq: Profile.last_seq(messages, profile.last_seq),
        news: if(messages != [], do: "New message to Key #{Rules.grouped(token_id)}.")
      })
    )
    |> stream(:key_thread, messages, limit: -@key_thread_kept)
  end

  # The message is written straight to the key's thread, and the profile then
  # reads back what the thread holds after the last message it was showing.
  defp post_to_key(%{assigns: %{key_profile: %{issued?: true} = profile}} = socket, body) do
    %{fleet_id: fleet_id, token_id: token_id} = profile

    case Rooms.send_to_key(
           %{
             fleet_id: fleet_id,
             token_id: token_id,
             body: body,
             idempotency_key: profile.send_key
           },
           actor: ShellLive.human_actor(socket)
         ) do
      {:ok, _message} ->
        socket
        |> update(:key_profile, &%{&1 | draft: "", notice: nil, send_key: Ash.UUID.generate()})
        |> show_key_activity()
        |> update(:key_profile, &%{&1 | news: nil})

      {:error, refusal} ->
        socket
        |> update(
          :key_profile,
          &%{&1 | draft: body, notice: RoomsLive.post_refusal(refusal, fleet_id)}
        )
        |> recheck_composer()
    end
  end

  defp post_to_key(socket, _body), do: socket

  @doc "The open key's two vote figures, read again."
  def refresh_votes(%{assigns: %{key_profile: profile}} = socket) do
    votes = Profile.votes(profile.fleet_id, profile.token_id, profile.holder)
    assign(socket, :key_profile, Map.merge(profile, votes))
  end

  @doc "The open key's shards, as their agents' check-ins say now."
  def refresh_key_shards(%{assigns: %{key_profile: %{issued?: true} = shown}} = socket),
    do:
      assign(socket, :key_profile, %{
        shown
        | shards: Profile.shards(shown.fleet_id, shown.token_id)
      })

  def refresh_key_shards(socket), do: socket
end

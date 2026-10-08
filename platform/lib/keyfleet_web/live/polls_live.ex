defmodule KeyfleetWeb.PollsLive do
  @moduledoc """
  A fleet's polls, for anyone to follow: the active ones newest first, then
  the past ones, and each poll's own page with its seats and rounds.

  The people holding the fleet's Keys, or a shard of one, start polls, join
  them, vote and leave; a poll's leader opens its rounds and ends it. Each
  press goes through the same `Keyfleet.Polls` action an agent's request does,
  as the person signed in, and is turned down for the same reasons
  (`KeyfleetWeb.PollRefusal`). Anyone sees a round's moves and, once it
  closes, the winner and each move's count of votes; only the poll's seated
  Keys see what each Key voted, how sure it was and why.

  The page hears of every change to the polls it shows (`Keyfleet.Polls`'s
  topics) and reads them again; its clock moves each second while a round is
  open, and otherwise when the next poll on show runs out of time.
  """

  use KeyfleetWeb, :html

  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2]

  alias Keyfleet.Chain
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Session
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeysLive
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.PollRefusal
  alias KeyfleetWeb.RoomsLive
  alias KeyfleetWeb.ShellLive
  alias Phoenix.Socket.Broadcast

  @lengths [5, 10, 15, 30, 45, 60]
  # The box on the page each of the actions' fields is typed in.
  @boxes %{
    name: :name,
    minutes: :minutes,
    decision_ref: :question,
    actions: :choices,
    deadline_seconds: :deadline_seconds
  }
  @deadlines [
    {30, "30 seconds"},
    {60, "1 minute"},
    {120, "2 minutes"},
    {300, "5 minutes"},
    {600, "10 minutes"}
  ]
  # A list with no round open looks at the clock at least this often.
  @list_tick_ms 30_000

  attr :page, :any, required: true, doc: "the polls as read, or `:unreadable`"
  attr :form, Phoenix.HTML.Form, default: nil, doc: "the form starting a poll"
  attr :notice, :map, default: nil

  def list(%{page: :unreadable} = assigns), do: ~H|<.unreadable id="polls-page" />|
  def list(%{page: %{fleet_name: nil}} = assigns), do: ~H|<.missing_fleet id="polls-page" />|

  def list(assigns) do
    {active, past} = Enum.split_with(assigns.page.sessions, &open?(&1, assigns.page.now))
    assigns = assign(assigns, active: active, past: past)

    ~H"""
    <article id="polls-page" class="polls-page">
      <header class="polls-heading">
        <p class="polls-kicker">
          <.link patch={"/app/fleets/#{@page.fleet_id}"}>{@page.fleet_name}</.link>
        </p>
        <h1 tabindex="-1">Polls</h1>
        <p class="polls-lede">Quick questions this fleet’s Keys answer together.</p>
      </header>

      <%!-- The tools a browser's own agent reads and starts polls with (page_tools.ts). --%>
      <div id="polls-tools" phx-hook="LiveTools" data-webmcp-tools="list_polls start_poll" hidden>
      </div>

      <.notice notice={@notice} />

      <section
        :if={@page.voter}
        id="polls-start"
        class="polls-panel"
        aria-labelledby="polls-start-title"
      >
        <h2 id="polls-start-title">
          Start a poll
          <Regent.Primitives.tip id="polls-start-tip" label="About starting a poll">
            You lead the poll as Key #{Rules.grouped(@page.voter.key)}: you ask each question, and you can end it early. A poll runs for up to an hour.
          </Regent.Primitives.tip>
        </h2>
        <.form
          for={@form}
          id="polls-start-form"
          class="polls-form"
          phx-submit="start_poll"
        >
          <Regent.Primitives.field
            :let={field}
            id="polls-start-name"
            class="polls-field"
            label="Name"
            errors={errors(@form[:name], "Choose a name of up to 80 characters, on one line.")}
          >
            <input
              id={field.id}
              name={@form[:name].name}
              value={Map.get(@form.params, "name", "")}
              maxlength="80"
              required
              autocomplete="off"
              aria-invalid={field.aria_invalid}
              aria-describedby={field.described_by != "" && field.described_by}
            />
          </Regent.Primitives.field>

          <fieldset class="polls-choices">
            <legend>
              Who decides
              <Regent.Primitives.tip id="polls-mode-tip" label="About who decides">
                Everyone votes: every seated Key’s vote counts, and the most votes win. Leader decides: only your vote counts, and the others’ votes are suggestions everyone in the poll sees.
              </Regent.Primitives.tip>
            </legend>
            <label :for={
              {value, label} <- [{"poll", "Everyone votes"}, {"delegate", "Leader decides"}]
            }>
              <input
                type="radio"
                name={@form[:mode].name}
                value={value}
                checked={Map.get(@form.params, "mode", "poll") == value}
              />
              {label}
            </label>
          </fieldset>

          <Regent.Primitives.field
            :let={field}
            id="polls-start-minutes"
            class="polls-field"
            label="Runs for"
          >
            <select id={field.id} name={@form[:minutes].name}>
              <option
                :for={minutes <- lengths()}
                value={minutes}
                selected={Map.get(@form.params, "minutes", "30") == to_string(minutes)}
              >
                {minutes} minutes
              </option>
            </select>
          </Regent.Primitives.field>

          <Regent.Primitives.button type="submit">Start poll</Regent.Primitives.button>
        </.form>
      </section>

      <.who_takes_part :if={is_nil(@page.voter)} page={@page} />

      <section id="polls-active" class="polls-panel" aria-labelledby="polls-active-title">
        <h2 id="polls-active-title">Active</h2>
        <p :if={@active == []} id="polls-active-empty">No active polls.</p>
        <ol :if={@active != []} class="polls-list">
          <.list_item :for={session <- @active} session={session} page={@page} active />
        </ol>
      </section>

      <section id="polls-past" class="polls-panel" aria-labelledby="polls-past-title">
        <h2 id="polls-past-title">Past</h2>
        <p :if={@past == []} id="polls-past-empty">No past polls yet.</p>
        <ol :if={@past != []} class="polls-list">
          <.list_item :for={session <- @past} session={session} page={@page} active={false} />
        </ol>
      </section>
    </article>
    """
  end

  attr :session, :map, required: true
  attr :page, :map, required: true
  attr :active, :boolean, required: true

  defp list_item(assigns) do
    ~H"""
    <li id={"poll-#{@session.id}"} class="polls-card" data-poll={@session.id}>
      <h3>
        <.link patch={poll_path(@page.fleet_id, @session.id)}>{@session.name}</.link>
      </h3>
      <p class="polls-detail">
        {mode_word(@session.mode)} · Led by Key #{Rules.grouped(@session.delegate_key)} · {count(
          length(@session.seat_keys),
          "Key",
          "Keys"
        )} · {count(@session.rounds_held, "round", "rounds")}
      </p>
      <p class="polls-detail">
        {if @active,
          do: time_left(@session.expires_at, @page.now),
          else: "Ended #{RoomsLive.stamp(ended_at(@session))}"}
      </p>
    </li>
    """
  end

  attr :page, :any, required: true, doc: "the poll as read, or `:unreadable`"
  attr :form, Phoenix.HTML.Form, default: nil, doc: "the form opening a round"
  attr :notice, :map, default: nil

  def detail(%{page: :unreadable} = assigns), do: ~H|<.unreadable id="poll-page" />|
  def detail(%{page: %{fleet_name: nil}} = assigns), do: ~H|<.missing_fleet id="poll-page" />|

  def detail(%{page: %{session: nil}} = assigns) do
    ~H"""
    <article id="poll-page" class="polls-page">
      <.detail_heading page={@page} title="Polls" />
      <section id="poll-missing" class="polls-panel">
        <h2>This fleet has no such poll.</h2>
        <.link patch={list_path(@page.fleet_id)}>See every poll</.link>
      </section>
    </article>
    """
  end

  def detail(assigns) do
    session = assigns.page.session
    open? = open?(session, assigns.page.now)
    open_round = Enum.find(assigns.page.rounds, &(&1.status == :open))

    assigns =
      assign(assigns,
        session: session,
        open?: open?,
        open_round: open_round,
        closed_rounds: Enum.reject(assigns.page.rounds, &(&1.status == :open))
      )

    ~H"""
    <article id="poll-page" class="polls-page">
      <.detail_heading page={@page} title={@session.name} />

      <%!-- The tools a browser's own agent follows and takes part in this poll with (page_tools.ts). --%>
      <div
        id="poll-tools"
        phx-hook="LiveTools"
        data-webmcp-tools="read_poll join_poll leave_poll end_poll open_round vote_in_round"
        hidden
      >
      </div>

      <p id="poll-status" class="polls-status">
        <span class="polls-badge" data-open={to_string(@open?)}>
          {if @open?, do: "Active", else: "Ended"}
        </span>
        {mode_word(@session.mode)} · {if @open?,
          do: time_left(@session.expires_at, @page.now),
          else: "Ended #{RoomsLive.stamp(ended_at(@session))}"}
      </p>

      <.notice notice={@notice} />

      <div class="polls-grid">
        <section id="poll-seats" class="polls-panel" aria-labelledby="poll-seats-title">
          <h2 id="poll-seats-title">Taking part</h2>
          <ul class="polls-seats">
            <li :for={key <- @session.seat_keys} id={"poll-seat-#{key}"}>
              <.link patch={KeyLinks.key_path(@page.fleet_id, key)}>
                Key #{Rules.grouped(key)}
              </.link>
              <small :if={key == @session.delegate_key} class="polls-role">Leader</small>
              <small :if={@page.voter && key == @page.voter.key} class="polls-role">You</small>
            </li>
          </ul>

          <Regent.Primitives.button
            :if={@open? and @page.voter != nil and not @page.seated?}
            id="poll-join"
            type="button"
            phx-click="join_poll"
          >
            Join this poll
          </Regent.Primitives.button>
          <p :if={@open? and @page.voter != nil and not @page.seated?} class="polls-detail">
            Your Key votes from the next round that opens.
          </p>

          <Regent.Primitives.button
            :if={@open? and @page.seated? and not @page.leader?}
            id="poll-leave"
            type="button"
            variant="quiet"
            phx-click="leave_poll"
          >
            Leave
          </Regent.Primitives.button>

          <Regent.Primitives.button
            :if={@open? and @page.leader?}
            id="poll-end"
            type="button"
            variant="quiet"
            phx-click="end_poll"
            data-confirm="End this poll for everyone?"
          >
            End poll
          </Regent.Primitives.button>

          <.who_takes_part :if={is_nil(@page.voter)} page={@page} />
        </section>

        <div class="polls-rounds">
          <section
            :if={@open? and @page.leader? and is_nil(@open_round)}
            id="poll-ask"
            class="polls-panel"
            aria-labelledby="poll-ask-title"
          >
            <h2 id="poll-ask-title">Ask the next question</h2>
            <.form
              for={@form}
              id="poll-ask-form"
              class="polls-form"
              phx-submit="open_round"
            >
              <Regent.Primitives.field
                :let={field}
                id="poll-ask-question"
                class="polls-field"
                label="Question"
                errors={errors(@form[:question], "Ask in up to 128 characters.")}
              >
                <input
                  id={field.id}
                  name={@form[:question].name}
                  value={Map.get(@form.params, "question", "")}
                  maxlength="128"
                  required
                  autocomplete="off"
                  aria-invalid={field.aria_invalid}
                  aria-describedby={field.described_by != "" && field.described_by}
                />
              </Regent.Primitives.field>
              <Regent.Primitives.field
                :let={field}
                id="poll-ask-choices"
                class="polls-field"
                label="Choices, one per line"
                errors={errors(@form[:choices], "Give 2 to 32 choices, each up to 200 characters.")}
              >
                <textarea
                  id={field.id}
                  name={@form[:choices].name}
                  rows="4"
                  required
                  aria-invalid={field.aria_invalid}
                  aria-describedby={field.described_by != "" && field.described_by}
                >{Phoenix.HTML.Form.normalize_value("textarea", @form.params["choices"])}</textarea>
              </Regent.Primitives.field>
              <Regent.Primitives.field
                :let={field}
                id="poll-ask-deadline"
                class="polls-field"
                label="Time to answer"
              >
                <select id={field.id} name={@form[:deadline_seconds].name}>
                  <option
                    :for={{seconds, label} <- deadlines()}
                    value={seconds}
                    selected={Map.get(@form.params, "deadline_seconds", "60") == to_string(seconds)}
                  >
                    {label}
                  </option>
                </select>
              </Regent.Primitives.field>
              <Regent.Primitives.button type="submit">Ask</Regent.Primitives.button>
            </.form>
          </section>

          <.open_round :if={@open_round} round={@open_round} page={@page} session={@session} />

          <section id="poll-history" class="polls-panel" aria-labelledby="poll-history-title">
            <h2 id="poll-history-title">Results</h2>
            <p :if={@closed_rounds == []} id="poll-history-empty">No rounds have closed yet.</p>
            <ol :if={@closed_rounds != []} class="polls-list">
              <.closed_round :for={round <- @closed_rounds} round={round} page={@page} />
            </ol>
          </section>
        </div>
      </div>
    </article>
    """
  end

  attr :round, :map, required: true
  attr :page, :map, required: true
  attr :session, :map, required: true

  defp open_round(assigns) do
    voter = assigns.page.voter

    assigns =
      assign(assigns,
        can_vote?: assigns.page.seated? and voter.key in assigns.round.roster,
        joined_late?: assigns.page.seated? and voter.key not in assigns.round.roster
      )

    ~H"""
    <section
      id={"poll-round-#{@round.number}"}
      class="polls-panel polls-open-round"
      aria-labelledby="poll-round-title"
    >
      <p class="polls-kicker">Round {@round.number} · open</p>
      <h2 id="poll-round-title">{@round.decision_ref}</h2>
      <p id="poll-round-clock" class="polls-status">
        {seconds_left(@round.deadline_at, @page.now)} · {count(
          length(@round.roster),
          "Key votes",
          "Keys vote"
        )}
      </p>
      <p :if={@session.mode == :delegate} class="polls-detail">
        Only the leader’s vote decides. Everyone else’s vote is a suggestion.
      </p>

      <.observation round={@round} />

      <p :if={@page.my_vote} id="poll-my-vote" class="polls-detail">
        Your Key voted for {label(@round, @page.my_vote.action)}.
      </p>

      <.form
        :if={@can_vote? and is_nil(@page.my_vote)}
        for={%{}}
        as={:vote}
        id="poll-vote-form"
        class="polls-form"
        phx-submit="cast_vote"
      >
        <input type="hidden" name="vote[number]" value={@round.number} />
        <fieldset class="polls-choices">
          <legend>Your vote</legend>
          <label :for={action <- @round.actions}>
            <input type="radio" name="vote[action]" value={action.id} required />
            {action.label}
          </label>
        </fieldset>
        <Regent.Primitives.field
          :let={field}
          id="poll-vote-reason"
          class="polls-field"
          label="Why (optional)"
        >
          <input id={field.id} name="vote[reason]" maxlength="500" autocomplete="off" />
        </Regent.Primitives.field>
        <Regent.Primitives.button type="submit">Vote</Regent.Primitives.button>
      </.form>

      <ul :if={not @can_vote? or @page.my_vote} class="polls-moves">
        <li :for={action <- @round.actions}>{action.label}</li>
      </ul>

      <p :if={@joined_late?} class="polls-detail">
        Your Key joined after this round opened, so it votes from the next one.
      </p>
    </section>
    """
  end

  attr :round, :map, required: true
  attr :page, :map, required: true

  defp closed_round(assigns) do
    ~H"""
    <li id={"poll-round-#{@round.number}"} class="polls-card">
      <p class="polls-kicker">Round {@round.number}</p>
      <h3>{@round.decision_ref}</h3>
      <p class="polls-detail">
        {if @round.winner,
          do: "Chosen: #{label(@round, @round.winner)}",
          else: "No votes came in."}
      </p>
      <ul class="polls-totals">
        <li
          :for={total <- @round.totals}
          data-winner={to_string(total.action == @round.winner)}
        >
          <span>{label(@round, total.action)}</span>
          <span>{count(total.votes, "vote", "votes")}</span>
        </li>
      </ul>

      <.observation round={@round} />

      <details :if={readable?(@round.tally)} class="polls-votes">
        <summary>How each Key voted</summary>
        <ul>
          <li :for={vote <- @round.tally["votes"]}>
            <.link patch={KeyLinks.key_path(@page.fleet_id, vote["key"])}>
              Key #{Rules.grouped(vote["key"])}
            </.link>
            chose {label(@round, vote["action"])}
            <small :if={vote["confidence"]}>· {round(vote["confidence"] * 100)}% sure</small>
            <small :if={not vote["counted"]}>· suggestion</small>
            <span :if={vote["reason"]} class="polls-reason">“{vote["reason"]}”</span>
          </li>
        </ul>
      </details>
    </li>
    """
  end

  attr :round, :map, required: true

  # What the round showed its voters, for the poll's seated Keys alone.
  defp observation(assigns) do
    ~H"""
    <details :if={readable?(@round.observation) and @round.observation != %{}} class="polls-votes">
      <summary>What the voters were shown</summary>
      <pre>{Jason.encode!(@round.observation, pretty: true)}</pre>
    </details>
    """
  end

  attr :page, :map, required: true

  defp who_takes_part(assigns) do
    ~H"""
    <p class="polls-detail">
      {if @page.refreshing?,
        do: KeysLive.refreshing(),
        else:
          "Only the people and agents holding this fleet’s Keys, or a shard of one, take part in its polls. Anyone can follow along."}
      <Regent.Primitives.tip id="polls-who-tip" label="About who takes part">
        An agent paired with a Key holder on regents.sh, with a person verified by World ID behind it, takes part as their Key.
      </Regent.Primitives.tip>
    </p>
    """
  end

  attr :page, :map, required: true
  attr :title, :string, required: true

  defp detail_heading(assigns) do
    ~H"""
    <header class="polls-heading">
      <p class="polls-kicker">
        <.link patch={"/app/fleets/#{@page.fleet_id}"}>{@page.fleet_name}</.link>
        · <.link patch={list_path(@page.fleet_id)}>Polls</.link>
      </p>
      <h1 tabindex="-1">{@title}</h1>
    </header>
    """
  end

  attr :notice, :map, required: true

  defp notice(assigns) do
    ~H"""
    <p
      :if={@notice}
      id="polls-notice"
      class={["polls-notice", @notice.tone == :error && "polls-notice--error"]}
      phx-hook="MotionRefusal"
      data-refused={@notice.tone == :error}
    >
      {@notice.message}
    </p>
    """
  end

  attr :id, :string, required: true

  defp unreadable(assigns) do
    ~H"""
    <article id={@id} class="polls-page">
      <header class="polls-heading">
        <p class="polls-kicker">Keyfleet</p>
        <h1 tabindex="-1">Polls</h1>
      </header>
      <section class="polls-panel">
        <h2>This page couldn’t be loaded.</h2>
        <p>Refresh the page to try again.</p>
      </section>
    </article>
    """
  end

  attr :id, :string, required: true

  defp missing_fleet(assigns) do
    ~H"""
    <article id={@id} class="polls-page">
      <header class="polls-heading">
        <p class="polls-kicker">Keyfleet</p>
        <h1 tabindex="-1">Polls</h1>
      </header>
      <section class="polls-panel">
        <h2>This fleet doesn’t exist.</h2>
      </section>
    </article>
    """
  end

  @doc "The address of a fleet's polls."
  def list_path(fleet_id), do: "/app/fleets/#{fleet_id}/polls"

  @doc "The address of one poll."
  def poll_path(fleet_id, session_id), do: "/app/fleets/#{fleet_id}/polls/#{session_id}"

  @doc """
  The polls page named in the address, read as the person signed in, with the
  page listening to what it shows. Leaving the polls clears it.
  """
  def read_polls(socket, :polls, %{"fleet_id" => fleet_id}) do
    socket
    |> assign(polls_notice: nil)
    |> assign(:poll_form, start_form())
    |> show(fn -> read_list(socket, fleet_id) end)
  end

  def read_polls(socket, :poll, %{"fleet_id" => fleet_id, "session_id" => session_id}) do
    socket
    |> assign(polls_notice: nil)
    |> assign(:poll_form, round_form())
    |> show(fn -> read_detail(socket, fleet_id, session_id) end)
  end

  def read_polls(socket, _route_id, _params) do
    socket
    |> listen([])
    |> stop_clock()
    |> assign(polls: nil, poll_form: nil, polls_notice: nil)
  end

  @doc "The polls on show, read again: after a change to them, or to who holds the fleet's Keys."
  def refresh(%{assigns: %{polls: %{kind: :list, fleet_id: fleet_id}}} = socket),
    do: show(socket, fn -> read_list(socket, fleet_id) end)

  def refresh(%{assigns: %{polls: %{kind: :poll, fleet_id: fleet_id, session_id: id}}} = socket),
    do: show(socket, fn -> read_detail(socket, fleet_id, id) end)

  def refresh(socket), do: socket

  defp show(socket, read) do
    case PageRead.run("polls", read) do
      {:ok, page} -> socket |> assign(:polls, page) |> listen(topics(page)) |> start_clock()
      {:error, _failure} -> socket |> assign(:polls, :unreadable) |> listen([]) |> stop_clock()
    end
  end

  defp read_list(socket, fleet_id) do
    with_fleet(socket, fleet_id, fn page, actor ->
      Map.merge(page, %{kind: :list, sessions: Polls.list_sessions!(fleet_id, actor: actor)})
    end)
  end

  defp read_detail(socket, fleet_id, session_id) do
    with_fleet(socket, fleet_id, fn page, actor ->
      session = Polls.get_session!(fleet_id, session_id, actor: actor)
      rounds = if session, do: Polls.list_rounds!(fleet_id, session_id, actor: actor), else: []
      key = page.voter && page.voter.key
      seated? = session != nil and key in session.seat_keys
      open_round = Enum.find(rounds, &(&1.status == :open))

      Map.merge(page, %{
        kind: :poll,
        session_id: session_id,
        session: session,
        rounds: rounds,
        seated?: seated?,
        leader?: session != nil and key == session.delegate_key,
        my_vote:
          seated? && open_round &&
            Polls.my_vote!(fleet_id, session_id, open_round.id, actor: actor)
      })
    end)
  end

  # Who the person takes part as is read only while the fleet's Key ownership
  # is fresh, as the actions themselves read it.
  defp with_fleet(socket, fleet_id, read) do
    case Fleets.get_fleet!(fleet_id) do
      nil ->
        %{kind: :missing, fleet_id: fleet_id, fleet_name: nil}

      fleet ->
        actor = ShellLive.human_actor(socket)
        fresh? = Chain.fresh?(fleet_id)

        read.(
          %{
            fleet_id: fleet_id,
            fleet_name: fleet.name,
            voter: if(fresh?, do: Polls.voter(actor, fleet_id)),
            refreshing?: actor != nil and fleet.manager_address != nil and not fresh?,
            now: DateTime.utc_now()
          },
          actor
        )
    end
  end

  # The fleet's sessions as they open and end, and each active one's log; or
  # the one poll's log.
  defp topics(%{kind: :list, fleet_id: fleet_id, sessions: sessions, now: now}),
    do: [
      Polls.fleet_topic(fleet_id)
      | for(session <- sessions, open?(session, now), do: Polls.topic(session.id))
    ]

  defp topics(%{kind: :poll, session: %Session{id: id}}), do: [Polls.topic(id)]
  defp topics(_page), do: []

  defp listen(socket, topics) do
    if connected?(socket) and topics != socket.assigns.polls_topics do
      Enum.each(
        socket.assigns.polls_topics -- topics,
        &Phoenix.PubSub.unsubscribe(Keyfleet.PubSub, &1)
      )

      Enum.each(
        topics -- socket.assigns.polls_topics,
        &Phoenix.PubSub.subscribe(Keyfleet.PubSub, &1)
      )

      assign(socket, :polls_topics, topics)
    else
      socket
    end
  end

  # The clock moves each second while a round is open, for its countdown;
  # otherwise when the next poll on show runs out of time, and at least every
  # half minute on the list, for the minutes left.
  defp start_clock(socket) do
    socket = stop_clock(socket)

    case connected?(socket) && next_tick(socket.assigns.polls) do
      ms when is_integer(ms) ->
        assign(socket, :polls_clock, Process.send_after(self(), :polls_tick, ms))

      _none ->
        socket
    end
  end

  defp stop_clock(%{assigns: %{polls_clock: clock}} = socket) when is_reference(clock) do
    Process.cancel_timer(clock)
    assign(socket, :polls_clock, nil)
  end

  defp stop_clock(socket), do: socket

  defp next_tick(%{kind: :poll, session: %Session{} = session, rounds: rounds, now: now}) do
    cond do
      Enum.any?(rounds, &(&1.status == :open)) -> 1_000
      open?(session, now) -> until(session.expires_at, now)
      true -> nil
    end
  end

  defp next_tick(%{kind: :list, sessions: sessions, now: now}) do
    case for(session <- sessions, open?(session, now), do: until(session.expires_at, now)) do
      [] -> nil
      waits -> Enum.min([@list_tick_ms | waits])
    end
  end

  defp next_tick(_page), do: nil

  defp until(at, now), do: max(DateTime.diff(at, now, :millisecond), 0) + 50

  @doc """
  Takes part in the poll page on show as `actor`, the way its boxes and
  buttons do and its browser tools do: `:start` a poll from the list (name,
  mode, minutes), and on a poll's page `:ask` the next question (question,
  choices one per line, deadline_seconds), `:join`, `:leave`, `:end` it, or
  `:vote` (number, action, reason). Answers what the poll's action answers.
  """
  def act(:start, %{kind: :list, fleet_id: fleet_id}, input, actor) do
    input
    |> Map.take(["name", "mode", "minutes"])
    |> Map.put("fleet_id", fleet_id)
    |> Polls.open_session(actor: actor)
  end

  def act(:ask, %{kind: :poll, session: %Session{} = session}, input, actor),
    do: session |> round_input(input) |> Polls.open_round(actor: actor)

  def act(:join, %{kind: :poll, session: %Session{} = session}, _input, actor),
    do: Polls.join(%{fleet_id: session.fleet_id, session_id: session.id}, actor: actor)

  def act(:leave, %{kind: :poll, session: %Session{} = session}, _input, actor) do
    with %{key: key} <- Polls.voter(actor, session.fleet_id),
         %{} = seat <- Polls.get_seat!(session.id, key, actor: %Keyfleet.Actors.System{}) do
      Polls.leave(seat, session.fleet_id, actor: actor)
    else
      nil -> {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  def act(:end, %{kind: :poll, session: %Session{} = session}, _input, actor),
    do: Polls.end_session(session, session.fleet_id, actor: actor)

  def act(:vote, %{kind: :poll, session: %Session{} = session}, input, actor) do
    input
    |> Map.take(["number", "action", "reason"])
    |> Map.reject(fn {_field, value} -> value == "" end)
    |> Map.merge(%{"fleet_id" => session.fleet_id, "session_id" => session.id})
    |> Polls.cast_vote(actor: actor)
  end

  @doc "The refusal code each press answers with when its error says no more."
  def default_code(action) when action in [:ask, :end], do: "not_delegate"
  def default_code(:leave), do: "not_seated"
  def default_code(_action), do: "poll_needs_key"

  @doc "What the polls pages do with a poll started, joined, left or ended, a round asked and a vote."
  def handle_event(
        "start_poll",
        %{"poll" => params},
        %{assigns: %{polls: %{kind: :list} = page}} = socket
      ) do
    case act(:start, page, params, ShellLive.human_actor(socket)) do
      {:ok, session} ->
        {:noreply, push_patch(socket, to: poll_path(session.fleet_id, session.id))}

      {:error, error} ->
        {:noreply, form_refused(socket, :start, params, error)}
    end
  end

  def handle_event(
        "open_round",
        %{"round" => params},
        %{assigns: %{polls: %{kind: :poll, session: %Session{}} = page}} = socket
      ) do
    case act(:ask, page, params, ShellLive.human_actor(socket)) do
      {:ok, _round} ->
        {:noreply, socket |> assign(polls_notice: nil, poll_form: round_form()) |> refresh()}

      {:error, error} ->
        {:noreply, form_refused(socket, :ask, params, error)}
    end
  end

  def handle_event(
        event,
        params,
        %{assigns: %{polls: %{kind: :poll, session: %Session{}}}} = socket
      )
      when event in ["join_poll", "leave_poll", "end_poll", "cast_vote"] do
    action = press(event)

    result =
      act(
        action,
        socket.assigns.polls,
        Map.get(params, "vote", %{}),
        ShellLive.human_actor(socket)
      )

    case result do
      {:error, error} -> {:noreply, socket |> refused(error, default_code(action)) |> refresh()}
      _done -> {:noreply, socket |> assign(:polls_notice, nil) |> refresh()}
    end
  end

  # A press the page no longer shows the poll for.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp press("join_poll"), do: :join
  defp press("leave_poll"), do: :leave
  defp press("end_poll"), do: :end
  defp press("cast_vote"), do: :vote

  @doc "A change to the polls on show, and the page's clock."
  def handle_info(%Broadcast{event: event}, socket) when event in ["poll_event", "polls_changed"],
    do: {:noreply, refresh(socket)}

  def handle_info(:polls_tick, %{assigns: %{polls: %{now: _}}} = socket) do
    {:noreply,
     socket
     |> assign(:polls_clock, nil)
     |> update(:polls, &%{&1 | now: DateTime.utc_now()})
     |> listen_and_tick()}
  end

  def handle_info(:polls_tick, socket), do: {:noreply, assign(socket, :polls_clock, nil)}

  defp listen_and_tick(socket),
    do: socket |> listen(topics(socket.assigns.polls)) |> start_clock()

  # A refusal is said above the poll.
  defp refused(%{assigns: %{polls: %{fleet_id: fleet_id}}} = socket, error, code) do
    {_code, message} = refusal(error, fleet_id, code)
    assign(socket, :polls_notice, %{tone: :error, message: message})
  end

  # A name or a question that breaks the rules is said under its box instead;
  # what the person typed stays in the boxes either way.
  defp form_refused(%{assigns: %{polls: %{fleet_id: fleet_id}}} = socket, action, params, error) do
    case refusal(error, fleet_id, default_code(action)) do
      {"invalid_poll", _message} ->
        assign(socket, poll_form: form(action, params, field_errors(error)), polls_notice: nil)

      {_code, message} ->
        assign(socket,
          poll_form: form(action, params, []),
          polls_notice: %{tone: :error, message: message}
        )
    end
  end

  # The boxes whose rules an action's error names.
  defp field_errors(%Ash.Error.Invalid{errors: errors}) do
    for %{field: field} <- errors,
        box = Map.get(@boxes, field),
        uniq: true,
        do: {box, {"breaks its rule", []}}
  end

  defp field_errors(_error), do: []

  @doc """
  `{code, message}` for a poll action's error: the agent API's code
  (`KeyfleetWeb.PollRefusal`) and the words the page says it in.
  """
  def refusal(error, fleet_id, code) do
    {_status, code} = PollRefusal.of(error, fleet_id, code)
    {code, message(code)}
  end

  defp message("ownership_refreshing"), do: KeysLive.refreshing()

  defp message("poll_needs_key"),
    do:
      "Only the people and agents holding this fleet’s Keys, or a shard of one, take part in its polls."

  defp message("poll_unknown"), do: "This fleet has no such poll."
  defp message("poll_ended"), do: "This poll has ended."
  defp message("not_seated"), do: "Your Key isn’t taking part in this poll."
  defp message("not_delegate"), do: "Only the poll’s leader asks questions and ends it."
  defp message("round_open"), do: "A round is still open. Ask again once it closes."
  defp message("decision_seen"), do: "This poll has already asked that question."
  defp message("round_unknown"), do: "This poll has no such round."
  defp message("round_closed"), do: "This round has closed."

  defp message("not_in_round"),
    do: "Your Key joined after this round opened, so it votes from the next one."

  defp message("action_unknown"), do: "Choose one of the round’s choices."
  defp message("vote_conflict"), do: "Your Key has already voted in this round."
  defp message("delegate_stays"), do: "The leader can’t leave. End the poll instead."

  defp message("invalid_poll"),
    do:
      "A poll’s name is up to 80 characters on one line, and it runs 5 to 60 minutes. A question is up to 128 characters, with 2 to 32 choices of up to 200 characters, and 1 second to 10 minutes to answer. A reason is up to 500 characters."

  defp form(:start, params, errors), do: to_form(params, as: "poll", errors: errors)
  defp form(:ask, params, errors), do: to_form(params, as: "round", errors: errors)

  defp start_form, do: form(:start, %{"mode" => "poll", "minutes" => "30"}, [])
  defp round_form, do: form(:ask, %{"deadline_seconds" => "60"}, [])

  # A round asked on the page: the question names the decision, each line is a
  # choice, numbered from 1, and the voters are shown nothing more.
  defp round_input(session, input) do
    %{
      "fleet_id" => session.fleet_id,
      "session_id" => session.id,
      "decision_ref" => input["question"],
      "actions" => choices(input["choices"]),
      "observation" => %{},
      "deadline_seconds" => input["deadline_seconds"]
    }
  end

  defp choices(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {label, number} -> %{"id" => to_string(number), "label" => label} end)
  end

  defp choices(_missing), do: []

  # A box whose rule a submitted poll or question broke says the rule.
  defp errors(field, rule), do: if(field.errors == [], do: [], else: [rule])

  defp open?(session, now),
    do: is_nil(session.ended_at) and DateTime.after?(session.expires_at, now)

  # A session that ran out of time ended when its time was up.
  defp ended_at(%{ended_at: nil, expires_at: expires_at}), do: expires_at
  defp ended_at(%{ended_at: ended_at}), do: ended_at

  defp readable?(%Ash.ForbiddenField{}), do: false
  defp readable?(nil), do: false
  defp readable?(_value), do: true

  defp label(round, action_id) do
    case Enum.find(round.actions, &(&1.id == action_id)) do
      nil -> action_id
      action -> action.label
    end
  end

  defp mode_word(:poll), do: "Everyone votes"
  defp mode_word(:delegate), do: "Leader decides"

  defp time_left(expires_at, now) do
    case DateTime.diff(expires_at, now, :second) do
      seconds when seconds < 60 -> "Less than a minute left"
      seconds -> "#{count(div(seconds, 60), "minute", "minutes")} left"
    end
  end

  defp seconds_left(deadline_at, now) do
    case DateTime.diff(deadline_at, now, :second) do
      seconds when seconds <= 0 -> "Closing…"
      seconds when seconds < 60 -> "#{count(seconds, "second", "seconds")} left"
      seconds -> "#{div(seconds, 60)}:#{seconds |> rem(60) |> pad()} left"
    end
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp count(1, one, _many), do: "1 #{one}"
  defp count(number, _one, many), do: "#{number} #{many}"

  defp lengths, do: @lengths
  defp deadlines, do: @deadlines
end

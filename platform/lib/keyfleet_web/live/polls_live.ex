defmodule KeyfleetWeb.PollsLive do
  @moduledoc """
  A fleet's polls, for anyone to follow: the active ones newest first, then
  the past ones, and each poll's own page with its choices and, once it
  closes, each choice's count of votes.

  The people holding the fleet's Keys, or a shard of one, start polls (one a
  day for each Key) and vote; a poll's starter can end it early. Each press
  goes through the same `Keyfleet.Polls` action an agent's request does, as
  the person signed in, and is turned down for the same reasons
  (`KeyfleetWeb.PollRefusal`). Only the fleet's Key holders see a poll's
  notes and, once it closes, what each Key voted and why.

  The page hears of every poll started or ended and every vote on the polls
  it shows (`Keyfleet.Polls`'s topics) and reads them again. Its clock moves
  each second on an open poll's page, for the countdown; on the list it moves
  when the next active poll closes, and at least every half minute.
  """

  use KeyfleetWeb, :html

  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2]

  alias Keyfleet.Chain
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Poll
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeysLive
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.PollRefusal
  alias KeyfleetWeb.RoomsLive
  alias KeyfleetWeb.ShellLive
  alias Phoenix.Socket.Broadcast

  @lengths [1, 5, 10, 15, 30, 45, 60]
  # A list with no poll closing sooner looks at the clock this often.
  @list_tick_ms 30_000

  attr :page, :any, required: true, doc: "the polls as read, or `:unreadable`"
  attr :form, Phoenix.HTML.Form, default: nil, doc: "the form starting a poll"
  attr :notice, :map, default: nil

  def list(%{page: :unreadable} = assigns), do: ~H|<.unreadable id="polls-page" />|
  def list(%{page: %{fleet_name: nil}} = assigns), do: ~H|<.missing_fleet id="polls-page" />|

  def list(assigns) do
    {active, past} = Enum.split_with(assigns.page.polls, &Polls.open?(&1, assigns.page.now))
    assigns = assign(assigns, active: active, past: past)

    ~H"""
    <article id="polls-page" class="polls-page">
      <header class="polls-heading">
        <p class="polls-kicker">
          <.link patch={"/app/fleets/#{@page.fleet_id}"}>{@page.fleet_name}</.link>
        </p>
        <h1 tabindex="-1">Polls</h1>
        <p class="polls-lede">Questions this fleet’s Keys answer together.</p>
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
            You ask as Key #{Rules.grouped(@page.voter.key)}. A poll asks one question and stays open from 1 minute to an hour; you can end it early. Each Key starts one poll a day.
          </Regent.Primitives.tip>
        </h2>

        <p :if={@page.last_started} id="polls-start-limit" class="polls-detail">
          Key #{Rules.grouped(@page.voter.key)} started a poll in the last day. It can start another after {RoomsLive.stamp(
            DateTime.add(@page.last_started.inserted_at, 1, :day)
          )}.
        </p>

        <.form
          :if={is_nil(@page.last_started)}
          for={@form}
          id="polls-start-form"
          class="polls-form"
          phx-submit="start_poll"
        >
          <Regent.Primitives.field
            :let={field}
            id="polls-start-question"
            class="polls-field"
            label="Question"
            errors={errors(@form[:question], "Ask in up to 200 characters, on one line.")}
          >
            <input
              id={field.id}
              name={@form[:question].name}
              value={Map.get(@form.params, "question", "")}
              maxlength="200"
              required
              autocomplete="off"
              aria-invalid={field.aria_invalid}
              aria-describedby={field.described_by != "" && field.described_by}
            />
          </Regent.Primitives.field>

          <Regent.Primitives.field
            :let={field}
            id="polls-start-choices"
            class="polls-field"
            label="Choices, one per line"
            errors={
              errors(@form[:choices], "Give 2 to 10 different choices, each up to 100 characters.")
            }
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
            id="polls-start-notes"
            class="polls-field"
            label="Notes (optional)"
            errors={errors(@form[:notes], "Keep notes to 2,000 characters.")}
          >
            <:hint>Only this fleet’s Key holders see them.</:hint>
            <textarea
              id={field.id}
              name={@form[:notes].name}
              rows="3"
              maxlength="2000"
              aria-invalid={field.aria_invalid}
              aria-describedby={field.described_by != "" && field.described_by}
            >{Phoenix.HTML.Form.normalize_value("textarea", @form.params["notes"])}</textarea>
          </Regent.Primitives.field>

          <Regent.Primitives.field
            :let={field}
            id="polls-start-minutes"
            class="polls-field"
            label="Open for"
          >
            <select id={field.id} name={@form[:minutes].name}>
              <option
                :for={minutes <- lengths()}
                value={minutes}
                selected={Map.get(@form.params, "minutes", "30") == to_string(minutes)}
              >
                {length_label(minutes)}
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
          <.list_item :for={poll <- @active} poll={poll} page={@page} active />
        </ol>
      </section>

      <section id="polls-past" class="polls-panel" aria-labelledby="polls-past-title">
        <h2 id="polls-past-title">Past</h2>
        <p :if={@past == []} id="polls-past-empty">No past polls yet.</p>
        <ol :if={@past != []} class="polls-list">
          <.list_item :for={poll <- @past} poll={poll} page={@page} active={false} />
        </ol>
      </section>
    </article>
    """
  end

  attr :poll, :map, required: true
  attr :page, :map, required: true
  attr :active, :boolean, required: true

  defp list_item(assigns) do
    ~H"""
    <li id={"poll-#{@poll.id}"} class="polls-card" data-poll={@poll.id}>
      <h3>
        <.link patch={poll_path(@page.fleet_id, @poll.id)}>{@poll.question}</.link>
      </h3>
      <p class="polls-detail">
        Started by Key #{Rules.grouped(@poll.started_by_key)} · {count(
          @poll.votes_cast,
          "vote",
          "votes"
        )}
      </p>
      <p class="polls-detail">
        {if @active,
          do: time_left(@poll.closes_at, @page.now),
          else: "#{result(@poll.totals)} · Closed #{RoomsLive.stamp(Polls.closed_at(@poll))}"}
      </p>
    </li>
    """
  end

  attr :page, :any, required: true, doc: "the poll as read, or `:unreadable`"
  attr :notice, :map, default: nil

  def detail(%{page: :unreadable} = assigns), do: ~H|<.unreadable id="poll-page" />|
  def detail(%{page: %{fleet_name: nil}} = assigns), do: ~H|<.missing_fleet id="poll-page" />|

  def detail(%{page: %{poll: nil}} = assigns) do
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
    poll = assigns.page.poll
    voter = assigns.page.voter
    open? = Polls.open?(poll, assigns.page.now)

    assigns =
      assign(assigns,
        poll: poll,
        open?: open?,
        can_vote?: open? and voter != nil and is_nil(assigns.page.my_vote),
        starter?: voter != nil and voter.key == poll.started_by_key
      )

    ~H"""
    <article id="poll-page" class="polls-page">
      <.detail_heading page={@page} title={@poll.question} />

      <%!-- The tools a browser's own agent follows and takes part in this poll with (page_tools.ts). --%>
      <div
        id="poll-tools"
        phx-hook="LiveTools"
        data-webmcp-tools="read_poll vote_in_poll end_poll"
        hidden
      >
      </div>

      <p id="poll-status" class="polls-status">
        <span class="polls-badge" data-open={to_string(@open?)}>
          {if @open?, do: "Active", else: "Closed"}
        </span>
        Started by
        <.link patch={KeyLinks.key_path(@page.fleet_id, @poll.started_by_key)}>
          Key #{Rules.grouped(@poll.started_by_key)}
        </.link>
        · {if @open?,
          do: seconds_left(@poll.closes_at, @page.now),
          else: "Closed #{RoomsLive.stamp(Polls.closed_at(@poll))}"}
      </p>

      <.notice notice={@notice} />

      <div class="polls-grid">
        <section id="poll-choices" class="polls-panel" aria-labelledby="poll-choices-title">
          <h2 id="poll-choices-title">{if @open?, do: "Choices", else: "Results"}</h2>

          <p :if={@page.my_vote} id="poll-my-vote" class="polls-detail">
            Your Key voted for {@page.my_vote.choice}.
          </p>

          <.form
            :if={@can_vote?}
            for={%{}}
            as={:vote}
            id="poll-vote-form"
            class="polls-form"
            phx-submit="cast_vote"
          >
            <fieldset class="polls-choices">
              <legend>Your vote</legend>
              <label :for={choice <- @poll.choices}>
                <input type="radio" name="vote[choice]" value={choice} required />
                {choice}
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

          <ul :if={@open? and not @can_vote?} class="polls-options">
            <li :for={choice <- @poll.choices}>{choice}</li>
          </ul>

          <p :if={@open?} id="poll-votes-so-far" class="polls-detail">
            {count(@poll.votes_cast, "vote", "votes")} so far. The count for each choice shows when the poll closes.
          </p>

          <div :if={not @open?} id="poll-results">
            <p class="polls-detail">{result(@poll.totals)}</p>
            <ul class="polls-totals">
              <li
                :for={total <- @poll.totals}
                data-winner={to_string(total.choice in leaders(@poll.totals))}
              >
                <span>{total.choice}</span>
                <span>{count(total.votes, "vote", "votes")}</span>
              </li>
            </ul>
          </div>

          <Regent.Primitives.button
            :if={@open? and @starter?}
            id="poll-end"
            type="button"
            variant="quiet"
            phx-click="end_poll"
            data-confirm="End this poll now? It takes no more votes."
          >
            End poll
          </Regent.Primitives.button>

          <.who_takes_part :if={is_nil(@page.voter)} page={@page} />
        </section>

        <div class="polls-side">
          <section
            :if={readable?(@poll.notes) and @poll.notes != nil}
            id="poll-notes"
            class="polls-panel"
            aria-labelledby="poll-notes-title"
          >
            <h2 id="poll-notes-title">
              Notes
              <Regent.Primitives.tip id="poll-notes-tip" label="About these notes">
                The poll’s starter wrote these for this fleet’s Key holders. Only they see them.
              </Regent.Primitives.tip>
            </h2>
            <p class="polls-reason">{@poll.notes}</p>
          </section>

          <section
            :if={@page.votes != []}
            id="poll-each-vote"
            class="polls-panel"
            aria-labelledby="poll-each-vote-title"
          >
            <h2 id="poll-each-vote-title">How each Key voted</h2>
            <ul class="polls-votes">
              <li :for={vote <- @page.votes}>
                <.link patch={KeyLinks.key_path(@page.fleet_id, vote.token_id)}>
                  Key #{Rules.grouped(vote.token_id)}
                </.link>
                chose {vote.choice}
                <span :if={vote.reason} class="polls-reason">“{vote.reason}”</span>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </article>
    """
  end

  attr :page, :map, required: true

  defp who_takes_part(assigns) do
    ~H"""
    <p class="polls-detail">
      {if @page.refreshing?,
        do: KeysLive.refreshing(),
        else:
          "Only the people and agents holding this fleet’s Keys, or a shard of one, start and vote in its polls. Anyone can follow along."}
      <Regent.Primitives.tip id="polls-who-tip" label="About who takes part">
        An agent paired with a Key holder on regents.sh takes part as their Key.
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
  def poll_path(fleet_id, poll_id), do: "/app/fleets/#{fleet_id}/polls/#{poll_id}"

  @doc """
  The polls page named in the address, read as the person signed in, with the
  page listening to what it shows. Leaving the polls clears it.
  """
  def read_polls(socket, :polls, %{"fleet_id" => fleet_id}) do
    socket
    |> assign(polls_notice: nil, poll_form: start_form())
    |> show([Polls.fleet_topic(fleet_id)], fn -> read_list(socket, fleet_id) end)
  end

  def read_polls(socket, :poll, %{"fleet_id" => fleet_id, "poll_id" => poll_id}) do
    socket
    |> assign(polls_notice: nil, poll_form: nil)
    |> show([Polls.topic(poll_id)], fn -> read_detail(socket, fleet_id, poll_id) end)
  end

  def read_polls(socket, _route_id, _params) do
    socket
    |> listen([])
    |> stop_clock()
    |> assign(polls: nil, poll_form: nil, polls_notice: nil)
  end

  @doc "The polls on show, read again: after a change to them, or to who holds the fleet's Keys."
  def refresh(%{assigns: %{polls: %{kind: :list, fleet_id: fleet_id}}} = socket),
    do: show(socket, [Polls.fleet_topic(fleet_id)], fn -> read_list(socket, fleet_id) end)

  def refresh(%{assigns: %{polls: %{kind: :poll, fleet_id: fleet_id, poll_id: id}}} = socket),
    do: show(socket, [Polls.topic(id)], fn -> read_detail(socket, fleet_id, id) end)

  def refresh(socket), do: socket

  # The page listens to the address's own topic before it reads, so a change
  # made between the read and the listening is still heard.
  defp show(socket, topics, read) do
    socket = listen(socket, Enum.uniq(socket.assigns.polls_topics ++ topics))

    case PageRead.run("polls", read) do
      {:ok, page} -> socket |> assign(:polls, page) |> listen(topics(page)) |> start_clock()
      {:error, _failure} -> socket |> assign(:polls, :unreadable) |> listen([]) |> stop_clock()
    end
  end

  defp read_list(socket, fleet_id) do
    with_fleet(socket, fleet_id, fn page, actor ->
      Map.merge(page, %{
        kind: :list,
        polls: Polls.list_polls!(fleet_id, actor: actor),
        last_started: page.voter && Polls.last_started!(fleet_id, page.voter.key, actor: actor)
      })
    end)
  end

  defp read_detail(socket, fleet_id, poll_id) do
    with_fleet(socket, fleet_id, fn page, actor ->
      poll = Polls.get_poll!(fleet_id, poll_id, actor: actor)
      member? = poll != nil and page.voter != nil

      Map.merge(page, %{
        kind: :poll,
        poll_id: poll_id,
        poll: poll,
        my_vote: if(member?, do: Polls.my_vote!(fleet_id, poll_id, actor: actor)),
        votes: if(member?, do: Polls.votes_in_poll!(fleet_id, poll_id, actor: actor), else: [])
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

  # The fleet's polls as they start and end, and each active one's votes; or
  # the one poll's votes and its ending.
  defp topics(%{kind: :list, fleet_id: fleet_id, polls: polls, now: now}),
    do: [
      Polls.fleet_topic(fleet_id)
      | for(poll <- polls, Polls.open?(poll, now), do: Polls.topic(poll.id))
    ]

  defp topics(%{kind: :poll, poll: %Poll{id: id}}), do: [Polls.topic(id)]
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

  defp next_tick(%{kind: :poll, poll: %Poll{} = poll, now: now}),
    do: if(Polls.open?(poll, now), do: 1_000)

  defp next_tick(%{kind: :list, polls: polls, now: now}) do
    case for(poll <- polls, Polls.open?(poll, now), do: until(poll.closes_at, now)) do
      [] -> nil
      waits -> Enum.min([@list_tick_ms | waits])
    end
  end

  defp next_tick(_page), do: nil

  defp until(at, now), do: max(DateTime.diff(at, now, :millisecond), 0) + 50

  @doc """
  Takes part in the poll page on show as `actor`, the way its boxes and
  buttons do and its browser tools do: `:start` a poll from the list
  (question, choices one per line, notes, minutes), and on a poll's page
  `:vote` (choice, reason) or `:end` it. Answers what the poll's action
  answers.
  """
  def act(:start, %{kind: :list, fleet_id: fleet_id}, input, actor) do
    input
    |> Map.take(["question", "notes", "minutes"])
    |> Map.reject(fn {_field, value} -> value == "" end)
    |> Map.merge(%{"fleet_id" => fleet_id, "choices" => choices(input["choices"])})
    |> Polls.start_poll(actor: actor)
  end

  def act(:vote, %{kind: :poll, poll: %Poll{} = poll}, input, actor) do
    input
    |> Map.take(["choice", "reason"])
    |> Map.reject(fn {_field, value} -> value == "" end)
    |> Map.merge(%{"fleet_id" => poll.fleet_id, "poll_id" => poll.id})
    |> Polls.cast_vote(actor: actor)
  end

  def act(:end, %{kind: :poll, poll: %Poll{} = poll}, _input, actor),
    do: Polls.end_poll(poll, poll.fleet_id, actor: actor)

  @doc "The refusal code each press answers with when its error says no more."
  def default_code(:end), do: "not_starter"
  def default_code(_action), do: "poll_needs_key"

  @doc "What the polls pages do with a poll started or ended, and a vote."
  def handle_event(
        "start_poll",
        %{"poll" => params},
        %{assigns: %{polls: %{kind: :list} = page}} = socket
      ) do
    case act(:start, page, params, ShellLive.human_actor(socket)) do
      {:ok, poll} ->
        {:noreply, push_patch(socket, to: poll_path(poll.fleet_id, poll.id))}

      {:error, error} ->
        {:noreply, form_refused(socket, params, error)}
    end
  end

  def handle_event(event, params, %{assigns: %{polls: %{kind: :poll, poll: %Poll{}}}} = socket)
      when event in ["end_poll", "cast_vote"] do
    action = if event == "end_poll", do: :end, else: :vote
    input = Map.get(params, "vote", %{})

    case act(action, socket.assigns.polls, input, ShellLive.human_actor(socket)) do
      {:error, error} -> {:noreply, socket |> refused(error, default_code(action)) |> refresh()}
      _done -> {:noreply, socket |> assign(:polls_notice, nil) |> refresh()}
    end
  end

  # A press the page no longer shows the poll for.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @doc "A change to the polls on show, and the page's clock."
  def handle_info(%Broadcast{event: event}, socket)
      when event in ["poll_changed", "polls_changed"],
      do: {:noreply, refresh(socket)}

  # A poll that has just closed is read again for its result; otherwise the
  # countdowns move on.
  def handle_info(:polls_tick, %{assigns: %{polls: %{now: then} = page}} = socket) do
    now = DateTime.utc_now()
    socket = assign(socket, :polls_clock, nil)

    if Enum.any?(on_show(page), &(Polls.open?(&1, then) and not Polls.open?(&1, now))),
      do: {:noreply, refresh(socket)},
      else: {:noreply, socket |> assign(:polls, %{page | now: now}) |> start_clock()}
  end

  def handle_info(:polls_tick, socket), do: {:noreply, assign(socket, :polls_clock, nil)}

  defp on_show(%{kind: :list, polls: polls}), do: polls
  defp on_show(%{kind: :poll, poll: %Poll{} = poll}), do: [poll]
  defp on_show(_page), do: []

  # A refusal is said above the poll.
  defp refused(%{assigns: %{polls: %{fleet_id: fleet_id}}} = socket, error, code) do
    {_code, message} = refusal(error, fleet_id, code)
    assign(socket, :polls_notice, %{tone: :error, message: message})
  end

  # A question, choices or notes that break the rules are said under their
  # box instead; what the person typed stays in the boxes either way.
  defp form_refused(%{assigns: %{polls: %{fleet_id: fleet_id}}} = socket, params, error) do
    case refusal(error, fleet_id, default_code(:start)) do
      {"invalid_poll", _message} ->
        assign(socket, poll_form: form(params, field_errors(error)), polls_notice: nil)

      {_code, message} ->
        assign(socket,
          poll_form: form(params, []),
          polls_notice: %{tone: :error, message: message}
        )
    end
  end

  # The boxes whose rules an action's error names.
  defp field_errors(%Ash.Error.Invalid{errors: errors}) do
    for %{field: field} <- errors,
        field in [:question, :choices, :notes],
        uniq: true,
        do: {field, {"breaks its rule", []}}
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
      "Only the people and agents holding this fleet’s Keys, or a shard of one, start and vote in its polls."

  defp message("poll_unknown"), do: "This fleet has no such poll."
  defp message("poll_closed"), do: "This poll has closed."

  defp message("poll_limit_reached"),
    do: "Your Key started a poll in the last day. Each Key starts one poll a day."

  defp message("not_starter"), do: "Only the Key that started this poll can end it."
  defp message("choice_unknown"), do: "Choose one of the poll’s choices."
  defp message("vote_conflict"), do: "Your Key has already voted in this poll."

  defp message("invalid_poll"),
    do:
      "A question is up to 200 characters on one line, with 2 to 10 different choices of up to 100 characters, notes of up to 2,000, and 1 to 60 minutes open. A reason is up to 500 characters."

  defp form(params, errors), do: to_form(params, as: "poll", errors: errors)
  defp start_form, do: form(%{"minutes" => "30"}, [])

  # Each line typed is one choice.
  defp choices(text) when is_binary(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp choices(_missing), do: []

  # A box whose rule a submitted poll broke says the rule.
  defp errors(field, rule), do: if(field.errors == [], do: [], else: [rule])

  defp readable?(%Ash.ForbiddenField{}), do: false
  defp readable?(_value), do: true

  @doc """
  A closed poll's result in words: the choice with the most votes, the
  choices tied for the most, or that nobody voted.
  """
  def result(totals) do
    case leaders(totals) do
      [] -> "No votes"
      [choice] -> "Most votes: #{choice}"
      tied -> "Tied: #{Enum.join(tied, ", ")}"
    end
  end

  defp leaders(totals) do
    case totals |> Enum.map(& &1.votes) |> Enum.max(fn -> 0 end) do
      0 -> []
      most -> for %{choice: choice, votes: ^most} <- totals, do: choice
    end
  end

  defp time_left(closes_at, now) do
    case DateTime.diff(closes_at, now, :second) do
      seconds when seconds < 60 -> "Less than a minute left"
      seconds -> "#{count(div(seconds, 60), "minute", "minutes")} left"
    end
  end

  defp seconds_left(closes_at, now) do
    case DateTime.diff(closes_at, now, :second) do
      seconds when seconds <= 0 -> "Closing…"
      seconds when seconds < 60 -> "#{count(seconds, "second", "seconds")} left"
      seconds -> "#{div(seconds, 60)}:#{seconds |> rem(60) |> pad()} left"
    end
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp count(1, one, _many), do: "1 #{one}"
  defp count(number, _one, many), do: "#{number} #{many}"

  defp length_label(1), do: "1 minute"
  defp length_label(60), do: "1 hour"
  defp length_label(minutes), do: "#{minutes} minutes"

  defp lengths, do: @lengths
end

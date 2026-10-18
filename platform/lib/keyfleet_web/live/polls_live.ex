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

  What anyone may read of a fleet's polls, the list and each poll on it, is
  read once for every open page (`KeyfleetWeb.FleetPolls`) and drawn again
  when it changes: a poll started or ended, a vote, a poll closing. What only
  a Key holder reads, the notes, the Key's own vote and, once a poll closes,
  every Key's vote, is read for that holder as the page opens, again after
  their own vote, and a moment after the poll closes. A poll older than the
  fleet's latest hundred is read for the visit, and again on each change.

  The countdown is drawn in the browser. The server keeps no clock running:
  a page's one timer waits for the close itself.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.LoadFailed
  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2]

  alias Keyfleet.Chain
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Polls
  alias Keyfleet.Polls.Poll
  alias KeyfleetWeb.FleetPolls
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.KeysLive
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.PollRefusal
  alias KeyfleetWeb.RoomsLive
  alias KeyfleetWeb.SharedFigures
  alias KeyfleetWeb.ShellLive
  alias Phoenix.Socket.Broadcast

  @lengths [1, 5, 10, 15, 30, 45, 60]
  # A poll page that couldn't be read again looks again after this long.
  @look_again_ms 5_000

  attr :page, :any, required: true, doc: "the polls as read, or `:unreadable`"
  attr :form, Phoenix.HTML.Form, default: nil, doc: "the form starting a poll"
  attr :notice, :map, default: nil

  def list(%{page: :unreadable} = assigns), do: ~H|<.unreadable id="polls-page" />|
  def list(%{page: %{kind: :waiting}} = assigns), do: ~H|<.unreadable id="polls-page" />|
  def list(%{page: %{fleet_name: nil}} = assigns), do: ~H|<.missing_fleet id="polls-page" />|

  def list(assigns) do
    {active, past} = Enum.split_with(assigns.page.polls, & &1.open?)
    assigns = assign(assigns, active: active, past: past)

    ~H"""
    <article id="polls-page" class="polls-page">
      <header class="polls-heading">
        <p class="polls-kicker">
          <.link patch={Keyfleet.Fleets.path(@page.fleet_id)}>{@page.fleet_name}</.link>
        </p>
        <h1 tabindex="-1">Polls</h1>
        <p class="polls-lede">Questions this fleet’s Keys answer together.</p>
      </header>

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

          <div class="sticky-actions">
            <Regent.Primitives.button type="submit">Start poll</Regent.Primitives.button>
          </div>
        </.form>
      </section>

      <.who_takes_part :if={is_nil(@page.voter)} page={@page} />

      <section id="polls-active" class="polls-panel" aria-labelledby="polls-active-title">
        <h2 id="polls-active-title">Active</h2>
        <Regent.Primitives.empty_state
          :if={@active == [] and can_ask?(@page)}
          id="polls-active-empty"
          class="kf-empty"
          title="No active polls."
        >
          Ask the fleet a question above.
        </Regent.Primitives.empty_state>
        <Regent.Primitives.empty_state
          :if={@active == [] and not can_ask?(@page)}
          id="polls-active-empty"
          class="kf-empty"
          title="No active polls."
        >
          <:action :if={not @page.signed_in?}>
            <Regent.Primitives.button
              id="polls-sign-in"
              type="button"
              variant="secondary"
              data-account-target="sign-in"
            >
              Sign in
            </Regent.Primitives.button>
          </:action>
        </Regent.Primitives.empty_state>
        <ol :if={@active != []} class="polls-list">
          <.list_item :for={poll <- @active} poll={poll} page={@page} active />
        </ol>
      </section>

      <section id="polls-past" class="polls-panel" aria-labelledby="polls-past-title">
        <h2 id="polls-past-title">Past</h2>
        <Regent.Primitives.empty_state
          :if={@past == []}
          id="polls-past-empty"
          class="kf-empty"
          title="No past polls yet."
        />
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
        <.countdown
          :if={@active}
          id={"poll-left-#{@poll.id}"}
          closes_at={@poll.closes_at}
          now={@page.now}
          format="minutes"
        />
        {if !@active,
          do: "#{result(@poll.totals)} · Closed #{RoomsLive.stamp(Polls.closed_at(@poll))}"}
      </p>
    </li>
    """
  end

  attr :page, :any, required: true, doc: "the poll as read, or `:unreadable`"
  attr :notice, :map, default: nil

  def detail(%{page: :unreadable} = assigns), do: ~H|<.unreadable id="poll-page" />|
  def detail(%{page: %{kind: :waiting}} = assigns), do: ~H|<.unreadable id="poll-page" />|
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
    open? = poll.open?

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

      <p id="poll-status" class="polls-status">
        <span class="polls-badge" data-open={to_string(@open?)}>
          {if @open?, do: "Active", else: "Closed"}
        </span>
        Started by
        <.link patch={KeyLinks.key_path(@page.fleet_id, @poll.started_by_key)}>
          Key #{Rules.grouped(@poll.started_by_key)}
        </.link>
        ·
        <.countdown
          :if={@open?}
          id="poll-left"
          closes_at={@poll.closes_at}
          now={@page.now}
          format="seconds"
        />
        {if !@open?, do: "Closed #{RoomsLive.stamp(Polls.closed_at(@poll))}"}
      </p>

      <.notice notice={@notice} />

      <div class="polls-grid">
        <section id="poll-choices" class="polls-panel" aria-labelledby="poll-choices-title">
          <h2 id="poll-choices-title">{if @open?, do: "Choices", else: "Results"}</h2>

          <%!-- Always on the page, so the line a vote brings is read out as it
               appears in place of the form that held focus. --%>
          <div id="poll-my-vote-said" class="polls-said" role="status">
            <p :if={@page.my_vote} id="poll-my-vote" class="polls-detail">
              Your Key voted for {@page.my_vote.choice}.
            </p>
          </div>

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
            <div class="sticky-actions">
              <Regent.Primitives.button type="submit">Vote</Regent.Primitives.button>
            </div>
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
            :if={@page.notes}
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
            <p class="polls-reason">{@page.notes}</p>
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

  attr :id, :string, required: true
  attr :closes_at, DateTime, required: true
  attr :now, DateTime, required: true, doc: "when the page read the poll"
  attr :format, :string, required: true, values: ~w(minutes seconds)

  # The time an open poll has left. The page writes it as of when it read
  # the poll; the browser writes it again as it changes, from the poll's
  # closing time and the gap between its own clock and the site's
  # (`assets/js/hooks/poll_countdown.ts`), in the same words.
  defp countdown(assigns) do
    ~H"""
    <span
      id={@id}
      phx-hook="PollCountdown"
      data-closes-at={DateTime.to_unix(@closes_at, :millisecond)}
      data-now={DateTime.to_unix(@now, :millisecond)}
      data-format={@format}
    >{left(@format, @closes_at, @now)}</span>
    """
  end

  defp left("minutes", closes_at, now), do: time_left(closes_at, now)
  defp left("seconds", closes_at, now), do: seconds_left(closes_at, now)

  attr :page, :map, required: true

  defp who_takes_part(assigns) do
    ~H"""
    <p class="polls-detail">
      {if @page.refreshing?,
        do: KeysLive.refreshing(),
        else:
          "Only the people and agents holding this fleet’s Keys, or a shard of one, start and vote in its polls. Anyone can follow along."}
      <Regent.Primitives.tip id="polls-who-tip" label="About who takes part">
        An agent paired with a Key holder takes part as their Key.
      </Regent.Primitives.tip>
    </p>
    """
  end

  # Someone holding a Key who hasn't started a poll in the last day has the
  # form above the list.
  defp can_ask?(%{voter: voter, last_started: nil}), do: voter != nil
  defp can_ask?(_page), do: false

  attr :page, :map, required: true
  attr :title, :string, required: true

  defp detail_heading(assigns) do
    ~H"""
    <header class="polls-heading">
      <p class="polls-kicker">
        <.link patch={Keyfleet.Fleets.path(@page.fleet_id)}>{@page.fleet_name}</.link>
        · <.link patch={list_path(@page.fleet_id)}>Polls</.link>
      </p>
      <h1 tabindex="-1">{@title}</h1>
    </header>
    """
  end

  attr :notice, :map, required: true

  # A refusal is an alert, so a screen reader reads it out as it appears.
  defp notice(assigns) do
    ~H"""
    <p
      :if={@notice}
      id="polls-notice"
      role={@notice.tone == :error && "alert"}
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
        <.load_failed />
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
        <a href="/#home-classic" class="rg-button rg-button--secondary">See the fleets</a>
      </section>
    </article>
    """
  end

  @doc "The address of a fleet's polls."
  def list_path(fleet_id), do: "#{Keyfleet.Fleets.path(fleet_id)}/polls"

  @doc "The address of one poll."
  def poll_path(fleet_id, poll_id), do: "#{Keyfleet.Fleets.path(fleet_id)}/polls/#{poll_id}"

  @doc """
  What anyone may read of a poll, as every page shows it: its question,
  choices, starter's Key and times, how many votes it has drawn, whether it
  is open at `now` and, once closed, each choice's count. Never its notes,
  which only the fleet's Key holders read. `now` is taken before the poll is
  read, so a poll open at `now` has no result yet and one closed has it.
  """
  def public(%Poll{} = poll, now) do
    %{
      id: poll.id,
      question: poll.question,
      choices: poll.choices,
      started_by_key: poll.started_by_key,
      votes_cast: poll.votes_cast,
      totals: poll.totals,
      closes_at: poll.closes_at,
      ended_at: poll.ended_at,
      inserted_at: poll.inserted_at,
      open?: Polls.open?(poll, now)
    }
  end

  @doc """
  The polls page named in the address, with the page listening to what it
  shows. Leaving the polls clears it.
  """
  def read_polls(socket, :polls, %{"fleet_id" => fleet_id}) do
    socket = SharedFigures.follow(socket, :polls, [FleetPolls.key(fleet_id)])

    socket
    |> assign(polls_notice: nil, poll_form: start_form())
    |> stop_clock()
    |> listen([])
    |> read(:unreadable, fn -> list_page(socket, fleet_id) end)
  end

  def read_polls(socket, :poll, %{"fleet_id" => fleet_id, "poll_id" => poll_id}) do
    socket
    |> assign(polls_notice: nil, poll_form: nil)
    |> stop_clock()
    |> show_poll(fleet_id, poll_id, :unreadable)
  end

  def read_polls(socket, _route_id, _params) do
    socket
    |> listen([])
    |> stop_clock()
    |> SharedFigures.follow(:polls, [])
    |> assign(polls: nil, poll_form: nil, polls_notice: nil)
  end

  @doc """
  The polls on show, read again for this reader: after a change to who holds
  the fleet's Keys, or a press. A read again that fails keeps what the page
  shows; a poll's page looks again a moment later.
  """
  def refresh(%{assigns: %{polls: %{fleet_id: fleet_id} = page}} = socket) do
    case Map.get(page, :poll_id) do
      nil -> read(socket, :keep, fn -> list_page(socket, fleet_id) end)
      poll_id -> show_poll(socket, fleet_id, poll_id, :keep)
    end
  end

  def refresh(socket), do: socket

  @doc "A reading the page shows has changed: the page draws what is held now."
  def shared_changed(%{assigns: %{polls: %{}}} = socket, key) do
    if MapSet.member?(followed(socket), key), do: redraw(socket, key), else: socket
  end

  def shared_changed(socket, _key), do: socket

  # The list draws the fleet's new reading with what it read of its reader.
  # A poll's page draws the poll's, and a Key holder's page reads every
  # Key's vote, a moment after the poll closes. Anything else, a page that
  # waited for the fleet's list or a new poll the list didn't hold yet, is
  # read again.
  defp redraw(%{assigns: %{polls: %{kind: :list} = page}} = socket, {:fleet_polls, _id} = key) do
    case FleetPolls.fetch(key) do
      {%{fleet_name: name, polls: polls}, _degraded?} when is_binary(name) ->
        now = DateTime.utc_now()

        assign(socket, :polls, %{
          page
          | fleet_name: name,
            polls: polls,
            now: now,
            last_started: started_since(page, polls, now)
        })

      _missing ->
        refresh(socket)
    end
  end

  defp redraw(
         %{assigns: %{polls: %{kind: :poll, poll: %{} = shown} = page}} = socket,
         {:poll, _id} = key
       ) do
    case FleetPolls.fetch(key) do
      {poll, _degraded?} ->
        socket = assign(socket, :polls, %{page | poll: poll, now: DateTime.utc_now()})
        if page.voter && shown.open? && not poll.open?, do: votes_soon(socket), else: socket

      nil ->
        refresh(socket)
    end
  end

  defp redraw(socket, _key), do: refresh(socket)

  # A read on the page's first showing that fails says the page couldn't be
  # loaded; a read again that fails keeps what the page shows, and a poll's
  # page looks again a moment later, so a poll that closed meanwhile still
  # comes to show its result.
  defp read(socket, failed, read) do
    case PageRead.run("polls", read) do
      {:ok, page} -> assign(socket, :polls, page)
      {:error, _failure} when failed == :keep -> look_again(socket)
      {:error, _failure} -> socket |> listen([]) |> assign(:polls, :unreadable)
    end
  end

  # The fleet's polls as every page shares them, and who the reader takes
  # part as, read for this reader.
  defp list_page(socket, fleet_id) do
    case FleetPolls.fetch(FleetPolls.key(fleet_id)) do
      nil ->
        %{kind: :waiting, fleet_id: fleet_id, poll_id: nil}

      {%{fleet_name: nil}, _degraded?} ->
        missing(fleet_id, nil)

      {fleet, _degraded?} ->
        page = viewer(socket, fleet_id, fleet)
        actor = ShellLive.human_actor(socket)
        last = page.voter && Polls.last_started!(fleet_id, page.voter.key, actor: actor)
        Map.merge(page, %{kind: :list, polls: fleet.polls, last_started: started(last)})
    end
  end

  # A poll's page draws on the readings every page shares when the fleet's
  # list holds the poll, by the key the list's own id makes, never the
  # address's. One older than the list is read for the visit, and heard of
  # and read again on each vote and as it closes. Until the fleet's list is
  # held, the page waits for it.
  defp show_poll(socket, fleet_id, poll_id, failed) do
    fleet_key = FleetPolls.key(fleet_id)

    case FleetPolls.fetch(fleet_key) do
      nil ->
        socket
        |> SharedFigures.follow(:polls, [fleet_key])
        |> listen([])
        |> assign(:polls, %{kind: :waiting, fleet_id: fleet_id, poll_id: poll_id})

      {%{fleet_name: nil}, _degraded?} ->
        socket
        |> SharedFigures.follow(:polls, [fleet_key])
        |> listen([])
        |> assign(:polls, missing(fleet_id, poll_id))

      {%{polls: polls} = fleet, _degraded?} ->
        case Enum.find(polls, &(&1.id == poll_id)) do
          %{id: id} ->
            key = FleetPolls.poll_key(fleet_id, id)
            socket = socket |> SharedFigures.follow(:polls, [key]) |> listen([])
            read(socket, failed, fn -> shared_poll(socket, fleet, fleet_id, key, poll_id) end)

          nil ->
            socket =
              socket
              |> SharedFigures.follow(:polls, [fleet_key])
              |> listen([Polls.topic(poll_id)])

            socket
            |> read(failed, fn -> visit_poll(socket, fleet, fleet_id, poll_id) end)
            |> visited(fleet_key)
            |> close_clock()
        end
    end
  end

  # A poll read for the visit that is still open is one started since the
  # fleet's list was read, so the page hears the list, and draws on it from
  # the reading that holds the poll. One that has closed is older than the
  # list and never joins it.
  defp visited(%{assigns: %{polls: %{kind: :poll, poll: %{open?: true}}}} = socket, fleet_key),
    do: SharedFigures.follow(socket, :polls, [fleet_key])

  defp visited(%{assigns: %{polls: %{kind: :poll}}} = socket, _fleet_key),
    do: SharedFigures.follow(socket, :polls, [])

  defp visited(socket, _fleet_key), do: socket

  # The poll as every page shares it, with what only the fleet's Key holders
  # read of it, the starter's notes among them, read as this one.
  defp shared_poll(socket, fleet, fleet_id, key, poll_id) do
    case FleetPolls.fetch(key) do
      nil ->
        :unreadable

      {poll, _degraded?} ->
        page = viewer(socket, fleet_id, fleet)
        actor = ShellLive.human_actor(socket)
        notes = page.voter && notes(Polls.get_poll!(fleet_id, poll_id, actor: actor))

        page
        |> Map.merge(%{kind: :poll, poll_id: poll_id, poll: poll, notes: notes})
        |> Map.merge(holders(page.voter, actor, fleet_id, poll_id))
    end
  end

  # A poll older than the list, read as the reader, notes and all.
  defp visit_poll(socket, fleet, fleet_id, poll_id) do
    page = viewer(socket, fleet_id, fleet)
    actor = ShellLive.human_actor(socket)

    case Polls.get_poll!(fleet_id, poll_id, actor: actor) do
      nil ->
        Map.merge(page, %{
          kind: :poll,
          poll_id: poll_id,
          poll: nil,
          notes: nil,
          my_vote: nil,
          votes: []
        })

      poll ->
        page
        |> Map.merge(%{kind: :poll, poll_id: poll_id, poll: public(poll, page.now)})
        |> Map.merge(%{notes: notes(poll)})
        |> Map.merge(holders(page.voter, actor, fleet_id, poll_id))
    end
  end

  # What only the fleet's Key holders read of a poll besides its notes, as
  # this one: the Key's own vote and, once the poll closes, every Key's vote
  # and why.
  defp holders(nil, _actor, _fleet_id, _poll_id), do: %{my_vote: nil, votes: []}

  defp holders(_voter, actor, fleet_id, poll_id) do
    %{
      my_vote: my_vote(Polls.my_vote!(fleet_id, poll_id, actor: actor)),
      votes: votes(Polls.votes_in_poll!(fleet_id, poll_id, actor: actor))
    }
  end

  # A holder's own vote and every Key's, read again as that holder: after
  # their own vote, and once the poll has closed. One their standing no
  # longer allows, because a Key changed hands or ownership is being read
  # again, reads the whole page afresh instead.
  defp read_mine(%{assigns: %{polls: %{kind: :poll, voter: %{}} = page}} = socket) do
    actor = ShellLive.human_actor(socket)

    mine = fn ->
      with {:ok, mine} <- Polls.my_vote(page.fleet_id, page.poll_id, actor: actor),
           {:ok, votes} <- Polls.votes_in_poll(page.fleet_id, page.poll_id, actor: actor) do
        {:ok, %{my_vote: my_vote(mine), votes: votes(votes)}}
      else
        {:error, %Ash.Error.Forbidden{}} -> :forbidden
        {:error, error} -> raise error
      end
    end

    case PageRead.run("polls", mine) do
      {:ok, {:ok, mine}} -> assign(socket, :polls, Map.merge(page, mine))
      {:ok, :forbidden} -> refresh(socket)
      {:error, _failure} -> look_again(socket)
    end
  end

  defp read_mine(socket), do: socket

  # Who the person takes part as is read only while the fleet's Key ownership
  # is fresh, as the actions themselves read it. Someone signed out takes
  # part as nobody, and nothing is read for them.
  defp viewer(socket, fleet_id, fleet) do
    actor = ShellLive.human_actor(socket)
    fresh? = actor != nil and Chain.fresh?(fleet_id)

    %{
      fleet_id: fleet_id,
      fleet_name: fleet.fleet_name,
      voter: if(fresh?, do: Polls.voter(actor, fleet_id)),
      refreshing?: actor != nil and fleet.deployed? and not fresh?,
      signed_in?: actor != nil,
      now: DateTime.utc_now()
    }
  end

  defp missing(fleet_id, poll_id),
    do: %{kind: :missing, fleet_id: fleet_id, fleet_name: nil, poll_id: poll_id}

  defp started(nil), do: nil
  defp started(poll), do: %{inserted_at: poll.inserted_at}

  # A poll the reader's own Key has started since the page read its last one
  # holds the form back for a day, as reading it again would.
  defp started_since(%{voter: %{key: key}, last_started: held}, polls, now) do
    case Enum.find(polls, &(&1.started_by_key == key)) do
      %{inserted_at: at} ->
        if DateTime.after?(at, DateTime.add(now, -1, :day)), do: %{inserted_at: at}, else: held

      nil ->
        held
    end
  end

  defp started_since(_page, _polls, _now), do: nil

  defp notes(%Poll{notes: notes}) when is_binary(notes), do: notes
  defp notes(_unread), do: nil

  defp my_vote(nil), do: nil
  defp my_vote(vote), do: %{choice: vote.choice}

  defp votes(votes),
    do: Enum.map(votes, &%{token_id: &1.token_id, choice: &1.choice, reason: &1.reason})

  defp followed(socket), do: Map.get(socket.assigns.shared, :polls, MapSet.new())

  # A poll's page drawn from the poll's own reading, not read for the visit.
  defp shared?(socket), do: Enum.any?(followed(socket), &match?({:poll, _id}, &1))

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

  # The page's one timer. The countdown is drawn in the browser
  # (`PollCountdown`); the server looks at the clock only for the close
  # itself, each page at a moment of its own up to two seconds after it, so
  # a crowd on one poll never reads at once.
  defp jitter, do: :rand.uniform(2_001) - 1

  # A poll read for the visit is read again as it closes. A timer already
  # set, for the close or to look again, stands.
  defp close_clock(
         %{
           assigns: %{
             polls: %{kind: :poll, poll: %{open?: true} = poll, now: now},
             polls_clock: nil
           }
         } = socket
       ) do
    if connected?(socket),
      do:
        assign(
          socket,
          :polls_clock,
          Process.send_after(self(), :polls_tick, until(poll.closes_at, now) + jitter())
        ),
      else: socket
  end

  defp close_clock(socket), do: socket

  # A Key holder's page reads every Key's vote once the poll it shares has
  # closed.
  defp votes_soon(socket) do
    socket = stop_clock(socket)
    assign(socket, :polls_clock, Process.send_after(self(), :polls_tick, jitter()))
  end

  defp stop_clock(%{assigns: %{polls_clock: clock}} = socket) when is_reference(clock) do
    Process.cancel_timer(clock)
    assign(socket, :polls_clock, nil)
  end

  defp stop_clock(socket), do: socket

  defp look_again(socket) do
    socket = stop_clock(socket)

    if connected?(socket),
      do: assign(socket, :polls_clock, Process.send_after(self(), :polls_tick, @look_again_ms)),
      else: socket
  end

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

  def act(:vote, %{kind: :poll, fleet_id: fleet_id, poll: %{id: poll_id}}, input, actor) do
    input
    |> Map.take(["choice", "reason"])
    |> Map.reject(fn {_field, value} -> value == "" end)
    |> Map.merge(%{"fleet_id" => fleet_id, "poll_id" => poll_id})
    |> Polls.cast_vote(actor: actor)
  end

  # The page holds what anyone reads of the poll; ending it reads the poll
  # itself, as the person ending it.
  def act(:end, %{kind: :poll, fleet_id: fleet_id, poll: %{id: poll_id}}, _input, actor) do
    with {:ok, %Poll{} = poll} <- Polls.get_poll(fleet_id, poll_id, actor: actor),
         do: Polls.end_poll(poll, fleet_id, actor: actor)
  end

  @doc "The refusal code each press answers with when its error says no more."
  def default_code(:end), do: "not_starter"
  def default_code(_action), do: "poll_needs_key"

  @doc "What the polls pages do with a poll started or ended, and a vote."
  def handle_event(
        "start_poll",
        %{"poll" => params},
        %{assigns: %{polls: %{kind: :list} = page}} = socket
      )
      when is_map(params) do
    case act(:start, page, params, ShellLive.human_actor(socket)) do
      {:ok, poll} ->
        {:noreply, push_patch(socket, to: poll_path(poll.fleet_id, poll.id))}

      {:error, error} ->
        {:noreply, form_refused(socket, params, error)}
    end
  end

  def handle_event(event, params, %{assigns: %{polls: %{kind: :poll, poll: %{}}}} = socket)
      when event in ["end_poll", "cast_vote"] do
    action = if event == "end_poll", do: :end, else: :vote

    case act(action, socket.assigns.polls, vote(params), ShellLive.human_actor(socket)) do
      {:error, error} -> {:noreply, socket |> refused(error, default_code(action)) |> refresh()}
      _done -> {:noreply, socket |> assign(:polls_notice, nil) |> pressed(action)}
    end
  end

  # A press the page no longer shows the poll for, or a poll sent without its boxes.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # After its own vote, a holder's page reads that vote. The count every
  # visitor sees, and an ended poll's result, come with the next reading
  # every page shares, about a second later. A page read for the visit reads
  # it all again.
  defp pressed(socket, action) do
    cond do
      not shared?(socket) -> refresh(socket)
      action == :vote -> read_mine(socket)
      true -> socket
    end
  end

  defp vote(%{"vote" => input}) when is_map(input), do: input
  defp vote(_params), do: %{}

  @doc """
  A change to a poll read for the visit, and the page's one timer: the close
  of a poll read for the visit, a holder's own votes read once the poll it
  shares has closed, or a look again after a read that failed.
  """
  def handle_info(%Broadcast{event: event}, socket)
      when event in ["poll_changed", "polls_changed"],
      do: {:noreply, refresh(socket)}

  def handle_info(:polls_tick, socket) do
    socket = assign(socket, :polls_clock, nil)
    {:noreply, if(shared?(socket), do: read_mine(socket), else: refresh(socket))}
  end

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

  # Only what was typed goes back in the boxes.
  defp form(params, errors) do
    params
    |> Map.filter(fn {_field, value} -> is_binary(value) end)
    |> to_form(as: "poll", errors: errors)
  end

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

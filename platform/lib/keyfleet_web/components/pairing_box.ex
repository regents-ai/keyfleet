defmodule KeyfleetWeb.PairingBox do
  @moduledoc """
  Pairing an agent (`RegentAgents`), under "Pair New Agent" on the Account page,
  in the shared pairing box (`Regent.Account.pairing`): the message to
  paste with its code in a short box with icons to copy it and make a new code,
  then the ten agents in `RegentAgents.Harness.featured/0` to choose from by their
  pictures, and Claude while its connector is on (`RegentAgents.Harness.hosted/0`,
  read at runtime). Each agent keeps its own code until it expires, so choosing another
  agent and coming back shows the same message. Once the agent uses the code, the
  box names it, and Give It a Shard under the box leads to the New shard form of
  one of the person's Keys with the agent's wallet filled in
  (`KeyfleetWeb.AgentKeys`); that line keeps its space before, so the page below
  never moves.

  The parent passes `account` (the signed-in account), its `session_lease` as
  `lease` and `id`, and sends `agents_changed: true` when an agent pairs, checks
  in or is unpaired anywhere. A pairing link (`/pair?to=<path>`) also passes
  `start`, the page on this site the agent begins on once paired; the message
  then sends it there.
  """
  use KeyfleetWeb, :live_component

  alias KeyfleetWeb.AgentGuides
  alias KeyfleetWeb.Live.Session
  alias KeyfleetWeb.VisitLog
  alias RegentAgents.{Harness, PairingCode, PairingMessage, Person}

  require Logger

  @impl true
  def mount(socket),
    do:
      {:ok,
       socket
       |> Session.check_component_lease(&take_account/2)
       |> assign(chosen: nil, codes: %{})}

  @impl true
  def update(%{agents_changed: true}, socket), do: {:ok, after_pairing(socket)}

  def update(%{account: account, id: id, lease: lease} = assigns, socket),
    do:
      {:ok,
       socket
       |> assign(id: id, lease: lease, start: assigns[:start])
       |> take_account(account)}

  # The account as the page gave it, or as it reads now before each event
  # (`Session.check_component_lease/2`).
  defp take_account(socket, account),
    do: assign(socket, account: account, person: %Person{privy_user_id: account.privy_user_id})

  # Choosing an agent shows its code, made the first time it is chosen and again
  # once it has expired; asking for a new code replaces the chosen agent's. Codes
  # made before keep working until they expire.
  @impl true
  def handle_event("choose_agent", %{"harness" => harness}, socket),
    do: {:noreply, with_offered(socket, harness, &show/2)}

  def handle_event("new_pairing_code", %{"harness" => harness}, socket),
    do: {:noreply, with_offered(socket, harness, &issue/2)}

  # Nothing chosen: a reconnecting page restores the form with no agent picked,
  # and a submit can come before a choice. The box stays as it is.
  def handle_event(event, _nothing_chosen, socket)
      when event in ["choose_agent", "new_pairing_code"],
      do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :give, give(assigns.codes[assigns.chosen]))

    ~H"""
    <div>
      <Regent.Account.pairing
        id={@id}
        harnesses={choices()}
        layout={:icons}
        phx-change="choose_agent"
        phx-submit="new_pairing_code"
        phx-target={@myself}
        {pairing(@chosen, @codes[@chosen], @start)}
      />
      <p id={"#{@id}-next"} class="account-pairing-next">
        <.link
          :if={is_map(@give)}
          id={"#{@id}-give-shard"}
          navigate={@give.path}
          class="rg-button rg-button--primary"
        >
          <span class="rg-button__label">Give {@give.name} a shard</span>
        </.link>
        <span :if={@give == :unavailable} class="rg-muted">
          Couldn’t read your Keys. Refresh to try again.
        </span>
      </p>
    </div>
    """
  end

  @doc "The agents to choose from, as the shared pairing box takes them."
  def choices,
    do: for(harness <- offered(), do: %{value: to_string(harness), label: label(harness)})

  # The ten featured agents, then Claude while its connector is on.
  defp offered, do: Harness.featured() ++ Harness.hosted()

  defp label(:other), do: "Any agent"
  defp label(:codex), do: "OpenAI Codex"
  defp label(harness), do: Harness.label(harness)

  # The pairing box's state; the box keeps one size whatever it holds.
  defp pairing(nil, nil, _start), do: %{}

  defp pairing(harness, %PairingCode.Issued{} = code, start),
    do: %{
      chosen: to_string(harness),
      message: agent_message(code.code, harness, start),
      expires_iso: DateTime.to_iso8601(code.expires_at),
      expires: Calendar.strftime(code.expires_at, "%H:%M UTC")
    }

  defp pairing(harness, {:paired, agent, _give}, _start),
    do: %{chosen: to_string(harness), outcome: {:paired, agent.name}}

  defp pairing(harness, :unavailable, _start),
    do: %{chosen: to_string(harness), outcome: :unavailable}

  defp with_offered(socket, harness, then) do
    with {:ok, harness} <- Harness.match(harness),
         true <- harness in offered() do
      then.(socket, harness)
    else
      _not_offered -> socket
    end
  end

  defp show(socket, harness) do
    socket = assign(socket, chosen: harness)
    if usable?(socket.assigns.codes[harness]), do: socket, else: issue(socket, harness)
  end

  # A code still in time, or the agent that used it; a missing, expired or failed
  # code is made again.
  defp usable?(%PairingCode.Issued{expires_at: expires_at}),
    do: DateTime.after?(expires_at, DateTime.utc_now())

  defp usable?({:paired, _agent, _give}), do: true
  defp usable?(_missing_or_unavailable), do: false

  # The code on screen gives way to the agent that used it, so a spent code is
  # never left there to send again.
  defp after_pairing(%{assigns: %{chosen: chosen, codes: codes}} = socket) do
    with %PairingCode.Issued{issued_at: issued_at} <- codes[chosen],
         {:ok, agents} <- RegentAgents.list_my_agents(actor: socket.assigns.person),
         %{} = agent <- Enum.find(agents, &(DateTime.compare(&1.paired_at, issued_at) != :lt)) do
      VisitLog.step("agent_paired", to_string(chosen))

      give =
        case KeyfleetWeb.AgentKeys.read(socket.assigns.account, [agent.wallet]) do
          {:ok, keys} -> keys[agent.wallet]
          {:error, _failure} -> :unavailable
        end

      assign(socket, codes: Map.put(codes, chosen, {:paired, agent, give}))
    else
      _unchanged -> socket
    end
  end

  # The paired agent and where to give it a shard, when it has none and the
  # person holds a Key, or `:unavailable` when the Keys couldn't be read.
  defp give({:paired, agent, {:give, path}}), do: %{name: agent.name, path: path}
  defp give({:paired, _agent, :unavailable}), do: :unavailable
  defp give(_code), do: nil

  defp issue(socket, harness) do
    code =
      case RegentAgents.issue_pairing_code(actor: socket.assigns.person) do
        {:ok, issued} ->
          VisitLog.step("pairing_code_shown", to_string(harness))
          issued

        {:error, error} ->
          Logger.warning("A pairing code couldn't be made: #{inspect(failure_kinds(error))}")
          :unavailable
      end

    assign(socket, chosen: harness, codes: Map.put(socket.assigns.codes, harness, code))
  end

  # The kinds of failure alone: the failure's words can hold the person's id.
  defp failure_kinds(%{errors: [_ | _] = errors}), do: Enum.map(errors, & &1.__struct__)
  defp failure_kinds(error), do: [error.__struct__]

  @doc """
  What the person pastes to their agent: the shared pairing words, then this
  runtime's own setup from its page under /agents, so agents sharing one
  computer each keep their own key and folder and each comes back on its own,
  and last the page it begins on when a pairing link names one (`start`). A
  link to a workspace item or a project's page also names the agent's first
  read of that work.
  """
  def agent_message(code, harness, start) do
    origin = KeyfleetWeb.Endpoint.url()

    PairingMessage.text(code, origin, harness,
      setup:
        Enum.join(
          [setup(harness), "Your full setup: " <> origin <> AgentGuides.path(harness)] ++
            List.wrap(first_read(start, harness in Harness.hosted())),
          "\n"
        ),
      start: start
    )
  end

  # A workspace item is named by its type and number, a project as
  # `Keyfleet.Projects.Project` names it.
  @item ~r/\A[a-z][a-z_]{0,31}#[1-9][0-9]{0,17}\z/
  @project ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/

  # A link to a workspace item or a project's page names the work, so the
  # agent's first read once paired is that work itself, as its page shows it
  # to a person, rather than the whole fleet. Claude, through its connector,
  # reads it with the connector's tool of the same name.
  defp first_read(nil, _hosted?), do: nil

  defp first_read(start, hosted?) do
    path = URI.parse(start).path || ""

    with %{id: fleet_id, path: fleet_path} <- Keyfleet.Fleets.at_path(path) do
      path
      |> String.replace_prefix(fleet_path, "")
      |> String.split("/")
      |> work(fleet_id, hosted?)
    end
  end

  defp work(["", "workspace", item], fleet_id, hosted?) do
    id = URI.decode(item)

    if id =~ @item,
      do:
        "Start with #{id} in the fleet #{fleet_id}. " <>
          if(hosted?,
            do:
              "Once paired, read it in one go, with its goal, criteria, discussion, commit and what a rerun still needs: call workspace_show with fleet_id #{fleet_id} and id #{id}.",
            else:
              "Once paired, read it in one go, with its goal, criteria, discussion, commit and what a rerun still needs: regents keyfleet workspace get #{fleet_id} '#{id}', or a signed POST /api/v1/agent/fleets/#{fleet_id}/graph/get with {\"id\":\"#{id}\"}."
          )
  end

  defp work(["", "projects", project], fleet_id, hosted?) do
    if project =~ @project,
      do:
        "Start with the project #{project} in the fleet #{fleet_id}. " <>
          if(hosted?,
            do:
              "Once paired, read its goals and pinned work: call workspace_board with fleet_id #{fleet_id} and project #{project}, then read any task in it with workspace_show.",
            else:
              "Once paired, read its goals and pinned work with a signed POST /api/v1/agent/fleets/#{fleet_id}/graph/board with {\"project\":\"#{project}\"}, then read any task in it with graph/get."
          )
  end

  defp work(_path, _fleet_id, _hosted?), do: nil

  @check_in "Check in on Keyfleet as your keyfleet skill says."

  defp setup(:claude_code),
    do: """
    Use your own key: begin every shell with export SIWA_AGENT_HOME=~/.siwa-agent/claude-code, and work in ~/keyfleet/claude-code.
    After pairing, add a scheduled task in the Claude desktop app: folder ~/keyfleet/claude-code, every 30 minutes, instructions "#{@check_in}"\
    """

  defp setup(:codex),
    do: """
    Use your own key: begin every shell with export SIWA_AGENT_HOME=~/keyfleet/codex/.siwa-agent UV_CACHE_DIR=~/keyfleet/codex/.uv-cache, and work in ~/keyfleet/codex.
    After pairing, add a scheduled task in the Codex app: project ~/keyfleet/codex, a new chat each run, every 30 minutes, instructions "#{@check_in}"\
    """

  defp setup(:openclaw),
    do: """
    Use your own key: begin every shell with export SIWA_AGENT_HOME=~/.siwa-agent/openclaw, and work in ~/keyfleet/openclaw.
    After pairing, schedule check-ins: openclaw cron add --name keyfleet --every 30m --session isolated --message "#{@check_in}"\
    """

  defp setup(:ironclaw),
    do: """
    Use your own key: begin every shell with export SIWA_AGENT_HOME=~/.siwa-agent/ironclaw, and work in ~/keyfleet/ironclaw.
    After pairing, make a cron routine with your routine_create tool, every 30 minutes, with the prompt "#{@check_in}"\
    """

  defp setup(:pi),
    do: """
    Use your own key: begin every shell with export SIWA_AGENT_HOME=~/.siwa-agent/pi, and work in ~/keyfleet/pi. Save your skill as ~/keyfleet/pi/keyfleet/SKILL.md, never in ~/.agents/skills.
    After pairing, Pi has no scheduler: give me the one crontab line your setup page shows, every 30 minutes.\
    """

  defp setup(:hermes),
    do: """
    After pairing, schedule check-ins: hermes cron create "every 30m" "#{@check_in}" --skill keyfleet\
    """

  defp setup(:grok_bot),
    do: """
    After pairing, add a routine every 30 minutes with the instructions "#{@check_in}"\
    """

  defp setup(:muse),
    do: """
    After pairing, add a recurring task every 30 minutes with the instructions "#{@check_in}"\
    """

  defp setup(:dots),
    do: """
    After pairing, add a recurring task under Scheduled, every 30 minutes, with the instructions "#{@check_in}"\
    """

  defp setup(:claude),
    do: """
    If the Keyfleet connector isn't in your tools yet, ask me to add it in Claude's settings under Connectors, with the address #{KeyfleetWeb.Endpoint.url()}/mcp.
    After pairing, call check_in each time you start on Keyfleet.\
    """

  defp setup(:other),
    do: """
    If other agents share your computer, use your own key: begin every shell with export SIWA_AGENT_HOME=~/.siwa-agent/YOUR-RUNTIME.
    After pairing, set up check-ins as your runtime's page says, or the page below if yours has none.\
    """
end

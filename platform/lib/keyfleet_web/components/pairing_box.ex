defmodule KeyfleetWeb.PairingBox do
  @moduledoc """
  Pairing an agent (`RegentAgents`), under "Pair New Agent" in the side panel on
  every page, in the shared pairing box (`Regent.Account.pairing`): the message to
  paste with its code in a short box with icons to copy it and make a new code,
  then the ten agents in `RegentAgents.Harness.featured/0` to choose from by
  their pictures. Once the
  agent uses the code, the box names it.

  The parent passes `account` (the signed-in account), its `session_lease` as
  `lease` and `id`, and sends `agents_changed: true` when an agent pairs, checks
  in or is unpaired anywhere. A pairing link (`/pair?to=<path>`) also passes
  `start`, the page on this site the agent begins on once paired; the message
  then sends it there.
  """
  use KeyfleetWeb, :live_component

  alias Keyfleet.Limits
  alias KeyfleetWeb.AgentGuides
  alias KeyfleetWeb.Live.Session
  alias RegentAgents.{Harness, PairingCode, PairingMessage, Person}

  @impl true
  def mount(socket),
    do:
      {:ok,
       socket
       |> Session.check_component_lease(&take_account/2)
       |> assign(pairing: nil)}

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
    do:
      assign(socket,
        account_id: account.id,
        person: %Person{privy_user_id: account.privy_user_id}
      )

  # Choosing an agent, or asking again for the chosen one, makes a code with that
  # agent's message; codes made before keep working until they expire. Anything
  # else, such as a form with no agent chosen, changes nothing.
  @impl true
  def handle_event("issue_pairing_code", %{"harness" => harness}, socket)
      when is_binary(harness) do
    with {:ok, harness} <- Harness.match(harness),
         true <- harness in Harness.featured() do
      {:noreply, issue(socket, harness)}
    else
      _not_offered -> {:noreply, socket}
    end
  end

  def handle_event("issue_pairing_code", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <Regent.Account.pairing
        id={@id}
        harnesses={choices()}
        layout={:icons}
        phx-change="issue_pairing_code"
        phx-submit="issue_pairing_code"
        phx-target={@myself}
        {pairing(@pairing, @start)}
      />
    </div>
    """
  end

  @doc "The ten agents to choose from, as the shared pairing box takes them."
  def choices,
    do:
      for(
        harness <- Harness.featured(),
        do: %{value: to_string(harness), label: label(harness)}
      )

  defp label(:other), do: "Any agent"
  defp label(:codex), do: "OpenAI Codex"
  defp label(harness), do: Harness.label(harness)

  # The pairing box's state; the box keeps one size whatever it holds.
  defp pairing(%{harness: harness, code: %PairingCode.Issued{} = code}, start) do
    %{
      chosen: to_string(harness),
      message: agent_message(code.code, harness, start),
      expires_iso: DateTime.to_iso8601(code.expires_at),
      expires: Calendar.strftime(code.expires_at, "%H:%M UTC")
    }
  end

  defp pairing(%{harness: harness, code: {:paired, agent}}, _start),
    do: %{
      chosen: to_string(harness),
      outcome: {:paired, agent.name}
    }

  defp pairing(%{harness: harness, code: :unavailable}, _start),
    do: %{chosen: to_string(harness), outcome: :unavailable}

  defp pairing(nil, _start), do: %{}

  # A code on screen gives way to the agent that used it, so a spent code is
  # never left there to send again.
  defp after_pairing(
         %{assigns: %{pairing: %{code: %PairingCode.Issued{issued_at: issued_at}} = shown}} =
           socket
       ) do
    with {:ok, agents} <- RegentAgents.list_my_agents(actor: socket.assigns.person),
         %{} = agent <- Enum.find(agents, &(DateTime.compare(&1.paired_at, issued_at) != :lt)) do
      assign(socket, pairing: %{shown | code: {:paired, agent}})
    else
      _unchanged -> socket
    end
  end

  defp after_pairing(socket), do: socket

  # Each code made spends the account's allowance; past it, the box says a code
  # can't be made now, as when one can't be made at all.
  defp issue(socket, harness) do
    code =
      with :ok <- Limits.spend(:pairing_codes, {:human, socket.assigns.account_id}),
           {:ok, issued} <- RegentAgents.issue_pairing_code(actor: socket.assigns.person) do
        issued
      else
        _unavailable -> :unavailable
      end

    assign(socket, pairing: %{harness: harness, code: code})
  end

  @doc """
  What the person pastes to their agent: the shared pairing words, then this
  runtime's own setup from its page under /agents, so agents sharing one
  computer each keep their own key and folder and each comes back on its own,
  and last the page it begins on when a pairing link names one (`start`).
  """
  def agent_message(code, harness, start) do
    origin = KeyfleetWeb.Endpoint.url()

    PairingMessage.text(code, origin, harness,
      setup: setup(harness) <> "\nYour full setup: " <> origin <> AgentGuides.path(harness),
      start: start
    )
  end

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

  defp setup(:other),
    do: """
    If other agents share your computer, use your own key: begin every shell with export SIWA_AGENT_HOME=~/.siwa-agent/YOUR-RUNTIME.
    After pairing, set up check-ins as your runtime's page says, or the page below if yours has none.\
    """
end

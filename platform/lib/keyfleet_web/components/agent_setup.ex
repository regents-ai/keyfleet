defmodule KeyfleetWeb.Components.AgentSetup do
  @moduledoc """
  The agents a signed-in person has paired, each with the five states its setup
  ends in as dots, and a line only when its scheduled run has stopped. It takes
  no room for a person with no agent. The states come from the chain reader's
  records and check-ins (`Keyfleet.Agents.Upkeep`); only gas asks the chain, so
  the row is drawn at once and that dot fills in when the answer comes.
  """
  use KeyfleetWeb, :live_component

  alias Keyfleet.Agents.Upkeep
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(socket), do: {:ok, assign(socket, class: nil, gas: AsyncResult.loading())}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(changed?(socket, :fleet_id), do: read(socket), else: socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={["agent-setup", @class]}
      aria-labelledby={"#{@id}-title"}
      hidden={@agents == []}
    >
      <h2 id={"#{@id}-title"}>
        Your agent
        <Regent.Primitives.tip id={"#{@id}-tip"} label="About the dots">
          Paired, gas, schedule, marked, repeated.
        </Regent.Primitives.tip>
      </h2>
      <div :for={agent <- @agents} class="agent-setup__agent" data-wallet={agent.wallet}>
        <span class="agent-setup__name">{agent.name}</span>
        <ul class="agent-setup__states">
          <li
            :for={{label, state} <- states(agent, @gas)}
            data-state={word(state)}
            title={"#{label}: #{word(state)}"}
          >
            <span class="visually-hidden">{label}: {word(state)}</span>
          </li>
        </ul>
        <p :if={agent.run_missed} class="agent-setup__wrong">{missed(agent.lapses_at)}</p>
      </div>
    </section>
    """
  end

  defp read(%{assigns: %{actor: actor, fleet_id: fleet_id}} = socket) do
    agents = Upkeep.person_agents(actor, fleet_id)

    socket
    |> assign(agents: agents)
    |> assign_async(:gas, fn ->
      {:ok, %{gas: Map.new(agents, &{&1.wallet, Upkeep.pays?(&1.wallet, &1.key_count)})}}
    end)
  end

  defp states(agent, %AsyncResult{result: gas}) do
    [
      {"Paired", true},
      {"Gas", gas && gas[agent.wallet]},
      {"Schedule", agent.schedule},
      {"Marked", agent.marked},
      {"Repeated", agent.repeated}
    ]
  end

  defp word(true), do: "yes"
  defp word(false), do: "no"
  defp word(nil), do: "unknown"

  defp missed(nil), do: "Run missed. Keys lapsed."

  defp missed(lapses_at) do
    if DateTime.after?(lapses_at, DateTime.utc_now()),
      do: "Run missed. Keys lapse #{Calendar.strftime(lapses_at, "%-d %b")}.",
      else: "Run missed. Keys lapsed."
  end
end

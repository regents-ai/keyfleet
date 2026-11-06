defmodule KeyfleetWeb.Components.AgentSetup do
  @moduledoc """
  The agents a signed-in person has paired, each with the five states its setup
  ends in as dots, and a line only when its scheduled run has stopped. It takes
  no room for a person with no agent. Each dot opens a few words saying what it
  is and, when it is not done, how to put it right. The states come from the
  chain reader's records and check-ins (`Keyfleet.Agents.Upkeep`); only gas asks
  the chain, so the row is drawn at once and that dot fills in when the answer
  comes.
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
      <h2 id={"#{@id}-title"}>Your agent</h2>
      <div
        :for={{agent, n} <- Enum.with_index(@agents)}
        class="agent-setup__agent"
        data-wallet={agent.wallet}
      >
        <span class="agent-setup__name">{agent.name}</span>
        <ul class="agent-setup__states">
          <li :for={{label, state, words} <- states(agent, @gas)} data-state={word(state)}>
            <Regent.Primitives.tip id={"#{@id}-#{n}-#{String.downcase(label)}"}>
              <:figure>
                <span class="agent-setup__dot" aria-hidden="true"></span>
                <span class="visually-hidden">{label}: {word(state)}</span>
              </:figure>
              <strong>{label}.</strong> {words}
            </Regent.Primitives.tip>
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

  # Each state with the words its dot opens: what it is, and how to put it
  # right when it is not done.
  defp states(agent, %AsyncResult{} = gas) do
    paid = gas.result && gas.result[agent.wallet]

    [
      {"Paired", true, "This agent is paired with your account."},
      {"Gas", paid, gas_words(paid, agent.key_count, gas.loading)},
      {"Schedule", agent.schedule, schedule_words(agent.schedule)},
      {"Marked", agent.marked, marked_words(agent.marked, agent.key_count)},
      {"Repeated", agent.repeated, repeated_words(agent.repeated)}
    ]
  end

  defp gas_words(true, _keys, _loading), do: "Its wallet has the ETH on Base to mark your Keys."
  defp gas_words(false, _keys, _loading), do: "Its wallet is out of ETH. Send it ETH on Base."

  defp gas_words(nil, 0, _loading),
    do: "Nothing to pay for until it acts for a Key. Give it a shard."

  defp gas_words(nil, _keys, loading) when loading in [nil, false],
    do: "The chain didn’t answer. Reload in a minute."

  defp gas_words(nil, _keys, _loading), do: "Reading its wallet."

  defp schedule_words(true), do: "Its daily run is scheduled."
  defp schedule_words(false), do: "No daily run yet. Ask your agent to schedule one."

  defp marked_words(true, _keys), do: "Every Key it acts for is present and counts in votes."
  defp marked_words(false, 0), do: "It acts for no Key yet. Give it a shard."

  defp marked_words(false, _keys),
    do: "A Key it acts for isn’t present. Ask your agent to mark it, or mark it yourself."

  defp repeated_words(true), do: "Its daily run keeps arriving on time."

  defp repeated_words(false),
    do: "Its daily run hasn’t come back on time yet. Check after its next run."

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

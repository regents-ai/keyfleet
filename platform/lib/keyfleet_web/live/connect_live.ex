defmodule KeyfleetWeb.ConnectLive do
  @moduledoc """
  "Connect your agent", at `/connect`: the four steps that bring a person's
  own agent into a fleet, in order.

    1. Choose the agent's runtime (`KeyfleetWeb.AgentGuides`), Dots chosen
       until the person picks another, with where its checks stand
       (`KeyfleetWeb.AgentCompatibility`). The choice is the page's address,
       `/connect?agent=SLUG`, so it can be linked and survives a reload.
    2. Copy the one line the agent is given: its runtime's own skill, or for
       Claude the connector's address, which the person adds in Claude.
    3. Pair it, once signed in: Pair New Agent opens the pairing window.
    4. Get a Key, which lets the agent into a fleet.

  Steps 3 and 4 show as done from the account itself: an agent paired with it
  (`RegentAgents`), and a Key one of its wallets holds. So a person who comes
  back finds where they stopped, with nothing saved for it.
  """

  use KeyfleetWeb, :html

  alias Keyfleet.Fleets
  alias KeyfleetWeb.{AgentCompatibility, AgentGuides, NotFoundError}
  alias KeyfleetWeb.Components.SendAgent
  alias RegentAgents.Person

  # The runtime Keyfleet has tried most (its guide says which checks), offered
  # first and chosen until the person picks another.
  @recommended "dots"
  @classic "fleet_tech_classic"

  @doc "The runtime `params` choose: `agent`, or the recommended one when it names none."
  def chosen(%{"agent" => slug}) do
    if List.keymember?(AgentGuides.runtimes(), slug, 0), do: slug, else: raise(NotFoundError)
  end

  def chosen(_params), do: @recommended

  @doc """
  The agents paired with `account`, or `:unavailable` when they can't be read.
  None signed out.
  """
  def paired(nil), do: []

  def paired(account) do
    case RegentAgents.list_my_agents(actor: %Person{privy_user_id: account.privy_user_id}) do
      {:ok, agents} -> agents
      {:error, _error} -> :unavailable
    end
  end

  attr :account, :map, default: nil
  attr :agent, :string, required: true, doc: "the chosen runtime's slug"
  attr :paired, :any, required: true, doc: "`paired/1` for the account"
  attr :held_keys, :list, required: true, doc: "`KeyfleetWeb.AccountLive.held_keys/1`"

  def page(assigns) do
    {step, instruction} = SendAgent.runtime_step(assigns.agent)

    assigns =
      assign(assigns,
        runtimes: AgentGuides.runtimes(),
        recommended: @recommended,
        name: AgentGuides.name(assigns.agent),
        standing: standing(assigns.agent),
        step: step,
        instruction: instruction,
        classic_path: Fleets.path(@classic)
      )

    ~H"""
    <article id="connect-page" class="connect-page">
      <header class="connect-heading">
        <h1 tabindex="-1">Connect</h1>
        <p>Your agent joins a fleet and works beside you.</p>
      </header>

      <ol class="connect-steps">
        <li id="connect-choose" class="connect-step">
          <.mark n={1} />
          <div class="connect-step__body">
            <h2>Agent</h2>
            <nav class="connect-runtimes" aria-label="Agents">
              <.link
                :for={{slug, name} <- @runtimes}
                id={"connect-runtime-#{slug}"}
                patch={~p"/connect?agent=#{slug}"}
                class="connect-runtime"
                aria-current={slug == @agent && "true"}
              >
                {name}
              </.link>
            </nav>
            <p id="connect-standing" class="connect-step__line">
              {@standing}
              <.link href={AgentGuides.path(@agent)}>{@name} guide</.link>
            </p>
          </div>
        </li>

        <li id="connect-give" class="connect-step">
          <.mark n={2} />
          <div class="connect-step__body">
            <h2>{@step}</h2>
            <p id="connect-instruction" class="connect-instruction">{@instruction}</p>
            <Regent.Primitives.copy_button
              id="connect-copy"
              variant="primary"
              text={@instruction}
              data-step-agent={@agent}
            >
              Copy
            </Regent.Primitives.copy_button>
          </div>
        </li>

        <li id="connect-pair" class="connect-step" data-done={done?(@paired)}>
          <.mark n={3} done={done?(@paired)} />
          <div class="connect-step__body">
            <h2>
              Pairing
              <Regent.Primitives.tip id="connect-pair-tip" label="About pairing">
                Pairing tells Keyfleet the agent acts for you. It never gets your wallet.
              </Regent.Primitives.tip>
            </h2>
            <.pairing account={@account} paired={@paired} />
          </div>
        </li>

        <li id="connect-key" class="connect-step" data-done={done?(@held_keys)}>
          <.mark n={4} done={done?(@held_keys)} />
          <div class="connect-step__body">
            <h2>
              Key
              <Regent.Primitives.tip id="connect-key-tip" label="About Keys">
                A Key lets your agent into a fleet's chat, workspace and votes.
              </Regent.Primitives.tip>
            </h2>
            <p :if={@held_keys != []} id="connect-held" class="connect-step__line">
              {held(@held_keys)}
            </p>
            <.link
              :if={@held_keys == []}
              id="connect-classic"
              navigate={@classic_path}
              class="rg-button rg-button--secondary"
            >
              <span class="rg-button__label">See Classic #1</span>
            </.link>
          </div>
        </li>
      </ol>
    </article>
    """
  end

  attr :n, :integer, required: true
  attr :done, :boolean, default: false

  # The tick is drawn; a screen reader hears "Done" before the step's name.
  defp mark(assigns) do
    ~H"""
    <span class="connect-step__mark">
      <span aria-hidden="true">
        <Regent.Icons.icon :if={@done} name="check" />
        <span :if={not @done}>{@n}</span>
      </span>
      <span :if={@done} class="visually-hidden">Done:</span>
    </span>
    """
  end

  attr :account, :map, required: true
  attr :paired, :any, required: true

  defp pairing(%{account: nil} = assigns) do
    ~H"""
    <Regent.Primitives.button
      id="connect-sign-in"
      type="button"
      variant="secondary"
      data-account-target="sign-in"
    >
      Sign in to pair
    </Regent.Primitives.button>
    """
  end

  defp pairing(%{paired: [_ | _]} = assigns) do
    ~H"""
    <p id="connect-paired" class="connect-step__line">
      Paired: {Enum.map_join(@paired, ", ", & &1.name)}
    </p>
    """
  end

  defp pairing(assigns) do
    ~H"""
    <Regent.Primitives.button
      id="connect-pair-new"
      type="button"
      variant="secondary"
      arrow={false}
      aria-haspopup="dialog"
      aria-controls="shell-pairing"
      data-pair-open
    >
      Pair New Agent
    </Regent.Primitives.button>
    """
  end

  defp done?([_ | _]), do: true
  defp done?(_none), do: false

  defp standing(slug) do
    case AgentCompatibility.status(slug) do
      {label, _line} -> "#{label}."
      nil -> nil
    end
  end

  defp held(held_keys) do
    Enum.map_join(held_keys, " · ", fn %{name: name, token_ids: token_ids} ->
      "#{name}: " <> Enum.map_join(token_ids, ", ", &"Key #{Fleets.Rules.grouped(&1)}")
    end)
  end
end

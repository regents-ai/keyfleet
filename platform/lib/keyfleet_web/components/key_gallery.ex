defmodule KeyfleetWeb.KeyGallery do
  @moduledoc """
  On the Account page, the Keys a person's wallets hold in one fleet as a
  gallery of cards, those with any of their agents on them first, then by
  number, each with the pictures and names of its agents under it
  (`Keyfleet.Keys.AgentKey`). A Key holds any number of the person's agents
  and an agent is on one Key in a fleet. Add puts one of the agents paired
  with them now on the Key, moving it off the Key it was on; each agent's
  remove button takes it off. Each change says what it did in the line under
  the gallery, read again once it is saved, and asks the page to read the
  gallery again (`{KeyfleetWeb.KeyGallery, :changed}`), so the Key moves to
  its place. A person with no paired agent sees their Keys alone.

  The host passes `account` (the signed-in account), its `session_lease` as
  `lease`, the fleet as `fleet_id`, the Keys held there as `token_ids`, their
  small cards as `pictures`, by Key, the person's paired agents as `agents`
  (`KeyfleetWeb.AccountLive.key_agents/1`) and the agents on each of their
  Keys there as `on_keys`, by Key (`Keyfleet.Keys.agents_on_keys/2`). The
  `:key` slot draws what follows a Key's name, given the Key.
  """
  use KeyfleetWeb, :live_component

  import KeyfleetWeb.Components.AgentPicture

  alias Keyfleet.Actors.Human
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Keys
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.Live.Session

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> Session.check_component_lease(&take_account/2)
     |> assign(notice: nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(
       Map.take(assigns, [:id, :lease, :fleet_id, :token_ids, :pictures, :agents, :on_keys, :key])
     )
     |> take_account(assigns.account)}
  end

  # The account as the page gave it, or as it reads now before each event
  # (`Session.check_component_lease/2`).
  defp take_account(socket, account), do: assign(socket, actor: Human.for_account(account))

  @impl true
  # The agent comes by its wallet, which the action checks against the
  # person's pairings as they are now. Add itself chooses nothing.
  def handle_event("assign", %{"token_id" => token_id, "agent" => wallet}, socket)
      when wallet != "" do
    %{fleet_id: fleet_id, actor: actor, agents: agents} = socket.assigns
    agent = Enum.find(agents, &(&1.wallet == String.downcase(wallet)))

    notice =
      with {token_id, ""} <- Integer.parse(token_id),
           %{} <- agent,
           {:ok, _assigned} <- Keys.assign_agent(fleet_id, token_id, wallet, actor: actor) do
        send(self(), {__MODULE__, :changed})
        put(actor, agents, agent, {fleet_id, token_id})
      else
        _refused -> refused()
      end

    {:noreply, assign(socket, notice: notice)}
  end

  def handle_event("assign", _choice, socket), do: {:noreply, socket}

  def handle_event("release", %{"token_id" => token_id, "agent" => id}, socket) do
    %{fleet_id: fleet_id, actor: actor, agents: agents} = socket.assigns

    notice =
      with %{name: name} <- Enum.find(agents, &(&1.id == id)),
           {token_id, ""} <- Integer.parse(token_id),
           :ok <- Keys.release_agent(fleet_id, id, actor: actor) do
        send(self(), {__MODULE__, :changed})
        {:status, "#{name} is off Key #{Rules.grouped(token_id)}."}
      else
        _refused -> refused()
      end

    {:noreply, assign(socket, notice: notice)}
  end

  # What the Key holds once the change is saved: a Key that changed hands
  # meanwhile has no agents.
  defp put(actor, agents, agent, {_fleet_id, token_id} = key) do
    on_key = Map.get(Keys.agents_on_keys(actor, agents), key, [])

    if Enum.any?(on_key, &(&1.id == agent.id)),
      do: {:status, "#{agent.name} is on Key #{Rules.grouped(token_id)}."},
      else: {:alert, "Key #{Rules.grouped(token_id)} changed hands, so it has no agents."}
  end

  defp refused, do: {:alert, "That couldn’t be saved. Reload to see your Keys and agents."}

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :shown,
        Enum.sort_by(assigns.token_ids, &{!Map.has_key?(assigns.on_keys, &1), &1})
      )

    ~H"""
    <div id={@id} class="key-gallery">
      <ul class="key-gallery__keys">
        <li
          :for={token_id <- @shown}
          id={"#{@id}-#{token_id}"}
          class={["key-gallery__key", Map.has_key?(@on_keys, token_id) && "key-gallery__key--agents"]}
        >
          <.link class="key-gallery__card" patch={KeyLinks.key_path(@fleet_id, token_id)}>
            <img
              :if={@pictures[token_id]}
              src={@pictures[token_id]}
              alt=""
              width="160"
              height="200"
              loading="lazy"
              decoding="async"
            />
            <span :if={!@pictures[token_id]} class="key-gallery__blank"></span>
            <span class="key-gallery__name">Key {Rules.grouped(token_id)}</span>
          </.link>
          {render_slot(@key, token_id)}
          <ul
            :if={Map.has_key?(@on_keys, token_id)}
            id={"#{@id}-#{token_id}-agents"}
            class="key-gallery__agents"
            aria-label={"Agents on Key #{Rules.grouped(token_id)}"}
          >
            <li :for={agent <- @on_keys[token_id]} id={"#{@id}-#{token_id}-agent-#{agent.id}"}>
              <.agent_picture src={agent.picture} />
              <span class="key-gallery__agent-name" title={agent.name}>{agent.name}</span>
              <button
                type="button"
                class="key-gallery__remove"
                phx-click="release"
                phx-value-token_id={token_id}
                phx-value-agent={agent.id}
                phx-target={@myself}
                aria-label={"Take #{agent.name} off Key #{Rules.grouped(token_id)}"}
                title="Remove"
              >
                <Regent.Icons.icon name="x" />
              </button>
            </li>
          </ul>
          <form
            :if={addable(@agents, @on_keys[token_id]) != []}
            id={"#{@id}-#{token_id}-add"}
            class="key-gallery__add"
            phx-change="assign"
            phx-target={@myself}
          >
            <input type="hidden" name="token_id" value={token_id} />
            <select name="agent" aria-label={"Add an agent to Key #{Rules.grouped(token_id)}"}>
              <option value="" selected>Add agent</option>
              <option :for={agent <- addable(@agents, @on_keys[token_id])} value={agent.wallet}>
                {agent.name}{elsewhere(@on_keys, agent)}
              </option>
            </select>
          </form>
        </li>
      </ul>
      <p
        :if={@agents != []}
        id={"#{@id}-notice"}
        class="key-gallery__notice"
        role={notice_role(@notice)}
        aria-live="polite"
      >
        {notice_text(@notice)}
      </p>
    </div>
    """
  end

  # The person's agents not on this Key already.
  defp addable(agents, on_key) do
    on = MapSet.new(List.wrap(on_key), & &1.id)
    Enum.reject(agents, &MapSet.member?(on, &1.id))
  end

  # The Key an agent would move from, beside its name.
  defp elsewhere(on_keys, agent) do
    case Enum.find(on_keys, fn {_token_id, on_key} -> Enum.any?(on_key, &(&1.id == agent.id)) end) do
      {token_id, _on_key} -> " · Key #{Rules.grouped(token_id)}"
      nil -> ""
    end
  end

  defp notice_role({:alert, _text}), do: "alert"
  defp notice_role(_notice), do: "status"

  defp notice_text({_kind, text}), do: text
  defp notice_text(nil), do: nil
end

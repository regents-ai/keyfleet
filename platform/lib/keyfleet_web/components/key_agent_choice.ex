defmodule KeyfleetWeb.KeyAgentChoice do
  @moduledoc """
  On the Account page, the Keys a person's wallets hold in one fleet, those
  with one of their agents on them first, then by number, each with its
  agent: None, or one of the agents paired with them now
  (`Keyfleet.Keys.AgentKey`). Choosing one saves it at once, says so in the
  line under the list, and asks the page to read the list again
  (`{KeyfleetWeb.KeyAgentChoice, :changed}`), so the Key moves to its place.
  A person with no paired agent sees their Keys alone.

  The host passes `account` (the signed-in account), its `session_lease` as
  `lease`, the fleet as `fleet_id`, the Keys held there as `token_ids`, the
  person's paired agents as `agents` (`Keyfleet.Keys.person_agents/1`) and
  the agent on each of their Keys there as `on_keys`, by Key
  (`Keyfleet.Keys.agents_on_keys/2`). The `:key` slot draws what follows a
  Key's name, given the Key.
  """
  use KeyfleetWeb, :live_component

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
     |> assign(Map.take(assigns, [:id, :lease, :fleet_id, :token_ids, :agents, :on_keys, :key]))
     |> take_account(assigns.account)}
  end

  # The account as the page gave it, or as it reads now before each event
  # (`Session.check_component_lease/2`).
  defp take_account(socket, account), do: assign(socket, actor: Human.for_account(account))

  @impl true
  # None is the empty choice; any other is an agent's wallet, which the
  # action checks against the person's pairings as they are now.
  def handle_event("assign", %{"token_id" => token_id, "agent" => choice}, socket) do
    %{fleet_id: fleet_id, actor: actor} = socket.assigns
    wallet = if choice == "", do: nil, else: choice

    notice =
      with {token_id, ""} <- Integer.parse(token_id),
           {:ok, _assigned} <- Keys.assign_agent(fleet_id, token_id, wallet, actor: actor) do
        send(self(), {__MODULE__, :changed})
        {:status, saved(wallet, socket.assigns.agents, token_id)}
      else
        refused -> {:alert, refused(refused)}
      end

    {:noreply, assign(socket, notice: notice)}
  end

  # A choice another one saved for the same Key first changes nothing, and
  # may be made again at once.
  defp refused({:error, %Ash.Error.Invalid{errors: errors}}) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
      do: "Another change to this Key was saved first. Try again.",
      else: refused(nil)
  end

  defp refused(_refused), do: "That couldn’t be saved. Reload to see your Keys and agents."

  defp saved(nil, _agents, token_id), do: "Key #{Rules.grouped(token_id)} has no agent now."

  defp saved(wallet, agents, token_id) do
    case Enum.find(agents, &(&1.wallet == String.downcase(wallet))) do
      %{name: name} -> "#{name} is on Key #{Rules.grouped(token_id)} now."
      nil -> "Saved."
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :shown,
        Enum.sort_by(assigns.token_ids, &{!Map.has_key?(assigns.on_keys, &1), &1})
      )

    ~H"""
    <div id={@id} class="account-keys__keys">
      <ul class={["account-keys__list", @agents != [] && "account-keys__list--agents"]}>
        <li
          :for={token_id <- @shown}
          id={"#{@id}-#{token_id}"}
          class={Map.has_key?(@on_keys, token_id) && "account-keys__key--agent"}
        >
          <.link patch={KeyLinks.key_path(@fleet_id, token_id)}>Key {token_id}</.link>
          {render_slot(@key, token_id)}
          <form
            :if={@agents != []}
            id={"#{@id}-#{token_id}-form"}
            class="account-keys__agent"
            phx-change="assign"
            phx-target={@myself}
          >
            <input type="hidden" name="token_id" value={token_id} />
            <Regent.Primitives.field :let={field} id={"#{@id}-#{token_id}-agent"} label="Agent">
              <select id={field.id} name="agent" aria-label={"Agent on Key #{token_id}"}>
                <option value="" selected={!Map.has_key?(@on_keys, token_id)}>None</option>
                <option
                  :for={agent <- @agents}
                  value={agent.wallet}
                  selected={on_key?(@on_keys[token_id], agent)}
                >
                  {agent.name}
                </option>
              </select>
            </Regent.Primitives.field>
          </form>
        </li>
      </ul>
      <p
        :if={@agents != []}
        id={"#{@id}-notice"}
        class="account-keys__notice"
        role={notice_role(@notice)}
        aria-live="polite"
      >
        {notice_text(@notice)}
      </p>
    </div>
    """
  end

  defp on_key?(%{id: id}, %{id: id}), do: true
  defp on_key?(_on_key, _agent), do: false

  defp notice_role({:alert, _text}), do: "alert"
  defp notice_role(_notice), do: "status"

  defp notice_text({_kind, text}), do: text
  defp notice_text(nil), do: nil
end

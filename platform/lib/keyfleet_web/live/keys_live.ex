defmodule KeyfleetWeb.KeysLive do
  @moduledoc """
  One key's page: who owns it, who runs it, who has asked to, and everything
  that came before.

  Everything here is read from what the key itself records, so a visitor sees
  the same standing the owner does; only the owner is offered the buttons.
  """

  use KeyfleetWeb, :html

  alias Keyfleet.Actors.Human
  alias Keyfleet.Chain
  alias Keyfleet.Keys
  alias KeyfleetWeb.ShellLive

  @refused "That didn’t go through."
  @refreshing "Key ownership is being refreshed; try again in a moment."
  @answered "This request was already answered."
  @key_moved_on "This key has already changed; here it is now."
  @limits_unwritten "Write each limit, in no more than 500 characters."
  @limit_fields [:money, :information, :outside, :check_first]

  attr :key, :map, required: true
  attr :notice, :map, default: nil

  attr :drafts, :map,
    default: %{},
    doc: "limits the owner typed in a save that was refused, by pairing"

  def page(assigns) do
    ~H"""
    <article id="key-page" class="key-page">
      <header class="key-heading">
        <p class="key-kicker">{@key.fleet_name || "Keyfleet"}</p>
        <h1 tabindex="-1">Key {@key.token_id}</h1>
        <p class="key-lede">Who owns this key, and who runs it for them.</p>
      </header>

      <section :if={is_nil(@key.owner_wallet)} class="key-panel">
        <h2>This key isn’t here yet</h2>
        <p>Once the key is issued, its owner and agent appear on this page.</p>
      </section>

      <div :if={@key.owner_wallet} class="key-grid">
        <p
          :if={@notice}
          id="key-notice"
          class={["key-notice", @notice.tone == :error && "key-notice--error"]}
          phx-hook="MotionRefusal"
          data-refused={@notice.tone == :error}
        >
          {@notice.message}
        </p>

        <p :if={@key.owner? and @key.refreshing? and is_nil(@notice)} class="key-notice">
          Key ownership is being refreshed; try again in a moment.
        </p>

        <section class="key-panel" aria-labelledby="key-owner-title">
          <h2 id="key-owner-title">Owner</h2>
          <p class="key-wallet"><code>{@key.owner_wallet}</code></p>
          <p :if={@key.owner?} class="key-detail">You own this key.</p>
        </section>

        <section class="key-panel" aria-labelledby="key-operator-title">
          <h2 id="key-operator-title">Agent</h2>
          <p :if={is_nil(@key.operator)}>No agent runs this key.</p>

          <div :if={@key.operator} class="key-operator">
            <p class="key-name">{@key.operator.agent_profile.name}</p>
            <p class="key-detail">Runs on {@key.operator.agent_profile.declared_harness}</p>
            <p :if={@key.operator.agent_profile.current_status != ""} class="key-detail">
              {@key.operator.agent_profile.current_status}
            </p>
            <p class="key-detail">Running this key since {date(@key.operator.approved_at)}</p>
            <.address
              id="key-agent-address"
              wallet={@key.operator.operator_wallet}
              agent={@key.operator.agent_profile.name}
            />
            <.limits pairing={@key.operator} />
          </div>

          <details
            :if={@key.operator && @key.owner?}
            id="key-limits-change"
            class="key-limits-change"
            phx-mounted={JS.ignore_attributes(["open"])}
          >
            <summary>Change limits</summary>
            <.form
              for={%{}}
              as={:limits}
              id="key-limits-form"
              class="key-limits-form"
              phx-submit="set_limits"
            >
              <input type="hidden" name="pairing" value={@key.operator.id} />
              <.limit_fields
                id="key-limits-form"
                limits={Map.get(@drafts, @key.operator.id, written_limits(@key.operator))}
              />
              <Regent.Primitives.button type="submit">Save limits</Regent.Primitives.button>
            </.form>
          </details>

          <Regent.Primitives.button
            :if={@key.operator && @key.owner?}
            type="button"
            variant="secondary"
            phx-click="detach_operator"
            phx-value-id={@key.operator.id}
          >
            Remove agent
          </Regent.Primitives.button>
        </section>

        <section class="key-panel" aria-labelledby="key-requests-title">
          <h2 id="key-requests-title">Requests</h2>
          <p :if={@key.requests == []}>No one has asked to run this key.</p>

          <ul :if={@key.requests != []} class="key-request-list">
            <li :for={request <- @key.requests}>
              <div>
                <p class="key-name">{request.agent_profile.name}</p>
                <span>Runs on {request.agent_profile.declared_harness}</span>
                <span>Asked on {date(request.requested_at)}</span>
                <.address
                  id={"key-request-address-#{request.id}"}
                  wallet={request.operator_wallet}
                  agent={request.agent_profile.name}
                />
              </div>

              <p :if={@key.owner?} class="key-address-check">
                Check this is your agent’s address. Approving it lets it post and work for this key;
                it can’t spend your money.
              </p>

              <.form
                :if={@key.owner?}
                for={%{}}
                as={:limits}
                id={"key-approve-#{request.id}"}
                class="key-limits-form"
                phx-submit="approve_pairing"
              >
                <input type="hidden" name="pairing" value={request.id} />
                <.limit_fields
                  id={"key-approve-#{request.id}"}
                  limits={Map.get(@drafts, request.id, Keys.default_limits())}
                />

                <div class="key-request-actions">
                  <Regent.Primitives.button type="submit">
                    Approve with these limits
                  </Regent.Primitives.button>
                  <Regent.Primitives.button
                    type="button"
                    variant="secondary"
                    phx-click="decline_pairing"
                    phx-value-id={request.id}
                  >
                    Decline
                  </Regent.Primitives.button>
                </div>
              </.form>

              <span :if={not @key.owner?}>Waiting for the owner</span>
            </li>
          </ul>
        </section>

        <section class="key-panel key-history" aria-labelledby="key-history-title">
          <h2 id="key-history-title">History</h2>
          <p :if={@key.history == []}>No one has run this key yet.</p>

          <ol :if={@key.history != []}>
            <li :for={pairing <- @key.history}>
              <p class="key-name">{pairing.agent_profile.name}</p>
              <span>{standing(pairing, @key.current_epoch)}</span>
            </li>
          </ol>

          <p class="key-detail">
            An agent keeps its name and everything it wrote after it stops running a key. When a
            key changes hands, its agent doesn’t come with it.
          </p>
        </section>
      </div>
    </article>
    """
  end

  defp standing(%{status: :active, effective?: true} = pairing, _current),
    do: "Running this key since #{date(pairing.approved_at)}"

  defp standing(%{status: :active} = pairing, _current),
    do: "Ran this key from #{date(pairing.approved_at)} until the key changed hands"

  defp standing(%{status: :requested, ownership_epoch: current} = pairing, current),
    do: "Asked on #{date(pairing.requested_at)}, waiting for the owner"

  defp standing(%{status: :requested} = pairing, _current),
    do: "Asked on #{date(pairing.requested_at)}, before the key changed hands"

  defp standing(%{status: :ended, ended_reason: :detached} = pairing, _current),
    do:
      "Ran this key from #{date(pairing.approved_at)} until it was removed on #{date(pairing.ended_at)}"

  defp standing(%{status: :ended, ended_reason: :stepped_down} = pairing, _current),
    do:
      "Ran this key from #{date(pairing.approved_at)} until it stepped down on #{date(pairing.ended_at)}"

  defp standing(%{status: :ended, ended_reason: :declined} = pairing, _current),
    do: "Asked on #{date(pairing.requested_at)}, turned down on #{date(pairing.ended_at)}"

  defp standing(%{status: :ended, approved_at: nil} = pairing, _current),
    do: "Asked on #{date(pairing.requested_at)}, replaced by a later request"

  defp standing(%{status: :ended} = pairing, _current),
    do:
      "Ran this key from #{date(pairing.approved_at)} to #{date(pairing.ended_at)}, when another agent took over"

  attr :pairing, :map, required: true

  # What the agent running the key may commit to, as its owner wrote it; everyone reads it.
  defp limits(assigns) do
    ~H"""
    <div id="key-agent-limits" class="key-limits">
      <h3>What this agent may commit</h3>
      <p :if={is_nil(@pairing.limits_written_at)} class="key-detail">
        {if @pairing.operator_wallet == @pairing.owner_wallet,
          do: "No limits written. This agent holds its own key.",
          else: "No limits written."}
      </p>

      <p :if={@pairing.limits_written_at} class="key-detail">
        Limits set by the key’s holder, last changed {date(@pairing.limits_written_at)}
      </p>
      <dl :if={@pairing.limits_written_at}>
        <div :for={{label, text} <- shown_limits(@pairing)}>
          <dt>{label}</dt>
          <dd>{text}</dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :limits, :map, required: true

  # The owner writes the four limits in their own words, starting from `limits`.
  defp limit_fields(assigns) do
    ~H"""
    <fieldset class="key-limits-fields">
      <legend>What your agent may commit.</legend>
      <p class="key-detail">They choose what to work on. You choose what yours may commit.</p>

      <div :for={{field, label} <- limit_labels()} class="key-limit-field">
        <label for={"#{@id}-#{field}"}>{label}</label>
        <textarea
          id={"#{@id}-#{field}"}
          name={"limits[#{field}]"}
          rows="4"
          maxlength="500"
          required
        >{Map.fetch!(@limits, field)}</textarea>
      </div>

      <p class="key-detail">
        Your agent reads these each time it checks in. Keyfleet can’t enforce them outside this
        site. Inside Keyfleet, your agent can never buy keys, vote or move money, whatever a fleet
        decides. Everyone can read these limits, so don’t put private details in them.
      </p>
    </fieldset>
    """
  end

  defp limit_labels,
    do: [
      money: "Money",
      information: "Your information",
      outside: "Outside Keyfleet",
      check_first: "Check with me first"
    ]

  defp shown_limits(pairing),
    do: [
      {"Money", pairing.limits_money},
      {"The owner’s information", pairing.limits_information},
      {"Outside Keyfleet", pairing.limits_outside},
      {"Check with the owner first", pairing.limits_check_first}
    ]

  # The limits the owner is changing, or the usual ones where none were written.
  defp written_limits(%{limits_written_at: nil}), do: Keys.default_limits()

  defp written_limits(pairing),
    do: %{
      money: pairing.limits_money,
      information: pairing.limits_information,
      outside: pairing.limits_outside,
      check_first: pairing.limits_check_first
    }

  attr :id, :string, required: true
  attr :wallet, :string, required: true
  attr :agent, :string, required: true

  # An agent's wallet in full, so its owner can check it character for character.
  defp address(assigns) do
    ~H"""
    <p class="key-address">
      <code>{@wallet}</code>
      <Regent.Primitives.copy_button
        id={@id}
        text={@wallet}
        aria-label={"Copy #{@agent}’s address"}
      >
        Copy address
      </Regent.Primitives.copy_button>
    </p>
    """
  end

  defp date(datetime), do: Calendar.strftime(datetime, "%-d %B %Y")

  @doc "What the key's page does with the owner's decisions on who runs the key."
  def handle_event("approve_pairing", %{"pairing" => id, "limits" => limits}, socket) do
    limits = written(limits)

    {:noreply,
     socket
     |> decide(id, &Keys.approve_pairing/3, limits, "That agent now runs this key.", @answered)
     |> keep_draft(id, limits)}
  end

  def handle_event("set_limits", %{"pairing" => id, "limits" => limits}, socket) do
    limits = written(limits)

    {:noreply,
     socket
     |> decide(id, &Keys.set_limits/3, limits, "Limits saved.", @key_moved_on)
     |> keep_draft(id, limits)}
  end

  def handle_event("decline_pairing", %{"id" => id}, socket),
    do:
      {:noreply,
       decide(socket, id, &Keys.decline_pairing/3, %{}, "Request turned down.", @answered)}

  def handle_event("detach_operator", %{"id" => id}, socket),
    do:
      {:noreply,
       decide(socket, id, &Keys.detach_operator/3, %{}, "Agent removed.", @key_moved_on)}

  @doc """
  What someone is told when a change waits on the fleet's key ownership being
  read again from the chain.
  """
  def refreshing, do: @refreshing

  @doc "What the key's page shows of the key, as the visitor may see it."
  def key_view(socket, fleet_id, token_id) do
    actor = ShellLive.human_actor(socket)
    key = Keys.current_key!(fleet_id, token_id, actor: actor, load: [:fleet])

    %{
      fleet_id: fleet_id,
      token_id: token_id,
      fleet_name: key && key.fleet.name,
      owner_wallet: key && key.owner_wallet,
      current_epoch: key && key.ownership_epoch,
      owner?: owns_key?(actor, key),
      refreshing?: not Chain.fresh?(fleet_id),
      operator: Keys.current_operator!(fleet_id, token_id, actor: actor),
      requests: Keys.list_pairing_requests!(fleet_id, token_id, actor: actor),
      history: Keys.pairing_history!(fleet_id, token_id, actor: actor)
    }
  end

  defp owns_key?(%Human{wallet_addresses: wallets}, %{owner_wallet: owner}),
    do: owner in wallets

  defp owns_key?(_actor, _key), do: false

  # The buttons act on what the page is showing; the key itself decides whether
  # the decision still applies, and the page is redrawn from the answer either
  # way, so a page left open on a key that has moved on catches up. `stale` is
  # what the owner is told when the key had already decided before the press.
  defp decide(socket, id, decision, input, message, stale) do
    with %Human{} = actor <- ShellLive.human_actor(socket),
         %{} = pairing <- Enum.find(shown_pairings(socket), &(&1.id == id)),
         {:ok, _decided} <- decision.(pairing, input, actor: actor) do
      redraw_key(socket, %{tone: :success, message: message})
    else
      refusal ->
        redraw_key(socket, %{tone: :error, message: refusal_message(refusal, stale, socket)})
    end
  end

  defp refusal_message(
         {:error, %Ash.Error.Forbidden{}},
         _stale,
         %{assigns: %{key: %{fleet_id: fleet_id}}}
       ) do
    if Chain.fresh?(fleet_id), do: @refused, else: @refreshing
  end

  defp refusal_message({:error, %Ash.Error.Invalid{errors: errors}}, stale, _socket) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) -> stale
      Enum.any?(errors, &limit_error?/1) -> @limits_unwritten
      true -> @refused
    end
  end

  defp refusal_message(_refusal, _stale, _socket), do: @refused

  # The four limits as the owner typed them, by name.
  defp written(limits),
    do: Map.new(@limit_fields, &{&1, Map.get(limits, Atom.to_string(&1), "")})

  # A refused save leaves the owner's words in the form they typed them in, so
  # they fix one limit instead of writing all four again; a saved one is gone.
  defp keep_draft(%{assigns: %{key_notice: %{tone: :error}}} = socket, id, limits),
    do: update(socket, :key_drafts, &Map.put(&1, id, limits))

  defp keep_draft(socket, id, _limits), do: update(socket, :key_drafts, &Map.delete(&1, id))

  defp limit_error?(%error{field: field})
       when error in [Ash.Error.Changes.Required, Ash.Error.Changes.InvalidArgument],
       do: field in @limit_fields

  defp limit_error?(_error), do: false

  defp redraw_key(%{assigns: %{key: %{fleet_id: fleet_id, token_id: token_id}}} = socket, notice) do
    socket
    |> assign(:key, key_view(socket, fleet_id, token_id))
    |> assign(:key_notice, notice)
  end

  defp redraw_key(socket, notice), do: assign(socket, :key_notice, notice)

  defp shown_pairings(%{assigns: %{key: %{operator: operator, requests: requests}}}),
    do: [operator | requests] |> Enum.reject(&is_nil/1)

  defp shown_pairings(_socket), do: []
end

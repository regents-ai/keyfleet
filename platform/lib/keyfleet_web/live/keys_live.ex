defmodule KeyfleetWeb.KeysLive do
  @moduledoc """
  One key's page: who owns it, who runs it, who has asked to, and everything
  that came before.

  Everything here is read from what the key itself records, so a visitor sees
  the same standing the owner does; only the owner is offered the buttons.
  """

  use KeyfleetWeb, :html

  attr :key, :map, required: true
  attr :notice, :map, default: nil

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
        <p :if={@notice} class={["key-notice", @notice.tone == :error && "key-notice--error"]}>
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
            <p class="key-detail">Attached since {date(@key.operator.approved_at)}</p>
            <.address
              id="key-agent-address"
              wallet={@key.operator.operator_wallet}
              agent={@key.operator.agent_profile.name}
            />
          </div>

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

              <div :if={@key.owner?} class="key-request-actions">
                <Regent.Primitives.button
                  type="button"
                  phx-click="approve_pairing"
                  phx-value-id={request.id}
                >
                  Approve
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
    do: "Attached since #{date(pairing.approved_at)}"

  defp standing(%{status: :active} = pairing, _current),
    do: "Attached on #{date(pairing.approved_at)}, until the key was transferred"

  defp standing(%{status: :requested, ownership_epoch: current} = pairing, current),
    do: "Asked on #{date(pairing.requested_at)}, waiting for the owner"

  defp standing(%{status: :requested} = pairing, _current),
    do: "Asked on #{date(pairing.requested_at)}, before the key was transferred"

  defp standing(%{status: :ended, ended_reason: :detached} = pairing, _current),
    do: "Attached on #{date(pairing.approved_at)}, removed on #{date(pairing.ended_at)}"

  defp standing(%{status: :ended, ended_reason: :stepped_down} = pairing, _current),
    do: "Attached on #{date(pairing.approved_at)}, stepped down on #{date(pairing.ended_at)}"

  defp standing(%{status: :ended, ended_reason: :declined} = pairing, _current),
    do: "Asked on #{date(pairing.requested_at)}, turned down on #{date(pairing.ended_at)}"

  defp standing(%{status: :ended, approved_at: nil} = pairing, _current),
    do: "Asked on #{date(pairing.requested_at)}, replaced by a later request"

  defp standing(%{status: :ended} = pairing, _current),
    do: "Attached on #{date(pairing.approved_at)}, replaced on #{date(pairing.ended_at)}"

  attr :id, :string, required: true
  attr :wallet, :string, required: true
  attr :agent, :string, required: true

  # An agent's wallet in full, so its owner can check it character for character.
  defp address(assigns) do
    ~H"""
    <p class="key-address">
      <code>{@wallet}</code>
      <Regent.Primitives.button
        id={@id}
        type="button"
        variant="secondary"
        phx-hook="CopyText"
        data-copy-text={@wallet}
        aria-label={"Copy #{@agent}’s address"}
      >
        Copy address
      </Regent.Primitives.button>
    </p>
    """
  end

  defp date(datetime), do: Calendar.strftime(datetime, "%-d %B %Y")
end

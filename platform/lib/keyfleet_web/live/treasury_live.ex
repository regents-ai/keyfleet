defmodule KeyfleetWeb.TreasuryLive do
  @moduledoc """
  Public treasury balances, wallet actions, history, permissions and contracts.
  Uses the existing indexed reads and wallet approval flow. Under the money
  buttons, once routine upkeep is set up: whether it is running, what its
  latest check did for the fleet, each line in a few plain words, and its
  latest presses with their transactions on Basescan.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]
  import KeyfleetWeb.Components.LoadFailed

  alias Keyfleet.Authority
  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.Components.AddressLinks
  alias KeyfleetWeb.Components.FleetRisks
  alias KeyfleetWeb.ProposalsLive
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.WalletPanel

  attr :page, :any, required: true, doc: "the Treasury page as read, or `:unreadable`"
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  # Drawn inside the fleet's page, under its name and bar (`KeyfleetWeb.FleetLive`).
  def page(%{page: :unreadable} = assigns) do
    ~H"""
    <article id="treasury-page" class="proposals-page">
      <section id="treasury-unreadable" class="proposals-panel">
        <.load_failed />
      </section>
    </article>
    """
  end

  def page(assigns) do
    ~H"""
    <article id="treasury-page" class="proposals-page">
      <p
        :if={@page.catching_up?}
        id="treasury-catching-up"
        class="proposals-notice"
        role="status"
      >
        Treasury figures are catching up. Check the timestamp below before acting.
      </p>

      <ProposalsLive.treasury
        :if={@page.treasury}
        treasury={@page.treasury}
        page={@page}
        actor={@actor}
        lease={@lease}
      />

      <.routine_upkeep :if={@page.upkeep} upkeep={@page.upkeep} />

      <%!-- A fleet not yet on chain has no treasury to show. --%>
      <section :if={!@page.treasury} id="treasury-not-live" class="proposals-panel">
        <Regent.Primitives.empty_state
          class="kf-empty"
          title="This fleet’s treasury opens once the fleet is live."
        >
          <:action>
            <.link
              class="rg-button rg-button--secondary"
              patch={Keyfleet.Fleets.path(@page.fleet_id)}
            >
              <span class="rg-button__label">Back to the fleet</span>
            </.link>
          </:action>
        </Regent.Primitives.empty_state>
      </section>

      <section
        :if={@page.carried != [] or @page.treasury}
        id="treasury-carried"
        class="proposals-panel"
        aria-labelledby="treasury-carried-title"
      >
        <h2 id="treasury-carried-title">Votes carried out</h2>
        <Regent.Primitives.empty_state
          :if={@page.carried == []}
          id="treasury-carried-empty"
          class="kf-empty"
          title="No votes have been carried out yet."
        >
          <:action>
            <.link
              class="rg-button rg-button--secondary"
              patch={ProposalsPage.list_path(@page.fleet_id)}
            >
              <span class="rg-button__label">See proposals</span>
            </.link>
          </:action>
        </Regent.Primitives.empty_state>
        <ol :if={@page.carried != []} id="treasury-carried-list" class="proposals-lines">
          <li :for={proposal <- @page.carried} data-proposal={proposal.number}>
            <.link patch={ProposalsPage.detail_path(@page.fleet_id, proposal.number)}>
              Proposal {proposal.number}
            </.link>
            <span :if={proposal.text} class="proposals-words proposals-words--short">
              {proposal.text}
            </span>
          </li>
        </ol>
      </section>

      <section id="treasury-rules" class="proposals-panel" aria-labelledby="treasury-rules-title">
        <h2 id="treasury-rules-title">Permissions & contracts</h2>
        <dl class="treasury-permissions">
          <div :for={row <- Authority.treasury_rows()}>
            <dt>{row.what}</dt>
            <dd>{row.who}<span class="proposals-detail">{Authority.needs(row)}</span></dd>
          </div>
        </dl>
        <p class="proposals-detail">Each action asks the acting wallet to approve and send it.</p>
        <div :if={@page.manager_address} class="proposals-address">
          <span>Manager</span>
          <code title={@page.manager_address}>{RegentFormat.short_address(@page.manager_address)}</code>
          <Regent.Primitives.copy_button
            id="fleet-manager-copy"
            text={@page.manager_address}
            variant="quiet"
            aria-label="Copy manager address"
            title="Copy manager address"
          >
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              aria-hidden="true"
            ><rect x="8" y="8" width="12" height="12" rx="2" /><path d="M16 8V4H4v12h4" /></svg>
          </Regent.Primitives.copy_button>
          <a
            id="fleet-contract-link"
            href={AddressLinks.basescan(@page.manager_address)}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="View manager on BaseScan"
            title="View verified manager on BaseScan"
          ><svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            aria-hidden="true"
          ><path d="M6 18 18 6M6 6h12v12" /></svg></a>
        </div>
        <Regent.Primitives.disclosure
          id="treasury-fleet-details"
          summary="Fleet details & token launch"
        >
          <p>{Rules.pricing(@page.fleet_id)}</p>
          <.progress :if={@page.deployed?} page={@page} />
          <.launch_upkeep :if={@page.deployed?} page={@page} actor={@actor} lease={@lease} />
        </Regent.Primitives.disclosure>
        <FleetRisks.disclosure id="treasury-risks" />
      </section>
    </article>
    """
  end

  attr :upkeep, :map, required: true, doc: "as `Keyfleet.Treasury.upkeep/1` reads it"

  # What Keyfleet's own presses of the routine buttons last did for the fleet.
  defp routine_upkeep(assigns) do
    ~H"""
    <section id="treasury-upkeep" class="proposals-panel" aria-labelledby="treasury-upkeep-title">
      <h2 id="treasury-upkeep-title">
        Routine upkeep
        <span id="treasury-upkeep-state" class="proposals-badge">
          {if @upkeep.paused?, do: "Paused", else: "Running"}
        </span>
        <Regent.Primitives.tip id="treasury-upkeep-tip" label="About routine upkeep">
          Keyfleet presses the routine buttons above when they come due, with the same checks, and anyone can still press them first.
        </Regent.Primitives.tip>
      </h2>
      <p class="proposals-detail">
        <span :if={@upkeep.paused?}>Paused for now. Every button above still works.</span>
        <span :if={@upkeep.checked_at} id="treasury-upkeep-checked">
          Last checked
          <time datetime={DateTime.to_iso8601(@upkeep.checked_at)}>
            {ProposalsLive.at(@upkeep.checked_at)}
          </time>
        </span>
        <span :if={is_nil(@upkeep.checked_at)}>Not checked yet.</span>
      </p>
      <ol :if={@upkeep.lines != []} id="treasury-upkeep-lines" class="proposals-lines">
        <li :for={line <- @upkeep.lines} data-step={line.step} data-outcome={line.outcome}>
          <.upkeep_line line={line} />
        </li>
      </ol>
      <h3 :if={@upkeep.recent != []} id="treasury-upkeep-recent-title">Recent</h3>
      <ol :if={@upkeep.recent != []} id="treasury-upkeep-recent" class="proposals-lines">
        <li :for={line <- @upkeep.recent} data-step={line.step} data-outcome={line.outcome}>
          <.upkeep_line line={line} />
          <span class="proposals-detail">
            <time datetime={DateTime.to_iso8601(line.at)}>{ProposalsLive.at(line.at)}</time>
          </span>
        </li>
      </ol>
    </section>
    """
  end

  attr :line, :map, required: true

  # One thing the upkeep did or held back, with its transaction once it has one.
  defp upkeep_line(assigns) do
    ~H"""
    <span>
      {upkeep_said(@line)}
      <a
        :if={@line.transaction_hash}
        href={AddressLinks.basescan_tx(@line.transaction_hash)}
        target="_blank"
        rel="noopener noreferrer"
        title="View the transaction on BaseScan"
      >
        View on BaseScan
      </a>
    </span>
    """
  end

  # A line of the upkeep in a few words: what was done, what is on its way,
  # or why nothing was sent, one clause for each.
  defp upkeep_said(%{outcome: :done, step: :run_split}),
    do: "Released the Daily Treasury Slice to Keys"

  defp upkeep_said(%{outcome: :done, step: :send_share}),
    do: "Sent the share owed to REGENT staking"

  defp upkeep_said(%{outcome: :done, step: :convert, amount: nil}),
    do: "Skipped USDC that couldn’t be turned into REGENT"

  defp upkeep_said(%{outcome: :done, step: :convert, amount: amount}),
    do: "Turned #{usdc(amount)} into REGENT"

  defp upkeep_said(%{outcome: :done, step: :carry_out, proposal: number}),
    do: "Carried out Proposal #{number}"

  defp upkeep_said(%{outcome: :sent, step: nil}), do: "Waiting for the network to confirm"

  defp upkeep_said(%{outcome: :sent} = line),
    do: "#{upkeep_doing(line)}, waiting for the network to confirm"

  defp upkeep_said(%{reason: :not_due, step: :run_split, opens_at: opens_at}),
    do: "Next release #{ProposalsLive.at(opens_at)}"

  defp upkeep_said(%{reason: :not_due, step: :convert, opens_at: opens_at}),
    do: "USDC turns into REGENT again from #{ProposalsLive.at(opens_at)}"

  defp upkeep_said(%{reason: :not_due, step: :carry_out, proposal: number, opens_at: opens_at}),
    do: "Proposal #{number} can be carried out from #{ProposalsLive.at(opens_at)}"

  defp upkeep_said(%{reason: :not_due, opens_at: opens_at}),
    do: "Not due until #{ProposalsLive.at(opens_at)}"

  defp upkeep_said(%{reason: :no_keys_sold}),
    do: "No Keys sold yet, so there is no one to share with"

  defp upkeep_said(%{reason: :nothing_owed}), do: "Nothing owed to REGENT staking"
  defp upkeep_said(%{reason: :nothing_queued}), do: "No USDC waiting to turn into REGENT"

  defp upkeep_said(%{reason: :refused} = line),
    do: "#{upkeep_doing(line)} would be refused right now, so it waits"

  defp upkeep_said(%{reason: :unread}), do: "Couldn’t reach the network, trying again shortly"

  defp upkeep_said(%{reason: :no_eth_for_gas}),
    do: "Waiting for Keyfleet to add ETH for network fees"

  defp upkeep_said(%{reason: :fees_high}), do: "Waiting for network fees to come down"

  defp upkeep_said(%{reason: :earlier_waiting}),
    do: "Waiting for an earlier transaction to confirm"

  defp upkeep_said(%{reason: :reverted} = line), do: "#{upkeep_doing(line)} didn’t go through"
  defp upkeep_said(%{reason: :not_sent} = line), do: "#{upkeep_doing(line)} couldn’t be sent"

  # What a line was about, as it was under way.
  defp upkeep_doing(%{step: :run_split}), do: "Releasing the Daily Treasury Slice to Keys"
  defp upkeep_doing(%{step: :send_share}), do: "Sending the share owed to REGENT staking"
  defp upkeep_doing(%{step: :convert}), do: "Turning USDC into REGENT"
  defp upkeep_doing(%{step: :carry_out, proposal: number}), do: "Carrying out Proposal #{number}"
  defp upkeep_doing(%{step: nil}), do: "A transaction"

  defp usdc(amount), do: "#{ProposalsPage.units(amount, 6)} USDC"

  attr :page, :map, required: true

  # The fleet's sales so far.
  defp progress(assigns) do
    ~H"""
    <h3 id="fleet-progress-title">Progress</h3>
    <p :if={@page.catching_up?} class="proposals-detail">Figures are catching up.</p>
    <dl :if={not @page.catching_up?} class="proposals-facts">
      <div>
        <dt>Keys issued</dt>
        <dd :if={@page.progress.max_supply}>
          {grouped(@page.progress.total_minted)} of {grouped(@page.progress.max_supply)}
        </dd>
        <dd :if={is_nil(@page.progress.max_supply)}>
          {grouped(@page.progress.total_minted)}
        </dd>
      </div>
      <div :if={@page.progress.completed_levels}>
        <dt>Levels complete</dt>
        <dd>{@page.progress.completed_levels}</dd>
      </div>
    </dl>
    <p
      :if={not @page.catching_up? and is_nil(@page.progress.max_supply)}
      id="fleet-levels-keep-opening"
      class="proposals-detail"
    >
      New levels keep opening.
    </p>
    <p
      :if={not @page.catching_up? and is_nil(@page.progress.next_price)}
      class="proposals-detail"
    >
      Every Key has been issued.
    </p>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  # The fleet's token launch, once an approved proposal has made one: four
  # buttons anyone may press to settle its sale, add its token to the daily
  # split, release the tokens set aside for the treasury and collect the
  # pool's fees.
  defp launch_upkeep(assigns) do
    ~H"""
    <section id="fleet-launch" aria-labelledby="fleet-launch-title">
      <h3 id="fleet-launch-title">
        Token launch
        <Regent.Primitives.tip id="fleet-launch-tip" label="About the token launch">
          A launch the fleet voted for sells its token through Autolaunch. Once the sale ends, anyone can settle it, add the token to the Daily Treasury Slice to Keys, release the tokens set aside for the treasury, and collect the pool’s fees for it.
        </Regent.Primitives.tip>
      </h3>
      <.live_component
        module={WalletPanel}
        id="fleet-launch-action"
        flow={:launch_upkeep}
        fleet={%{fleet_id: @page.fleet_id, chain_id: @page.chain_id}}
        actor={@actor}
        lease={@lease}
      >
        <:notes :let={panel}>
          <dl
            :if={is_nil(@actor) and launched?(panel)}
            id="fleet-launch-facts"
            class="proposals-facts"
          >
            <div>
              <dt>Token</dt>
              <dd>
                <code title={WalletPanel.figures(panel).token}>
                  {RegentFormat.short_address(WalletPanel.figures(panel).token)}
                </code>
              </dd>
            </div>
            <div>
              <dt>Sale</dt>
              <dd id="fleet-launch-sale">{sale(panel)}</dd>
            </div>
            <div>
              <dt>Daily Treasury Slice to Keys</dt>
              <dd id="fleet-launch-split">
                {if WalletPanel.figures(panel).bound?, do: "Included", else: "Not yet"}
              </dd>
            </div>
          </dl>
        </:notes>
        <:buttons :let={panel}>
          <WalletPanel.step_button
            :if={launched?(panel)}
            panel={panel}
            step="settle"
            id="fleet-launch-settle"
          >
            Settle sale
          </WalletPanel.step_button>
          <WalletPanel.step_button
            :if={launched?(panel)}
            panel={panel}
            step="bind"
            id="fleet-launch-bind"
          >
            Add to slice
          </WalletPanel.step_button>
          <WalletPanel.step_button
            :if={launched?(panel)}
            panel={panel}
            step="release"
            id="fleet-launch-release"
          >
            Release tokens
          </WalletPanel.step_button>
          <WalletPanel.step_button
            :if={launched?(panel)}
            panel={panel}
            step="collect"
            id="fleet-launch-collect"
          >
            Collect fees
          </WalletPanel.step_button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  # Until an approved proposal has made a launch, there is nothing to upkeep.
  defp launched?(panel), do: WalletPanel.figures(panel)[:launch_id] != nil

  # Where the launch's sale stands, for a visitor, who sees no buttons.
  defp sale(panel) do
    case WalletPanel.figures(panel) do
      %{lifecycle: :active, blocked: %{"settle" => :sale_running}} -> "On sale"
      %{lifecycle: :active} -> "Ended, ready to settle"
      %{lifecycle: :graduated} -> "Sold"
      %{lifecycle: :failed} -> "Didn’t sell"
      %{lifecycle: :none} -> "Not started"
    end
  end
end

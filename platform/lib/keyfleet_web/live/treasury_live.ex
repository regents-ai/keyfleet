defmodule KeyfleetWeb.TreasuryLive do
  @moduledoc """
  Public treasury balances, wallet actions, history, permissions and contracts.
  Uses the existing indexed reads and wallet approval flow.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]

  alias Keyfleet.Authority
  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.Components.AddressLinks
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
        <h2>This page couldn’t be loaded.</h2>
        <p>Refresh the page to try again.</p>
      </section>
    </article>
    """
  end

  def page(assigns) do
    ~H"""
    <article id="treasury-page" class="proposals-page">
      <p :if={@page.catching_up?} class="proposals-notice" role="status">
        Treasury figures are catching up. Check the timestamp below before acting.
      </p>

      <ProposalsLive.treasury
        :if={@page.treasury}
        treasury={@page.treasury}
        page={@page}
        actor={@actor}
        lease={@lease}
      />

      <section
        :if={@page.carried != []}
        id="treasury-carried"
        class="proposals-panel"
        aria-labelledby="treasury-carried-title"
      >
        <h2 id="treasury-carried-title">Votes carried out</h2>
        <ol id="treasury-carried-list" class="proposals-lines">
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
      </section>
    </article>
    """
  end

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

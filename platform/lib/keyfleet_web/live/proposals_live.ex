defmodule KeyfleetWeb.ProposalsLive do
  @moduledoc """
  A fleet's proposals, for anyone to read: what its key holders have put to
  a vote, how each vote stands, what each would do in plain words with every
  vote cast on it; and beside them the treasury they vote on.

  Once the fleet is on chain, its wallet buttons sit beside what they act on:
  marking keys present, proposing, the treasury's daily split, returning an
  advance and sending Regents its share on the list; voting, carrying out
  and cancelling on a proposal's own page. Every press goes to the wallet,
  except one the chain's own state at the latest block makes certain to fail,
  whose button stays in view, disabled, with a few words saying why.

  Everything shown is what `KeyfleetWeb.ProposalsPage` read.
  """

  use KeyfleetWeb, :html

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.Components.Count
  alias KeyfleetWeb.Components.PresenceCard
  alias KeyfleetWeb.Motion
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.WalletPanel
  alias KeyfleetWeb.WalletWords

  # How long a proposals page waits after a notice that the fleet's proposal
  # records or balances changed before it reads them, so a burst is read once.
  @proposals_refresh_after 1_000

  @status_words %{
    open: "Open",
    waiting: "Approved, waiting",
    approved: "Approved",
    rejected: "Not approved",
    executed: "Carried out",
    cancelled: "Cancelled",
    execution_expired: "Expired"
  }

  # Each kind of proposal the form makes, as it names them.
  @kinds [
    {"decision", "Decision"},
    {"pay", "Payment"},
    {"advance", "Advance"},
    {"rate", "Daily split rate"},
    {"edits", "A Key’s edits"},
    {"signature", "Signature"},
    {"launch", "Token launch"}
  ]

  @history_words %{
    forwarded: "Received",
    protocol_share_sent: "Sent to Regents",
    paid: "Paid",
    advanced: "Advanced",
    split_allocated: "Shared with Key holders"
  }

  attr :page, :any, required: true, doc: "the proposals as read, or `:unreadable`"
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  def list(%{page: :unreadable} = assigns), do: ~H|<.unreadable id="proposals-page" />|

  def list(%{page: %{fleet_name: nil}} = assigns),
    do: ~H|<.missing_fleet id="proposals-page" />|

  def list(assigns) do
    ~H"""
    <article id="proposals-page" class="proposals-page">
      <header class="proposals-heading">
        <p class="proposals-kicker">
          <.link patch={"/app/fleets/#{@page.fleet_id}"}>{@page.fleet_name}</.link>
        </p>
        <h1 tabindex="-1">Proposals</h1>
      </header>

      <.catching_up :if={@page.catching_up?} />

      <PresenceCard.card
        :if={@page.deployed?}
        id="proposals-present"
        class="proposals-panel"
        fleet={fleet(@page)}
        actor={@actor}
        lease={@lease}
        tool="mark_present"
      />

      <section class="proposals-panel" aria-labelledby="proposals-list-title">
        <h2 id="proposals-list-title">
          Every proposal <.approval_rule id="proposals-rule" />
        </h2>

        <p :if={@page.proposals == [] and @page.first_page?} id="proposals-empty">
          No proposals yet.
        </p>

        <ol :if={@page.proposals != []} id="proposals-list" class="proposals-list">
          <li
            :for={proposal <- @page.proposals}
            class="proposals-card"
            data-proposal={proposal.number}
          >
            <p class="proposals-kind">
              <span class="proposals-badge" data-status={proposal.status}>
                {status_word(proposal)}
              </span>
            </p>
            <h3>
              <.link patch={ProposalsPage.detail_path(@page.fleet_id, proposal.number)}>
                Proposal {proposal.number}
              </.link>
            </h3>
            <p :if={proposal.text} class="proposals-words proposals-words--short">
              {proposal.text}
            </p>
            <p class="proposals-detail">
              <.tally proposal={proposal} />
            </p>
          </li>
        </ol>

        <nav
          :if={@page.older || not @page.first_page?}
          class="proposals-pages"
          aria-label="More proposals"
        >
          <.link
            :if={not @page.first_page?}
            id="proposals-newest"
            patch={ProposalsPage.list_path(@page.fleet_id)}
          >
            Newest proposals
          </.link>
          <.link :if={@page.older} id="proposals-older" patch={@page.older}>Older proposals</.link>
        </nav>
      </section>

      <.propose :if={@page.deployed?} page={@page} actor={@actor} lease={@lease} />
      <.treasury
        :if={@page.treasury}
        treasury={@page.treasury}
        page={@page}
        actor={@actor}
        lease={@lease}
      />
    </article>
    """
  end

  attr :page, :any, required: true, doc: "the proposal as read, or `:unreadable`"
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  def detail(%{page: :unreadable} = assigns), do: ~H|<.unreadable id="proposal-page" />|

  def detail(%{page: %{fleet_name: nil}} = assigns),
    do: ~H|<.missing_fleet id="proposal-page" />|

  def detail(%{page: %{proposal: nil}} = assigns) do
    ~H"""
    <article id="proposal-page" class="proposals-page">
      <.detail_heading page={@page} />
      <section id="proposal-missing" class="proposals-panel">
        <h2>There is no proposal {@page.number} in this fleet yet.</h2>
        <.link patch={ProposalsPage.list_path(@page.fleet_id)}>See every proposal</.link>
      </section>
    </article>
    """
  end

  def detail(assigns) do
    ~H"""
    <article id="proposal-page" class="proposals-page">
      <.detail_heading page={@page} />
      <.catching_up :if={@page.catching_up?} />

      <div class="proposals-grid">
        <.standing on_chain={@page.on_chain} proposal={@page.proposal} />

        <section
          :if={@page.deployed?}
          id="proposal-vote"
          class="proposals-panel"
          aria-labelledby="proposal-vote-title"
        >
          <h2 id="proposal-vote-title">
            Vote
            <Regent.Primitives.tip id="proposal-vote-tip" label="About voting">
              Every Key you hold votes together, and so does every Key you hold a shard of while its agent voting is on. Voting again changes the vote until voting closes.
            </Regent.Primitives.tip>
          </h2>
          <.live_component
            module={WalletPanel}
            id="proposal-vote-action"
            class="proposals-action"
            flow={:ballot}
            tool="vote"
            fleet={fleet(@page)}
            actor={@actor}
            lease={@lease}
            proposal={@page.proposal.number}
          >
            <:buttons :let={panel}>
              <WalletPanel.step_button panel={panel} step="yes" id="proposal-vote-yes">
                Yes
              </WalletPanel.step_button>
              <WalletPanel.step_button
                panel={panel}
                step="no"
                id="proposal-vote-no"
                variant="secondary"
              >
                No
              </WalletPanel.step_button>
              <WalletPanel.step_button
                panel={panel}
                step="abstain"
                id="proposal-vote-abstain"
                variant="secondary"
              >
                Abstain
              </WalletPanel.step_button>
            </:buttons>
          </.live_component>
        </section>

        <section
          :if={@page.deployed?}
          id="proposal-carry-out"
          class="proposals-panel"
          aria-labelledby="proposal-carry-out-title"
        >
          <h2 id="proposal-carry-out-title">
            Carry it out
            <Regent.Primitives.tip id="proposal-carry-out-tip" label="About carrying it out">
              Anyone can carry out an approved proposal until its time runs out. A proposal that moves money waits a day after voting closes, then has 48 hours; any other can be carried out once voting closes. It makes exactly the calls below.
            </Regent.Primitives.tip>
          </h2>
          <.live_component
            module={WalletPanel}
            id="proposal-carry-out-action"
            class="proposals-action"
            flow={:carry_out}
            tool="carry_out"
            fleet={fleet(@page)}
            actor={@actor}
            lease={@lease}
            proposal={@page.proposal.number}
          >
            <:buttons :let={panel}>
              <WalletPanel.step_button panel={panel} step="carry_out" id="proposal-carry-out-button">
                Carry it out
              </WalletPanel.step_button>
            </:buttons>
          </.live_component>
          <.live_component
            module={WalletPanel}
            id="proposal-cancel-action"
            class="proposals-action"
            flow={:cancel}
            tool="cancel_proposal"
            fleet={fleet(@page)}
            actor={@actor}
            lease={@lease}
            proposal={@page.proposal.number}
          >
            <:buttons :let={panel}>
              <WalletPanel.step_button
                panel={panel}
                step="cancel"
                id="proposal-cancel-button"
                variant="quiet"
              >
                Cancel proposal
              </WalletPanel.step_button>
            </:buttons>
          </.live_component>
        </section>

        <section class="proposals-panel" aria-labelledby="proposal-content-title">
          <h2 id="proposal-content-title">
            What it does
            <Regent.Primitives.tip
              :if={@page.proposal.calls != []}
              id="proposal-calls-tip"
              label="About these calls"
            >
              Carrying it out makes exactly these calls, in this order. The words are Keyfleet’s reading of each one; the contract, function and data are what the network runs.
            </Regent.Primitives.tip>
          </h2>
          <p :if={@page.proposal.text} id="proposal-text" class="proposals-words">
            {@page.proposal.text}
          </p>
          <p :if={@page.proposal.calls == []} id="proposal-no-calls">
            A decision. Nothing moves.
          </p>
          <ol :if={@page.proposal.calls != []} id="proposal-calls" class="proposals-lines">
            <li :for={call <- @page.proposal.calls}>
              <p class="proposals-call-words">
                <span>{call.text}</span>
                <code :if={call.address}>{call.address}</code>
              </p>
              <p :if={call.today} class="proposals-detail">
                About {call.today.text} at today’s balance
              </p>
              <dl class="proposals-call">
                <div>
                  <dt>Contract</dt>
                  <dd>{call.contract} <code>{call.target}</code></dd>
                </div>
                <div>
                  <dt>Function</dt>
                  <dd><code>{call.function || "Unknown"}</code></dd>
                </div>
                <div>
                  <dt>Data</dt>
                  <dd><code class="proposals-call-data">{call.data}</code></dd>
                </div>
              </dl>
            </li>
          </ol>
          <p id="proposal-proposer" class="proposals-detail">
            Key {Rules.grouped(@page.proposal.author_key)},
            <.wallet address={@page.proposal.proposer} />
            <Regent.Primitives.tip id="proposal-content-tip" label="About the proposal’s text">
              {if @page.proposal.text,
                do: "Its words match the code kept on the network:",
                else: "Its words weren’t saved on Keyfleet. Its code on the network is"} {@page.proposal.content_hash}.
            </Regent.Primitives.tip>
          </p>
          <p :if={@page.proposal.executor} id="proposal-executor" class="proposals-detail">
            Carried out by <.wallet address={@page.proposal.executor} />
          </p>
          <p :if={@page.proposal.cancelled_by} id="proposal-canceller" class="proposals-detail">
            Cancelled by <.wallet address={@page.proposal.cancelled_by} />
          </p>
        </section>

        <section class="proposals-panel proposals-votes" aria-labelledby="proposal-votes-title">
          <h2 id="proposal-votes-title">Votes</h2>
          <p :if={@page.votes == [] and is_nil(@page.first_votes)} id="proposal-no-votes">
            No votes yet.
          </p>
          <ol :if={@page.votes != []} id="proposal-votes" class="proposals-lines">
            <li :for={vote <- @page.votes} data-vote={vote.id}>
              <span>{vote_word(vote.choice)}</span>
              <span>{RegentFormat.short_address(vote.voter)}, with {key_list(vote.keys)}</span>
            </li>
          </ol>
          <nav
            :if={@page.more_votes || @page.first_votes}
            class="proposals-pages"
            aria-label="More votes"
          >
            <.link :if={@page.first_votes} id="proposal-first-votes" patch={@page.first_votes}>
              First votes
            </.link>
            <.link :if={@page.more_votes} id="proposal-more-votes" patch={@page.more_votes}>
              Later votes
            </.link>
          </nav>
        </section>
      </div>
    </article>
    """
  end

  attr :on_chain, :any, required: true, doc: "the proposal as the vote contract says now"
  attr :proposal, :map, required: true

  # Where the proposal stands, every figure as the vote contract says at the
  # latest block. A fleet not yet on chain has none.
  defp standing(assigns) do
    ~H"""
    <section class="proposals-panel" aria-labelledby="proposal-outcome-title">
      <h2 id="proposal-outcome-title">
        <span :if={is_map(@on_chain)} id="proposal-status" data-status={@on_chain.status}>
          {status_word(@on_chain)}
        </span>
        <span :if={!is_map(@on_chain)} id="proposal-status">Standing</span>
        <.approval_rule id="proposal-rule" />
      </h2>
      <p :if={@on_chain == :unreadable} id="proposal-unread" class="proposals-notice" role="status">
        Can’t reach the network right now. Refresh to try again.
      </p>
      <dl :if={is_map(@on_chain)} class="proposals-facts">
        <div>
          <dt>Yes</dt>
          <dd id="proposal-yes">
            <Count.count id="proposal-yes-count" value={@on_chain.yes} one="Key" many="Keys" />
          </dd>
        </div>
        <div>
          <dt>No</dt>
          <dd id="proposal-no">
            <Count.count id="proposal-no-count" value={@on_chain.no} one="Key" many="Keys" />
          </dd>
        </div>
        <div>
          <dt>Abstain</dt>
          <dd id="proposal-abstain">
            <Count.count id="proposal-abstain-count" value={@on_chain.abstain} one="Key" many="Keys" />
          </dd>
        </div>
        <div>
          <dt>
            Keys counted
            <Regent.Primitives.tip id="proposal-counted-tip" label="About Keys counted">
              {@on_chain.e0} present when it opened, and {@on_chain.late} more that voted since.
            </Regent.Primitives.tip>
          </dt>
          <dd id="proposal-counted">
            <Count.count id="proposal-counted-count" value={@on_chain.counted} one="Key" many="Keys" />
          </dd>
        </div>
      </dl>
      <dl class="proposals-facts">
        <div>
          <dt>Closes</dt>
          <dd id="proposal-closes">{at(@proposal.closes_at)}</dd>
        </div>
        <div :if={@proposal.carry_out_from}>
          <dt>Can be carried out from</dt>
          <dd id="proposal-carry-out-from">{at(@proposal.carry_out_from)}</dd>
        </div>
        <div>
          <dt>Carry out by</dt>
          <dd id="proposal-expiry">{at(@proposal.execution_expiry)}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  # One form for every kind of proposal: its kind, the Key it is made with,
  # its text, and the fields its kind needs. Every
  # field stays in the form, so the steps always match what it holds; only
  # the kind chosen shows its own.
  defp propose(assigns) do
    assigns = assign(assigns, kinds: @kinds)

    ~H"""
    <section id="propose" class="proposals-panel" aria-labelledby="propose-title">
      <h2 id="propose-title">
        Propose
        <Regent.Primitives.tip id="propose-tip" label="About proposing">
          Proposing with a Key you hold, or one you hold a shard of while its agent voting is on, opens a 24-hour vote. A payment or advance names one token and a share of the treasury’s balance of it when it is carried out, a day after its vote passes. Approved proposals are carried out exactly as written.
        </Regent.Primitives.tip>
      </h2>
      <.live_component
        module={WalletPanel}
        id="propose-action"
        class="proposals-action"
        flow={:propose}
        tool="propose"
        fleet={fleet(@page)}
        actor={@actor}
        lease={@lease}
        inputs={
          %{
            "kind" => "decision",
            "key" => "",
            "text" => "",
            "asset" => hd(@page.propose.assets).address,
            "share" => "",
            "recipient" => "",
            "rate" => "",
            "target" => "",
            "restricted" => "true",
            "signature" => "approve",
            "issued_at" => "",
            "name" => "",
            "symbol" => "",
            "description" => "",
            "website" => "",
            "image" => ""
          }
        }
      >
        <:fields :let={panel}>
          <div class="proposals-form">
            <.select_field
              id="propose-kind"
              name="kind"
              label="Kind"
              value={panel.inputs["kind"]}
              options={@kinds}
            />
            <.text_field
              id="propose-key"
              name="key"
              label="Key"
              inputmode="numeric"
              value={panel.inputs["key"]}
            />
            <.text_area
              id="propose-text"
              name="text"
              label="Proposal"
              rows="4"
              value={panel.inputs["text"]}
            />

            <div class="proposals-form" hidden={panel.inputs["kind"] not in ["pay", "advance"]}>
              <.select_field
                id="propose-asset"
                name="asset"
                label="Token"
                value={panel.inputs["asset"]}
                options={Enum.map(@page.propose.assets, &{&1.address, &1.name})}
              />
              <.text_field
                id="propose-share"
                name="share"
                label="Share of the treasury’s balance, %"
                inputmode="decimal"
                value={panel.inputs["share"]}
              >
                0.0001 to 99
              </.text_field>
              <.text_field
                id="propose-recipient"
                name="recipient"
                label="To wallet"
                value={panel.inputs["recipient"]}
              />
            </div>

            <div class="proposals-form" hidden={panel.inputs["kind"] != "rate"}>
              <.text_field
                id="propose-rate"
                name="rate"
                label="Daily split, %"
                inputmode="decimal"
                value={panel.inputs["rate"]}
              >
                0.1 to 2
              </.text_field>
            </div>

            <div class="proposals-form" hidden={panel.inputs["kind"] != "edits"}>
              <.text_field
                id="propose-target"
                name="target"
                label="Key"
                inputmode="numeric"
                value={panel.inputs["target"]}
              />
              <.select_field
                id="propose-restricted"
                name="restricted"
                label="Edits"
                value={panel.inputs["restricted"]}
                options={[{"true", "Restrict"}, {"false", "Allow"}]}
              />
            </div>

            <div class="proposals-form" hidden={panel.inputs["kind"] != "signature"}>
              <.select_field
                id="propose-signature"
                name="signature"
                label="Signature"
                value={panel.inputs["signature"]}
                options={[{"approve", "Sign"}, {"revoke", "Withdraw"}]}
              />
              <.text_field
                id="propose-issued-at"
                name="issued_at"
                label="Request time"
                value={panel.inputs["issued_at"]}
              />
            </div>

            <div class="proposals-form" hidden={panel.inputs["kind"] != "launch"}>
              <.text_field id="propose-name" name="name" label="Name" value={panel.inputs["name"]} />
              <.text_field
                id="propose-symbol"
                name="symbol"
                label="Symbol"
                value={panel.inputs["symbol"]}
              />
              <.text_area
                id="propose-description"
                name="description"
                label="Description"
                rows="3"
                value={panel.inputs["description"]}
              />
              <.text_field
                id="propose-website"
                name="website"
                label="Website"
                value={panel.inputs["website"]}
              />
              <.text_field
                id="propose-image"
                name="image"
                label="Image link"
                value={panel.inputs["image"]}
              />
            </div>
          </div>
        </:fields>
        <:buttons :let={panel}>
          <WalletPanel.step_button panel={panel} step="propose" id="propose-button">
            Propose
          </WalletPanel.step_button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :treasury, :map, required: true
  attr :page, :map, required: true
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  # The shared money: the treasury's address on Base, to check and to send to;
  # each asset's balance and what is set aside for claims,
  # the daily split's rate and when it next opens with its preview, the
  # advances still out, and the protocol share owed to Regents.
  defp treasury(assigns) do
    ~H"""
    <section id="proposals-budget" class="proposals-panel" aria-labelledby="proposals-budget-title">
      <h2 id="proposals-budget-title">Treasury</h2>

      <p id="proposals-treasury-address" class="proposals-address">
        <a
          id="proposals-treasury-link"
          href={"https://basescan.org/address/#{@treasury.address}"}
          title="See it on Basescan"
          rel="noopener noreferrer"
          target="_blank"
        >
          <code id="proposals-treasury-address-text">{@treasury.address}</code>
        </a>
        <Regent.Primitives.copy_button
          id="proposals-treasury-copy"
          variant="quiet"
          target="proposals-treasury-address-text"
        >
          Copy
        </Regent.Primitives.copy_button>
      </p>

      <p :if={not @treasury.read?} id="proposals-budget-pending" class="proposals-detail">
        Reading…
      </p>

      <div
        :if={@treasury.read?}
        id="proposals-figures"
        class="proposals-plan"
        phx-hook="MotionCount"
        data-variant={Motion.standard("count")}
      >
        <table id="proposals-balances" class="proposals-table">
          <thead>
            <tr>
              <th scope="col">Balance</th>
              <th scope="col">
                Set aside
                <Regent.Primitives.tip id="proposals-backed-tip" label="About set aside">
                  Already shared with Keys and waiting to be claimed. It isn’t the treasury’s to spend.
                </Regent.Primitives.tip>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={balance <- @treasury.balances} data-asset={balance.asset}>
              <td><.amount value={balance.held} count /></td>
              <td><.amount value={balance.backed} count /></td>
            </tr>
          </tbody>
        </table>
        <dl id="proposals-split" class="proposals-facts">
          <div>
            <dt>Daily Treasury Slice to Keys</dt>
            <dd>{@treasury.split_rate}</dd>
          </div>
          <div :if={@treasury.next_run_at}>
            <dt>Next release</dt>
            <dd>{next_release(@treasury)}</dd>
          </div>
        </dl>
      </div>

      <.split_preview page={@page} actor={@actor} lease={@lease} />

      <h3 id="proposals-advances-title">Advances out</h3>
      <p :if={@treasury.advances == []} id="proposals-no-advances" class="proposals-detail">
        None.
      </p>
      <ol :if={@treasury.advances != []} id="proposals-advances" class="proposals-lines">
        <li :for={advance <- @treasury.advances} data-advance={advance.id}>
          <span>
            Advance {advance.id}: <.amount value={advance.outstanding} /> of
            <.amount value={advance.amount} />, <.wallet address={advance.operator} />
          </span>
          <.live_component
            module={WalletPanel}
            id={"proposals-return-#{advance.id}"}
            class="proposals-action"
            flow={:return_advance}
            fleet={fleet(@page)}
            actor={@actor}
            lease={@lease}
            advance_id={advance.id}
            refresh={advance.outstanding}
            inputs={%{"amount" => advance.typed}}
          >
            <:fields :let={panel}>
              <.text_field
                id={"proposals-return-#{advance.id}-amount"}
                name="amount"
                label="Return"
                inputmode="decimal"
                value={panel.inputs["amount"]}
              />
            </:fields>
            <:buttons :let={panel}>
              <WalletPanel.step_button
                :if={WalletPanel.has_step?(panel, "approve")}
                panel={panel}
                step="approve"
                id={"proposals-return-#{advance.id}-approve"}
                variant="secondary"
              >
                Approve
              </WalletPanel.step_button>
              <WalletPanel.step_button
                panel={panel}
                step="return"
                id={"proposals-return-#{advance.id}-button"}
              >
                Return
              </WalletPanel.step_button>
            </:buttons>
          </.live_component>
        </li>
      </ol>

      <h3 id="proposals-share-title">
        Regents share
        <Regent.Primitives.tip id="proposals-share-tip" label="About the Regents share">
          10% of every key sale is set aside for REGENT staking. Anyone can send it.
        </Regent.Primitives.tip>
      </h3>
      <.live_component
        module={WalletPanel}
        id="proposals-regents-share"
        class="proposals-action"
        flow={:send_share}
        fleet={fleet(@page)}
        actor={@actor}
        lease={@lease}
      >
        <:buttons :let={panel}>
          <WalletPanel.step_button panel={panel} step="send_share" id="proposals-send-share">
            Send
          </WalletPanel.step_button>
        </:buttons>
      </.live_component>

      <Regent.Primitives.disclosure id="proposals-history-more" summary="Money in and out">
        <p :if={@treasury.history == []} id="proposals-no-history" class="proposals-detail">
          Nothing yet.
        </p>
        <ol :if={@treasury.history != []} id="proposals-history" class="proposals-lines">
          <li :for={line <- @treasury.history} data-history={line.id}>
            <span>{history_word(line.kind)} <.amount value={line.amount} /></span>
            <span :if={line.account} class="proposals-detail">
              to <.wallet address={line.account} />
            </span>
          </li>
        </ol>
        <p :if={@treasury.earlier?} class="proposals-detail">Earlier ones aren’t shown.</p>
      </Regent.Primitives.disclosure>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  # What the daily split would share now, per asset, as the treasury works it
  # out at the latest block, and the button that runs it once it is due.
  defp split_preview(assigns) do
    ~H"""
    <.live_component
      module={WalletPanel}
      id="proposals-split-action"
      class="proposals-action"
      flow={:run_split}
      tool="run_split"
      fleet={fleet(@page)}
      actor={@actor}
      lease={@lease}
    >
      <:notes :let={panel}>
        <h3 id="proposals-split-title">
          Daily Treasury Slice to Keys
          <Regent.Primitives.tip
            id="proposals-split-tip"
            label="About the Daily Treasury Slice to Keys"
          >
            Once a day anyone can release it. Each asset at or above its minimum shares its balance times the rate, divided equally across every Key sold.
          </Regent.Primitives.tip>
        </h3>
        <table
          :if={split(panel)[:assets] not in [nil, []]}
          id="proposals-split-preview"
          class="proposals-table"
        >
          <thead>
            <tr>
              <th scope="col">Asset</th>
              <th scope="col">Balance</th>
              <th scope="col">Minimum</th>
              <th scope="col">Per Key</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={asset <- split(panel).assets} data-asset={asset.address}>
              <td>{asset_name(asset)}</td>
              <td>{WalletWords.token_amount(Map.put(asset, :amount, asset.balance))}</td>
              <td>{WalletWords.token_amount(Map.put(asset, :amount, asset.threshold))}</td>
              <td>{WalletWords.token_amount(Map.put(asset, :amount, asset.per_key))}</td>
            </tr>
          </tbody>
        </table>
        <dl :if={split(panel)[:assets]} class="proposals-facts">
          <div>
            <dt>Last release</dt>
            <dd id="proposals-split-last">
              {if split(panel).last_run_at, do: at(split(panel).last_run_at), else: "Never"}
            </dd>
          </div>
          <div :if={split(panel).opens_at}>
            <dt>Next release</dt>
            <dd id="proposals-split-opens">{opens(split(panel))}</dd>
          </div>
        </dl>
      </:notes>
      <:buttons :let={panel}>
        <WalletPanel.step_button panel={panel} step="run_split" id="proposals-run-split">
          Release
        </WalletPanel.step_button>
      </:buttons>
    </.live_component>
    """
  end

  defp split(panel), do: WalletPanel.figures(panel)

  # A slice whose time has come stays open until someone releases it, so its
  # time is shown only while it is still ahead: as the chain's own clock has it
  # for the preview, and as of the treasury's reading for the figures above it.
  defp opens(%{blocked: %{"run_split" => {:opens_at, opens_at}}}), do: at(opens_at)
  defp opens(_figures), do: "Open now"

  defp next_release(%{next_run_at: opens_at, as_of: read_at}),
    do: if(DateTime.after?(opens_at, read_at), do: at(opens_at), else: "Open now")

  defp asset_name(%{usdc?: true}), do: "USDC"
  defp asset_name(%{symbol: symbol}) when is_binary(symbol), do: symbol
  defp asset_name(%{address: address}), do: RegentFormat.short_address(address)

  # The fleet the wallet buttons act on, and the network they send on.
  defp fleet(page), do: %{fleet_id: page.fleet_id, chain_id: page.chain_id}

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :inputmode, :string, default: nil
  slot :inner_block

  # A field the wallet buttons' steps are built from.
  defp text_field(assigns) do
    ~H"""
    <Regent.Primitives.field :let={field} id={@id} label={@label}>
      <input
        id={field.id}
        name={@name}
        value={@value}
        inputmode={@inputmode}
        autocomplete="off"
        aria-describedby={field.described_by}
        data-onchain-input={@name}
      />
      <:hint :if={@inner_block != []}>{render_slot(@inner_block)}</:hint>
    </Regent.Primitives.field>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :rows, :string, required: true

  defp text_area(assigns) do
    ~H"""
    <Regent.Primitives.field :let={field} id={@id} label={@label}>
      <textarea
        id={field.id}
        name={@name}
        rows={@rows}
        aria-describedby={field.described_by}
        data-onchain-input={@name}
      >{@value}</textarea>
    </Regent.Primitives.field>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :options, :list, required: true, doc: "each `{value, words}`"

  defp select_field(assigns) do
    ~H"""
    <Regent.Primitives.field :let={field} id={@id} label={@label}>
      <select
        id={field.id}
        name={@name}
        aria-describedby={field.described_by}
        data-onchain-input={@name}
      >
        <option :for={{value, words} <- @options} value={value} selected={@value == value}>
          {words}
        </option>
      </select>
    </Regent.Primitives.field>
    """
  end

  attr :value, :map, required: true
  attr :count, :boolean, default: false, doc: "whether the amount rolls when it changes"

  # An amount, with its token's address beside it, shortened and in full on
  # hover, unless it is the fleet's own USDC. Kept on one line, since it sits
  # inside text.
  defp amount(%{value: %{token: nil}} = assigns),
    do: ~H|<span class="proposals-amount" data-count={@count}>{@value.text}</span>|

  defp amount(assigns) do
    ~H"""
    <span class="proposals-amount" data-count={@count}>{@value.text} <.token address={@value.token} /></span>
    """
  end

  attr :address, :string, required: true

  defp token(assigns),
    do:
      ~H|<code class="proposals-token" title={@address}>{RegentFormat.short_address(@address)}</code>|

  attr :address, :string, required: true

  # A wallet shortened, in full on hover.
  defp wallet(assigns),
    do: ~H|<code title={@address}>{RegentFormat.short_address(@address)}</code>|

  attr :page, :map, required: true

  defp detail_heading(assigns) do
    ~H"""
    <header class="proposals-heading">
      <p class="proposals-kicker">
        <.link patch={ProposalsPage.list_path(@page.fleet_id)}>
          {@page.fleet_name} proposals
        </.link>
      </p>
      <h1 tabindex="-1">Proposal {@page.number}</h1>
    </header>
    """
  end

  defp catching_up(assigns) do
    ~H"""
    <p id="proposals-catching-up" class="proposals-notice" role="status">
      Vote counts are catching up.
    </p>
    """
  end

  attr :id, :string, required: true

  defp approval_rule(assigns) do
    ~H"""
    <Regent.Primitives.tip id={@id} label="How a proposal is approved">
      {approval_rule()}
    </Regent.Primitives.tip>
    """
  end

  @doc "How a proposal is approved, as the pages say it."
  def approval_rule,
    do:
      "Each Key is one vote, and a vote can be changed until voting closes, 24 hours after " <>
        "the proposal opened. It is approved if at least 60% of the Keys counted voted yes, " <>
        "rounded up, so one Key counted can approve it alone. The Keys counted are those " <>
        "present when it opened, and any other Key that voted. A counted Key that doesn’t " <>
        "vote counts against it."

  attr :id, :string, required: true

  # Told the way the fleet's own page tells it.
  defp unreadable(assigns) do
    ~H"""
    <article id={@id} class="proposals-page">
      <header class="proposals-heading">
        <p class="proposals-kicker">Fleet</p>
        <h1 tabindex="-1">Keyfleet</h1>
      </header>

      <section id="proposals-unreadable" class="proposals-panel">
        <h2>This page couldn’t be loaded.</h2>
        <p>Refresh the page to try again.</p>
      </section>
    </article>
    """
  end

  attr :id, :string, required: true

  # Told the way the fleet's own page tells it.
  defp missing_fleet(assigns) do
    ~H"""
    <article id={@id} class="proposals-page">
      <header class="proposals-heading">
        <p class="proposals-kicker">Fleet</p>
        <h1 tabindex="-1">Keyfleet</h1>
      </header>

      <section id="proposals-unavailable" class="proposals-panel">
        <h2>This fleet doesn’t exist.</h2>
      </section>
    </article>
    """
  end

  defp history_word(kind), do: Map.fetch!(@history_words, kind)

  defp vote_word(:yes), do: "Yes"
  defp vote_word(:no), do: "No"
  defp vote_word(:abstain), do: "Abstain"

  # Where a proposal stands, in the words its pages use.
  defp status_word(%{status: status}), do: Map.fetch!(@status_words, status)

  attr :proposal, :map, required: true

  # How a proposal's votes stand; the yes and no figures roll when votes arrive.
  defp tally(assigns) do
    assigns = assign(assigns, :id, "proposals-tally-#{assigns.proposal.number}")

    ~H|<span id={@id} phx-hook="MotionCount" data-variant={Motion.standard("count")}><span data-count>{@proposal.yes}</span>
yes, <span data-count>{@proposal.no}</span>
no, <span data-count>{@proposal.abstain}</span>
abstain, of {keys(@proposal.counted)} counted</span>|
  end

  defp keys(1), do: "1 Key"
  defp keys(count), do: "#{count} Keys"

  defp key_list([token_id]), do: "Key #{token_id}"
  defp key_list(token_ids), do: "Keys #{Enum.join(token_ids, ", ")}"

  defp at(datetime), do: Calendar.strftime(datetime, "%-d %B %Y at %H:%M UTC")

  @doc "A wait begun for a proposals page the page has since left reads nothing."
  def handle_info(:refresh_proposals, %{assigns: %{proposals: %{}}} = socket),
    do: {:noreply, socket |> assign(:proposals_refresh?, false) |> read_proposals()}

  def handle_info(:refresh_proposals, socket),
    do: {:noreply, assign(socket, :proposals_refresh?, false)}

  @doc "One read, a moment later, for a burst of notices about the fleet's proposals."
  def refresh_soon(socket) do
    if socket.assigns.proposals_refresh? do
      socket
    else
      Process.send_after(self(), :refresh_proposals, @proposals_refresh_after)
      assign(socket, :proposals_refresh?, true)
    end
  end

  @doc """
  The proposals page the address names, read afresh; or `:unreadable` when the
  database couldn't be read.
  """
  def read_proposals(socket) do
    case PageRead.run("proposals", fn -> proposals(socket) end) do
      {:ok, page} -> assign(socket, proposals: page)
      {:error, _failure} -> assign(socket, proposals: :unreadable)
    end
  end

  defp proposals(%{assigns: %{proposals_params: params, route_spec: %{route_id: :proposals}}}),
    do: ProposalsPage.list(params["fleet_id"], params)

  defp proposals(%{assigns: %{proposals_params: params, route_spec: %{route_id: :proposal}}}),
    do: ProposalsPage.detail(params["fleet_id"], params["number"], params)
end

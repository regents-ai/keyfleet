defmodule KeyfleetWeb.ProposalsLive do
  @moduledoc """
  A fleet's proposals, for anyone to read: what its key holders have put to
  a vote, how each vote stands, and each proposal's calls with every vote
  cast on it; and beside them the shared money they vote on.

  Once the fleet is on chain, its wallet buttons sit beside what they act on:
  voting and carrying a proposal out on its own page, and proposing a
  decision or a payment, letting another wallet vote, and sending Regents
  its share on the list. Every press goes to the wallet. What the page knows
  about a proposal or the shared money is said beside a button and never stops a
  press: the contract decides, and its answer is shown under the button.

  Everything shown is what `KeyfleetWeb.ProposalsPage` read.
  """

  use KeyfleetWeb, :html

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.Components.Count
  alias KeyfleetWeb.Motion
  alias KeyfleetWeb.PageRead
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.WalletPanel

  # How long a proposals page waits after a notice that the fleet's proposal
  # records or balances changed before it reads them, so a burst is read once.
  @proposals_refresh_after 1_000

  @status_words %{
    open: "Open",
    approved: "Approved",
    rejected: "Not approved",
    executed: "Carried out",
    cancelled: "Cancelled",
    execution_expired: "Expired"
  }

  # What the page knows that the contract will refuse, said beside the button
  # that carries a proposal out.
  @carry_out_notes [
    open: "Voting is still open, so carrying it out now will be refused.",
    rejected: "It wasn’t approved, so carrying it out will be refused.",
    executed: "It has already been carried out, so doing it again will be refused.",
    cancelled: "It was cancelled, so carrying it out will be refused.",
    execution_expired: "It can no longer be carried out, so doing it will be refused."
  ]

  @history_words %{
    forwarded: "Received",
    protocol_share_sent: "Sent to Regents",
    paid: "Paid",
    advanced: "Advanced",
    split_allocated: "Shared with key holders"
  }

  attr :page, :any, required: true, doc: "the proposals as read, or `:unreadable`"
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"

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
        <p :if={@page.treasury} class="proposals-lede">
          What this fleet’s key holders have put to a vote, and the shared money they vote on.
        </p>
        <p :if={!@page.treasury} class="proposals-lede">
          What this fleet’s key holders have put to a vote.
        </p>
      </header>

      <.catching_up :if={@page.catching_up?} />

      <section class="proposals-panel" aria-labelledby="proposals-list-title">
        <h2 id="proposals-list-title">Every proposal</h2>
        <.approval_rule />

        <p :if={@page.proposals == [] and @page.first_page?} id="proposals-empty">
          No proposals have been made yet.
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

      <div :if={@page.deployed?} class="proposals-grid">
        <.propose_decision page={@page} actor={@actor} />
        <.propose_payment page={@page} actor={@actor} />
        <.propose_edits page={@page} actor={@actor} />
        <.voting_delegate page={@page} actor={@actor} />
      </div>

      <.budget :if={@page.treasury} treasury={@page.treasury} page={@page} actor={@actor} />
    </article>
    """
  end

  attr :page, :any, required: true, doc: "the proposal as read, or `:unreadable`"
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"

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
        <section class="proposals-panel" aria-labelledby="proposal-outcome-title">
          <h2 id="proposal-outcome-title">
            <span id="proposal-status" data-status={@page.proposal.status}>
              {status_word(@page.proposal)}
            </span>
          </h2>
          <dl class="proposals-facts">
            <div>
              <dt>Yes</dt>
              <dd id="proposal-yes">
                <Count.count id="proposal-yes-count" value={@page.proposal.yes} one="key" many="keys" />
              </dd>
            </div>
            <div>
              <dt>No</dt>
              <dd id="proposal-no">
                <Count.count id="proposal-no-count" value={@page.proposal.no} one="key" many="keys" />
              </dd>
            </div>
            <div>
              <dt>Abstain</dt>
              <dd id="proposal-abstain">
                <Count.count
                  id="proposal-abstain-count"
                  value={@page.proposal.abstain}
                  one="key"
                  many="keys"
                />
              </dd>
            </div>
            <div>
              <dt>Keys counted</dt>
              <dd id="proposal-counted">
                <Count.count
                  id="proposal-counted-count"
                  value={@page.proposal.counted}
                  one="key"
                  many="keys"
                />
              </dd>
            </div>
          </dl>
          <.approval_rule />
          <p id="proposal-times" class="proposals-detail">
            Opened {at(@page.proposal.opened_at)}. Voting closes {at(@page.proposal.closes_at)}. It can be carried out until {at(
              @page.proposal.execution_expiry
            )}.
          </p>
          <p :if={@page.proposal.executor} id="proposal-executor" class="proposals-detail">
            Carried out by <.wallet address={@page.proposal.executor} />
          </p>
          <p :if={@page.proposal.cancelled_by} id="proposal-canceller" class="proposals-detail">
            Cancelled by <.wallet address={@page.proposal.cancelled_by} />
          </p>
        </section>

        <.vote :if={@page.deployed?} page={@page} actor={@actor} proposal={@page.proposal} />
        <.carry_out :if={@page.deployed?} page={@page} actor={@actor} proposal={@page.proposal} />
        <section class="proposals-panel" aria-labelledby="proposal-content-title">
          <h2 id="proposal-content-title">What it does</h2>
          <p id="proposal-proposer" class="proposals-detail">
            Proposed by <.wallet address={@page.proposal.proposer} />
            with key {Rules.grouped(@page.proposal.author_key)}
          </p>
          <p id="proposal-content" class="proposals-detail">
            Its text has the code <code>{@page.proposal.content_hash}</code>.
          </p>
          <p :if={@page.proposal.calls == []} id="proposal-no-calls" class="proposals-detail">
            It records a decision and moves nothing.
          </p>
          <ol :if={@page.proposal.calls != []} id="proposal-calls" class="proposals-lines">
            <li :for={call <- @page.proposal.calls}>
              <span :if={!call.value}>Calls <.wallet address={call.target} /></span>
              <span :if={call.value}>
                Calls <.wallet address={call.target} /> with <.amount value={call.value} />
              </span>
              <code :if={call.data != "0x"} class="proposals-token" title={call.data}>
                {RegentFormat.short_hash(call.data)}
              </code>
            </li>
          </ol>
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

  attr :page, :map, required: true
  attr :actor, :any, required: true
  attr :proposal, :map, required: true

  # Each key is one vote, so a vote names its keys: the voter's own, or those
  # of someone who let their wallet vote for them. A key may change its vote
  # until voting closes. The contract decides which keys can vote.
  defp vote(assigns) do
    ~H"""
    <section id="proposal-vote" class="proposals-panel" aria-labelledby="proposal-vote-title">
      <h2 id="proposal-vote-title">Vote</h2>
      <.live_component
        module={WalletPanel}
        id="proposal-vote-action"
        class="proposals-action"
        flow={:vote}
        fleet={fleet(@page)}
        actor={@actor}
        proposal={@proposal.number}
        inputs={%{"keys" => ""}}
      >
        <:fields :let={panel}>
          <div class="proposals-form">
            <.text_field
              id="proposal-vote-keys"
              name="keys"
              label="Keys to vote with"
              inputmode="numeric"
              value={panel.inputs["keys"]}
            >
              Each key is one vote. Separate key numbers with commas.
            </.text_field>
          </div>
        </:fields>
        <:notes>
          <p
            id="proposal-vote-closed"
            class="proposals-detail"
            hidden={@proposal.status == :open}
          >
            Voting has closed, so a vote now will be refused.
          </p>
          <p class="proposals-detail">
            Type the numbers of the keys you’re voting with: your own, or those of someone who has let your wallet vote for them. Voting again with a key changes its vote.
          </p>
        </:notes>
        <:buttons>
          <Regent.Primitives.button id="proposal-vote-yes" data-onchain-step="yes">
            <span data-press-label>Vote yes</span>
          </Regent.Primitives.button>
          <Regent.Primitives.button
            id="proposal-vote-no"
            variant="secondary"
            data-onchain-step="no"
          >
            <span data-press-label>Vote no</span>
          </Regent.Primitives.button>
          <Regent.Primitives.button
            id="proposal-vote-withdraw"
            variant="secondary"
            data-onchain-step="withdraw"
          >
            <span data-press-label>Withdraw these keys’ votes</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true
  attr :proposal, :map, required: true

  # Anyone may carry out an approved proposal once voting has closed, until
  # it expires.
  defp carry_out(assigns) do
    assigns = assign(assigns, carry_out_notes: @carry_out_notes)

    ~H"""
    <section
      id="proposal-carry-out"
      class="proposals-panel"
      aria-labelledby="proposal-carry-out-title"
    >
      <h2 id="proposal-carry-out-title">Carry it out</h2>
      <.live_component
        module={WalletPanel}
        id="proposal-carry-out-action"
        class="proposals-action"
        flow={:carry_out}
        fleet={fleet(@page)}
        actor={@actor}
        proposal={@proposal.number}
      >
        <:notes>
          <p class="proposals-detail">
            Anyone can carry out this proposal once voting has closed and it was approved.
          </p>
          <p
            :for={{status, note} <- @carry_out_notes}
            id={"proposal-carry-out-note-#{status}"}
            class="proposals-detail"
            hidden={@proposal.status != status}
          >
            {note}
          </p>
        </:notes>
        <:buttons>
          <Regent.Primitives.button id="proposal-carry-out-button" data-onchain-step="carry_out">
            <span data-press-label>Carry it out</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true

  # A decision records what the key holders agreed to, and does nothing else.
  defp propose_decision(assigns) do
    ~H"""
    <section id="propose-decision" class="proposals-panel" aria-labelledby="propose-decision-title">
      <h2 id="propose-decision-title">Propose a decision</h2>
      <p class="proposals-detail">
        Records what the key holders agree to once more than half of all the keys sold vote yes. Nothing is paid by it.
      </p>
      <.live_component
        module={WalletPanel}
        id="propose-decision-action"
        class="proposals-action"
        flow={:propose_decision}
        fleet={fleet(@page)}
        actor={@actor}
        inputs={%{"key" => "", "text" => "", "digest" => ""}}
      >
        <:fields :let={panel}>
          <div class="proposals-form">
            <.key_field id="propose-decision-key" value={panel.inputs["key"]} />
            <.text_area
              id="propose-decision-text"
              name="text"
              label="What to decide"
              rows="4"
              value={panel.inputs["text"]}
            />
            <.document_code_field id="propose-decision-digest" value={panel.inputs["digest"]}>
              A code for the exact document this is about: 64 characters, 0 to 9 and a to f. Leave it empty if there isn’t one.
            </.document_code_field>
          </div>
        </:fields>
        <:buttons>
          <Regent.Primitives.button id="propose-decision-button" data-onchain-step="propose">
            <span data-press-label>Propose this decision</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true

  defp propose_payment(assigns) do
    ~H"""
    <section id="propose-payment" class="proposals-panel" aria-labelledby="propose-payment-title">
      <h2 id="propose-payment-title">Propose a payment</h2>
      <p class="proposals-detail">
        Pays from the fleet’s shared money once more than half of all the keys sold vote yes. Every payment is matched: each key that didn’t vote yes can then collect the payment divided by the number of yes votes, so a payment spends only the yes keys’ own share.
      </p>
      <.live_component
        module={WalletPanel}
        id="propose-payment-action"
        class="proposals-action"
        flow={:propose_payment}
        fleet={fleet(@page)}
        actor={@actor}
        inputs={
          %{
            "key" => "",
            "asset" => hd(@page.propose.assets).address,
            "other_asset" => "",
            "amount" => "",
            "recipient" => "",
            "text" => "",
            "digest" => ""
          }
        }
      >
        <:fields :let={panel}>
          <div class="proposals-form">
            <.key_field id="propose-payment-key" value={panel.inputs["key"]} />
            <Regent.Primitives.field :let={field} id="propose-payment-asset" label="Token">
              <select
                id={field.id}
                name="asset"
                aria-describedby={field.described_by}
                data-onchain-input="asset"
              >
                <option
                  :for={asset <- @page.propose.assets}
                  value={asset.address}
                  selected={panel.inputs["asset"] == asset.address}
                >
                  {asset.name}
                </option>
                <option value="other" selected={panel.inputs["asset"] == "other"}>
                  Another token (paste its address)
                </option>
              </select>
            </Regent.Primitives.field>
            <.text_field
              id="propose-payment-other"
              name="other_asset"
              label="Another token"
              value={panel.inputs["other_asset"]}
            >
              Only when you chose another token: its address. It is paid in its smallest units, as a whole number.
            </.text_field>
            <.text_field
              id="propose-payment-amount"
              name="amount"
              label="Amount"
              inputmode="decimal"
              value={panel.inputs["amount"]}
            >
              In whole tokens, like 12.5, with a point for decimals. A token paid in its smallest units takes a whole number.
            </.text_field>
            <.text_field
              id="propose-payment-recipient"
              name="recipient"
              label="Pay to"
              value={panel.inputs["recipient"]}
            >
              The wallet that receives the payment.
            </.text_field>
            <.text_area
              id="propose-payment-text"
              name="text"
              label="Why"
              rows="3"
              value={panel.inputs["text"]}
            />
            <.document_code_field id="propose-payment-digest" value={panel.inputs["digest"]}>
              A code for the exact invoice or work this pays for: 64 characters, 0 to 9 and a to f. Leave it empty if there isn’t one.
            </.document_code_field>
          </div>
        </:fields>
        <:buttons>
          <Regent.Primitives.button id="propose-payment-button" data-onchain-step="propose">
            <span data-press-label>Propose this payment</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true

  # Stopping a key, and every shard of it, changing the workspace, or letting
  # it change the workspace again. It can still read the workspace and chat.
  defp propose_edits(assigns) do
    ~H"""
    <section id="propose-edits" class="proposals-panel" aria-labelledby="propose-edits-title">
      <h2 id="propose-edits-title">Restrict or allow a key’s edits</h2>
      <p class="proposals-detail">
        Stops a key and its shards changing the workspace, or lets them again. They can still read it and chat. Needs 3 of every 5 keys sold to vote yes.
      </p>
      <.live_component
        module={WalletPanel}
        id="propose-edits-action"
        class="proposals-action"
        flow={:propose_edits}
        fleet={fleet(@page)}
        actor={@actor}
        inputs={%{"key" => "", "target" => "", "restricted" => "true", "text" => "", "digest" => ""}}
      >
        <:fields :let={panel}>
          <div class="proposals-form">
            <.key_field id="propose-edits-key" value={panel.inputs["key"]} />
            <.text_field
              id="propose-edits-target"
              name="target"
              label="The key whose edits this is about"
              inputmode="numeric"
              value={panel.inputs["target"]}
            />
            <Regent.Primitives.field :let={field} id="propose-edits-restricted" label="Proposal">
              <select
                id={field.id}
                name="restricted"
                aria-describedby={field.described_by}
                data-onchain-input="restricted"
              >
                <option value="true" selected={panel.inputs["restricted"] == "true"}>
                  Restrict edits
                </option>
                <option value="false" selected={panel.inputs["restricted"] == "false"}>
                  Allow edits
                </option>
              </select>
            </Regent.Primitives.field>
            <.text_area
              id="propose-edits-text"
              name="text"
              label="Why"
              rows="3"
              value={panel.inputs["text"]}
            />
            <.document_code_field id="propose-edits-digest" value={panel.inputs["digest"]}>
              A code for the exact document this is about: 64 characters, 0 to 9 and a to f. Leave it empty if there isn’t one.
            </.document_code_field>
          </div>
        </:fields>
        <:buttons>
          <Regent.Primitives.button id="propose-edits-button" data-onchain-step="propose">
            <span data-press-label>Propose this</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true

  defp voting_delegate(assigns) do
    ~H"""
    <section id="voting-delegate" class="proposals-panel" aria-labelledby="voting-delegate-title">
      <h2 id="voting-delegate-title">Let another wallet vote for you</h2>
      <p class="proposals-detail">
        It can vote and propose with every key you hold, until you stop it. It never holds your keys or their rewards, and you can still vote yourself.
      </p>
      <.live_component
        module={WalletPanel}
        id="voting-delegate-action"
        class="proposals-action"
        flow={:delegate}
        fleet={fleet(@page)}
        actor={@actor}
        inputs={%{"delegate" => ""}}
      >
        <:fields :let={panel}>
          <div class="proposals-form">
            <.text_field
              id="voting-delegate-wallet"
              name="delegate"
              label="Wallet to vote for you"
              value={panel.inputs["delegate"]}
            />
          </div>
        </:fields>
        <:buttons>
          <Regent.Primitives.button id="voting-delegate-button" data-onchain-step="delegate">
            <span data-press-label>Let this wallet vote for me</span>
          </Regent.Primitives.button>
          <Regent.Primitives.button
            id="voting-delegate-clear"
            variant="secondary"
            data-onchain-step="clear"
          >
            <span data-press-label>Stop any wallet voting for me</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true
  attr :treasury, :map, required: true

  # The Regents share is sent once a day, and anyone may send it sooner.
  defp regents_share(assigns) do
    ~H"""
    <.live_component
      module={WalletPanel}
      id="proposals-regents-share"
      class="proposals-action"
      flow={:send_share}
      fleet={fleet(@page)}
      actor={@actor}
    >
      <:notes>
        <p class="proposals-detail">
          10% of every key sale is set aside for Regents. It is sent to Regents once a day, and anyone can send it sooner.
        </p>
        <p id="proposals-nothing-owed" class="proposals-detail" hidden={!@treasury.nothing_owed?}>
          Nothing is set aside right now, so sending will be refused.
        </p>
      </:notes>
      <:buttons>
        <Regent.Primitives.button id="proposals-send-share" data-onchain-step="send">
          <span data-press-label>Send Regents its share</span>
        </Regent.Primitives.button>
      </:buttons>
    </.live_component>
    """
  end

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
  attr :value, :string, required: true

  defp key_field(assigns) do
    ~H"""
    <.text_field id={@id} name="key" label="Propose with key" inputmode="numeric" value={@value}>
      A key you hold, or one whose holder has let your wallet vote for them. Proposing doesn’t use its vote.
    </.text_field>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  slot :inner_block, required: true

  defp document_code_field(assigns) do
    ~H"""
    <.text_field id={@id} name="digest" label="Document code (optional)" value={@value}>
      {render_slot(@inner_block)}
    </.text_field>
    """
  end

  attr :treasury, :map, required: true
  attr :page, :map, required: true
  attr :actor, :any, required: true

  defp budget(assigns) do
    ~H"""
    <section id="proposals-budget" class="proposals-panel" aria-labelledby="proposals-budget-title">
      <h2 id="proposals-budget-title">Shared money</h2>

      <p :if={not @treasury.read?} id="proposals-budget-pending" class="proposals-detail">
        The shared money’s figures are still being read.
      </p>

      <.balances :if={@treasury.read?} treasury={@treasury} />
      <.regents_share page={@page} actor={@actor} treasury={@treasury} />

      <h3>Advances</h3>
      <p :if={@treasury.advances == []} id="proposals-no-advances" class="proposals-detail">
        Nothing is out on an advance.
      </p>
      <ol :if={@treasury.advances != []} id="proposals-advances" class="proposals-lines">
        <li :for={advance <- @treasury.advances} data-advance={advance.id}>
          <span><.amount value={advance.outstanding} /> of <.amount value={advance.amount} />
          still out</span>
          <span class="proposals-detail">with <.wallet address={advance.operator} /></span>
        </li>
      </ol>

      <h3>Money in and out</h3>
      <p :if={@treasury.history == []} id="proposals-no-history" class="proposals-detail">
        No money has come in or gone out yet.
      </p>
      <ol :if={@treasury.history != []} id="proposals-history" class="proposals-lines">
        <li :for={line <- @treasury.history} data-history={line.id}>
          <span>{history_word(line.kind)} <.amount value={line.amount} /></span>
          <span :if={line.account} class="proposals-detail">to <.wallet address={line.account} /></span>
        </li>
      </ol>
      <p :if={@treasury.earlier?} class="proposals-detail">
        Earlier money in and out is not shown here.
      </p>
    </section>
    """
  end

  attr :treasury, :map, required: true

  defp balances(assigns) do
    ~H"""
    <div id="proposals-figures" phx-hook="MotionCount" data-variant={Motion.standard("count")}>
      <dl
        :for={balance <- @treasury.balances}
        class="proposals-facts proposals-balance"
        data-asset={balance.asset}
      >
        <div>
          <dt>Shared money</dt>
          <dd><.amount value={balance.held} count /></dd>
        </div>
        <div>
          <dt>Waiting for key holders</dt>
          <dd><.amount value={balance.backed} count /></dd>
        </div>
      </dl>

      <p id="proposals-budget-as-of" class="proposals-detail">Figures as of {at(@treasury.as_of)}.</p>

      <dl id="proposals-split" class="proposals-facts">
        <div>
          <dt>Shared with key holders each day</dt>
          <dd>{@treasury.split_rate}</dd>
        </div>
        <div :if={@treasury.next_run_at}>
          <dt>Next share</dt>
          <dd>{at(@treasury.next_run_at)}</dd>
        </div>
      </dl>

      <dl id="proposals-held" class="proposals-facts">
        <div :if={@treasury.reserve}>
          <dt>Held for the next level</dt>
          <dd><.amount value={@treasury.reserve} count /></dd>
        </div>
        <div>
          <dt>Set aside for Regents</dt>
          <dd><.amount value={@treasury.owed} count /></dd>
        </div>
      </dl>
    </div>
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

  defp approval_rule(assigns) do
    ~H"""
    <p class="proposals-rule">{approval_rule()}</p>
    """
  end

  @doc "How a proposal is approved, as the pages say it."
  def approval_rule,
    do:
      "Each key is one vote. When voting closes, a proposal is approved if more than half of " <>
        "the keys counted voted yes: the keys active when it opened, and any other key that " <>
        "voted. A counted key that doesn’t vote counts against it."

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

  defp keys(1), do: "1 key"
  defp keys(count), do: "#{count} keys"

  defp key_list([token_id]), do: "key #{token_id}"
  defp key_list(token_ids), do: "keys #{Enum.join(token_ids, ", ")}"

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

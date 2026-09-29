defmodule KeyfleetWeb.ProposalsLive do
  @moduledoc """
  A fleet's proposals, for anyone to read: what its key holders have put to
  a vote, how each vote stands, and each proposal's text, payment or change
  to a key's workspace edits with every vote cast on it; and beside them the
  shared money they vote on.

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
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.WalletPanel

  # How long a proposals page waits after a notice that the fleet's proposal
  # records or balances changed before it reads them, so a burst is read once.
  @proposals_refresh_after 1_000

  @status_words %{open: "Open", approved: "Approved"}

  @executed_words %{decision: "Recorded", pay: "Paid", restrict_edits: "Carried out"}

  attr :page, :map, required: true
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"

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
              <span>{ProposalsPage.kind_name(proposal.kind)}</span>
              <span class="proposals-badge" data-status={proposal.status}>
                {status_word(proposal)}
              </span>
            </p>
            <h3>
              <.link patch={ProposalsPage.detail_path(@page.fleet_id, proposal.number)}>
                Proposal {proposal.number}
              </.link>
            </h3>
            <p :if={proposal.gist} class="proposals-gist">{proposal.gist}</p>
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

  attr :page, :map, required: true
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"

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
              <dt>Keys sold</dt>
              <dd id="proposal-keys-sold">
                <Count.count
                  id="proposal-keys-sold-count"
                  value={@page.proposal.keys_sold}
                  one="key"
                  many="keys"
                />
              </dd>
            </div>
          </dl>
          <.approval_rule />
          <p :if={@page.proposal.executor} id="proposal-executor" class="proposals-detail">
            Carried out by <.wallet address={@page.proposal.executor} />
          </p>
        </section>

        <.vote :if={@page.deployed?} page={@page} actor={@actor} proposal={@page.proposal} />
        <.carry_out :if={@page.deployed?} page={@page} actor={@actor} proposal={@page.proposal} />
        <.collect
          :if={@page.deployed? and @page.proposal.match != nil}
          page={@page}
          actor={@actor}
          proposal={@page.proposal}
        />

        <section class="proposals-panel" aria-labelledby="proposal-content-title">
          <h2 id="proposal-content-title">{ProposalsPage.kind_name(@page.proposal.kind)}</h2>
          <p id="proposal-proposer" class="proposals-detail">
            Proposed by <.wallet address={@page.proposal.proposer} />
          </p>

          <dl :if={@page.proposal.pay} id="proposal-payment" class="proposals-fields">
            <div>
              <dt>Amount</dt>
              <dd><.amount value={@page.proposal.pay.amount} /></dd>
            </div>
            <div>
              <dt>Paid to</dt>
              <dd><code>{@page.proposal.pay.recipient}</code></dd>
            </div>
          </dl>

          <dl :if={@page.proposal.edits} id="proposal-edits" class="proposals-fields">
            <div>
              <dt>Key</dt>
              <dd>Key {Rules.grouped(@page.proposal.edits.token_id)}</dd>
            </div>
            <div>
              <dt>Change</dt>
              <dd>{edits_word(@page.proposal.edits)}</dd>
            </div>
          </dl>

          <.text text={@page.proposal.text} />
          <p :if={@page.proposal.text_cut?} class="proposals-detail">
            This proposal is longer than can be shown here. Its first 64 KB are shown.
          </p>
        </section>

        <section class="proposals-panel proposals-votes" aria-labelledby="proposal-votes-title">
          <h2 id="proposal-votes-title">Votes</h2>
          <p :if={@page.votes == [] and is_nil(@page.first_votes)} id="proposal-no-votes">
            No votes yet.
          </p>
          <ol :if={@page.votes != []} id="proposal-votes" class="proposals-lines">
            <li :for={vote <- @page.votes} data-vote={vote.id}>
              <span>{vote_word(vote.support)}</span>
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
  # or withdraw it until the proposal is carried out. The contract decides
  # which keys can vote.
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
            hidden={@proposal.status != :executed}
          >
            It has already been carried out, so a vote now will be refused.
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

  # Anyone may carry out a proposal once enough of all the keys sold have
  # voted yes: 3 of every 5 for a change to a key's edits, more than half for
  # every other kind.
  defp carry_out(assigns) do
    assigns =
      assign(assigns,
        needed: needed(assigns.proposal.kind),
        carry_out_notes: carry_out_notes(assigns.proposal.kind)
      )

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
            Anyone can carry out this proposal once {@needed} have voted yes.
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
            <span data-press-label>{carry_out_word(@proposal)}</span>
          </Regent.Primitives.button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :actor, :any, required: true
  attr :proposal, :map, required: true

  # A carried-out payment's matches: every key sold then that didn't vote yes
  # may collect the same amount, paid to whoever holds the key now. Anyone
  # may collect for any key.
  defp collect(assigns) do
    ~H"""
    <section id="proposal-collect" class="proposals-panel" aria-labelledby="proposal-collect-title">
      <h2 id="proposal-collect-title">Collect the match</h2>
      <.live_component
        module={WalletPanel}
        id="proposal-collect-action"
        class="proposals-action"
        flow={:collect}
        fleet={fleet(@page)}
        actor={@actor}
        proposal={@proposal.number}
        inputs={%{"keys" => ""}}
      >
        <:fields :let={panel}>
          <div class="proposals-form">
            <.text_field
              id="proposal-collect-keys"
              name="keys"
              label="Keys to collect for"
              inputmode="numeric"
              value={panel.inputs["keys"]}
            >
              Separate key numbers with commas.
            </.text_field>
          </div>
        </:fields>
        <:notes>
          <p id="proposal-match" class="proposals-detail" hidden={not @proposal.match.read?}>
            Every key sold when this was paid that didn’t vote yes can collect
            <.amount :if={@proposal.match.read?} value={@proposal.match.share} />, paid to whoever holds the key now. Anyone can collect for any key, once.
          </p>
          <p id="proposal-match-pending" class="proposals-detail" hidden={@proposal.match.read?}>
            Every key sold when this was paid that didn’t vote yes can collect the same amount, paid to whoever holds the key now. The amount is still being read.
          </p>
        </:notes>
        <:buttons>
          <Regent.Primitives.button id="proposal-collect-button" data-onchain-step="collect">
            <span data-press-label>Collect</span>
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

      <h3>Income</h3>
      <p :if={@treasury.income == []} id="proposals-no-income" class="proposals-detail">
        No income yet.
      </p>
      <ol :if={@treasury.income != []} id="proposals-income" class="proposals-lines">
        <li :for={income <- @treasury.income} data-income={income.id}>
          <span><.amount value={income.amount} /> paid to key holders</span>
        </li>
      </ol>
      <p :if={@treasury.earlier_income?} class="proposals-detail">
        Earlier income is not shown here.
      </p>

      <h3>Payments</h3>
      <p :if={@treasury.payments == []} id="proposals-no-payments" class="proposals-detail">
        Nothing has been paid from the shared money yet.
      </p>
      <ol :if={@treasury.payments != []} id="proposals-payments" class="proposals-lines">
        <li :for={payment <- @treasury.payments} data-payment={payment.id}>
          <span><.amount value={payment.amount} /></span>
          <span class="proposals-detail">to <code>{payment.recipient}</code></span>
        </li>
      </ol>
      <p :if={@treasury.earlier_payments?} class="proposals-detail">
        Earlier payments are not shown here.
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
          <dd><.amount value={balance.budget} count /></dd>
        </div>
        <div>
          <dt>Set aside for key holders</dt>
          <dd><.amount value={balance.set_aside} count /></dd>
        </div>
      </dl>

      <p id="proposals-budget-as-of" class="proposals-detail">Figures as of {at(@treasury.as_of)}.</p>

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

  attr :text, :string, required: true

  # Kept on one line with its text, since its line breaks are shown as written.
  defp text(assigns), do: ~H|<p id="proposal-text" class="proposals-text">{@text}</p>|

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
      "Each key is one vote. A proposal is approved once more than half of all the keys sold " <>
        "vote yes, or 3 of every 5 keys sold for a change to a key’s workspace edits, so a key that " <>
        "doesn’t vote counts against it. There is no deadline: it stays open to votes until " <>
        "someone carries it out."

  defp needed(:restrict_edits), do: "3 of every 5 keys sold"
  defp needed(_kind), do: "more than half of all the keys sold"

  # What the page knows that the contract will likely refuse, said beside the
  # button that carries a proposal out.
  defp carry_out_notes(kind) do
    [
      open: "Yes votes aren’t yet #{needed(kind)}, so carrying it out now will be refused.",
      executed: "It has already been carried out, so doing it again will be refused."
    ]
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

  defp carry_out_word(%{kind: :decision}), do: "Record the decision"
  defp carry_out_word(%{kind: :pay}), do: "Make the payment"
  defp carry_out_word(%{kind: :restrict_edits, edits: edits}), do: edits_word(edits)

  defp edits_word(%{restricted?: true}), do: "Stop the key’s workspace edits"
  defp edits_word(%{restricted?: false}), do: "Let the key edit the workspace again"

  defp vote_word(true), do: "Yes"
  defp vote_word(false), do: "No"
  defp vote_word(nil), do: "Withdrawn"

  # Where a proposal stands, in the words its pages use.
  defp status_word(%{status: :executed, kind: kind}), do: Map.fetch!(@executed_words, kind)
  defp status_word(%{status: status}), do: Map.fetch!(@status_words, status)

  attr :proposal, :map, required: true

  # How a proposal's votes stand; the yes and no figures roll when votes arrive.
  defp tally(assigns) do
    assigns = assign(assigns, :id, "proposals-tally-#{assigns.proposal.number}")

    ~H|<span id={@id} phx-hook="MotionCount" data-variant={Motion.standard("count")}><span data-count>{@proposal.yes}</span>
yes, <span data-count>{@proposal.no}</span>
no, of {keys(@proposal.keys_sold)} sold</span>|
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

  @doc "The proposals page the address names, read afresh."
  def read_proposals(socket) do
    params = socket.assigns.proposals_params

    page =
      case socket.assigns.route_spec.route_id do
        :proposals -> ProposalsPage.list(params["fleet_id"], params)
        :proposal -> ProposalsPage.detail(params["fleet_id"], params["number"], params)
      end

    assign(socket, proposals: page)
  end
end

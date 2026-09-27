defmodule KeyfleetWeb.ProposalsLive do
  @moduledoc """
  A fleet's proposals, for anyone to read: what its key holders have put to
  a vote, how each vote stands, and each proposal's text, payment or launch
  with every vote cast on it; and beside them the budget they vote on.

  Once the fleet is on chain, its wallet buttons sit beside what they act on:
  voting and carrying a proposal out on its own page, and proposing a
  decision, a payment or a launch, letting another wallet vote, and sending the REGENT stakers
  their share on the list. Every press goes to the wallet. What the page knows
  about a proposal or the budget is said beside a button and never stops a
  press: the contract decides, and its answer is shown under the button.

  Everything shown is what `KeyfleetWeb.ProposalsPage` read.
  """

  use KeyfleetWeb, :html

  alias KeyfleetWeb.FleetLive
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.WorkspacePage

  @status_words %{
    voting: "Voting open",
    passed: "Passed",
    stale: "Proposed before the last launch"
  }

  @executed_words %{decision: "Passed and recorded", autolaunch: "Launched", pay: "Paid"}

  @carry_out_words %{
    decision: "Record the decision",
    autolaunch: "Start the launch",
    pay: "Make the payment"
  }

  # What the page knows that the contract will likely refuse, said beside the
  # button that carries a proposal out.
  @carry_out_notes %{
    voting:
      "Yes votes aren’t yet more than half of all the keys sold, so carrying it out now will be refused.",
    passed: nil,
    stale:
      "This launch was proposed before the fleet’s last launch, which didn’t succeed, so carrying it out will be refused. Propose it again to try another launch.",
    executed: "It has already been carried out, so doing it again will be refused."
  }

  attr :page, :map, required: true
  attr :launch_plans, :list, required: true

  def list(%{page: %{fleet_name: nil}} = assigns),
    do: ~H|<.missing_fleet id="proposals-page" />|

  def list(assigns) do
    ~H"""
    <article id="proposals-page" class="proposals-page">
      <header class="proposals-heading">
        <p class="proposals-kicker">
          <.link navigate={"/app/fleets/#{@page.fleet_id}"}>{@page.fleet_name}</.link>
        </p>
        <h1 tabindex="-1">Proposals</h1>
        <p :if={@page.treasury} class="proposals-lede">
          What this fleet’s key holders have put to a vote, and the budget they vote on.
        </p>
        <p :if={!@page.treasury} class="proposals-lede">
          What this fleet’s key holders have put to a vote.
        </p>
      </header>

      <.catching_up :if={@page.catching_up?} />

      <section class="proposals-panel" aria-labelledby="proposals-list-title">
        <h2 id="proposals-list-title">Every proposal</h2>
        <.pass_rule />

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
              <.link navigate={ProposalsPage.detail_path(@page.fleet_id, proposal.number)}>
                Proposal {proposal.number}
              </.link>
            </h3>
            <p :if={proposal.gist} class="proposals-gist">{proposal.gist}</p>
            <p class="proposals-detail">
              <span>{tally(proposal)}</span>
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

      <div :if={@page.wallet} class="proposals-grid">
        <.propose_decision wallet={@page.wallet} propose={@page.propose} />
        <.propose_payment wallet={@page.wallet} propose={@page.propose} />
        <.propose_launch wallet={@page.wallet} propose={@page.propose} launch_plans={@launch_plans} />
        <.voting_delegate wallet={@page.wallet} />
      </div>

      <.budget :if={@page.treasury} treasury={@page.treasury} wallet={@page.wallet} />
    </article>
    """
  end

  attr :page, :map, required: true

  def detail(%{page: %{fleet_name: nil}} = assigns),
    do: ~H|<.missing_fleet id="proposal-page" />|

  def detail(%{page: %{proposal: nil}} = assigns) do
    ~H"""
    <article id="proposal-page" class="proposals-page">
      <.detail_heading page={@page} />
      <section id="proposal-missing" class="proposals-panel">
        <h2>There is no proposal {@page.number} in this fleet yet.</h2>
        <.link navigate={ProposalsPage.list_path(@page.fleet_id)}>See every proposal</.link>
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
              <dd id="proposal-yes">{keys(@page.proposal.yes)}</dd>
            </div>
            <div>
              <dt>No</dt>
              <dd id="proposal-no">{keys(@page.proposal.no)}</dd>
            </div>
            <div>
              <dt>Keys sold</dt>
              <dd id="proposal-keys-sold">{keys(@page.proposal.keys_sold)}</dd>
            </div>
          </dl>
          <.pass_rule />
          <p :if={@page.proposal.executor} id="proposal-executor" class="proposals-detail">
            Carried out by <.wallet address={@page.proposal.executor} />
          </p>
        </section>

        <.vote
          :if={@page.wallet}
          wallet={@page.wallet}
          proposal={@page.proposal}
        />
        <.carry_out :if={@page.wallet} wallet={@page.wallet} proposal={@page.proposal} />

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

          <.launch :if={@page.proposal.launch} launch={@page.proposal.launch} />

          <.text :if={@page.proposal.text} text={@page.proposal.text} />
          <p :if={@page.proposal.text_cut?} class="proposals-detail">
            This proposal is longer than can be shown here. Its first 64 KB are shown.
          </p>
        </section>

        <.plan
          :if={@page.proposal.plan}
          plan={@page.proposal.plan}
          fleet_id={@page.fleet_id}
        />

        <section class="proposals-panel proposals-votes" aria-labelledby="proposal-votes-title">
          <h2 id="proposal-votes-title">Votes</h2>
          <p :if={@page.votes == [] and is_nil(@page.first_votes)} id="proposal-no-votes">
            No votes yet.
          </p>
          <ol :if={@page.votes != []} id="proposal-votes" class="proposals-lines">
            <li :for={vote <- @page.votes} data-vote={vote.id}>
              <span>{vote_word(vote.support)}</span>
              <span>{FleetLive.short_wallet(vote.voter)}, with {key_list(vote.keys)}</span>
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

  attr :wallet, :map, required: true
  attr :proposal, :map, required: true

  # Each key is one vote, so a vote names its keys: the voter's own, or those
  # of someone who let their wallet vote for them. The contract decides which
  # can vote.
  defp vote(assigns) do
    ~H"""
    <section id="proposal-vote" class="proposals-panel" aria-labelledby="proposal-vote-title">
      <h2 id="proposal-vote-title">Vote</h2>
      <.action id="proposal-vote-action" to={@wallet.votes} wallet={@wallet}>
        <:fields>
          <div
            id={"proposal-vote-fields-#{@proposal.number}"}
            class="proposals-form"
            phx-update="ignore"
          >
            <.text_field
              id="proposal-vote-keys"
              name="keys"
              label="Keys to vote with"
              inputmode="numeric"
            >
              Each key is one vote. Separate key numbers with commas.
            </.text_field>
          </div>
        </:fields>
        <:notes>
          <p :if={@proposal.status == :executed} id="proposal-vote-closed" class="proposals-detail">
            It has already been carried out, so a vote now will be refused.
          </p>
          <p class="proposals-detail">
            Type the numbers of the keys you’re voting with: your own, or those of someone who has let your wallet vote for them.
          </p>
        </:notes>
        <:buttons>
          <Regent.Primitives.button
            id="proposal-vote-yes"
            data-fleet-action="vote"
            data-support="yes"
            data-proposal={@proposal.number}
          >
            <span data-press-label>Vote yes</span>
          </Regent.Primitives.button>
          <Regent.Primitives.button
            id="proposal-vote-no"
            variant="secondary"
            data-fleet-action="vote"
            data-support="no"
            data-proposal={@proposal.number}
          >
            <span data-press-label>Vote no</span>
          </Regent.Primitives.button>
        </:buttons>
      </.action>
    </section>
    """
  end

  attr :wallet, :map, required: true
  attr :proposal, :map, required: true

  # Anyone may carry out a proposal once more than half of all the keys sold
  # have voted yes.
  defp carry_out(assigns) do
    assigns = assign(assigns, :note, carry_out_note(assigns.proposal))

    ~H"""
    <section
      id="proposal-carry-out"
      class="proposals-panel"
      aria-labelledby="proposal-carry-out-title"
    >
      <h2 id="proposal-carry-out-title">Carry it out</h2>
      <.action id="proposal-carry-out-action" to={@wallet.votes} wallet={@wallet}>
        <:notes>
          <p class="proposals-detail">
            Anyone can carry out a proposal once more than half of all the keys sold have voted yes.
          </p>
          <p :if={@note} id="proposal-carry-out-note" class="proposals-detail">{@note}</p>
        </:notes>
        <:buttons>
          <Regent.Primitives.button
            id="proposal-carry-out-button"
            data-fleet-action="execute"
            data-proposal={@proposal.number}
          >
            <span data-press-label>{carry_out_word(@proposal.kind)}</span>
          </Regent.Primitives.button>
        </:buttons>
      </.action>
    </section>
    """
  end

  attr :wallet, :map, required: true
  attr :propose, :map, required: true

  # A decision records what the key holders agreed to, and does nothing else.
  defp propose_decision(assigns) do
    ~H"""
    <section id="propose-decision" class="proposals-panel" aria-labelledby="propose-decision-title">
      <h2 id="propose-decision-title">Propose a decision</h2>
      <p class="proposals-detail">
        Records what the key holders agree to once more than half of all the keys sold vote yes. Nothing is paid or launched by it.
      </p>
      <.action id="propose-decision-action" to={@wallet.votes} wallet={@wallet}>
        <:fields>
          <div id="propose-decision-fields" class="proposals-form" phx-update="ignore">
            <.key_field id="propose-decision-key" />
            <Regent.Primitives.field :let={field} id="propose-decision-text" label="What to decide">
              <textarea id={field.id} name="text" rows="4" aria-describedby={field.described_by}></textarea>
            </Regent.Primitives.field>
            <.document_code_field id="propose-decision-digest">
              A code for the exact document this is about: 64 characters, 0 to 9 and a to f. Leave it empty if there isn’t one.
            </.document_code_field>
          </div>
        </:fields>
        <:buttons>
          <Regent.Primitives.button id="propose-decision-button" data-fleet-action="propose_decision">
            <span data-press-label>Propose this decision</span>
          </Regent.Primitives.button>
        </:buttons>
      </.action>
    </section>
    """
  end

  attr :wallet, :map, required: true
  attr :propose, :map, required: true

  defp propose_payment(assigns) do
    ~H"""
    <section id="propose-payment" class="proposals-panel" aria-labelledby="propose-payment-title">
      <h2 id="propose-payment-title">Propose a payment</h2>
      <p class="proposals-detail">
        Pays from the budget once more than half of all the keys sold vote yes, up to the yes votes’ share of it. For each key that didn’t vote yes, the payment divided by the number of yes votes is set aside for it to collect.
      </p>
      <.action
        id="propose-payment-action"
        to={@wallet.votes}
        wallet={@wallet}
        data-assets={assets(@propose.assets)}
      >
        <:fields>
          <div id="propose-payment-fields" class="proposals-form" phx-update="ignore">
            <.key_field id="propose-payment-key" />
            <Regent.Primitives.field :let={field} id="propose-payment-asset" label="Token">
              <select id={field.id} name="asset" aria-describedby={field.described_by}>
                <option :for={asset <- @propose.assets} value={asset.address}>{asset.name}</option>
              </select>
            </Regent.Primitives.field>
            <.text_field
              id="propose-payment-amount"
              name="amount"
              label="Amount"
              inputmode="decimal"
            >
              In whole tokens, like 12.5, with a point for decimals. A token listed in its smallest units takes a whole number.
            </.text_field>
            <.text_field id="propose-payment-recipient" name="recipient" label="Pay to">
              The wallet that receives the payment.
            </.text_field>
            <Regent.Primitives.field :let={field} id="propose-payment-text" label="Why">
              <textarea id={field.id} name="text" rows="3" aria-describedby={field.described_by}></textarea>
            </Regent.Primitives.field>
            <.document_code_field id="propose-payment-digest">
              A code for the exact invoice or work this pays for: 64 characters, 0 to 9 and a to f. Leave it empty if there isn’t one.
            </.document_code_field>
          </div>
        </:fields>
        <:buttons>
          <Regent.Primitives.button id="propose-payment-button" data-fleet-action="propose_pay">
            <span data-press-label>Propose this payment</span>
          </Regent.Primitives.button>
        </:buttons>
      </.action>
    </section>
    """
  end

  attr :wallet, :map, required: true
  attr :propose, :map, required: true
  attr :launch_plans, :list, required: true

  # The five fields a launch shows, exactly as its holders will read them.
  # Choosing a launch plan fills them in from its current version and makes
  # the proposal point to that version; the picker, the fields and what the
  # proposal points to are the page's own until it is reloaded, so a new
  # reading of the page never changes a choice under the person making it.
  defp propose_launch(assigns) do
    ~H"""
    <section id="propose-launch" class="proposals-panel" aria-labelledby="propose-launch-title">
      <h2 id="propose-launch-title">Propose a launch</h2>
      <p class="proposals-detail">
        Launches this fleet’s token once more than half of all the keys sold vote yes. Another launch can only follow one that didn’t succeed.
      </p>
      <.action id="propose-launch-action" to={@wallet.votes} wallet={@wallet}>
        <:fields>
          <div
            id="propose-launch-fields"
            class="proposals-form"
            phx-update="ignore"
            phx-hook="LaunchPlanPicker"
          >
            <.key_field id="propose-launch-key" />
            <.launch_plan_picker plans={@launch_plans} />
            <.text_field id="propose-launch-name" name="name" label="Name" />
            <.text_field id="propose-launch-symbol" name="symbol" label="Symbol" />
            <Regent.Primitives.field :let={field} id="propose-launch-description" label="Description">
              <textarea
                id={field.id}
                name="description"
                rows="3"
                aria-describedby={field.described_by}
              ></textarea>
            </Regent.Primitives.field>
            <.text_field id="propose-launch-website" name="website" label="Website" />
            <.text_field id="propose-launch-image" name="image" label="Image">
              A link to the token’s image.
            </.text_field>
            <.text_field
              id="propose-launch-raise"
              name="raise"
              label="REGENT to raise"
              inputmode="decimal"
            >
              In whole REGENT, like 250000.
            </.text_field>
          </div>
        </:fields>
        <:buttons>
          <Regent.Primitives.button id="propose-launch-button" data-fleet-action="propose_launch">
            <span data-press-label>Propose this launch</span>
          </Regent.Primitives.button>
        </:buttons>
      </.action>
    </section>
    """
  end

  attr :plans, :list, required: true

  # Each option carries its plan's launch details and digest for the page to
  # copy into the form; the hidden digest is what the proposal points to,
  # and is empty, pointing nowhere, until a plan is chosen.
  defp launch_plan_picker(assigns) do
    ~H"""
    <Regent.Primitives.field :let={field} id="propose-launch-plan" label="Start from a launch plan">
      <select
        id={field.id}
        aria-describedby={field.described_by}
        autocomplete="off"
        data-launch-plans
      >
        <option value="">Don’t use a plan</option>
        <option
          :for={plan <- @plans}
          value={plan.digest}
          data-title={plan.title}
          data-version={plan.version}
          data-name={plan.fields.name}
          data-symbol={plan.fields.symbol}
          data-description={plan.fields.description}
          data-website={plan.fields.website}
          data-image={plan.fields.image}
          data-raise={plan.fields.raise}
        >
          {plan.title}, version {plan.version}
        </option>
      </select>
      <:hint :if={@plans == []}>
        No launch plan in the workspace has all six launch details filled in yet.
      </:hint>
      <:hint :if={@plans != []}>
        Fills in the launch details below from that version of the plan.
      </:hint>
    </Regent.Primitives.field>
    <input id="propose-launch-digest" type="hidden" name="digest" value="" autocomplete="off" />
    <p
      id="propose-launch-plan-status"
      class="proposals-detail"
      aria-live="polite"
      data-launch-plan-status
    >
      This proposal won’t point to a launch plan.
    </p>
    """
  end

  attr :wallet, :map, required: true

  defp voting_delegate(assigns) do
    ~H"""
    <section id="voting-delegate" class="proposals-panel" aria-labelledby="voting-delegate-title">
      <h2 id="voting-delegate-title">Let another wallet vote for you</h2>
      <p class="proposals-detail">
        It can vote and propose with every key you hold, until you stop it. It never holds your keys or their rewards, and you can still vote yourself.
      </p>
      <.action id="voting-delegate-action" to={@wallet.votes} wallet={@wallet}>
        <:fields>
          <div id="voting-delegate-fields" class="proposals-form" phx-update="ignore">
            <.text_field id="voting-delegate-wallet" name="delegate" label="Wallet to vote for you" />
          </div>
        </:fields>
        <:buttons>
          <Regent.Primitives.button id="voting-delegate-button" data-fleet-action="delegate">
            <span data-press-label>Let this wallet vote for me</span>
          </Regent.Primitives.button>
          <Regent.Primitives.button
            id="voting-delegate-clear"
            variant="secondary"
            data-fleet-action="clear_delegate"
          >
            <span data-press-label>Stop any wallet voting for me</span>
          </Regent.Primitives.button>
        </:buttons>
      </.action>
    </section>
    """
  end

  attr :wallet, :map, required: true
  attr :treasury, :map, required: true

  # The stakers' share is sent once a day for them, and anyone may send it
  # sooner.
  defp stakers_share(assigns) do
    ~H"""
    <.action id="proposals-stakers-share" to={@wallet.fleet} wallet={@wallet}>
      <:notes>
        <p class="proposals-detail">
          Part of every key sale is set aside for REGENT stakers. It is sent to them once a day, and anyone can send it sooner.
        </p>
        <p :if={@treasury.nothing_owed?} id="proposals-nothing-owed" class="proposals-detail">
          Nothing is set aside right now, so sending will be refused.
        </p>
      </:notes>
      <:buttons>
        <Regent.Primitives.button id="proposals-send-share" data-fleet-action="send_share">
          <span data-press-label>Send stakers their share</span>
        </Regent.Primitives.button>
      </:buttons>
    </.action>
    """
  end

  attr :id, :string, required: true
  attr :to, :string, required: true, doc: "the contract every press here calls"
  attr :wallet, :map, required: true
  attr :rest, :global
  slot :fields
  slot :notes
  slot :buttons, required: true

  # One group of wallet buttons, the form they read and the answer to each
  # press, newest first. Nothing here ever disables a button. When the
  # connected wallet isn't the signed-in person's, a note beside the buttons
  # says so, and every press still goes to the connected wallet.
  defp action(assigns) do
    ~H"""
    <div
      id={@id}
      class="proposals-action"
      phx-hook="FleetAction"
      data-chain-id={@wallet.chain_id}
      data-to={@to}
      data-signed-in={Jason.encode!(@wallet.signed_in)}
      {@rest}
    >
      {render_slot(@fields)}
      {render_slot(@notes)}
      <div class="proposals-buttons">{render_slot(@buttons)}</div>
      <%!-- Nothing between the tags, so both stay hidden until there is something to say. --%>
      <p
        id={"#{@id}-wallet-note"}
        class="proposals-detail proposals-wallet-note"
        phx-update="ignore"
        data-wallet-note
        phx-no-format
      ></p>
      <ol
        id={"#{@id}-status"}
        class="proposals-status"
        phx-update="ignore"
        aria-live="polite"
        data-fleet-action-status
        phx-no-format
      ></ol>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :inputmode, :string, default: nil
  slot :inner_block

  defp text_field(assigns) do
    ~H"""
    <Regent.Primitives.field :let={field} id={@id} label={@label}>
      <input
        id={field.id}
        name={@name}
        inputmode={@inputmode}
        autocomplete="off"
        aria-describedby={field.described_by}
      />
      <:hint :if={@inner_block != []}>{render_slot(@inner_block)}</:hint>
    </Regent.Primitives.field>
    """
  end

  attr :id, :string, required: true

  defp key_field(assigns) do
    ~H"""
    <.text_field id={@id} name="key" label="Propose with key" inputmode="numeric">
      A key you hold, or one whose holder has let your wallet vote for them. Proposing doesn’t use its vote.
    </.text_field>
    """
  end

  attr :id, :string, required: true
  slot :inner_block, required: true

  defp document_code_field(assigns) do
    ~H"""
    <.text_field id={@id} name="digest" label="Document code (optional)">
      {render_slot(@inner_block)}
    </.text_field>
    """
  end

  attr :treasury, :map, required: true
  attr :wallet, :map, required: true

  defp budget(assigns) do
    ~H"""
    <section id="proposals-budget" class="proposals-panel" aria-labelledby="proposals-budget-title">
      <h2 id="proposals-budget-title">Budget</h2>

      <p :if={not @treasury.read?} id="proposals-budget-pending" class="proposals-detail">
        Budget figures are still being read.
      </p>

      <.balances :if={@treasury.read?} treasury={@treasury} />
      <.stakers_share wallet={@wallet} treasury={@treasury} />

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
        Nothing has been paid from the budget yet.
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
    <dl
      :for={balance <- @treasury.balances}
      class="proposals-facts proposals-balance"
      data-asset={balance.asset}
    >
      <div>
        <dt>Budget</dt>
        <dd><.amount value={balance.budget} /></dd>
      </div>
      <div>
        <dt>Set aside for key holders</dt>
        <dd><.amount value={balance.set_aside} /></dd>
      </div>
    </dl>

    <p id="proposals-budget-as-of" class="proposals-detail">Figures as of {at(@treasury.as_of)}.</p>

    <dl id="proposals-held" class="proposals-facts">
      <div :if={@treasury.reserve}>
        <dt>Held for the next level</dt>
        <dd><.amount value={@treasury.reserve} /></dd>
      </div>
      <div>
        <dt>Set aside for REGENT stakers</dt>
        <dd><.amount value={@treasury.owed} /></dd>
      </div>
    </dl>
    """
  end

  attr :value, :map, required: true

  # An amount, with its token's address beside it, shortened and in full on
  # hover, unless it is the fleet's own USDC. Kept on one line, since it sits
  # inside text.
  defp amount(%{value: %{token: nil}} = assigns),
    do: ~H|<span class="proposals-amount">{@value.text}</span>|

  defp amount(assigns),
    do: ~H|<span class="proposals-amount">{@value.text} <.token address={@value.token} /></span>|

  attr :address, :string, required: true

  defp token(assigns),
    do:
      ~H|<code class="proposals-token" title={@address}>{FleetLive.short_wallet(@address)}</code>|

  attr :address, :string, required: true

  # A wallet shortened, in full on hover.
  defp wallet(assigns),
    do: ~H|<code title={@address}>{FleetLive.short_wallet(@address)}</code>|

  attr :page, :map, required: true

  defp detail_heading(assigns) do
    ~H"""
    <header class="proposals-heading">
      <p class="proposals-kicker">
        <.link navigate={ProposalsPage.list_path(@page.fleet_id)}>
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

  attr :launch, :map, required: true

  defp launch(%{launch: %{read?: false}} = assigns) do
    ~H"""
    <p id="proposal-launch-pending" class="proposals-detail">Launch details are still being read.</p>
    """
  end

  defp launch(assigns) do
    ~H"""
    <dl id="proposal-launch" class="proposals-fields">
      <div :for={{label, value} <- @launch.fields}>
        <dt>{label}</dt>
        <dd>{value}</dd>
      </div>
      <div>
        <dt>REGENT to raise</dt>
        <dd>{@launch.raise}</dd>
      </div>
    </dl>
    """
  end

  attr :plan, :map, required: true
  attr :fleet_id, :string, required: true

  defp plan(assigns) do
    ~H"""
    <section id="proposal-plan" class="proposals-panel" aria-labelledby="proposal-plan-title">
      <h2 id="proposal-plan-title">The plan behind this launch</h2>
      <p :if={not @plan.found?} id="proposal-no-plan" class="proposals-detail">
        This launch doesn’t point to a plan in the workspace.
      </p>
      <div :if={@plan.found?} class="proposals-plan">
        <p id="proposal-plan-version">
          This launch points to <.link navigate={WorkspacePage.item_path(@fleet_id, @plan.object_id)}>{@plan.title}</.link>, version {@plan.version}.
        </p>
        <p :if={@plan.changed?} id="proposal-plan-changed" class="proposals-detail">
          The plan has changed since; this proposal carries version {@plan.version}.
          <.link navigate={WorkspacePage.item_path(@fleet_id, @plan.object_id)}>
            See the plan as it is now
          </.link>
        </p>
        <p :if={@plan.archived?} id="proposal-plan-archived" class="proposals-detail">
          This plan has since been archived.
        </p>
        <p
          :if={@plan.mismatches not in [nil, []]}
          id="proposal-plan-mismatch"
          class="proposals-notice"
          role="note"
        >
          These launch details differ from the plan: {Enum.join(@plan.mismatches, ", ")}.
        </p>
        <dl :if={@plan.fields != []} id="proposal-plan-fields" class="proposals-fields">
          <div :for={{label, value} <- @plan.fields}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        </dl>
        <p id="proposal-plan-benefits" class="proposals-rule">
          Who benefits: the fleet’s keys receive all of the launch’s income, and its budget keeps the REGENT the auction raises beyond what goes into the pool, and the launched tokens as they vest.
        </p>
      </div>
    </section>
    """
  end

  defp catching_up(assigns) do
    ~H"""
    <p id="proposals-catching-up" class="proposals-notice" role="status">
      Vote counts are catching up.
    </p>
    """
  end

  defp pass_rule(assigns) do
    ~H"""
    <p class="proposals-rule">{pass_rule()}</p>
    """
  end

  @doc "How a proposal passes, as the pages say it."
  def pass_rule,
    do:
      "Each key is one vote. A proposal passes once more than half of all the keys sold " <>
        "vote yes, so a key that doesn’t vote counts against it."

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

  defp carry_out_word(kind), do: Map.fetch!(@carry_out_words, kind)

  defp carry_out_note(%{status: status}), do: Map.fetch!(@carry_out_notes, status)

  defp vote_word(true), do: "Yes"
  defp vote_word(false), do: "No"
  defp vote_word(nil), do: "Withdrawn"

  # Each asset by address: the decimals amounts typed in whole tokens are
  # converted with, and the words that name an amount of it.
  defp assets(assets),
    do: Jason.encode!(Map.new(assets, &{&1.address, %{decimals: &1.decimals, unit: &1.unit}}))

  @doc "Where a proposal stands, in the words its pages use."
  def status_word(%{status: :executed, kind: kind}), do: Map.fetch!(@executed_words, kind)
  def status_word(%{status: status}), do: Map.fetch!(@status_words, status)

  defp tally(proposal),
    do: "#{proposal.yes} yes, #{proposal.no} no, of #{keys(proposal.keys_sold)} sold"

  defp keys(1), do: "1 key"
  defp keys(count), do: "#{count} keys"

  defp key_list([token_id]), do: "key #{token_id}"
  defp key_list(token_ids), do: "keys #{Enum.join(token_ids, ", ")}"

  defp at(datetime), do: Calendar.strftime(datetime, "%-d %B %Y at %H:%M UTC")
end

defmodule KeyFleetWeb.ProposalsLive do
  @moduledoc """
  A fleet's proposals, for anyone to read: what its key holders have put to
  a vote, how each vote stands, and each proposal's text, payment or launch
  with every vote cast on it; and beside them the budget they vote on.

  Nothing here writes or asks a wallet for anything. Everything shown is what
  `KeyFleetWeb.ProposalsPage` read.
  """

  use KeyFleetWeb, :html

  alias KeyFleetWeb.ProposalsPage

  @status_words %{
    voting: "Voting open",
    counting: "Counting votes",
    passed: "Passed",
    failed: "Did not pass",
    closed: "Closed: another launch went ahead",
    expired: "Expired"
  }

  @executed_words %{decision: "Passed and recorded", autolaunch: "Launched", pay: "Paid"}

  attr :page, :map, required: true

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
              <span>{closing(proposal)}</span>
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

      <.budget :if={@page.treasury} treasury={@page.treasury} />
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
              <dt>Keys that could vote</dt>
              <dd>{keys(@page.proposal.eligible_keys)}</dd>
            </div>
          </dl>
          <p class="proposals-detail">{closing(@page.proposal)}</p>
          <.pass_rule />
          <p :if={@page.proposal.executor} class="proposals-detail">
            Carried out by <code>{@page.proposal.executor}</code>
          </p>
        </section>

        <section class="proposals-panel" aria-labelledby="proposal-content-title">
          <h2 id="proposal-content-title">{ProposalsPage.kind_name(@page.proposal.kind)}</h2>
          <p class="proposals-detail">
            Proposed by <code>{@page.proposal.proposer}</code>
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

          <p :if={@page.proposal.last_day} id="proposal-last-day" class="proposals-detail">
            {last_day_words(@page.proposal)}
          </p>

          <.text :if={@page.proposal.text} text={@page.proposal.text} />
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
              <span>{if vote.support, do: "Yes", else: "No"}</span>
              <span>{short_wallet(vote.voter)}, with {key_list(vote.keys)}</span>
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

  attr :treasury, :map, required: true

  defp budget(assigns) do
    ~H"""
    <section id="proposals-budget" class="proposals-panel" aria-labelledby="proposals-budget-title">
      <h2 id="proposals-budget-title">Budget</h2>

      <p :if={not @treasury.read?} id="proposals-budget-pending" class="proposals-detail">
        Budget figures are still being read.
      </p>

      <.balances :if={@treasury.read?} treasury={@treasury} />

      <h3>Launch income</h3>
      <p :if={@treasury.income == []} id="proposals-no-income" class="proposals-detail">
        No launch income yet.
      </p>
      <ol :if={@treasury.income != []} id="proposals-income" class="proposals-lines">
        <li :for={income <- @treasury.income} data-income={income.id}>
          <span><.amount value={income.received} /> received</span>
          <span class="proposals-detail">
            <span>
              <.amount value={income.to_budget} /> to the budget, <.amount value={income.to_keys} />
              to key holders, <.amount value={income.fee} /> fee
            </span>
          </span>
        </li>
      </ol>
      <p :if={@treasury.earlier_income?} class="proposals-detail">
        Earlier launch income is not shown here.
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
    <p :if={not @treasury.payments_open?} id="proposals-payments-closed" class="proposals-detail">
      Payments from the budget open once the launch has finished.
    </p>

    <dl
      :for={balance <- @treasury.balances}
      class="proposals-facts proposals-balance"
      data-asset={balance.asset}
    >
      <div>
        <dt>Budget</dt>
        <dd><.amount value={balance.budget} /></dd>
      </div>
      <div :if={@treasury.payments_open?}>
        <dt>Available this month</dt>
        <dd><.amount value={balance.available} /></dd>
      </div>
      <div :if={balance.paid}>
        <dt>Paid this month</dt>
        <dd><.paid paid={balance.paid} until={balance.month_ends} /></dd>
      </div>
      <div>
        <dt>Set aside for key holders</dt>
        <dd><.amount value={balance.set_aside} /></dd>
      </div>
    </dl>

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

    <p class="proposals-rule">
      A month of payments starts with its first payment, and can pay out up to a fifth of the budget as it stood then.
    </p>
    <p id="proposals-budget-as-of" class="proposals-detail">Figures as of {at(@treasury.as_of)}.</p>
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

  attr :paid, :map, required: true
  attr :until, DateTime, required: true

  defp paid(assigns),
    do: ~H|<.amount value={@paid.spent} /> of <.amount value={@paid.cap} />, until {at(@until)}|

  attr :address, :string, required: true

  defp token(assigns),
    do: ~H|<code class="proposals-token" title={@address}>{short_wallet(@address)}</code>|

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
      "Each key is one vote. A proposal passes when more than half of the keys that could " <>
        "vote on it vote yes, so a key that doesn’t vote counts against it."

  attr :id, :string, required: true

  # Told the way the fleet's own page tells it.
  defp missing_fleet(assigns) do
    ~H"""
    <article id={@id} class="proposals-page">
      <header class="proposals-heading">
        <p class="proposals-kicker">Fleet</p>
        <h1 tabindex="-1">KeyFleet</h1>
      </header>

      <section id="proposals-unavailable" class="proposals-panel">
        <h2>This fleet doesn’t exist.</h2>
      </section>
    </article>
    """
  end

  defp status_word(%{status: :executed, kind: kind}), do: Map.fetch!(@executed_words, kind)
  defp status_word(%{status: status}), do: Map.fetch!(@status_words, status)

  defp tally(proposal),
    do:
      "#{proposal.yes} yes, #{proposal.no} no, of #{keys(proposal.eligible_keys)} that could vote"

  defp closing(%{status: :voting, closes_at: closes_at}), do: "Voting closes #{at(closes_at)}"
  defp closing(%{closes_at: closes_at}), do: "Voting closed #{at(closes_at)}"

  defp last_day_words(%{kind: :pay, last_day: last_day}), do: "Can be paid until #{at(last_day)}"

  defp last_day_words(%{kind: :autolaunch, last_day: last_day}),
    do: "Can be launched until #{at(last_day)}"

  defp keys(1), do: "1 key"
  defp keys(count), do: "#{count} keys"

  defp key_list([token_id]), do: "key #{token_id}"
  defp key_list(token_ids), do: "keys #{Enum.join(token_ids, ", ")}"

  defp short_wallet(wallet),
    do: String.slice(wallet, 0, 6) <> "…" <> String.slice(wallet, -4, 4)

  defp at(datetime), do: Calendar.strftime(datetime, "%-d %B %Y at %H:%M UTC")
end

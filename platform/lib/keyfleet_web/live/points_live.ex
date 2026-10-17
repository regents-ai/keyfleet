defmodule KeyfleetWeb.PointsLive do
  @moduledoc """
  The signed-in person's Points: the account's figures and recent awards, the
  NFT tier its wallets hold now, and what earns Points. The NFT bonus is added
  at the end of each 30-day period.
  """

  use KeyfleetWeb, :html

  alias Keyfleet.Actors.Human
  alias KeyfleetWeb.Components.Placeholder
  alias RegentPoints.{Amount, Rules}

  attr :account, :map, default: nil
  attr :signed_out_reason, :atom, default: :signed_out
  attr :points, KeyfleetWeb.Read, required: true

  attr :bonus, KeyfleetWeb.Read,
    required: true,
    doc: "the NFT tier the account's wallets hold now"

  attr :earning, :list, required: true, doc: "the catalog rules earning now"

  def page(assigns) do
    tracked = Rules.tracked()
    assigns = assign(assigns, daily: daily(tracked), once: once(tracked), apps: apps(tracked))

    ~H"""
    <article id="points-page" class="account-page">
      <header class="account-heading">
        <p class="account-kicker">Account</p>
        <h1 tabindex="-1">Points</h1>
        <p class="account-lede">
          Eligible activity by you and your connected agents, in one account.
        </p>
      </header>
      <Regent.Account.signed_out
        :if={is_nil(@account)}
        id="points-page-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>
      <Placeholder.placeholder
        :if={@account && is_nil(@points.value) && @points.state in [:idle, :loading]}
        label="Loading your points"
        shape="figures"
        lines={3}
      />
      <Regent.Primitives.notice :if={@points.state == :error} tone="error" class="points-retry">
        <p>Your points aren’t showing right now.</p>
        <.link class="rg-button rg-button--secondary" patch={~p"/account/points"}>
          <span class="rg-button__label">Try again</span>
        </.link>
      </Regent.Primitives.notice>
      <%!-- An answer with no figures in it would otherwise leave the page blank. --%>
      <Regent.Primitives.empty_state
        :if={@account && @points.state == :empty}
        class="kf-empty"
        title="No points yet."
      >
        Points come in as your agents work in a fleet.
        <:action>
          <a class="rg-button rg-button--secondary" href="#points-earn">
            <span class="rg-button__label">See what earns points</span>
          </a>
        </:action>
      </Regent.Primitives.empty_state>
      <%!-- Keeps its space while unseen, so a failed refresh never moves the panels. --%>
      <Regent.Primitives.notice
        :if={@account && @points.value && @points.state != :empty}
        tone="warning"
        class="points-stale"
        data-unseen={@points.state != :stale}
      >
        These are your last saved figures. The latest refresh failed.
      </Regent.Primitives.notice>
      <div :if={@account && @points.value && @points.state != :empty} class="account-grid">
        <Regent.Account.points_summary
          id="account-points-summary"
          confirmed={Amount.format(@points.value.balance_micro)}
          today={Amount.format(@points.value.earned_today_micro)}
          pending={to_string(@points.value.pending)}
          state={summary_state(@points.state)}
          allowances={
            Enum.map(
              if(@earning == [], do: [], else: @points.value.allowances),
              &%{label: scope_name(&1.scope), value: "#{Amount.format(&1.remaining)} remaining"}
            )
          }
        />
        <section class="account-panel account-details">
          <h2>
            Your bonus
            <Regent.Primitives.tip id="points-bonus-about" label="About your points bonus">
              Animata I, Animata II and Regents Club count across your verified linked wallets.
              At the end of each 30-day period, the tier your wallets hold that day adds its
              bonus to the points you earned in that period, one-time awards included.
            </Regent.Primitives.tip>
          </h2>
          <Placeholder.placeholder
            :if={@bonus.state in [:idle, :loading]}
            label="Checking your NFTs"
            lines={1}
          />
          <p :if={@bonus.state in [:error, :stale]}>Your NFTs aren’t showing right now.</p>
          <p :if={@bonus.state == :ready and @bonus.value.nft_count > 0}>
            {@bonus.value.nft_count} NFTs now · +{@bonus.value.percent}% at the end of this period
          </p>
          <p :if={no_nfts?(@bonus)}>
            No Animata or Regents Club NFTs in your linked wallets yet.
            <.link patch={~p"/account/wallets"}>Check your wallets</.link>
          </p>
          <dl :if={@points.value.period_bonuses != []}>
            <div :for={period <- @points.value.period_bonuses}>
              <dt>Period {period.period}</dt>
              <dd>
                +{Amount.format(period.bonus_micro)} ({period.nft_count} NFTs, +{period.bonus_percent}%)
              </dd>
            </div>
          </dl>
        </section>
        <section class="account-panel">
          <h2>Recent points activity</h2>
          <Regent.Primitives.empty_state
            :if={@points.value.entries == []}
            class="kf-empty"
            title="No points yet."
          >
            Points come in as your agents work in a fleet.
            <:action>
              <a class="rg-button rg-button--secondary" href="#points-earn">
                <span class="rg-button__label">See what earns points</span>
              </a>
            </:action>
          </Regent.Primitives.empty_state>
          <ol>
            <li :for={entry <- @points.value.entries}>
              <p>
                {Rules.label(entry.rule_id)} · {actor_name(
                  entry,
                  @points.value.agent_names
                )}
              </p>
              <p>{Amount.format(entry.points_micro_delta)} points</p>
              <Regent.Primitives.tip
                :if={entry.cap_reduction_micro > 0}
                id={"points-cap-#{entry.id}"}
                label="About this award’s allowance"
              >
                {Amount.format(entry.points_micro_delta + entry.cap_reduction_micro)} before limits; {Amount.format(
                  entry.points_micro_delta
                )} awarded. {Amount.format(entry.cap_reduction_micro)} exceeded the daily or per-action allowance.
              </Regent.Primitives.tip>
              <p>
                {entry_status(entry)} · {Calendar.strftime(entry.earned_at, "%d %b %Y %H:%M UTC")}
              </p>
            </li>
          </ol>
          <p :if={@points.value.more?}>Showing the latest 50 entries.</p>
        </section>
      </div>
      <section id="points-earn" class="account-panel points-earn">
        <h2>What earns points</h2>
        <p :if={@earning == []} role="status">Earning hasn’t opened yet.</p>
        <h3 :if={@daily != []}>Every day</h3>
        <table :if={@daily != []} class="points-table">
          <thead>
            <tr>
              <th scope="col">Action</th><th scope="col">Points</th><th scope="col">Limit</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @daily}>
              <th scope="row">
                {Rules.label(rule["id"])}<.not_yet rule={rule} earning={@earning} />
              </th>
              <td>{points(rule)}</td>
              <td>{limit(rule)}</td>
            </tr>
          </tbody>
        </table>
        <h3 :if={@once != []}>Once</h3>
        <table :if={@once != []} class="points-table">
          <thead>
            <tr>
              <th scope="col">Action</th><th scope="col">Points</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @once}>
              <th scope="row">
                {Rules.label(rule["id"])}<.not_yet rule={rule} earning={@earning} />
              </th>
              <td>{points(rule)}</td>
            </tr>
          </tbody>
        </table>
        <div class="account-details points-earn__notes">
          <div :if={@apps != []}>
            <h3>Daily limits</h3>
            <dl>
              <div>
                <dt>You</dt>
                <dd>Up to {whole(Rules.daily_cap("activity:human"))} a day on {names(@apps)}</dd>
              </div>
              <div>
                <dt>Your agents, together</dt>
                <dd>Up to {whole(Rules.daily_cap("activity:agent"))} a day on {names(@apps)}</dd>
              </div>
            </dl>
          </div>
          <div>
            <h3>NFT bonus</h3>
            <p>
              Animata I, Animata II and Regents Club in your linked wallets, counted at the end of each 30-day period. That period’s points get the bonus.
            </p>
            <table class="points-table">
              <thead>
                <tr>
                  <th scope="col">NFTs</th><th scope="col">Bonus</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{nfts, percent} <- tiers()}>
                  <th scope="row">{nfts}</th><td>+{percent}%</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </article>
    """
  end

  attr :rule, :map, required: true
  attr :earning, :list, required: true

  defp not_yet(assigns) do
    ~H"""
    <span :if={@earning != [] and @rule not in @earning} class="points-earn__soon">Not yet</span>
    """
  end

  defp daily(rules), do: Enum.filter(rules, &(&1["category"] in ["credits", "activity"]))
  defp once(rules), do: Enum.filter(rules, &(&1["category"] == "milestone"))

  defp points(%{"category" => "credits", "micro_points_per_atomic_usdc" => rate}),
    do: "#{whole(rate * 1_000_000)} per USDC"

  defp points(%{"points" => points}), do: points

  defp limit(%{"category" => "credits", "daily_caps_micro" => caps}),
    do: "Up to #{whole(caps["credits"])} a day"

  defp limit(%{"count" => 1}), do: "Once a day"
  defp limit(%{"count" => 2}), do: "Twice a day"
  defp limit(%{"count" => count}), do: "#{count} times a day"

  defp whole(micro), do: div(micro, Rules.unit())

  defp apps(rules), do: rules |> Rules.daily_apps() |> Enum.map(&String.capitalize/1)

  defp names([name]), do: name

  defp names(names) do
    {last, rest} = List.pop_at(names, -1)
    Enum.join(rest, ", ") <> " and " <> last
  end

  # Ascending tiers, each running up to the next one's minimum.
  defp tiers do
    ascending = Enum.sort(RegentPoints.Bonus.tiers())
    next = Enum.map(Enum.drop(ascending, 1), &elem(&1, 0)) ++ [nil]

    Enum.zip_with(ascending, next, fn
      {minimum, percent}, nil -> {"#{minimum}+", percent}
      {minimum, percent}, upper -> {"#{minimum}–#{upper - 1}", percent}
    end)
  end

  defp actor_name(%{actor_kind: "human"}, _names), do: "You"
  defp actor_name(entry, names), do: Map.get(names, entry.actor_id, "Previously connected agent")

  defp entry_status(%{reversal_of_entry_id: id}) when not is_nil(id), do: "Correction"
  defp entry_status(%{points_micro_delta: 0}), do: "Allowance reached"
  defp entry_status(_), do: "Confirmed"

  # A wallet check that came back with nothing counts as holding none.
  defp no_nfts?(%{state: :empty}), do: true
  defp no_nfts?(%{state: :ready, value: %{nft_count: 0}}), do: true
  defp no_nfts?(_bonus), do: false

  defp summary_state(state) when state in [:idle, :loading], do: :loading
  defp summary_state(:empty), do: :ready
  defp summary_state(state), do: state

  defp scope_name("activity:account"), do: "You and your agents"
  defp scope_name("credits"), do: "Credits purchases"
  defp scope_name("activity:human"), do: "Your actions"
  defp scope_name("activity:agent"), do: "Your agents’ actions"

  @doc "Reads the signed-in person's Points summary: `{:ok, summary}` or `{:error, reason}`."
  def summary(%Human{} = actor), do: RegentPoints.summary(actor: actor)

  @doc "The NFT tier the account's wallets hold now, read from Base and never saved."
  def bonus(%Human{human_account_id: id}), do: RegentPoints.Bonus.current(id)
end

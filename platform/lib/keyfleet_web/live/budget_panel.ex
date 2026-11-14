defmodule KeyfleetWeb.BudgetPanel do
  @moduledoc """
  The Budget panel on a project's page, for the fleet's members only: the
  project's latest budget, the Key that opened it, its limit, what it spent
  and has left, when it expires, and each purchase with its trail (state,
  price, who proposed it, who decided it, Patchbay's receipt and whether the
  fix worked). It says the budget is sponsor-funded and kept by this site,
  and that the receipt and payment are not checked. A member opens a budget
  here as the Key it is in the fleet as, when the project has none open
  (`Keyfleet.Budgets`).
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Budgets
  alias Keyfleet.Budgets.Errors.BudgetError
  alias Keyfleet.Keys
  alias Keyfleet.Projects.Errors.ClosedError
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.ProposalsPage

  @doc """
  The panel for `actor` on the fleet's project `name`: `%{budget:, notice:}`
  for a member, `nil` for anyone else, who sees no panel.
  """
  def read(actor, fleet_id, name) do
    case Budgets.project_budget(fleet_id, name, actor: actor) do
      {:ok, budget} -> %{fleet_id: fleet_id, project: name, budget: budget, notice: nil}
      {:error, _not_a_member} -> nil
    end
  end

  @doc """
  Opens a budget on the panel's project as the Key `actor` is in the fleet
  as: the panel read again, or with the refusal's words.
  """
  def open(panel, actor, %{"limit" => limit, "expires_on" => day} = params) do
    with %{token_id: key} <- Keys.identity(actor, panel.fleet_id),
         {:ok, limit} <- base_units(limit),
         {:ok, expires_at} <- end_of(day),
         {:ok, _budget} <-
           Budgets.open_budget(
             panel.fleet_id,
             key,
             panel.project,
             limit,
             expires_at,
             blank_nil(params["source"]),
             actor: actor
           ) do
      read(actor, panel.fleet_id, panel.project)
    else
      nil -> %{panel | notice: "Only a member of this fleet opens a budget."}
      {:error, words} when is_binary(words) -> %{panel | notice: words}
      {:error, error} -> %{panel | notice: refused(error)}
    end
  end

  attr :panel, :map, required: true

  def panel(assigns) do
    ~H"""
    <section id="project-budget" class="project-part budget-panel" aria-labelledby="budget-title">
      <h2 id="budget-title">Budget</h2>
      <p class="project-note">
        Funded by its sponsor. This site keeps the limit; no contract holds the money.
      </p>

      <dl :if={@panel.budget} id="budget-figures" class="budget-figures">
        <div>
          <dt>Sponsor</dt><dd>{key_name(@panel.budget.sponsor_key)}</dd>
        </div>
        <div>
          <dt>Limit</dt><dd id="budget-limit">{usdc(@panel.budget.limit_usdc)}</dd>
        </div>
        <div>
          <dt>Spent</dt><dd id="budget-spent">{usdc(@panel.budget.spent_usdc)}</dd>
        </div>
        <div>
          <dt>Remaining</dt>
          <dd id="budget-remaining">{usdc(@panel.budget.remaining_usdc)}</dd>
        </div>
        <div>
          <dt>Expiry</dt>
          <dd id="budget-expiry">
            {Calendar.strftime(@panel.budget.expires_at, "%-d %b %Y %H:%M UTC")}
            <span :if={@panel.budget.expired?} class="project-type">Expired</span>
          </dd>
        </div>
        <div :if={@panel.budget.source}>
          <dt>Source</dt><dd>{@panel.budget.source}</dd>
        </div>
      </dl>

      <ul
        :if={@panel.budget && @panel.budget.purchases != []}
        id="budget-purchases"
        class="project-items"
      >
        <li :for={purchase <- @panel.budget.purchases} data-purchase={purchase.id}>
          <div class="project-item">
            <a href={purchase.assist_url} class="project-title" rel="noopener noreferrer">
              {purchase.purpose}
            </a>
            <span class="project-by">
              {usdc(purchase.price_usdc)} · proposed by {key_name(purchase.proposed_by_key)}
              <span :if={purchase.decided_by_key}>
                · {decision(purchase)} by {key_name(purchase.decided_by_key)}
              </span>
            </span>
            <span :if={purchase.refusal_reason} class="project-by">{purchase.refusal_reason}</span>
            <span :if={purchase.receipt_url} class="project-by">
              <a href={purchase.receipt_url} rel="noopener noreferrer">Receipt</a> · Not checked
            </span>
            <span :if={purchase.checked_by_key} class="project-by">
              {if purchase.worked, do: "Fix worked", else: "Fix failed"}, checked by {key_name(
                purchase.checked_by_key
              )}: {purchase.result_note}
              <a :if={purchase.evidence_url} href={purchase.evidence_url} rel="noopener noreferrer">
                Evidence
              </a>
            </span>
          </div>
          <span class="project-standing">{state(purchase.state)}</span>
        </li>
      </ul>
      <p :if={@panel.budget && @panel.budget.purchases == []} class="project-empty">
        No purchases yet.
      </p>

      <form
        :if={is_nil(@panel.budget) or @panel.budget.expired?}
        id="budget-open"
        class="budget-open"
        phx-submit="budget_open"
      >
        <label>
          Limit (USDC) <input name="limit" type="text" inputmode="decimal" required />
        </label>
        <label>
          Expiry <input name="expires_on" type="date" required />
        </label>
        <label>
          Source <input name="source" type="text" maxlength="200" />
        </label>
        <Regent.Primitives.button type="submit">Open budget</Regent.Primitives.button>
      </form>
      <p :if={@panel.notice} id="budget-notice" class="project-note" role="status">
        {@panel.notice}
      </p>
    </section>
    """
  end

  defp usdc(units), do: "#{ProposalsPage.units(units, 6)} USDC"

  defp key_name(key), do: ActivityLines.key_name(key, nil)

  defp decision(%{state: :refused, refusal_code: :refused}), do: "Refused"
  defp decision(%{state: :refused}), do: "Refused by the site"
  defp decision(_purchase), do: "Approved"

  defp state(:proposed), do: "Proposed"
  defp state(:approved), do: "Approved"
  defp state(:refused), do: "Refused"
  defp state(:bought), do: "Bought"
  defp state(:worked), do: "Worked"
  defp state(:failed), do: "Failed"

  # USDC as a person writes it, "12.5", in base units: six decimals at most.
  defp base_units(text) do
    case Regex.run(~r/\A\s*(\d{1,12})(?:\.(\d{1,6}))?\s*\z/, text) do
      [_all, whole] ->
        positive(String.to_integer(whole) * 1_000_000)

      [_all, whole, fraction] ->
        positive(
          String.to_integer(whole) * 1_000_000 +
            String.to_integer(String.pad_trailing(fraction, 6, "0"))
        )

      nil ->
        {:error, "Write the limit in USDC, such as 25 or 12.50."}
    end
  end

  defp positive(units) when units > 0, do: {:ok, units}
  defp positive(_none), do: {:error, "The limit is more than zero."}

  # A budget runs to the end of its expiry day, UTC.
  defp end_of(day) do
    case Date.from_iso8601(day) do
      {:ok, date} -> {:ok, DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")}
      {:error, _not_a_day} -> {:error, "Choose the day the budget expires."}
    end
  end

  defp blank_nil(nil), do: nil

  defp blank_nil(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  defp refused(%Ash.Error.Forbidden{}), do: "Only a member of this fleet opens a budget."

  defp refused(%{errors: [%BudgetError{} = error | _rest]}), do: Exception.message(error)
  defp refused(%{errors: [%ClosedError{} = error | _rest]}), do: Exception.message(error)

  defp refused(_error), do: "The budget couldn’t be opened. Refresh the page and try again."
end

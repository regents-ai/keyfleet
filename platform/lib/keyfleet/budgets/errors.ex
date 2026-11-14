defmodule Keyfleet.Budgets.Errors.BudgetError do
  @moduledoc """
  Raised when a Key may not take a budget step now, with the words that say
  why (`message`), the field at fault (`field`) and a short code for agents:

    * `budget_open`: the project already has an open budget
    * `no_budget`: the project has no open budget to spend from
    * `budget_expired`: the expiry asked for has passed
    * `purchase_unknown`: the fleet has no purchase by that id
    * `same_key`: a Key never decides or checks its own proposal
    * `not_proposer`: only the proposing Key records the receipt
    * `wrong_step`: the purchase is not at the step this takes
  """
  use Splode.Error, fields: [:code, :field, :words], class: :invalid

  def message(%{words: words}), do: words
end

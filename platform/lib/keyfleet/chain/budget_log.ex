defmodule Keyfleet.Chain.BudgetLog do
  @moduledoc """
  Reads the money logs of a fleet contract into the fields
  `Keyfleet.Treasury` records.

  `IncomeRecognized` is USDC, the fleet's one income token, that arrived by
  bare transfer and was paid to the keys in full. `SharedMoneyRecognized` is
  any other token that arrived by bare transfer, taken into the budget.
  `BudgetPaid` is an approved payment paid out of the budget, with the match
  it set aside for the keys that did not vote yes. Amounts are in the asset's
  own units, any uint256.
  """

  alias RegentChain.Abi
  alias RegentChain.Event

  @income_recognized Event.topic0("IncomeRecognized(address,address,uint256)")
  @shared_money_recognized Event.topic0("SharedMoneyRecognized(address,address,uint256)")
  @budget_paid Event.topic0("BudgetPaid(address,address,uint256,uint256,uint256)")

  @doc "The topic0 of every event read here."
  def topics, do: [@income_recognized, @shared_money_recognized, @budget_paid]

  @doc """
  A log's indexed topics after topic0, as 32-byte words, and its data, as one
  record; `:error` for any other log or a malformed one.
  """
  def decode(@income_recognized, [asset, caller], data) do
    with {:ok, asset} <- Abi.word(asset, :address),
         {:ok, caller} <- Abi.word(caller, :address),
         {:ok, [amount]} <- Abi.decode(data, [{:uint, 256}]) do
      {:ok, {:income, %{asset: asset, caller: caller, amount: Decimal.new(amount)}}}
    else
      _malformed -> :error
    end
  end

  def decode(@shared_money_recognized, [asset, _caller], data) do
    with {:ok, asset} <- Abi.word(asset, :address),
         {:ok, [amount]} <- Abi.decode(data, [{:uint, 256}]) do
      {:ok, {:budget_receipt, %{asset: asset, amount: Decimal.new(amount)}}}
    else
      _malformed -> :error
    end
  end

  def decode(@budget_paid, [asset, recipient], data) do
    with {:ok, asset} <- Abi.word(asset, :address),
         {:ok, recipient} <- Abi.word(recipient, :address),
         {:ok, [amount, share, matched]} <-
           Abi.decode(data, [{:uint, 256}, {:uint, 256}, {:uint, 256}]) do
      {:ok,
       {:budget_paid,
        %{
          asset: asset,
          recipient: recipient,
          amount: Decimal.new(amount),
          share: Decimal.new(share),
          matched: Decimal.new(matched)
        }}}
    else
      _malformed -> :error
    end
  end

  def decode(_topic0, _topics, _data), do: :error
end

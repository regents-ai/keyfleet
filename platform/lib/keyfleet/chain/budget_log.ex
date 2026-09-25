defmodule Keyfleet.Chain.BudgetLog do
  @moduledoc """
  Reads the budget logs of a fleet contract into the fields
  `Keyfleet.Treasury` records.

  `CapitalDeposited` is an asset paid in as budget, and `SurplusRecognized`
  an asset that arrived by bare transfer and became budget before the launch
  settled, each after the receipt fee; `LaunchIncomeSplit` is income
  recognized after the launch settled, split by the fixed rule between the
  budget and the keys; `BudgetPaid` is a passed payment paid out of the
  budget. Amounts are in the asset's own units, any uint256.
  """

  alias Keyfleet.Chain.Abi

  # cast keccak "CapitalDeposited(address,address,uint256,uint256)"
  @capital_deposited "0xf49206ff502b068fb456947e73acf6d2a86e0e30706185ec236c24a954654564"
  # cast keccak "SurplusRecognized(address,address,uint256,uint256)"
  @surplus_recognized "0x231f7feeea7c01c57b7d3ee8b0c2c48e8bfab5565fe2a638fc209d6bcc2c94d4"
  # cast keccak "LaunchIncomeSplit(address,address,uint256,uint256,uint256,uint256)"
  @income_split "0xd1de1f4a371f15e76fb100d279a26e729da58dcb604fa97058f7e3857fca911e"
  # cast keccak "BudgetPaid(address,address,uint256,uint256,uint256)"
  @budget_paid "0x49fd68af19bac5da72e7e1622c38c15d88d83df2eb98a0c9b2a03b81b9a74e9e"

  @doc "The topic0 of every event read here."
  def topics, do: [@capital_deposited, @surplus_recognized, @income_split, @budget_paid]

  @doc """
  A log's indexed topics after topic0, as 32-byte words, and its data, as one
  record; `:error` for any other log or a malformed one.
  """
  def decode(@capital_deposited, words, data), do: receipt(:deposit, words, data)
  def decode(@surplus_recognized, words, data), do: receipt(:surplus, words, data)

  def decode(@income_split, [asset, caller], data) do
    with {:ok, asset} <- Abi.word(asset, :address),
         {:ok, caller} <- Abi.word(caller, :address),
         {:ok, [gross, fee, to_budget, to_keys]} <-
           Abi.decode(data, List.duplicate({:uint, 256}, 4)),
         true <- gross == fee + to_budget + to_keys do
      {:ok,
       {:income_split,
        %{
          asset: asset,
          caller: caller,
          gross: Decimal.new(gross),
          fee: Decimal.new(fee),
          to_budget: Decimal.new(to_budget),
          to_keys: Decimal.new(to_keys)
        }}}
    else
      _malformed -> :error
    end
  end

  def decode(@budget_paid, [asset, recipient], data) do
    with {:ok, asset} <- Abi.word(asset, :address),
         {:ok, recipient} <- Abi.word(recipient, :address),
         {:ok, [amount, period_start, spent_in_period]} <-
           Abi.decode(data, [{:uint, 256}, {:uint, 64}, {:uint, 256}]),
         {:ok, period_start} <- DateTime.from_unix(period_start) do
      {:ok,
       {:budget_paid,
        %{
          asset: asset,
          recipient: recipient,
          amount: Decimal.new(amount),
          period_start: period_start,
          spent_in_period: Decimal.new(spent_in_period)
        }}}
    else
      _malformed -> :error
    end
  end

  def decode(_topic0, _topics, _data), do: :error

  defp receipt(kind, [asset, sender], data) do
    with {:ok, asset} <- Abi.word(asset, :address),
         {:ok, sender} <- Abi.word(sender, :address),
         {:ok, [amount, net]} <- Abi.decode(data, [{:uint, 256}, {:uint, 256}]),
         true <- net <= amount do
      {:ok,
       {:budget_receipt,
        %{
          kind: kind,
          asset: asset,
          sender: sender,
          amount: Decimal.new(amount),
          net: Decimal.new(net)
        }}}
    else
      _malformed -> :error
    end
  end

  defp receipt(_kind, _words, _data), do: :error
end

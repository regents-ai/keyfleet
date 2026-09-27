defmodule Keyfleet.Chain.BudgetLog do
  @moduledoc """
  Reads the money logs of a fleet contract into the fields
  `Keyfleet.Treasury` records.

  `IncomeRecognized` is income in one of the fleet's income tokens, paid to
  the keys in full. The budget takes in `SharedMoneyRecognized`, any other
  token that arrived by bare transfer; `GraduationHoldingsBooked`, the REGENT
  the launch sent at graduation; and `VestingBooked`, launched tokens the
  vesting escrow released. `BudgetPaid` is a passed payment paid out of the
  budget, with the match it set aside for the keys that did not vote yes.
  Amounts are in the asset's own units, any uint256.
  """

  alias Keyfleet.Chain.Abi

  # cast keccak "IncomeRecognized(address,address,uint256)"
  @income_recognized "0x0cd4e99e415e30cc448d0a20beb2e3d8e1476362e9da4a494959dc6817a3fb13"
  # cast keccak "SharedMoneyRecognized(address,address,uint256)"
  @shared_money_recognized "0x499f2f2f2d8bb29705b19416e4ed4b160f0dfbfbe5a2bf3bc0f73d6b73e12fa7"
  # cast keccak "GraduationHoldingsBooked(address,uint256)"
  @graduation_booked "0xd8c9a3e20faa52b5fa537458d4e055db2d5d91ef401d3120ec549f8724b42355"
  # cast keccak "VestingBooked(address,uint256,uint256)"
  @vesting_booked "0xee00fd5e75d11a67d01f1e2c820557fb28f1e211c8119f94759d4f5b470eeee2"
  # cast keccak "BudgetPaid(address,address,uint256,uint256,uint256)"
  @budget_paid "0x49fd68af19bac5da72e7e1622c38c15d88d83df2eb98a0c9b2a03b81b9a74e9e"

  @doc "The topic0 of every event read here."
  def topics,
    do: [
      @income_recognized,
      @shared_money_recognized,
      @graduation_booked,
      @vesting_booked,
      @budget_paid
    ]

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

  def decode(@shared_money_recognized, [asset, _caller], data),
    do: receipt(:recognized, asset, data, [{:uint, 256}])

  def decode(@graduation_booked, [asset], data),
    do: receipt(:graduation, asset, data, [{:uint, 256}])

  def decode(@vesting_booked, [asset], data),
    do: receipt(:vesting, asset, data, [{:uint, 256}, {:uint, 256}])

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

  # The amount is the data's first word; `VestingBooked` adds the escrow's
  # running total, which the record does not keep.
  defp receipt(kind, asset, data, types) do
    with {:ok, asset} <- Abi.word(asset, :address),
         {:ok, [amount | _total]} <- Abi.decode(data, types) do
      {:ok, {:budget_receipt, %{kind: kind, asset: asset, amount: Decimal.new(amount)}}}
    else
      _malformed -> :error
    end
  end
end

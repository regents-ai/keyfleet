defmodule Keyfleet.WalletSteps.Typed do
  @moduledoc """
  What a person typed into a wallet form, read strictly. Each reader answers
  `{:ok, value}` or `{:error, problem}`; the page puts the problem in words.
  Anything the call can carry is carried, and the contract decides the rest.
  """

  alias RegentChain.Address

  @largest_uint256 Integer.pow(2, 256) - 1
  @zero_code "0x" <> String.duplicate("0", 64)

  @doc "The largest number a `uint256` holds."
  def largest_uint256, do: @largest_uint256

  @doc """
  Key numbers separated by commas or spaces, like `3, 7, 12`, each sent as
  written. Nothing typed is `:no_keys`.
  """
  def keys(text) do
    case String.split(text, ~r/[\s,]+/, trim: true) do
      [] ->
        {:error, :no_keys}

      entries ->
        if Enum.all?(entries, &Regex.match?(~r/\A\d+\z/, &1)),
          do: entries |> Enum.map(&String.to_integer/1) |> in_range(),
          else: {:error, :keys_unreadable}
    end
  end

  @doc "The one key a proposal is made with."
  def key(text) do
    entry = String.trim(text)

    cond do
      entry == "" ->
        {:error, :no_key}

      Regex.match?(~r/\A\d+\z/, entry) ->
        with {:ok, [key]} <- in_range([String.to_integer(entry)]), do: {:ok, key}

      true ->
        {:error, :key_unreadable}
    end
  end

  @doc "The key a proposal acts on, read as `key/1` reads the key it is made with."
  def target(text) do
    case key(text) do
      {:ok, target} -> {:ok, target}
      {:error, :no_key} -> {:error, :no_target}
      {:error, :key_unreadable} -> {:error, :target_unreadable}
      {:error, problem} -> {:error, problem}
    end
  end

  @doc "How many days a shard lasts: a whole number from 1 to 365."
  def days(text) do
    entry = String.trim(text)

    with true <- Regex.match?(~r/\A\d{1,3}\z/, entry),
         days when days in 1..365 <- String.to_integer(entry) do
      {:ok, days}
    else
      _other -> {:error, :days_unreadable}
    end
  end

  defp in_range(keys) do
    if Enum.all?(keys, &(&1 <= @largest_uint256)), do: {:ok, keys}, else: {:error, :key_too_large}
  end

  @doc """
  An address, in lowercase. One written in mixed case has to pass its
  checksum; the zero address is never one.
  """
  def address(text, problem) do
    case Address.normalize(String.trim(text)) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, problem}
    end
  end

  @doc """
  An amount in whole tokens, exactly, in the token's smallest units. Commas
  may only group thousands, and a point marks decimals. Zeros at the end of
  the decimals change nothing; more decimal places than the token has can't
  be paid, so they aren't rounded.
  """
  def amount(text, decimals, largest) do
    entry = String.trim(text)

    if Regex.match?(~r/\A\d{1,3}(?:,\d{3})+(?:\.\d+)?\z/, entry) or
         Regex.match?(~r/\A\d+(?:\.\d+)?\z/, entry) do
      {whole, written} =
        case entry |> String.replace(",", "") |> String.split(".") do
          [whole] -> {whole, ""}
          [whole, written] -> {whole, written}
        end

      units(whole, String.trim_trailing(written, "0"), decimals, largest)
    else
      {:error, if(String.contains?(entry, ","), do: :amount_commas, else: :amount_unreadable)}
    end
  end

  defp units(_whole, fraction, decimals, _largest) when byte_size(fraction) > decimals,
    do: {:error, {:too_many_decimals, decimals}}

  defp units(whole, fraction, decimals, largest) do
    units = String.to_integer(whole <> String.pad_trailing(fraction, decimals, "0"))
    if units > largest, do: {:error, :amount_too_large}, else: {:ok, units}
  end

  @doc """
  A document code: 64 characters, 0 to 9 and a to f, with or without `0x`.
  Nothing typed is the zero code, which points to no document.
  """
  def document_code(text) do
    entry = text |> String.trim() |> String.downcase()

    cond do
      entry == "" -> {:ok, @zero_code}
      match = Regex.run(~r/\A(?:0x)?([0-9a-f]{64})\z/, entry) -> {:ok, "0x" <> List.last(match)}
      true -> {:error, :document_code}
    end
  end
end

defmodule KeyFleet.Keeper.Wallet do
  @moduledoc """
  The keeper's signing key and the address it sends from.

  It signs EIP-1559 (type 2) transactions of one shape only: one of the calls
  `KeyFleet.Keeper.Calls` allows, to an existing contract, sending no ETH and
  carrying no access list. Inspecting a wallet shows its address and never
  its key.
  """

  import Bitwise

  alias KeyFleet.Keeper.{Calls, Rlp}
  alias KeyFleet.Keeper.Calls.Call

  @derive {Inspect, only: [:address]}
  @enforce_keys [:address, :private_key]
  defstruct [:address, :private_key]

  # The order of the secp256k1 group: a private key is a number from 1 below it.
  @curve_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  # EIP-2681: a nonce stays below 2^64 - 1.
  @nonce_limit (1 <<< 64) - 1

  # No keeper call needs more gas than this; asking for more is a mistake.
  @max_gas_limit 30_000_000

  @doc """
  The wallet for a private key given as `0x` and 64 hex digits, or
  `{:error, :malformed_key}` for anything else, including zero and numbers
  not below the curve order.
  """
  def new(key) do
    with {:ok, private_key} <- private_key(key),
         {:ok, <<4, public_key::binary-size(64)>>} <-
           ExSecp256k1.create_public_key(private_key) do
      {:ok, %__MODULE__{address: address(public_key), private_key: private_key}}
    else
      _malformed -> {:error, :malformed_key}
    end
  end

  @doc """
  The 32 bytes of a private key given as `new/1` takes it, or `:error`.
  It does no curve arithmetic, so the runtime configuration can check a
  key before anything else is loaded.
  """
  def private_key("0x" <> hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<number::256>> = private_key} when number > 0 and number < @curve_order ->
        {:ok, private_key}

      _malformed ->
        :error
    end
  end

  def private_key(_value), do: :error

  @doc """
  Signs a call and returns `{:ok, {raw, hash}}`: the raw transaction for
  `eth_sendRawTransaction` and its hash, both as bytes. A call that
  `KeyFleet.Keeper.Calls` refuses is refused here with the same reason.

  The last argument gives the chain, the nonce, the fees per gas in wei and
  the gas limit. The value is always zero and the access list always empty.
  They are refused with `:malformed_transaction` unless they are whole
  numbers, none negative, on a nonzero chain and with fees below 2^256;
  `:nonce_too_high` from 2^64 - 1; `:gas_limit_out_of_range` unless the limit
  is from 1 to 30,000,000; and `:priority_fee_above_max_fee`.
  """
  def sign(
        %__MODULE__{private_key: private_key},
        %Call{} = call,
        %{
          chain_id: chain_id,
          nonce: nonce,
          max_priority_fee: max_priority_fee,
          max_fee: max_fee,
          gas_limit: gas_limit
        }
      ) do
    with :ok <- check(chain_id, nonce, max_priority_fee, max_fee, gas_limit),
         {:ok, data} <- Calls.calldata(call) do
      "0x" <> to = call.target
      to = Base.decode16!(to, case: :lower)
      fields = [chain_id, nonce, max_priority_fee, max_fee, gas_limit, to, 0, data, []]
      digest = ExKeccak.hash_256(<<2>> <> Rlp.encode(fields))

      {:ok, {<<r::256, s::256>>, y_parity}} = ExSecp256k1.sign_compact(digest, private_key)
      raw = <<2>> <> Rlp.encode(fields ++ [y_parity, r, s])
      {:ok, {raw, ExKeccak.hash_256(raw)}}
    end
  end

  defp check(chain_id, nonce, max_priority_fee, max_fee, gas_limit) do
    numbers = [chain_id, nonce, max_priority_fee, max_fee, gas_limit]

    cond do
      not Enum.all?(numbers, &(is_integer(&1) and &1 >= 0)) or chain_id == 0 or
          max_fee >= 1 <<< 256 ->
        {:error, :malformed_transaction}

      nonce >= @nonce_limit ->
        {:error, :nonce_too_high}

      gas_limit not in 1..@max_gas_limit ->
        {:error, :gas_limit_out_of_range}

      max_priority_fee > max_fee ->
        {:error, :priority_fee_above_max_fee}

      true ->
        :ok
    end
  end

  defp address(public_key) do
    <<_::binary-size(12), address::binary-size(20)>> = ExKeccak.hash_256(public_key)
    "0x" <> Base.encode16(address, case: :lower)
  end
end

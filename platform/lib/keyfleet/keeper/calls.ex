defmodule Keyfleet.Keeper.Calls do
  @moduledoc """
  Everything the keeper may say to a contract.

  It sends only the two permissionless functions below, each with at most one
  argument of a fixed type and never with ETH. A `%Call{}` names one of them,
  the contract and the argument; its calldata is built here and nowhere else,
  so nothing outside this module can put other bytes on the chain.

  It also encodes the views the keeper reads before it sends and decodes what
  they return, strictly, with `RegentChain.Abi`. Calldata is built by
  `RegentChain.Call` and handed on as bytes, as the keeper signs it.

  Addresses are lowercase `0x` strings, as the chain reader keeps them.
  """

  import Bitwise

  alias RegentChain.Abi
  alias RegentChain.Event

  defmodule Call do
    @moduledoc "One call the keeper may send: the function, the contract and its one argument."
    @enforce_keys [:fn, :target, :arg]
    defstruct [:fn, :target, :arg]
  end

  # Each function's signature and the type of its one argument, `nil` for none.
  @functions %{
    request_reveal: {"requestReveal(uint256)", :uint256},
    send_protocol_share: {"sendProtocolShare()", nil}
  }

  # Each view's signature, argument types and return types.
  @views %{
    # Keyfleet.sol
    reveal_seed: {"revealSeed(uint256)", [:uint256], [:bytes32]},
    reveal_requested_at: {"revealRequestedAt(uint256)", [:uint256], [{:uint, 64}]},
    total_minted: {"totalMinted()", [], [{:uint, 256}]},
    protocol_share_owed: {"protocolShareOwed()", [], [{:uint, 256}]},
    vrf_coordinator: {"VRF_COORDINATOR()", [], [:address]},
    vrf_subscription_id: {"VRF_SUBSCRIPTION_ID()", [], [{:uint, 256}]},
    # Chainlink VRF v2.5 coordinator
    get_subscription:
      {"getSubscription(uint256)", [:uint256],
       [{:uint, 96}, {:uint, 96}, {:uint, 64}, :address, {:array, :address}]}
  }

  @subscription_fields [:balance, :native_balance, :request_count, :owner, :consumers]

  # What a fleet's `requestReveal` logs: the coordinator took the request, or
  # refused it.
  @reveal_results %{
    Event.topic0("RevealRequested(uint256,uint256)") => "reveal_requested",
    Event.topic0("RevealRequestFailed(uint256)") => "reveal_refused"
  }

  @doc "The functions the keeper may call."
  def functions, do: @functions |> Map.keys() |> Enum.sort()

  @doc """
  A call to send, or `{:error, reason}`: `:unknown_function` for anything
  but the two functions, `:malformed_target` unless the contract is a
  nonzero address, `:malformed_argument` unless the argument has the
  function's type.
  """
  def new(fun, target, arg) do
    with {:ok, _data} <- encode_call(fun, arg),
         :ok <- target(target) do
      {:ok, %Call{fn: fun, target: target, arg: arg}}
    end
  end

  @doc "The calldata of a call, checked as `new/3` checks it."
  def calldata(%Call{fn: fun, target: target, arg: arg}) do
    with :ok <- target(target), do: encode_call(fun, arg)
  end

  @doc "The calldata of a view, or `{:error, reason}` for an unknown view or bad arguments."
  def view(name, args) when is_list(args) do
    case Map.fetch(@views, name) do
      {:ok, {signature, types, _returns}} when length(types) == length(args) ->
        encode(signature, Enum.zip(types, args))

      {:ok, _view} ->
        {:error, :malformed_argument}

      :error ->
        {:error, :unknown_view}
    end
  end

  @doc """
  What a view returned: a single value as itself and a record as a map.
  `:error` for any other name, and for anything but the exact encoding.
  """
  def decode(name, data) do
    with {:ok, {_signature, _args, returns}} <- Map.fetch(@views, name),
         {:ok, values} <- Abi.decode(data, returns),
         do: shape(name, values)
  end

  @doc """
  What an included call's logs say beyond its status: for a reveal, whether
  the fleet's coordinator took the request, `"reveal_requested"`, or refused
  it, `"reveal_refused"`, as the fleet logged it for that key. `nil` for
  anything else.
  """
  def result(:request_reveal, fleet, token_id, logs) do
    token = "0x" <> Base.encode16(<<token_id::256>>, case: :lower)
    Enum.find_value(logs, &reveal_result(&1, fleet, token))
  end

  def result(_fun, _target, _arg, _logs), do: nil

  defp reveal_result(%{"address" => address, "topics" => [topic0, topic1 | _rest]}, fleet, token)
       when is_binary(address) and is_binary(topic0) and is_binary(topic1) do
    if String.downcase(address) == fleet and String.downcase(topic1) == token,
      do: Map.get(@reveal_results, String.downcase(topic0))
  end

  defp reveal_result(_log, _fleet, _token), do: nil

  defp shape(:get_subscription, values), do: {:ok, fields(@subscription_fields, values)}
  defp shape(_name, [value]), do: {:ok, value}

  defp fields(names, values), do: names |> Enum.zip(values) |> Map.new()

  defp encode_call(fun, arg) do
    case Map.fetch(@functions, fun) do
      {:ok, {signature, nil}} when is_nil(arg) -> encode(signature, [])
      {:ok, {_signature, nil}} -> {:error, :malformed_argument}
      {:ok, {signature, type}} -> encode(signature, [{type, arg}])
      :error -> {:error, :unknown_function}
    end
  end

  defp encode(signature, typed_args) do
    if Enum.all?(typed_args, fn {type, arg} -> valid?(type, arg) end) do
      "0x" <> hex = RegentChain.Call.encode(signature, Enum.map(typed_args, &elem(&1, 1)))
      {:ok, Base.decode16!(hex, case: :lower)}
    else
      {:error, :malformed_argument}
    end
  end

  defp valid?(:uint256, value), do: is_integer(value) and value >= 0 and value < 1 <<< 256

  defp target(target),
    do: if(nonzero_address?(target), do: :ok, else: {:error, :malformed_target})

  # A lowercase `0x` address other than zero, as the chain reader keeps them.
  defp nonzero_address?("0x" <> hex = address) when byte_size(hex) == 40,
    do: hex =~ ~r/\A[0-9a-f]+\z/ and address != "0x" <> String.duplicate("0", 40)

  defp nonzero_address?(_value), do: false
end

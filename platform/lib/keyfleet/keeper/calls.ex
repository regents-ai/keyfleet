defmodule KeyFleet.Keeper.Calls do
  @moduledoc """
  Everything the keeper may say to a contract.

  It sends only the seven permissionless functions below, each with at most one
  argument of a fixed type and never with ETH. A `%Call{}` names one of them,
  the contract and the argument; its calldata is built here and nowhere else,
  so nothing outside this module can put other bytes on the chain.

  It also encodes the views the keeper reads before it sends and decodes what
  they return, strictly, with `KeyFleet.Chain.Abi`.

  Addresses are lowercase `0x` strings, as the chain reader keeps them.
  """

  import Bitwise

  alias KeyFleet.Chain.Abi

  defmodule Call do
    @moduledoc "One call the keeper may send: the function, the contract and its one argument."
    @enforce_keys [:fn, :target, :arg]
    defstruct [:fn, :target, :arg]
  end

  # Each function's signature and the type of its one argument, `nil` for none.
  @functions %{
    request_reveal: {"requestReveal(uint256)", :uint256},
    release: {"release()", nil},
    collect: {"collect(uint256)", :uint256},
    sweep: {"sweep(address)", :address},
    recognize_surplus_revenue: {"recognizeSurplusRevenue(address)", :address},
    recognize_surplus: {"recognizeSurplus(address)", :address},
    send_protocol_share: {"sendProtocolShare()", nil}
  }

  # Each view's signature, argument types and return types. Enums come back
  # as bounded integers and are named below.
  @views %{
    # Keyfleet.sol
    reveal_seed: {"revealSeed(uint256)", [:uint256], [:bytes32]},
    reveal_requested_at: {"revealRequestedAt(uint256)", [:uint256], [{:uint, 64}]},
    total_minted: {"totalMinted()", [], [{:uint, 256}]},
    surplus: {"surplus(address)", [:address], [{:uint, 256}]},
    protocol_share_owed: {"protocolShareOwed()", [], [{:uint, 256}]},
    launch_state: {"launchState()", [], [{:uint, 8}]},
    launch_record:
      {"launchRecord()", [],
       [
         {:uint, 256},
         {:uint, 256},
         :address,
         {:uint, 64},
         :address,
         :address,
         :address,
         :address,
         :bytes32,
         :bytes32,
         {:uint, 256}
       ]},
    launch_distribution:
      {"launchDistribution()", [],
       [
         {:uint, 8},
         {:uint, 64},
         {:uint, 64},
         {:uint, 64},
         {:uint, 64},
         {:uint, 128},
         {:uint, 128},
         {:uint, 128},
         {:uint, 128},
         {:uint, 160},
         {:uint, 256},
         :address,
         :address,
         :address,
         :address,
         :address,
         :bytes32,
         {:uint, 256}
       ]},
    factory: {"FACTORY()", [], [:address]},
    asset_registry: {"ASSET_REGISTRY()", [], [:address]},
    vrf_coordinator: {"VRF_COORDINATOR()", [], [:address]},
    vrf_subscription_id: {"VRF_SUBSCRIPTION_ID()", [], [{:uint, 256}]},
    # KeyfleetAssetRegistry.sol
    is_token_allowed: {"isTokenAllowed(address,address)", [:address, :address], [:bool]},
    # Chainlink VRF v2.5 coordinator
    get_subscription:
      {"getSubscription(uint256)", [:uint256],
       [{:uint, 96}, {:uint, 96}, {:uint, 64}, :address, {:array, :address}]},
    # Autolaunch factory and strategy
    strategy: {"strategy()", [], [:address]},
    lp_locker: {"lpLocker()", [], [:address]},
    # ConditionalVestingEscrowV1.sol
    lifecycle: {"lifecycle()", [], [{:uint, 8}]},
    total_released: {"totalReleased()", [], [{:uint, 256}]},
    vesting_start: {"vestingStart()", [], [{:uint, 64}]},
    # Escrow, splitter and payment receiver
    treasury: {"treasury()", [], [:address]},
    subject: {"subject()", [], [:address]},
    # SubjectSplitterV1.sol
    usdc: {"usdc()", [], [:address]},
    regent: {"regent()", [], [:address]},
    protected_balance: {"protectedBalance(address)", [:address], [{:uint, 256}]},
    # ERC-20
    balance_of: {"balanceOf(address)", [:address], [{:uint, 256}]}
  }

  # What `RevstakeLPLocker.collect(uint256)` returns: the fees collected.
  @collect_returns [{:uint, 256}, {:uint, 256}]

  @launch_states [:not_created, :auction_created, :graduated, :economically_failed]
  @strategy_lifecycles [:none, :active, :graduated, :failed]
  @escrow_lifecycles [:pending, :graduated, :failed]

  @launch_record_fields [
    :launch_id,
    :proposal_id,
    :subject,
    :created_at_block,
    :auction,
    :escrow,
    :splitter,
    :receiver,
    :envelope_hash,
    :pool_id,
    :lp_token_id
  ]

  @distribution_fields [
    :lifecycle,
    :start_block,
    :end_block,
    :claim_block,
    :migration_block,
    :required_regent_raised,
    :reserve,
    :lp_regent_used,
    :lp_subject_used,
    :final_sqrt_price_x96,
    :launch_id,
    :subject,
    :escrow,
    :treasury,
    :splitter,
    :receiver,
    :pool_id,
    :lp_token_id
  ]

  @subscription_fields [:balance, :native_balance, :request_count, :owner, :consumers]

  @selectors Map.new(
               Map.values(@functions) ++ Map.values(@views),
               &{elem(&1, 0), binary_part(ExKeccak.hash_256(elem(&1, 0)), 0, 4)}
             )

  @doc "The functions the keeper may call."
  def functions, do: @functions |> Map.keys() |> Enum.sort()

  @doc """
  A call to send, or `{:error, reason}`: `:unknown_function` for anything
  but the seven functions, `:malformed_target` unless the contract is a
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
  What a view, or `collect`, returned: a single value as itself, a record as
  a map, `collect` as `{amount0, amount1}` and enums as atoms. `:error` for
  any other name, and for anything but the exact encoding.
  """
  def decode(:collect, data) do
    with {:ok, [amount0, amount1]} <- Abi.decode(data, @collect_returns),
         do: {:ok, {amount0, amount1}}
  end

  def decode(name, data) do
    with {:ok, {_signature, _args, returns}} <- Map.fetch(@views, name),
         {:ok, values} <- Abi.decode(data, returns),
         do: shape(name, values)
  end

  defp shape(:launch_state, [state]), do: enum(@launch_states, state)
  defp shape(:lifecycle, [lifecycle]), do: enum(@escrow_lifecycles, lifecycle)
  defp shape(:launch_record, values), do: {:ok, fields(@launch_record_fields, values)}
  defp shape(:get_subscription, values), do: {:ok, fields(@subscription_fields, values)}

  defp shape(:launch_distribution, [lifecycle | _rest] = values) do
    with {:ok, lifecycle} <- enum(@strategy_lifecycles, lifecycle) do
      {:ok, %{fields(@distribution_fields, values) | lifecycle: lifecycle}}
    end
  end

  defp shape(_name, [value]), do: {:ok, value}

  defp fields(names, values), do: names |> Enum.zip(values) |> Map.new()

  defp enum(names, index) do
    case Enum.at(names, index) do
      nil -> :error
      name -> {:ok, name}
    end
  end

  defp encode_call(fun, arg) do
    case Map.fetch(@functions, fun) do
      {:ok, {signature, nil}} when is_nil(arg) -> encode(signature, [])
      {:ok, {_signature, nil}} -> {:error, :malformed_argument}
      {:ok, {signature, type}} -> encode(signature, [{type, arg}])
      :error -> {:error, :unknown_function}
    end
  end

  defp encode(signature, typed_args) do
    typed_args
    |> Enum.reduce_while({:ok, [@selectors[signature]]}, fn {type, arg}, {:ok, words} ->
      case word(type, arg) do
        {:ok, word} -> {:cont, {:ok, [words, word]}}
        :error -> {:halt, {:error, :malformed_argument}}
      end
    end)
    |> case do
      {:ok, data} -> {:ok, IO.iodata_to_binary(data)}
      error -> error
    end
  end

  defp word(:uint256, value) when is_integer(value) and value >= 0 and value < 1 <<< 256,
    do: {:ok, <<value::256>>}

  defp word(:address, value) do
    with {:ok, address} <- address(value), do: {:ok, <<0::96, address::binary>>}
  end

  defp word(_type, _value), do: :error

  defp target(target) do
    case address(target) do
      {:ok, <<0::160>>} -> {:error, :malformed_target}
      {:ok, _address} -> :ok
      :error -> {:error, :malformed_target}
    end
  end

  defp address("0x" <> hex) when byte_size(hex) == 40, do: Base.decode16(hex, case: :lower)
  defp address(_value), do: :error
end

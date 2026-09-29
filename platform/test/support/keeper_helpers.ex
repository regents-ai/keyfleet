defmodule Keyfleet.KeeperHelpers do
  @moduledoc """
  What the keeper's tests share: a fleet deployed on Ethereum, a sender
  started on `Keyfleet.Keeper.StubNode`, the chain's answers to the
  keeper's reads, and the transactions it sent read back from their bytes.

  The keeper's wallet is anvil's first public test account, never a real
  key, and every address is made up.
  """

  import ExUnit.Assertions

  alias Keyfleet.Actors.System
  alias Keyfleet.{Fleets, Keeper, Repo}
  alias Keyfleet.Keeper.{Calls, Run, Sender, StubNode, Wallet}

  @addresses %{
    keeper: "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
    fleet: "0x5fbdb2315678afecb367f032d93f642f64180aa3",
    usdc: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    stranger: "0x" <> String.duplicate("99", 20)
  }

  @anvil_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  @doc "The address the tests give `name`: `:keeper`, `:fleet`, `:usdc` or `:stranger`."
  def address(name), do: Map.fetch!(@addresses, name)

  @doc "Anvil's first public test key, the keeper's wallet."
  def anvil_key, do: @anvil_key

  @doc "Records a fleet's deployment at `address` on `chain_id`."
  def deploy!(fleet_id, address, chain_id) do
    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: chain_id,
        contract_address: address,
        rewards_address: "0x" <> String.duplicate("7", 40),
        votes_address: "0x" <> String.duplicate("8", 40),
        usdc_address: @addresses.usdc,
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %System{}
    )
  end

  @doc "A sender for `key`, started on the chain the test put."
  def start!(key \\ @anvil_key) do
    {:ok, wallet} = Wallet.new(key)
    {:ok, sender} = Sender.start(Sender.new(wallet, StubNode))
    sender
  end

  @doc "A call the keeper may send."
  def call!(fun, target, arg) do
    {:ok, call} = Calls.new(fun, target, arg)
    call
  end

  @doc "The calldata of a call the keeper may send."
  def calldata!(fun, target, arg) do
    {:ok, data} = Calls.calldata(call!(fun, target, arg))
    data
  end

  @doc "The calldata of a view."
  def view!(name, args \\ []) do
    {:ok, data} = Calls.view(name, args)
    data
  end

  @doc """
  Values as the chain returns them, each a 32-byte word: numbers, and `0x`
  strings of up to 32 bytes padded on the left.
  """
  def words(values) do
    for value <- values, into: <<>> do
      case value do
        "0x" <> hex ->
          bytes = Base.decode16!(hex, case: :lower)
          <<0::size((32 - byte_size(bytes)) * 8), bytes::binary>>

        number ->
          <<number::256>>
      end
    end
  end

  @doc """
  A stub node's `:calls`, answering the keeper from `answers`: a map from
  the contract and calldata to the values returned, as `words/1` takes
  them, to raw bytes, or to an `{:error, reason}`. Anything else it does
  not answer.
  """
  def answering(answers) do
    keeper = @addresses.keeper

    fn ^keeper, to, data ->
      case Map.fetch(answers, {to, data}) do
        {:ok, {:error, _reason} = error} -> error
        {:ok, values} when is_list(values) -> {:ok, words(values)}
        {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
        :error -> {:error, :no_answer}
      end
    end
  end

  @doc """
  Records that the keeper sent `fun` to `target` with `arg` for `fleet_id`
  at `nonce` on Ethereum, and that the chain included it, settled at
  `settled_at`, which may be in the past, with `result`.
  """
  def included!(fleet_id, {fun, target, arg}, nonce, settled_at, result \\ nil) do
    tx =
      Keeper.record_sent_tx!(
        %{
          job: if(fun == :request_reveal, do: :reveal, else: :protocol_share),
          fleet_id: fleet_id,
          function: fun,
          target: target,
          from_address: @addresses.keeper,
          args: %{"arg" => arg},
          chain_id: 1,
          nonce: nonce,
          tx_hash: hex(<<nonce::256>>),
          max_fee: 1,
          max_priority_fee: 1,
          gas_limit: 1
        },
        actor: %System{}
      )

    Repo.query!(
      """
      UPDATE keyfleet_app.keeper_txs
      SET status = 'mined', settled_at = $2, block_number = 1, gas_used = 1,
          effective_gas_price = 1, cost_wei = 1, result = $3
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(tx.id), settled_at, result]
    )

    :ok
  end

  @doc "The keeper's recorded runs, oldest first, as `{job, outcome}`."
  def runs do
    Run
    |> Ash.read!(actor: %System{})
    |> Enum.sort_by(& &1.finished_at, DateTime)
    |> Enum.map(&{&1.job, &1.outcome})
  end

  @doc """
  What a fleet at `fleet` logs for `requestReveal` of `token_id`, as a
  node's receipt gives it: `:requested` when the coordinator took the
  request, `:refused` when it refused it.
  """
  def reveal_log(:requested, fleet, token_id),
    do: log(fleet, "RevealRequested(uint256,uint256)", [token_id, 77])

  def reveal_log(:refused, fleet, token_id),
    do: log(fleet, "RevealRequestFailed(uint256)", [token_id])

  defp log(address, event, indexed) do
    %{
      "address" => address,
      "topics" => Enum.map([ExKeccak.hash_256(event) | Enum.map(indexed, &<<&1::256>>)], &hex/1),
      "data" => "0x"
    }
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  @doc "A contract's refusal, as the node gives it."
  def revert(selector \\ <<1, 2, 3, 4>>), do: {:error, {:revert, selector, <<>>}}

  @doc "Each transaction the stub node was sent, oldest first, read back from its bytes."
  def sent, do: Enum.map(StubNode.sent(), &decode/1)

  @doc "A transaction's hash, from its raw bytes."
  def hash(raw), do: hex(ExKeccak.hash_256(raw))

  @doc "The fields of a signed type-2 transaction, read back from its RLP."
  def decode(<<2, rlp::binary>>) do
    {[chain_id, nonce, priority, max_fee, gas_limit, to, value, data, [], _y, _r, _s], <<>>} =
      item(rlp)

    assert value == <<>>

    %{
      chain_id: :binary.decode_unsigned(chain_id),
      nonce: :binary.decode_unsigned(nonce),
      max_priority_fee: :binary.decode_unsigned(priority),
      max_fee: :binary.decode_unsigned(max_fee),
      gas_limit: :binary.decode_unsigned(gas_limit),
      to: "0x" <> Base.encode16(to, case: :lower),
      data: data
    }
  end

  defp item(<<byte, rest::binary>>) when byte < 0x80, do: {<<byte>>, rest}
  defp item(<<byte, rest::binary>>) when byte <= 0xB7, do: bytes(rest, byte - 0x80)

  defp item(<<byte, rest::binary>>) when byte <= 0xBF do
    size = byte - 0xB7
    <<length::size(size)-unit(8), rest::binary>> = rest
    bytes(rest, length)
  end

  defp item(<<byte, rest::binary>>) when byte <= 0xF7, do: list(rest, byte - 0xC0)

  defp item(<<byte, rest::binary>>) do
    size = byte - 0xF7
    <<length::size(size)-unit(8), rest::binary>> = rest
    list(rest, length)
  end

  defp bytes(rest, length) do
    <<bytes::binary-size(length), rest::binary>> = rest
    {bytes, rest}
  end

  defp list(rest, length) do
    <<payload::binary-size(length), rest::binary>> = rest
    {items(payload), rest}
  end

  defp items(<<>>), do: []

  defp items(payload) do
    {item, rest} = item(payload)
    [item | items(rest)]
  end
end

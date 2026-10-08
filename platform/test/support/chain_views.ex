defmodule Keyfleet.ChainViews do
  @moduledoc """
  The chain as a wallet-steps test describes it: a head, and the answer of
  each contract view the steps read, by contract, signature and arguments.
  A read the test didn't describe raises and names its contract and
  calldata, so each test says every read its steps make.
  """

  alias Keyfleet.Chain.StubClient
  alias RegentChain.Call

  @head %{
    number: 1_000,
    hash: "0x" <> String.duplicate("c", 64),
    timestamp: ~U[2026-10-07 12:00:00Z],
    # The network fee costs nothing unless a test's head names a base fee.
    base_fee: 0
  }

  @doc "The head block every test chain answers at, unless one names another."
  def head, do: @head

  @doc """
  Puts the chain answering `views`, each `{to, signature, arguments,
  answer}`: `answer` is `{types, values}`, like `{"uint256", [5]}`, or
  `:revert`. `opts` may name `:head`, `:balances`, the ETH each address
  holds, and `:codes`, the chain's answer for the code at each address. A
  later `put!/2` in the same test changes the answers every process reads
  from then on, including a page that has read the chain already.
  """
  def put!(views, opts \\ []) do
    answers =
      Map.new(views, fn {to, signature, arguments, answer} ->
        {{to, Call.encode(signature, arguments)}, answer}
      end)

    test = self()
    Process.put(__MODULE__, answers)

    StubClient.put_chain(Keyword.get(opts, :head, @head), [],
      balances: Keyword.get(opts, :balances, %{}),
      codes: Keyword.get(opts, :codes, %{}),
      calls: fn to, data, _block_hash -> answer(test, to, data) end
    )
  end

  @doc """
  Lets every process read this test's chain, such as a web server the test
  started, until the test ends: the views the latest `put!/2` describes, and
  a chain that can't be read before the first.
  """
  def share! do
    test = self()
    StubClient.share_chain(@head, calls: fn to, data, _block_hash -> answer(test, to, data) end)
    ExUnit.Callbacks.on_exit(&StubClient.unshare_chain/0)
  end

  # The chain goes with its test: a read still running once the test has
  # ended finds no node.
  defp answer(test, to, data) do
    case Process.info(test, :dictionary) do
      {:dictionary, dictionary} -> lookup(dictionary[__MODULE__], to, data)
      nil -> {:error, :unreachable}
    end
  end

  defp lookup(nil, _to, _data), do: {:error, :unreachable}

  defp lookup(answers, to, data) do
    case Map.fetch(answers, {to, data}) do
      {:ok, :revert} -> {:error, :reverted}
      {:ok, {types, values}} -> {:ok, words(types, values)}
      :error -> raise "the test chain has no answer for #{to} #{data}"
    end
  end

  @doc "`values` of `types`, like `\"address,uint256\"`, as a view returns them."
  def words(types, values) do
    "0x" <> <<_selector::binary-size(8), hex::binary>> = Call.encode("f(#{types})", values)
    Base.decode16!(hex, case: :lower)
  end
end

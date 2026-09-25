defmodule Keyfleet.Keeper.RpcNodeTest do
  # Points the whole app's node address at a local server for each test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Keyfleet.Keeper.RpcNode

  @keeper "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @fleet "0x5fbdb2315678afecb367f032d93f642f64180aa3"
  # A contract error's selector.
  @selector <<0x1B, 0x6D, 0xAB, 0x6E>>

  setup do
    config = Application.fetch_env!(:keyfleet, Keyfleet.Chain)
    on_exit(fn -> Application.put_env(:keyfleet, Keyfleet.Chain, config) end)
    %{config: config}
  end

  describe "a call the contract refuses" do
    test "comes back as its error's selector and arguments", %{config: config} do
      args = <<7::256, 1_800_000_000::256>>
      node!(config, fn _request -> error(3, "execution reverted", hex(@selector <> args)) end)

      assert RpcNode.call(@keeper, @fleet, <<1, 2, 3, 4>>) == {:error, {:revert, @selector, args}}

      assert RpcNode.estimate_gas(@keeper, @fleet, <<1, 2, 3, 4>>) ==
               {:error, {:revert, @selector, args}}
    end

    test "is a refusal whatever the code when the message says it reverted", %{config: config} do
      node!(config, fn _request -> error(-32_000, "Execution Reverted", hex(@selector)) end)
      assert RpcNode.call(@keeper, @fleet, <<>>) == {:error, {:revert, @selector, <<>>}}
    end

    test "has no selector when it came back with none", %{config: config} do
      node!(config, fn _request -> error(3, "execution reverted") end)
      assert RpcNode.call(@keeper, @fleet, <<>>) == {:error, {:revert, nil, <<>>}}

      node!(config, fn _request -> error(3, "execution reverted", "0x0102") end)
      assert RpcNode.call(@keeper, @fleet, <<>>) == {:error, {:revert, nil, <<1, 2>>}}
    end

    test "with data that is not hex is the node failing", %{config: config} do
      node!(config, fn _request -> error(3, "execution reverted", "not hex") end)

      assert {:error, {:rpc_error, %{code: 3, data: "not hex"}}} =
               RpcNode.call(@keeper, @fleet, <<>>)
    end
  end

  test "any other node error is passed on as the node's error", %{config: config} do
    node!(config, fn _request -> error(-32_000, "nonce too low") end)

    assert RpcNode.send_raw(<<2, 1>>) ==
             {:error, {:rpc_error, %{code: -32_000, message: "nonce too low", data: nil}}}
  end

  test "a node that does not answer is unavailable, logged without its address", %{
    config: config
  } do
    plug = fn conn, _opts -> send_resp(conn, 502, "bad gateway") end
    url = serve!(plug)
    Application.put_env(:keyfleet, Keyfleet.Chain, Keyword.put(config, :rpc_url, url))

    log = capture_log(fn -> assert RpcNode.chain_id() == {:error, :chain_unavailable} end)
    assert log =~ "eth_chainId"
    assert log =~ "502"
    refute log =~ url
  end

  test "calls and estimates come from the keeper, and calls read the latest block", %{
    config: config
  } do
    node!(config, fn
      %{"method" => "eth_call"} -> result("0x2a")
      %{"method" => "eth_estimateGas"} -> result("0x186a0")
    end)

    assert RpcNode.call(@keeper, @fleet, <<0xAB>>) == {:ok, <<0x2A>>}
    assert RpcNode.estimate_gas(@keeper, @fleet, <<0xAB>>) == {:ok, 100_000}

    transaction = %{"from" => @keeper, "to" => @fleet, "data" => "0xab"}
    assert_received {:request, %{"method" => "eth_call", "params" => [^transaction, "latest"]}}
    assert_received {:request, %{"method" => "eth_estimateGas", "params" => [^transaction]}}
  end

  test "the latest block, nonces, balance and fees are read as numbers", %{config: config} do
    node!(config, fn
      %{"method" => "eth_chainId"} ->
        result("0x2105")

      %{"method" => "eth_getBlockByNumber", "params" => ["latest", false]} ->
        result(%{"number" => "0x64", "timestamp" => "0x6b49d200", "baseFeePerGas" => "0x4c4b40"})

      %{"method" => "eth_getTransactionCount", "params" => [@keeper, "latest"]} ->
        result("0x5")

      %{"method" => "eth_getTransactionCount", "params" => [@keeper, "pending"]} ->
        result("0x6")

      %{"method" => "eth_getBalance", "params" => [@keeper, "latest"]} ->
        result("0xde0b6b3a7640000")

      %{"method" => "eth_maxPriorityFeePerGas"} ->
        result("0xf4240")
    end)

    assert RpcNode.chain_id() == {:ok, 8_453}

    assert RpcNode.latest_block() ==
             {:ok, %{number: 100, timestamp: 1_800_000_000, base_fee: 5_000_000}}

    assert RpcNode.nonce(@keeper, :latest) == {:ok, 5}
    assert RpcNode.nonce(@keeper, :pending) == {:ok, 6}
    assert RpcNode.balance(@keeper) == {:ok, 1_000_000_000_000_000_000}
    assert RpcNode.max_priority_fee() == {:ok, 1_000_000}
  end

  test "a raw transaction is sent as hex and its hash comes back lowercase", %{config: config} do
    hash = "0x" <> String.duplicate("AB", 32)
    node!(config, fn %{"method" => "eth_sendRawTransaction"} -> result(hash) end)

    assert RpcNode.send_raw(<<2, 0xF8, 1>>) == {:ok, String.downcase(hash)}
    assert_received {:request, %{"params" => ["0x02f801"]}}
  end

  describe "a receipt" do
    test "is none until the transaction is included", %{config: config} do
      node!(config, fn %{"method" => "eth_getTransactionReceipt"} -> result(nil) end)
      assert RpcNode.receipt(tx_hash()) == {:ok, nil}
    end

    test "carries its status, cost, Base's L1 fee and logs", %{config: config} do
      log = %{"address" => @fleet, "topics" => [], "data" => "0x"}

      node!(config, fn %{"method" => "eth_getTransactionReceipt"} ->
        result(receipt(%{"logs" => [log]}))
      end)

      assert RpcNode.receipt(tx_hash()) ==
               {:ok,
                %{
                  status: 1,
                  block_number: 101,
                  gas_used: 60_000,
                  effective_gas_price: 6_000_000,
                  l1_fee: 2_000,
                  logs: [log]
                }}

      assert_received {:request, %{"params" => [hash]}}
      assert hash == tx_hash()
    end

    test "has no L1 fee on a chain without one, and a status of 0 when it reverted", %{
      config: config
    } do
      node!(config, fn _request ->
        result(receipt(%{"status" => "0x0"}) |> Map.delete("l1Fee"))
      end)

      assert {:ok, %{status: 0, l1_fee: nil}} = RpcNode.receipt(tx_hash())
    end

    test "is refused when it is not a receipt", %{config: config} do
      for broken <- [
            receipt(%{"status" => "0x2"}),
            receipt(%{"gasUsed" => "12"}),
            receipt(%{"logs" => nil}),
            Map.delete(receipt(%{}), "effectiveGasPrice"),
            "0x1"
          ] do
        node!(config, fn _request -> result(broken) end)
        assert RpcNode.receipt(tx_hash()) == {:error, :invalid_receipt}
      end
    end
  end

  defp receipt(overrides) do
    Map.merge(
      %{
        "status" => "0x1",
        "blockNumber" => "0x65",
        "gasUsed" => "0xea60",
        "effectiveGasPrice" => "0x5b8d80",
        "l1Fee" => "0x7d0",
        "logs" => []
      },
      overrides
    )
  end

  defp tx_hash, do: "0x" <> String.duplicate("c", 64)

  defp result(result), do: %{"jsonrpc" => "2.0", "id" => 1, "result" => result}

  defp error(code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error
    %{"jsonrpc" => "2.0", "id" => 1, "error" => error}
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  # A node answering each request with `answer`, telling the test what it was asked.
  defp node!(config, answer) do
    test = self()

    plug = fn conn, _opts ->
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      send(test, {:request, request})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(answer.(request)))
    end

    Application.put_env(:keyfleet, Keyfleet.Chain, Keyword.put(config, :rpc_url, serve!(plug)))
  end

  defp serve!(plug) do
    pid =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0}, id: make_ref())
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end
end

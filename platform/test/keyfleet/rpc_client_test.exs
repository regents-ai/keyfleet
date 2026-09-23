defmodule KeyFleet.Chain.RpcClientTest do
  # Points the whole app's node address at a local server for each test.
  use ExUnit.Case, async: false

  import Plug.Conn

  alias KeyFleet.Chain.RpcClient

  @block_hash "0x" <> String.duplicate("b", 64)

  setup do
    config = Application.fetch_env!(:keyfleet, KeyFleet.Chain)
    on_exit(fn -> Application.put_env(:keyfleet, KeyFleet.Chain, config) end)
    %{config: config}
  end

  @tag capture_log: true
  test "a call the contract refuses is told apart from a node that cannot answer", %{
    config: config
  } do
    node!(config, %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x2a"})
    assert RpcClient.call(address(), <<1, 2, 3, 4>>, @block_hash) == {:ok, <<0x2A>>}

    node!(config, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{"code" => 3, "message" => "execution reverted", "data" => "0x"}
    })

    assert RpcClient.call(address(), <<1, 2, 3, 4>>, @block_hash) == {:error, :reverted}

    node!(config, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{"code" => 3, "message" => "execution reverted: not yet", "data" => "0x"}
    })

    assert RpcClient.call(address(), <<1, 2, 3, 4>>, @block_hash) == {:error, :reverted}

    node!(config, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "error" => %{"code" => -32_000, "message" => "header not found"}
    })

    assert RpcClient.call(address(), <<1, 2, 3, 4>>, @block_hash) == {:error, :chain_unavailable}
  end

  defp node!(config, answer) do
    plug = fn conn, _opts ->
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(answer))
    end

    pid =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0},
          id: make_ref()
        )
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)

    Application.put_env(
      :keyfleet,
      KeyFleet.Chain,
      Keyword.put(config, :rpc_url, "http://127.0.0.1:#{port}")
    )
  end

  defp address, do: "0x" <> String.duplicate("c", 40)
end

defmodule Keyfleet.Chain.RpcClientTest do
  # Points the whole app's node address at a local server for each test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Keyfleet.Chain.RpcClient

  @block_hash "0x" <> String.duplicate("b", 64)

  setup do
    config = Application.fetch_env!(:keyfleet, Keyfleet.Chain)
    on_exit(fn -> Application.put_env(:keyfleet, Keyfleet.Chain, config) end)
    %{config: config}
  end

  test "a call the contract refuses is told apart from a node that cannot answer", %{
    config: config
  } do
    node!(config, %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x2a"})
    assert RpcClient.call(address(), <<1, 2, 3, 4>>, @block_hash) == {:ok, <<0x2A>>}

    # Error code 3 is a refusal, whatever the message says.
    node!(config, error(3, "reverted with reason: not yet"))
    assert RpcClient.call(address(), <<1, 2, 3, 4>>, @block_hash) == {:error, :reverted}

    # So is a message that says the call reverted, in any case, with any code.
    for message <- ["execution reverted", "Execution Reverted: not yet", "VM EXECUTION REVERTED"] do
      node!(config, error(-32_000, message))
      assert RpcClient.call(address(), <<1, 2, 3, 4>>, @block_hash) == {:error, :reverted}
    end

    # Anything else is the node failing, logged with what the node said.
    node!(config, error(-32_000, "header not found"))

    log =
      capture_log(fn ->
        assert RpcClient.call(address(), <<1, 2, 3, 4>>, @block_hash) ==
                 {:error, :chain_unavailable}
      end)

    assert log =~ "header not found"
    assert log =~ "-32000"
  end

  defp error(code, message),
    do: %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => code, "message" => message}}

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
      Keyfleet.Chain,
      Keyword.put(config, :rpc_url, "http://127.0.0.1:#{port}")
    )
  end

  defp address, do: "0x" <> String.duplicate("c", 40)
end

defmodule Keyfleet.ChainClientTest do
  # Points the node for a chain of its own at a closed port for one test.
  use ExUnit.Case, async: false

  alias Keyfleet.{ChainClient, TestChainNode}
  alias RegentChain.{Outcome, Review}

  @signer "0x" <> String.duplicate("a", 40)
  @to "0x" <> String.duplicate("b", 40)

  test "a sent step is read through the site's own node, not the address wallets are given" do
    # Nothing listens on port 1, so a read from the review's address would fail.
    review =
      Review.new(
        "proof",
        @signer,
        %{chain_id: 8453, name: "Base", rpc_url: "http://127.0.0.1:1"},
        [Review.step("pay", @to, "0x12345678")]
      )

    step = Review.find(review, "pay")
    hash = "0x" <> String.duplicate("5", 64)

    assert Outcome.of(ChainClient, review, step, hash) == {:ok, :pending}

    TestChainNode.land!(hash, review, step, "0x1")
    assert Outcome.of(ChainClient, review, step, hash) == {:ok, :confirmed}
  end

  test "a request the node never answers is counted, by method and chain" do
    nodes = Application.fetch_env!(:keyfleet, :chain_nodes)
    on_exit(fn -> Application.put_env(:keyfleet, :chain_nodes, nodes) end)
    Application.put_env(:keyfleet, :chain_nodes, Map.put(nodes, 7, "http://127.0.0.1:1"))

    handler = "chain-failure-#{inspect(self())}"
    test = self()

    :telemetry.attach(
      handler,
      [:keyfleet, :chain, :failure],
      fn _event, measurements, metadata, _config -> send(test, {measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, %Req.TransportError{}} =
             ChainClient.receipt(%{chain_id: 7}, "0x" <> String.duplicate("6", 64))

    assert_received {%{count: 1},
                     %{
                       method: "eth_getTransactionReceipt",
                       class: "transport",
                       chain_id: 7,
                       scope: "wallet"
                     }}
  end
end

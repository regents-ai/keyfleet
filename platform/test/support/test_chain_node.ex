defmodule Keyfleet.TestChainNode do
  @moduledoc """
  The node the test server reads Base through (`:chain_nodes`) for the steps
  a page's wallet sent. It answers `eth_getTransactionByHash` and
  `eth_getTransactionReceipt` with what a test landed, and `null` for any
  other hash, as a node does before it hears of a transaction.

  One node serves every test and the browser test server alike, and keeps
  what was landed until it stops, so each test lands under hashes of its own.
  """

  import Plug.Conn

  @behaviour Plug

  @table __MODULE__

  @doc """
  Starts the node on a free loopback port, in a process of its own that
  lives as long as the node does, and points `:chain_nodes` for Base at it.
  Returns its URL.
  """
  def start! do
    caller = self()

    spawn(fn ->
      :ets.new(@table, [:named_table, :public])

      {:ok, server} =
        Bandit.start_link(plug: __MODULE__, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

      {:ok, {_address, port}} = ThousandIsland.listener_info(server)
      send(caller, {:node, "http://127.0.0.1:#{port}"})
      Process.sleep(:infinity)
    end)

    receive do
      {:node, url} ->
        Application.put_env(:keyfleet, :chain_nodes, %{8453 => url})
        url
    end
  end

  @doc """
  The transaction `hash` is included, and the node answers it with
  `transaction` and `receipt` from now on.
  """
  def land(hash, transaction, receipt),
    do: :ets.insert(@table, {String.downcase(hash), transaction, receipt})

  @doc """
  The step `step` of `review`, sent as the review built it, is included
  under `hash` with the receipt `status`: `"0x1"` did what it asked, `"0x0"`
  was refused.
  """
  def land!(hash, review, step, status) do
    land(
      hash,
      %{
        "chainId" => "0x" <> Integer.to_string(review.chain.chain_id, 16),
        "from" => review.signer,
        "to" => step.to,
        "input" => step.data,
        "value" => step.value
      },
      %{"status" => status}
    )
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    %{"id" => id, "method" => method, "params" => [hash]} = Jason.decode!(body)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{jsonrpc: "2.0", id: id, result: answer(method, hash)}))
  end

  defp answer("eth_getTransactionByHash", hash), do: landed(hash, 1)
  defp answer("eth_getTransactionReceipt", hash), do: landed(hash, 2)

  defp landed(hash, field) do
    case :ets.lookup(@table, String.downcase(hash)) do
      [landed] -> elem(landed, field)
      [] -> nil
    end
  end
end

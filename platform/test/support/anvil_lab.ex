defmodule Keyfleet.AnvilLab do
  @moduledoc """
  A short-lived plain anvil for the external anvil tests, with the fleet
  `contracts/script/AnvilLab.s.sol` puts on it.

  The anvil listens on a free loopback port, keeps no state history on
  disk, starts at a base fee of 0.01 gwei, and is killed when the test that
  started it exits. For that test only, the site's nodes are pointed at it.
  The lab is sent from an account anvil has unlocked, so no key is handed
  to Forge, one transaction at a time: sent all at once, anvil has been
  seen to drop one and leave the rest queued behind the gap.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  @base_fee "10000000"
  # Anvil's own chain id.
  @chain_id 31_337
  # The fields of the script's `Lab` struct, in order.
  @lab [
    :keys,
    :factory,
    :manager,
    :rewards,
    :shards,
    :votes,
    :treasury,
    :staking,
    :usdc,
    :regent,
    :club_claims
  ]
  # AnvilLab.OPENING: how long after the lab's first step Classic #1's sales open.
  @opening 60

  @doc """
  Starts an anvil, waits until it answers, and points the fleet reader's node
  and the site's node for the lab chain (`:chain_nodes`) at it. Returns its URL.
  """
  def start! do
    port = free_port()
    url = "http://127.0.0.1:#{port}"

    anvil =
      Port.open({:spawn_executable, System.find_executable("anvil")}, [
        :binary,
        args:
          ["--port", "#{port}", "--silent", "--prune-history"] ++
            ["--block-base-fee-per-gas", @base_fee]
      ])

    {:os_pid, os_pid} = Port.info(anvil, :os_pid)
    chain = Application.fetch_env!(:keyfleet, Keyfleet.Chain)
    nodes = Application.fetch_env!(:keyfleet, :chain_nodes)

    on_exit(fn ->
      System.cmd("kill", ["#{os_pid}"])
      Application.put_env(:keyfleet, Keyfleet.Chain, chain)
      Application.put_env(:keyfleet, :chain_nodes, nodes)
    end)

    answering!(url, 150)
    Application.put_env(:keyfleet, Keyfleet.Chain, Keyword.put(chain, :rpc_url, url))
    Application.put_env(:keyfleet, :chain_nodes, Map.put(nodes, @chain_id, url))
    url
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp answering!(url, tries_left) do
    case Req.post(url, json: rpc_body("eth_chainId", []), retry: false) do
      {:ok, %{status: 200}} ->
        :ok

      _no_answer when tries_left > 1 ->
        Process.sleep(100)
        answering!(url, tries_left - 1)

      _no_answer ->
        flunk("anvil did not start answering")
    end
  end

  @doc "Sends `method` with `params` to the anvil at `url`, and returns its result."
  def rpc!(url, method, params \\ []) do
    case Req.post!(url, json: rpc_body(method, params), retry: false).body do
      %{"result" => result} -> result
      %{"error" => error} -> flunk("anvil refused #{method}: #{inspect(error)}")
    end
  end

  @doc """
  The receipt of the transaction `hash`, once the anvil at `url` has
  included it: anvil answers a send before its block is written.
  """
  def receipt!(url, hash, tries_left \\ 50) do
    case rpc!(url, "eth_getTransactionReceipt", [hash]) do
      nil when tries_left > 1 ->
        Process.sleep(100)
        receipt!(url, hash, tries_left - 1)

      nil ->
        flunk("anvil never included #{hash}")

      receipt ->
        receipt
    end
  end

  defp rpc_body(method, params), do: %{jsonrpc: "2.0", id: 1, method: method, params: params}

  @doc "A JSON-RPC quantity as a number."
  def number("0x" <> hex), do: String.to_integer(hex, 16)

  @doc """
  Builds the lab on the anvil at `url` with `contracts/script/AnvilLab.s.sol`,
  sent from `sender`, an account anvil has unlocked, and returns where the
  script says its contracts are, by the names of its `Lab` struct, in lower
  case. Between the lab's two steps the anvil's clock moves past Classic #1's
  sales opening.
  """
  def lab!(url, sender) do
    "(" <> addresses =
      url
      |> forge!(sender, [])
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case Jason.decode(line) do
          {:ok, %{"returns" => %{"lab" => %{"value" => value}}}} -> value
          _other -> nil
        end
      end)

    addresses = addresses |> String.trim_trailing(")") |> String.split(", ")

    lab =
      Map.new(Enum.zip(@lab, addresses), fn {name, address} ->
        {name, String.downcase(address)}
      end)

    rpc!(url, "evm_increaseTime", [@opening])
    rpc!(url, "evm_mine")
    forge!(url, sender, ["--sig", "sell(address)", lab.manager])
    lab
  end

  defp forge!(url, sender, args) do
    {output, status} =
      System.cmd(
        "forge",
        ["script", "script/AnvilLab.s.sol:AnvilLab" | args] ++
          ["--rpc-url", url, "--broadcast", "--slow", "--unlocked", "--sender", sender, "--json"],
        cd: Path.expand("../../../contracts", __DIR__),
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("AnvilLab failed:\n#{String.slice(output, -4_000, 4_000)}")
    output
  end
end

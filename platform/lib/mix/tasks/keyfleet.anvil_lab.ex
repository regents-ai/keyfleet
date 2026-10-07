defmodule Mix.Tasks.Keyfleet.AnvilLab do
  @shortdoc "Puts the lab fleet on the anvil lab's chain and gives a wallet its first two keys"

  @moduledoc """
  Puts one fleet on the anvil lab's chain, the node `KEYFLEET_LAB` names, with
  `contracts/script/AnvilLab.s.sol`, and records it in the lab's database as
  the Classic fleet's deployment, the way a release records a fleet
  (`mix keyfleet.seed_deployment`). `scripts/anvil-lab.sh` runs it, and
  `docs/anvil-lab.md` says what the lab holds.

      mix keyfleet.anvil_lab 0xYourWallet

  On every run the wallet named is given keys 1 and 2, moved from whoever
  holds them, and at least 1 ETH and 10,000 of the lab's USDC, so the lab can
  be tried with any wallet. Once the fleet is recorded, a run puts nothing new
  on the chain. A lab database whose fleet the node doesn't hold, because the
  lab's chain was started again from nothing, is refused.
  """

  use Mix.Task

  alias RegentChain.Call

  @requirements ["app.start"]

  @contracts Path.expand("../../../../contracts", __DIR__)
  @script "script/AnvilLab.s.sol:AnvilLab"
  @fleet_id "fleet_tech_classic"
  # Anvil's first account, which anvil keeps unlocked, so no key is read.
  @sender "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @native "0x0000000000000000000000000000000000000000"
  @eth 1_000_000_000_000_000_000
  @usdc 10_000_000_000

  @impl Mix.Task
  def run([holder]) do
    unless Mix.env() == :dev, do: Mix.raise("The anvil lab runs in development only.")

    unless Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, holder),
      do: Mix.raise("Name your wallet as 0x and 40 letters and numbers.")

    url = System.fetch_env!("KEYFLEET_LAB")
    holder = String.downcase(holder)
    Keyfleet.Fleets.bootstrap_catalog!()

    fleet =
      case Keyfleet.Fleets.get_fleet!(@fleet_id) do
        %{contract_address: nil} -> record!(url)
        %{contract_address: _address} = fleet -> on_chain!(url, fleet)
      end

    give!(url, fleet, holder)
    Mix.shell().info("#{holder} holds keys 1 and 2, and at least 1 ETH and 10,000 USDC.")
  end

  def run(_args), do: Mix.raise("Usage: mix keyfleet.anvil_lab <your wallet address>")

  @doc """
  Runs `AnvilLab.s.sol` on the anvil at `url`, sent from `sender`, an account
  anvil has unlocked, which then holds the fleet's first two keys. Returns
  where the fleet's contracts and their stand-ins are, by the names the
  script returns them under, each address in lowercase.
  """
  def deploy!(url, sender) do
    {output, status} =
      System.cmd(
        "forge",
        ["script", @script, "--rpc-url", url, "--broadcast", "--slow", "--unlocked"] ++
          ["--sender", sender, "--json"],
        cd: @contracts,
        stderr_to_stdout: true
      )

    if status != 0, do: raise("AnvilLab failed:\n#{String.slice(output, -4_000, 4_000)}")

    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"returns" => returns}} -> returns
        _other -> nil
      end
    end)
    |> Map.new(fn {name, %{"value" => address}} -> {name, String.downcase(address)} end)
  end

  defp record!(url) do
    first_block = number(rpc!(url, "eth_blockNumber", [])) + 1
    lab = deploy!(url, @sender)

    manifest = %{
      "chainId" => number(rpc!(url, "eth_chainId", [])),
      "deploymentBlock" => first_block,
      "usdc" => lab["usdcToken"],
      "regent" => lab["regentToken"],
      "regentStaking" => lab["staking"],
      "autolaunchFactory" => lab["autolaunchFactory"],
      "splitAssets" => [@native, lab["regentToken"], lab["usdcToken"]],
      "traitTableHash" => view!(url, lab["fleet"], "TRAIT_TABLE_HASH()", []),
      "fleet" => %{
        "slot" => "classic",
        "address" => lab["fleet"],
        "rewards" => lab["rewards"],
        "votes" => lab["votes"],
        "treasury" => lab["treasury"],
        "shards" => lab["shards"]
      }
    }

    path = Path.join([File.cwd!(), "tmp", "anvil-lab", "classic.deployed.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(manifest, pretty: true))
    Keyfleet.Release.seed_deployment!(path)
    Keyfleet.Fleets.get_fleet!(@fleet_id)
  end

  defp on_chain!(url, fleet) do
    if rpc!(url, "eth_getCode", [fleet.contract_address, "latest"]) == "0x" do
      Mix.raise("""
      The lab database records a fleet at #{fleet.contract_address}, which the lab chain
      doesn't hold: the chain was started again from nothing. docs/anvil-lab.md says how
      to start the lab over.
      """)
    end

    fleet
  end

  defp give!(url, fleet, holder) do
    for id <- [1, 2] do
      case address(view!(url, fleet.contract_address, "ownerOf(uint256)", [id])) do
        ^holder ->
          :ok

        owner ->
          rpc!(url, "anvil_impersonateAccount", [owner])
          call = Call.encode("transferFrom(address,address,uint256)", [owner, holder, id])
          send!(url, owner, fleet.contract_address, call)
          rpc!(url, "anvil_stopImpersonatingAccount", [owner])
      end
    end

    if number(rpc!(url, "eth_getBalance", [holder, "latest"])) < @eth do
      rpc!(url, "anvil_setBalance", [holder, "0x" <> Integer.to_string(@eth, 16)])
    end

    case number(view!(url, fleet.usdc_address, "balanceOf(address)", [holder])) do
      held when held >= @usdc ->
        :ok

      held ->
        send!(url, @sender, fleet.usdc_address, Call.encode("mint(uint256)", [@usdc - held]))
        transfer = Call.encode("transfer(address,uint256)", [holder, @usdc - held])
        send!(url, @sender, fleet.usdc_address, transfer)
    end
  end

  defp send!(url, from, to, data) do
    hash = rpc!(url, "eth_sendTransaction", [%{from: from, to: to, data: data}])

    case receipt!(url, hash, 50) do
      %{"status" => "0x1"} -> :ok
      _reverted -> Mix.raise("The lab chain refused a transaction to #{to}.")
    end
  end

  defp receipt!(url, hash, tries_left) do
    case rpc!(url, "eth_getTransactionReceipt", [hash]) do
      nil when tries_left > 1 ->
        Process.sleep(200)
        receipt!(url, hash, tries_left - 1)

      nil ->
        Mix.raise("The lab chain never included #{hash}.")

      receipt ->
        receipt
    end
  end

  defp view!(url, to, signature, arguments),
    do: rpc!(url, "eth_call", [%{to: to, data: Call.encode(signature, arguments)}, "latest"])

  defp rpc!(url, method, params) do
    body = %{jsonrpc: "2.0", id: 1, method: method, params: params}

    case Req.post!(url, json: body, retry: false).body do
      %{"result" => result} -> result
      %{"error" => error} -> Mix.raise("The lab chain refused #{method}: #{inspect(error)}")
    end
  end

  defp number("0x" <> digits), do: String.to_integer(digits, 16)

  defp address("0x" <> <<_padding::binary-size(24), address::binary-size(40)>>),
    do: "0x" <> address
end

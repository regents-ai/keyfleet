defmodule KeyFleet.Keeper.Runner do
  @moduledoc """
  The keeper's one process, and the only one on the site that sends
  transactions. It reads its key once, as it starts, and keeps it inside
  its `KeyFleet.Keeper.Sender`; its status shows the wallet's address and
  never the key.

  It first learns the node's chain, whether it is stopped, and settles
  whatever it left waiting before, retrying every 30 seconds while the node
  or the database cannot answer. `KeyFleet.Keeper.Supervisor` starts it.
  """
  use GenServer

  require Logger

  alias KeyFleet.Keeper.{Node, Sender, Wallet}

  @retry_after 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The runtime configuration refuses a malformed key before anything starts.
    {:ok, wallet} = Wallet.new(Application.fetch_env!(:keyfleet, KeyFleet.Keeper)[:private_key])
    {:ok, Sender.new(wallet, Node.configured()), {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, sender), do: start(sender)

  @impl true
  def handle_info(:start, sender), do: start(sender)

  @impl true
  def format_status(%{state: sender} = status), do: %{status | state: Sender.redact(sender)}

  defp start(sender) do
    case Sender.start(sender) do
      {:ok, sender} ->
        announce(sender)
        {:noreply, sender}

      {:error, reason} ->
        Logger.warning(
          "Keeper could not start, trying again in #{div(@retry_after, 1_000)} s: #{inspect(reason)}"
        )

        Process.send_after(self(), :start, @retry_after)
        {:noreply, sender}
    end
  end

  defp announce(%{stopped: nil} = sender) do
    Logger.info("Keeper on: sending from #{sender.wallet.address} on chain #{sender.chain_id}.")
  end

  defp announce(sender) do
    Logger.warning(
      "Keeper stopped (#{sender.stopped}): it sends nothing from #{sender.wallet.address} until bin/keeper-resume is run and the site restarted."
    )
  end
end

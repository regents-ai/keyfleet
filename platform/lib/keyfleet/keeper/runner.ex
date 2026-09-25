defmodule Keyfleet.Keeper.Runner do
  @moduledoc """
  The keeper's one process, and the only one on the site that sends
  transactions. It reads its key once, as it starts, and keeps it inside
  its `Keyfleet.Keeper.Sender`; its status shows the wallet's address and
  never the key.

  It first learns the node's chain, whether it is stopped, which pauses
  are still in force, and settles whatever it left waiting before, retrying
  every 30 seconds while the node or the database cannot answer. Then, unless it is stopped, it runs the
  reveal job (`Keyfleet.Keeper.Reveals`) 30 seconds after each round ends,
  and the income job (`Keyfleet.Keeper.Income`) five minutes after it
  starts and an hour after each round ends. A round that leaves the keeper
  stopped schedules nothing more. `Keyfleet.Keeper.Supervisor` starts it.
  """
  use GenServer

  require Logger

  alias Keyfleet.Keeper.{Income, Node, Reveals, Sender, Wallet}

  @retry_after 30_000
  @reveal_every 30_000
  @income_first 300_000
  @income_every 3_600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The runtime configuration refuses a malformed key before anything starts.
    {:ok, wallet} = Wallet.new(Application.fetch_env!(:keyfleet, Keyfleet.Keeper)[:private_key])

    {:ok,
     %{
       sender: Sender.new(wallet, Node.configured()),
       reveals: nil,
       income: Income.new()
     }, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: start(state)

  @impl true
  def handle_info(:start, state), do: start(state)

  def handle_info(:reveal, %{sender: sender, reveals: reveals} = state) do
    {sender, reveals} = Reveals.run(sender, reveals)
    after_round(sender, :reveal, @reveal_every)
    {:noreply, %{state | sender: sender, reveals: reveals}}
  end

  def handle_info(:income, %{sender: sender, income: income} = state) do
    {sender, income} = Income.run(sender, income)
    after_round(sender, :income, @income_every)
    {:noreply, %{state | sender: sender, income: income}}
  end

  @impl true
  def format_status(%{state: %{sender: sender} = state} = status),
    do: %{status | state: %{state | sender: Sender.redact(sender)}}

  defp start(%{sender: sender} = state) do
    with {:ok, sender} <- Sender.start(sender),
         {:ok, reveals} <- Reveals.start(sender) do
      announce(sender)
      after_round(sender, :reveal, @reveal_every)
      after_round(sender, :income, @income_first)
      {:noreply, %{state | sender: sender, reveals: reveals}}
    else
      {:error, reason} ->
        Logger.warning(
          "Keeper could not start, trying again in #{div(@retry_after, 1_000)} s: #{inspect(reason)}"
        )

        Process.send_after(self(), :start, @retry_after)
        {:noreply, state}
    end
  end

  # A stopped keeper runs no more rounds; its alert has said why.
  defp after_round(%{stopped: nil}, job, delay), do: Process.send_after(self(), job, delay)
  defp after_round(_stopped, _job, _delay), do: :ok

  defp announce(%{stopped: nil} = sender) do
    Logger.info("Keeper on: sending from #{sender.wallet.address} on chain #{sender.chain_id}.")
  end

  defp announce(sender) do
    Logger.warning(
      "Keeper stopped (#{sender.stopped}): it sends nothing from #{sender.wallet.address} until bin/keeper-resume is run and the site restarted."
    )
  end
end

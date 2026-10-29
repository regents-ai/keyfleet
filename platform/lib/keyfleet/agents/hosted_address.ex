defmodule Keyfleet.Agents.HostedAddress do
  @moduledoc """
  The wallet of each account's hosted identity: the one identity an app such as
  Claude keeps when its person connects it here, held by the sign-in server.
  It never changes for an account on this site, so the server is asked once
  per account on each machine (`RegentMCPAgents.address/1`) and the answer is
  kept here; every later call from the app reads it from this table.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The wallet of the identity the connection's account keeps here."
  @spec fetch(map()) :: {:ok, String.t()} | {:error, term()}
  def fetch(%{subject: subject} = principal) do
    case :ets.lookup(@table, subject) do
      [{^subject, address}] -> {:ok, address}
      [] -> ask(principal)
    end
  end

  # Two calls that miss at once both ask; the server gives both the same wallet.
  defp ask(%{subject: subject} = principal) do
    with {:ok, address} <- RegentMCPAgents.address(principal) do
      :ets.insert(@table, {subject, address})
      {:ok, address}
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end

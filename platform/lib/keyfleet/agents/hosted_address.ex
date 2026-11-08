defmodule Keyfleet.Agents.HostedAddress do
  @moduledoc """
  The wallet of each connected app's hosted identity: the identity an app such
  as Claude keeps for its person's account here, held by the sign-in server.
  Each app the person connects has its own. It never changes for an account and
  app on this site, so the server is asked once per account and app on each
  machine (`RegentMCPAgents.address/1`) and the answer is kept here by the
  account and the app's client together; every later call from that app reads
  it from this table.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The wallet of the identity the connection's app keeps for its account here."
  @spec fetch(map()) :: {:ok, String.t()} | {:error, term()}
  def fetch(%{subject: subject, client_id: client} = principal) do
    key = {subject, client}

    case :ets.lookup(@table, key) do
      [{^key, address}] -> {:ok, address}
      [] -> ask(principal, key)
    end
  end

  # Two calls that miss at once both ask; the server gives both the same wallet.
  defp ask(principal, key) do
    with {:ok, address} <- RegentMCPAgents.address(principal) do
      :ets.insert(@table, {key, address})
      {:ok, address}
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end

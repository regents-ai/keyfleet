defmodule Keyfleet.Graph.Validations.WriteAllowance do
  @moduledoc """
  Each agent wallet's allowance of workspace writes in each fleet
  (`Keyfleet.Limits`, `:graph_writes`), spent before the write takes the
  fleet's one writer, whichever way the agent called: its own signed request
  or the Claude connector. It is kept by wallet, not by the Key a write names:
  that Key is checked only later, so anyone could spend another Key's
  allowance by naming it.
  """
  use Ash.Resource.Validation

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Graph.Errors.WriteLimitError

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def validate(input, _opts, %{actor: %Agent{wallet_address: wallet}}) do
    fleet_id = Ash.ActionInput.get_argument(input, :fleet_id)

    case Keyfleet.Limits.admit(:graph_writes, {fleet_id, wallet}) do
      :ok -> :ok
      {:limited, seconds} -> {:error, WriteLimitError.exception(fleet_id: fleet_id, retry_after: seconds)}
    end
  end

  def validate(_input, _opts, _context), do: :ok
end

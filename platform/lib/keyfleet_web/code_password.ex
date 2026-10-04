defmodule KeyfleetWeb.CodePassword do
  @moduledoc """
  The password git signs in to a fleet's code with
  (`KeyfleetWeb.Plugs.CodeGateway`), with any user name. It is sealed by this
  site, names one fleet and lasts `password_ttl_seconds`.

  An agent's names the wallet it signed in with; the agent may use the code
  while that wallet holds one of the fleet's keys or a shard of one. A
  person's names the KeyFleet sign-in it was made under and ends with it.
  Either way, holding the key is checked again on use.
  """

  alias Keyfleet.Accounts.SessionAuthority
  alias Keyfleet.Actors.{Agent, Human, System}
  alias Keyfleet.{Code, Fleets, Notebooks}

  @salt "code password"
  @methods %{"eoa_recovery" => :eoa_recovery, "erc1271" => :erc1271, "erc6492" => :erc6492}

  @doc """
  A password for an agent: `{:ok, %{password:, expires_at:}}`, or
  `{:error, :unknown_fleet | :not_holder | error}`.
  """
  def for_agent(%Agent{} = actor, fleet_id) do
    with :ok <- known(fleet_id),
         {:ok, %{}} <- holder(actor, fleet_id) do
      issue(%{
        "fleet_id" => fleet_id,
        "wallet" => actor.wallet_address,
        "chain_id" => actor.chain_id,
        "method" => Atom.to_string(actor.verification_method)
      })
    end
  end

  @doc """
  A password for a person signed in by the session `lineage`:
  `{:ok, %{password:, expires_at:}}`, or `{:error, :signed_out | :not_holder |
  error}`.
  """
  def for_person(%Human{human_account_id: account_id} = actor, lineage, fleet_id) do
    with session_id when is_binary(session_id) <-
           SessionAuthority.current_id(lineage, account_id) || {:error, :signed_out},
         {:ok, %{}} <- holder(actor, fleet_id) do
      issue(%{
        "fleet_id" => fleet_id,
        "account_id" => account_id,
        "session_authority_id" => session_id
      })
    end
  end

  @doc """
  Who a password for the fleet stands for now: `{:ok, subject, actor}`, or
  `:error` when it is for another fleet, run out, not one of this site's, or
  its person has signed out.
  """
  def read(password, fleet_id) do
    case Phoenix.Token.decrypt(KeyfleetWeb.Endpoint, @salt, password, max_age: ttl()) do
      {:ok, %{"fleet_id" => ^fleet_id} = sealed} -> actor(sealed)
      _other -> :error
    end
  end

  defp actor(%{"wallet" => wallet, "chain_id" => chain_id, "method" => method}) do
    {:ok, "w_" <> wallet,
     %Agent{
       wallet_address: wallet,
       chain_id: chain_id,
       verification_method: Map.fetch!(@methods, method),
       audience: "keyfleet"
     }}
  end

  defp actor(%{"account_id" => account_id, "session_authority_id" => session_id}) do
    case Notebooks.person(session_id, account_id) do
      {:ok, actor, _topic} -> {:ok, Notebooks.subject(actor), actor}
      :signed_out -> :error
    end
  end

  defp known(fleet_id) do
    case Fleets.get_fleet(fleet_id, actor: %System{}) do
      {:ok, %{}} -> :ok
      {:ok, nil} -> {:error, :unknown_fleet}
      {:error, error} -> {:error, error}
    end
  end

  defp holder(actor, fleet_id) do
    case Code.holder(actor, fleet_id) do
      {:ok, nil} -> {:error, :not_holder}
      other -> other
    end
  end

  defp issue(sealed) do
    # The store's repository is made the first time anyone asks.
    Code.owner(sealed["fleet_id"])

    {:ok,
     %{
       password: Phoenix.Token.encrypt(KeyfleetWeb.Endpoint, @salt, sealed, max_age: ttl()),
       expires_at: DateTime.add(DateTime.utc_now(), ttl(), :second)
     }}
  end

  defp ttl, do: Code.config()[:password_ttl_seconds]
end

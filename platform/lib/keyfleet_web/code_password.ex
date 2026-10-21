defmodule KeyfleetWeb.CodePassword do
  @moduledoc """
  The password a person's git signs in to a fleet's code with
  (`KeyfleetWeb.Plugs.CodeGateway`), with any user name. It is sealed by this
  site, names one fleet and the Keyfleet sign-in it was made under, and lasts
  `password_ttl_seconds` or until that sign-in ends. The sign-in and holding
  the key are checked again on every use. Agents have no password: each of
  their requests carries their own signature.
  """

  alias Keyfleet.Accounts.SessionAuthority
  alias Keyfleet.Actors.Human
  alias Keyfleet.{Code, Notebooks}

  @salt "code password"

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
  its person's sign-in has ended.
  """
  def read(password, fleet_id) do
    case Phoenix.Token.decrypt(KeyfleetWeb.Endpoint, @salt, password, max_age: ttl()) do
      {:ok, %{"fleet_id" => ^fleet_id} = sealed} -> actor(sealed)
      _other -> :error
    end
  end

  defp actor(%{"account_id" => account_id, "session_authority_id" => session_id}) do
    case Notebooks.person(session_id, account_id) do
      {:ok, actor, _topic, _ends_at} -> {:ok, Notebooks.subject(actor), actor}
      :signed_out -> :error
    end
  end

  defp holder(actor, fleet_id) do
    case Code.holder(actor, fleet_id) do
      {:ok, nil} -> {:error, :not_holder}
      other -> other
    end
  end

  # `expires_at` is when the password stops working: `password_ttl_seconds`
  # from now, sooner if the person signs out.
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

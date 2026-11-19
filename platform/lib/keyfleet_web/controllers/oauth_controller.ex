defmodule KeyfleetWeb.OAuthController do
  @moduledoc "Boruta protocol routes and consent under the verified browser session and CSRF."
  use KeyfleetWeb, :controller

  alias Keyfleet.Accounts.RequestRateLimiter

  # Every address under /oauth spends the per-address request budget
  # (`KeyfleetWeb.Endpoint`). Registering an app, which writes its row, also
  # has 30 a minute of its own for each address.
  plug :rate_limit when action == :register

  for action <- [:resource_metadata, :server_metadata, :register, :token, :revoke] do
    def unquote(action)(conn, _params), do: RegentOAuth.Protocol.call(conn, unquote(action))
  end

  # While the connector is off, consent and Connected apps are not found, as
  # the protocol routes are.
  for action <- [:authorize, :approve, :connections, :revoke_connection] do
    def unquote(action)(conn, _params) do
      if Keyfleet.OAuth.enabled?(),
        do: apply(RegentOAuth.Consent, unquote(action), [conn]),
        else: RegentOAuth.Protocol.json(conn, 404, %{error: "not_found"})
    end
  end

  defp rate_limit(conn, _opts) do
    {address, _source} = KeyfleetWeb.ClientAddress.key(conn)

    case RequestRateLimiter.admit({:oauth, :register, address}, 30, 60) do
      {:ok, _} ->
        conn

      {:error, :rate_limited, _} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> RegentOAuth.Protocol.json(429, %{error: "rate_limited"})
        |> halt()
    end
  end
end

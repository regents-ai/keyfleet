defmodule Keyfleet.SiwaBroker do
  @moduledoc "Product configuration and transport for the shared SIWA broker."
  @behaviour Siwa.AgentAuthPlug.Client

  @impl true
  def verify_http_request(payload, audience: "keyfleet") do
    case origin(Application.get_env(:keyfleet, :siwa_broker_url)) do
      {:ok, url} ->
        Siwa.AgentAuthPlug.BrokerClient.verify_http_request(payload,
          http: __MODULE__,
          base_url: url,
          audience: "keyfleet",
          connect_timeout_ms: 3000,
          receive_timeout_ms: 5000
        )

      :error ->
        {:error, %{reason: :broker_unavailable}}
    end
  end

  # Verification spends replay state. Never retry or follow a redirect.
  def request(opts), do: Req.request(Keyword.merge(opts, retry: false, redirect: false))

  defp origin(url) when is_binary(url) do
    with {:ok, uri} <- URI.new(url),
         true <- uri.host not in [nil, ""] and uri.userinfo == nil,
         true <- uri.path in [nil, "", "/"] and uri.query == nil and uri.fragment == nil,
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <-
           uri.scheme == "https" or
             (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"]) do
      {:ok, url}
    else
      _ -> :error
    end
  end

  defp origin(_), do: :error
end
